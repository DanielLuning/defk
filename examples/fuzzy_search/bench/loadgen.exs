# Load generator, run in its OWN VM so it does not compete for the server's schedulers:
#
#   elixir --erl "+S 2" bench/loadgen.exs [port] [seconds_per_phase] [concurrency]
#
# For each backend: (1) one client to measure per-request latency, then (2) a
# saturating load while a prober hits /health every 5ms. A blocked scheduler
# shows up as /health latency.

defmodule HTTP do
  # minimal keep-alive HTTP/1.1 client: just enough for GET + Content-Length
  def connect(port) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :http_bin, nodelay: true])
    s
  end

  def get(s, path) do
    :ok = :gen_tcp.send(s, ["GET ", path, " HTTP/1.1\r\nhost: localhost\r\n\r\n"])
    {:ok, {:http_response, _, status, _}} = :gen_tcp.recv(s, 0)
    len = headers(s, 0)
    :ok = :inet.setopts(s, packet: :raw)
    {:ok, body} = if len > 0, do: :gen_tcp.recv(s, len), else: {:ok, ""}
    :ok = :inet.setopts(s, packet: :http_bin)
    {status, body}
  end

  defp headers(s, len) do
    case :gen_tcp.recv(s, 0) do
      {:ok, :http_eoh} -> len
      {:ok, {:http_header, _, :"Content-Length", _, v}} -> headers(s, String.to_integer(v))
      {:ok, {:http_header, _, _, _, _}} -> headers(s, len)
    end
  end
end

defmodule Load do
  def queries(n) do
    :rand.seed(:exsss, {7, 7, 7})

    words =
      "/usr/share/dict/words"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&(&1 =~ ~r/^[a-z]{4,}$/))
      |> List.to_tuple()

    for _ <- 1..n, do: typo(elem(words, :rand.uniform(tuple_size(words)) - 1))
  end

  # one or two random edits of a real word
  defp typo(w) do
    Enum.reduce(1..Enum.random(1..2), String.to_charlist(w), fn _, w ->
      i = Enum.random(0..(length(w) - 1))

      case Enum.random([:replace, :delete, :insert]) do
        :replace -> List.replace_at(w, i, Enum.random(?a..?z))
        :delete when length(w) > 1 -> List.delete_at(w, i)
        _ -> List.insert_at(w, i, Enum.random(?a..?z))
      end
    end)
    |> to_string()
  end

  # `clients` connections, each looping requests until `deadline`; returns latencies in us
  def run(port, backend, queries, clients, deadline) do
    qs = List.to_tuple(queries)

    1..clients
    |> Task.async_stream(
      fn c ->
        s = HTTP.connect(port)
        loop(s, backend, qs, c, deadline, [])
      end,
      max_concurrency: clients,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, lat} -> lat end)
  end

  defp loop(s, backend, qs, i, deadline, acc) do
    if now() >= deadline do
      :gen_tcp.close(s)
      acc
    else
      q = elem(qs, rem(i, tuple_size(qs)))
      t = now()
      {200, _} = HTTP.get(s, "/search?q=#{q}&backend=#{backend}")
      loop(s, backend, qs, i + 7, deadline, [now() - t | acc])
    end
  end

  def probe(port, deadline) do
    s = HTTP.connect(port)
    probe_loop(s, deadline, [])
  end

  defp probe_loop(s, deadline, acc) do
    if now() >= deadline do
      acc
    else
      t = now()
      {200, "ok"} = HTTP.get(s, "/health")
      lat = now() - t
      Process.sleep(5)
      probe_loop(s, deadline, [lat | acc])
    end
  end

  def now, do: System.monotonic_time(:microsecond)

  def pct(list, p) do
    sorted = Enum.sort(list)
    Enum.at(sorted, min(length(sorted) - 1, trunc(p / 100 * length(sorted))))
  end
end

[port, secs, conc] =
  case System.argv() do
    [p, s, c] -> [String.to_integer(p), String.to_integer(s), String.to_integer(c)]
    [p, s] -> [String.to_integer(p), String.to_integer(s), :erlang.system_info(:logical_processors) * 2]
    [p] -> [String.to_integer(p), 8, :erlang.system_info(:logical_processors) * 2]
    [] -> [4000, 8, :erlang.system_info(:logical_processors) * 2]
  end

queries = Load.queries(500)
ms = fn us -> :erlang.float_to_binary(us / 1000, decimals: 1) end
IO.puts("fuzzy_search load test: port #{port}, #{secs}s per phase, #{conc} concurrent clients")
IO.puts("queries like: #{Enum.take(queries, 4) |> Enum.join(", ")}\n")

IO.puts(
  String.pad_trailing("backend", 10) <>
    String.pad_leading("1 client p50", 14) <>
    String.pad_leading("req/s", 9) <>
    String.pad_leading("p50", 9) <>
    String.pad_leading("p99", 9) <>
    String.pad_leading("health p50", 12) <>
    String.pad_leading("p99", 9) <>
    String.pad_leading("max", 9)
)

for backend <- ~w(elixir defk blocking) do
  # warm up connections, code and caches
  Load.run(port, backend, queries, 2, Load.now() + 500_000)

  single = Load.run(port, backend, queries, 1, Load.now() + secs * 1_000_000)

  deadline = Load.now() + secs * 1_000_000
  prober = Task.async(fn -> Load.probe(port, deadline) end)
  loaded = Load.run(port, backend, queries, conc, deadline)
  health = Task.await(prober, :infinity)

  IO.puts(
    String.pad_trailing(backend, 10) <>
      String.pad_leading(ms.(Load.pct(single, 50)) <> " ms", 14) <>
      String.pad_leading(:erlang.float_to_binary(length(loaded) / secs, decimals: 1), 9) <>
      String.pad_leading(ms.(Load.pct(loaded, 50)), 9) <>
      String.pad_leading(ms.(Load.pct(loaded, 99)), 9) <>
      String.pad_leading(ms.(Load.pct(health, 50)), 12) <>
      String.pad_leading(ms.(Load.pct(health, 99)), 9) <>
      String.pad_leading(ms.(Enum.max(health)), 9)
  )
end

IO.puts("\nlatencies in ms; health = GET /health every 5ms while the server is saturated")
