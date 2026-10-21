# The base cost of a kernel call, broken down by stage: the BEAM's NIF call
# (a bare NIF), argument decoding and result encoding, defk's entry (the
# sigsetjmp, the thread-local store pair, the frame fields, the slice init),
# a yielding kernel's clock read, and the generated Elixir function with its
# run-queue hint. The stages are measured on the generated C itself: the
# bench module's C is varied with string replacements, each variant built
# and loaded as its own library. docs/performance.md 5.1.
#
#   mix run bench/call_cost.exs [rounds]
#
# Each row is the median over the rounds of (ns per call over n calls) minus
# the empty loop, rounds interleaved. Other processes' CPU is printed before
# each block (Defk.Bench.other_cpu/0): at most one core counts as quiet.
rounds = String.to_integer(List.first(System.argv()) || "9")
n = 1_000_000

defmodule CallCost.Kernels do
  use Defk

  # the snapshot's kernel: two i64 in, one out, no loop: the NIF is the function
  defk add(a :: i64, b :: i64) :: i64 do
    a + b
  end

  # poor_tiny_calls' kernel: three f64 in, one out
  defk clamp(x :: f64, lo :: f64, hi :: f64) :: f64 do
    min(max(x, lo), hi)
  end

  # one array argument: the bind (inspect, alignment check)
  defk len(p :: [i64]) :: i64 do
    length(p)
  end

  # one loop, one trip: a yielding kernel, so its function reads the
  # run-queue hint and the entry reads the clock
  defk loop1(n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> acc + i
    end
  end
end

defmodule CallCost.NoAdaptive do
  use Defk, adaptive_slice: false

  # the same loop without the hint: the NIF is the function, the clock stays
  defk loop1(n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> acc + i
    end
  end
end

defmodule CallCost.NoYield do
  use Defk

  # the same loop with no safepoints: no clock, no resume preamble
  defk loop1(n :: i64) :: i64, yield: false do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> acc + i
    end
  end
end

defmodule CallCost.Elixir do
  def add(a, b), do: a + b
end

# ---- the floor: plain NIFs -------------------------------------------------

defmodule CallCost.Floor do
  @so Path.join(System.tmp_dir!(), "defk_call_cost_floor")
  @on_load :load
  def load do
    args =
      ~w(-O3 -std=gnu11 -fPIC -shared -I) ++
        [Defk.Build.erts_include(), "-o", @so <> ".so", "bench/call_cost_nif.c"] ++
        if(match?({:unix, :darwin}, :os.type()), do: ~w(-undefined dynamic_lookup), else: [])

    {_, 0} = System.cmd("cc", args)
    :erlang.load_nif(String.to_charlist(@so), 0)
  end

  def bare(_), do: :erlang.nif_error(:not_loaded)
  def add2(_, _), do: :erlang.nif_error(:not_loaded)
  def add2_jmp(_, _), do: :erlang.nif_error(:not_loaded)
  def add2_clock(_, _), do: :erlang.nif_error(:not_loaded)
  def clock_enif(_), do: :erlang.nif_error(:not_loaded)
  def clock_posix(_), do: :erlang.nif_error(:not_loaded)
  def clock_fast(_), do: :erlang.nif_error(:not_loaded)
end

# ---- variants of the generated C --------------------------------------------

defmodule CallCost.Variant do
  @moduledoc false
  # `edits` is a list of {from, to} applied to CallCost.Kernels' C; every
  # `from` must occur, so a change in the generated text fails loudly.
  def build(name, edits) do
    mod = Module.concat(CallCost, name)
    src = CallCost.Kernels.__defk_c_source__()

    src =
      Enum.reduce([{"Elixir.CallCost.Kernels", Atom.to_string(mod)} | edits], src, fn {from, to},
                                                                                      s ->
        unless String.contains?(s, from),
          do: raise("variant #{name}: #{inspect(from)} not in the C")

        String.replace(s, from, to)
      end)

    {:ok, base} = Defk.Build.library(mod, src, __ENV__.file)

    Module.create(
      mod,
      quote do
        @on_load :load
        def load, do: :erlang.load_nif(String.to_charlist(unquote(base)), 0)
        def add(_, _), do: :erlang.nif_error(:not_loaded)
        def clamp(_, _, _), do: :erlang.nif_error(:not_loaded)
        def len(_), do: :erlang.nif_error(:not_loaded)
        def __defk_native_loop1__(_, _), do: :erlang.nif_error(:not_loaded)
        def __defk_stats__, do: :erlang.nif_error(:not_loaded)
        def __defk_force_yields__(_), do: :erlang.nif_error(:not_loaded)
      end,
      Macro.Env.location(__ENV__)
    )

    mod
  end
end

# the guard's sigsetjmp (an error would then longjmp into garbage: no call here raises)
nojmp = [{"if (sigsetjmp(F->ctx.jb, 0)) { *defk_slot = NULL; return DEFK_ERR; }\n", ""}]
# the thread-local store pair of fault containment (ADR-0009)
notls = [
  {"defk_ctx **defk_slot = &defk_cur_ctx; /* one thread-local lookup per call */\n", ""},
  {"*defk_slot = &F->ctx;\n", ""},
  {"{ *defk_slot = NULL; return DEFK_ERR; }", "{ return DEFK_ERR; }"},
  {"*defk_slot = NULL;\n", ""}
]

# the clock read at a yielding kernel's entry (one trip never reaches a tick)
noclock = [
  {"defk_clock_init(&defk_clk, ctx);",
   "defk_clk.last = 0; defk_clk.unreported = 0; defk_clk.ctx = ctx;"}
]

# the slice init (the hint's decode) of loop1's entry
noslice = [
  {"defk_slice_init(env, &local.ctx, argc > 1 ? &argv[1] : NULL);",
   "local.ctx.slice_us = DEFK_SLICE_US; local.ctx.short_left = 0;"}
]

_ = CallCost.Variant.build(:NoJmp, nojmp)
_ = CallCost.Variant.build(:NoTls, notls)
_ = CallCost.Variant.build(:NoClock, noclock)
_ = CallCost.Variant.build(:NoSlice, noslice)
# the stores go first: the sigsetjmp line then reads `{ return DEFK_ERR; }`
_ =
  CallCost.Variant.build(
    :None,
    notls ++ [{"if (sigsetjmp(F->ctx.jb, 0)) { return DEFK_ERR; }\n", ""}] ++ noclock ++ noslice
  )

# ---- the measurement ---------------------------------------------------------

defmodule CallCost.Time do
  def loop(_f, 0), do: :ok

  def loop(f, k) do
    f.()
    loop(f, k - 1)
  end

  def ns(f, n) do
    {us, _} = :timer.tc(fn -> loop(f, n) end)
    us * 1000 / n
  end

  def median(l), do: Enum.at(Enum.sort(l), div(length(l), 2))

  # interleaved: each round runs every row once; the empty loop is subtracted
  def block(title, rows, n, rounds) do
    IO.puts("\n#{title}  (other CPU: #{Float.round(Defk.Bench.other_cpu() * 1.0, 2)} cores)")
    rows = rows ++ [{"empty loop", fn -> :ok end}]

    res =
      for _ <- 1..rounds, {name, f} <- rows, reduce: %{} do
        acc -> Map.update(acc, name, [ns(f, n)], &[ns(f, n) | &1])
      end

    empty = median(res["empty loop"])

    for {name, _} <- rows, name != "empty loop" do
      IO.puts(
        "  #{String.pad_trailing(name, 58)} #{Float.round(median(res[name]) - empty, 1) |> :erlang.float_to_binary(decimals: 1) |> String.pad_leading(6)} ns"
      )
    end
  end
end

alias CallCost.{Kernels, NoAdaptive, NoYield, Floor}
p = <<1::64-native>>

# every row gives the same answer as its kernel
3 = Kernels.add(1, 2)
3 = Floor.add2(1, 2)
3 = CallCost.None.add(1, 2)
0 = Kernels.loop1(1)
0 = NoAdaptive.loop1(1)
0 = NoYield.loop1(1)
0 = CallCost.None.__defk_native_loop1__(1, 0)
1 = Kernels.len(p)
5.0 = Kernels.clamp(5.0, -10.0, 90.0)

IO.puts(
  "call cost: n = #{n} calls per row, median of #{rounds} interleaved rounds, minus the empty loop"
)

IO.puts(
  "#{:erlang.system_info(:system_architecture)}, OTP #{:erlang.system_info(:otp_release)}, Elixir #{System.version()}, #{System.schedulers_online()} schedulers"
)

CallCost.Time.block(
  "1. the floor and the non-yielding kernels",
  [
    {"Elixir remote call add/2", fn -> CallCost.Elixir.add(1, 2) end},
    {"bare NIF (returns its argument)", fn -> Floor.bare(1) end},
    {"plain NIF add2 (decode two i64, encode one)", fn -> Floor.add2(1, 2) end},
    {"plain NIF add2 + sigsetjmp", fn -> Floor.add2_jmp(1, 2) end},
    {"defk add/2 (the kernel as generated)", fn -> Kernels.add(1, 2) end},
    {"defk add/2 without the sigsetjmp", fn -> CallCost.NoJmp.add(1, 2) end},
    {"defk add/2 without the thread-local stores", fn -> CallCost.NoTls.add(1, 2) end},
    {"defk add/2 without both", fn -> CallCost.None.add(1, 2) end},
    {"defk clamp/3 (three f64 in, f64 out)", fn -> Kernels.clamp(5.0, -10.0, 90.0) end},
    {"defk len/1 (one [i64] argument)", fn -> Kernels.len(p) end}
  ],
  n,
  rounds
)

CallCost.Time.block(
  "2. a yielding kernel with one loop trip",
  [
    {"defk add/2 (no loop, for reference)", fn -> Kernels.add(1, 2) end},
    {"loop1 with yield: false (no safepoints)", fn -> NoYield.loop1(1) end},
    {"loop1 with adaptive_slice: false (NIF direct, clock read)", fn -> NoAdaptive.loop1(1) end},
    {"loop1 (default: function + hint BIF + NIF + clock read)", fn -> Kernels.loop1(1) end},
    {"loop1's NIF called directly with hint 0", fn -> Kernels.__defk_native_loop1__(1, 0) end},
    {"loop1's NIF called directly with hint 5 (short slice)",
     fn -> Kernels.__defk_native_loop1__(1, 5) end},
    {"loop1's NIF without the clock read",
     fn -> CallCost.NoClock.__defk_native_loop1__(1, 0) end},
    {"loop1's NIF without the slice init",
     fn -> CallCost.NoSlice.__defk_native_loop1__(1, 0) end},
    {"loop1's NIF without clock, slice init, sigsetjmp, TLS",
     fn -> CallCost.None.__defk_native_loop1__(1, 0) end},
    {"the hint BIF alone: statistics(:total_run_queue_lengths)",
     fn -> :erlang.statistics(:total_run_queue_lengths) end}
  ],
  n,
  rounds
)

CallCost.Time.block(
  "3. clock reads, each on top of the bare NIF",
  [
    {"bare NIF", fn -> Floor.bare(1) end},
    {"enif_monotonic_time(ERL_NIF_USEC)", fn -> Floor.clock_enif(1) end},
    {"clock_gettime(CLOCK_MONOTONIC)", fn -> Floor.clock_posix(1) end},
    {"mach_absolute_time / cntvct_el0 / rdtsc", fn -> Floor.clock_fast(1) end},
    {"plain NIF add2 + enif_monotonic_time", fn -> Floor.add2_clock(1, 2) end}
  ],
  n,
  rounds
)
