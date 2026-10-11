# defk-04y: the three examples whose parallel kernel chunks stay on few
# schedulers (defk-8qs), under each slice treatment of bench/adaptive_slice.exs
# (today / fixed50 / adaptive / gap), interleaved, medians:
#   batched_levenshtein  234k words, 12 chunks of lev_myers (Task.async_stream)
#   monte_carlo_rtp      1M spins, 48 chunks of simulate (Task.async_stream)
#   cosine_topk          100k x 384 f32 rows, 12 chunks of topk (Task.async_stream)
# The kernels (and the data builders) are read from the example files, so the
# examples' own Mix.install deps are not needed.
#
#   mix run bench/adaptive_slice_examples.exs [rounds]
#   ERL_FLAGS_LABEL="+swt very_low" elixir --erl "+swt very_low" -S mix run bench/adaptive_slice_examples.exs
take = fn file, mod ->
  lines = File.read!(Path.join("examples", file)) |> String.split("\n")
  {_, from} = Enum.split_while(lines, &(&1 != "defmodule #{mod} do"))
  {body, ["end" | _]} = Enum.split_while(from, &(&1 != "end"))
  Code.compile_string(Enum.join(body ++ ["end"], "\n"), file)
end

take.("batched_levenshtein.exs", "Lev.Kernels")
take.("monte_carlo_rtp.exs", "RTP.Kernels")
take.("monte_carlo_rtp.exs", "RTP")
take.("cosine_topk.exs", "Cosine.Kernels")
take.("cosine_topk.exs", "Cosine.Data")

defmodule SliceEx do
  # the NIF behind a kernel name (Elixir-mode modules rename it)
  def nif(mod, name) do
    if function_exported?(mod, :__defk_elixir__, 2), do: Defk.ElixirMode.native_name(name), else: name
  end

  def crowded?,
    do: :lists.nth(:erlang.system_info(:scheduler_id), :erlang.statistics(:run_queue_lengths)) > 0

  def call(:today, m, f, a), do: apply(m, nif(m, f), a)
  def call(:fixed50, m, f, a), do: apply(m, Defk.Compiler.sliced_name(nif(m, f)), a ++ [50, 0])
  def call(:gap, m, f, a), do: apply(m, Defk.Compiler.sliced_name(nif(m, f)), a ++ [-50, 1000])

  def call(:adaptive, m, f, a) do
    if crowded?(),
      do: apply(m, Defk.Compiler.sliced_name(nif(m, f)), a ++ [50, 1000]),
      else: apply(m, nif(m, f), a)
  end

  # runs fun.(item) per item under Task.async_stream (max_concurrency 12),
  # recording the scheduler before and after each call
  def stream(items, fun) do
    items
    |> Task.async_stream(
      fn x ->
        s0 = :erlang.system_info(:scheduler_id)
        r = fun.(x)
        {r, s0, :erlang.system_info(:scheduler_id)}
      end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, r} -> r end)
  end

  def med(l), do: Enum.at(Enum.sort(l), div(length(l), 2))
  def load, do: :os.cmd(~c"uptime") |> to_string() |> String.trim()
end

rounds = String.to_integer(List.first(System.argv()) || "9")
IO.puts("# examples  #{System.get_env("ERL_FLAGS_LABEL", "default VM")}  #{SliceEx.load()}")

# ---- batched_levenshtein: the example's index of the dictionary ----
words =
  File.read!("/usr/share/dict/words")
  |> String.split("\n")
  |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  |> Enum.filter(&(&1 =~ ~r/^[a-z]+$/))
  |> Enum.uniq()

{offs, total} = Enum.map_reduce(words, 0, fn w, at -> {at, at + byte_size(w)} end)
offs_b = for o <- offs ++ [total], into: <<>>, do: <<o::signed-64-native>>
:persistent_term.put(:lev, {IO.iodata_to_binary(words), offs_b, length(words)})
q = "accomodation"

lev = fn t ->
  {blob, offs_b, n} = :persistent_term.get(:lev)
  size = div(n + 11, 12)

  0..(n - 1)//size
  |> SliceEx.stream(fn lo -> SliceEx.call(t, Lev.Kernels, :lev_myers, [q, blob, offs_b, lo, min(n, lo + size)]) end)
end

# ---- monte_carlo_rtp: 1M spins in 48 seeded chunks ----
{reels_b, lines_b, pays_b} = RTP.packed(RTP.model())

rtp = fn t ->
  RTP.chunks(42, 1_000_000, 48)
  |> SliceEx.stream(fn {{%{type: :exsss}, [h | tl]}, spins} ->
    SliceEx.call(t, RTP.Kernels, :simulate, [reels_b, lines_b, pays_b, h, tl, spins])
  end)
end

# ---- cosine_topk: 100k x 384 in 12 chunks ----
:persistent_term.put(:cos, Cosine.Data.index(100_000, 1))
qv = Cosine.Data.query(2, 17)
norm = :math.sqrt(Enum.reduce(qv, 0.0, &(&1 * &1 + &2)))
qb = for x <- qv, into: <<>>, do: <<x / norm::float-64-native>>

cos = fn t ->
  m = :persistent_term.get(:cos)
  row = 384 * 4
  n = div(byte_size(m), row)
  per = div(n + 11, 12)

  0..11
  |> SliceEx.stream(fn c ->
    s = c * per
    SliceEx.call(t, Cosine.Kernels, :topk, [binary_part(m, s * row, min(per, n - s) * row), qb, 10, s])
  end)
end

# one call of the whole job, for scale
{blob, offs_all, n_words} = :persistent_term.get(:lev)
one = fn f -> SliceEx.med(for _ <- 1..11, do: elem(:timer.tc(f), 0)) / 1000 end

IO.puts(
  "# one call: lev_myers #{n_words} words #{one.(fn -> Lev.Kernels.__defk_native_lev_myers__(q, blob, offs_all, 0, n_words) end)} ms, " <>
    "simulate 1M #{one.(fn -> RTP.Kernels.simulate(reels_b, lines_b, pays_b, 1, 2, 1_000_000) end)} ms, " <>
    "topk 100k #{one.(fn -> Cosine.Kernels.__defk_native_topk__(:persistent_term.get(:cos), qb, 10, 0) end)} ms"
)

ts = [:today, :fixed50, :adaptive, :gap]

# results agree across treatments
for {name, job} <- [lev: lev, rtp: rtp, cos: cos] do
  [r | rs] = for t <- ts, do: Enum.map(job.(t), &elem(&1, 0))
  true = Enum.all?(rs, &(&1 == r)) || raise "#{name}: treatments disagree"
end

for {name, job} <- [
      {"batched_levenshtein 234k, 12 chunks", lev},
      {"monte_carlo_rtp 1M, 48 chunks", rtp},
      {"cosine_topk 100k, 12 chunks", cos}
    ] do
  for t <- ts, do: job.(t)

  res =
    for _ <- 1..rounds, t <- ts do
      {us, rs} = :timer.tc(fn -> job.(t) end)
      {t, us, rs |> Enum.flat_map(fn {_, a, b} -> [a, b] end) |> Enum.uniq() |> length()}
    end

  for t <- ts do
    rs = for {^t, us, s} <- res, do: {us, s}

    IO.puts(
      "#{String.pad_trailing(name, 36)} #{String.pad_trailing(to_string(t), 9)} wall #{Float.round(SliceEx.med(Enum.map(rs, &elem(&1, 0))) / 1000, 2)} ms  " <>
        "schedulers #{SliceEx.med(Enum.map(rs, &elem(&1, 1)))} #{rs |> Enum.map(&elem(&1, 1)) |> Enum.min_max() |> inspect()}"
    )
  end
end

IO.puts("# end  #{SliceEx.load()}")
