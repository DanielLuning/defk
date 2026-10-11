# Resuming a yielded kernel must give the same answer as never yielding.
# Each kernel shape is compiled twice (yielding and `yield: false`) and run
# with natural yields and with a yield forced at every clock read, which
# exercises the resume path of every safepoint, including those in loops of
# inlined kernel calls (defk-jaj).
#
# The kernel bodies in `shapes` are fixture data: credo counts their nested
# `for`s and reports them as one complex function (defk-x15.3), so the
# complexity/nesting checks are off here.

# credo:disable-for-this-file

Code.require_file("../examples/fuzzy_search/lib/fuzzy_search/kernels.ex", __DIR__)

defmodule Defk.ResumeTest.Shapes do
  defmacro shapes(suffix, opts) do
    n = fn base -> :"#{base}#{suffix}" end

    quote do
      # array generator with a filter and a nested range; a loop in an if-branch
      defk unquote(n.(:mix))(a :: [i64], reps :: i64) :: {i64, i64}, unquote(opts) do
        for r <- 1..reps//1, reduce: {0, 0} do
          {s, t} ->
            s2 =
              for x <- a, rem(x, 3) != 0, j <- 0..(rem(x, 7) + 2)//1, reduce: s do
                acc -> rem(acc * 31 + x * j + r, 1_000_000_007)
              end

            t2 =
              if rem(r, 2) == 0 do
                for i <- 0..(len(a) - 1)//1, reduce: t do
                  acc ->
                    inner =
                      for k <- 0..(rem(i, 5) + 1)//1, reduce: 0 do
                        z -> z + a[i] * k
                      end

                    rem(acc + inner, 1_000_000_007)
                end
              else
                t + 1
              end

            {s2, t2}
        end
      end

      # three deep, with flat sibling loops around the middle level
      defk unquote(n.(:deep))(n :: i64) :: i64, unquote(opts) do
        buf = alloc(i64, n + 1)

        for a <- 1..n//1, reduce: 0 do
          acc ->
            for j <- 0..n//1 do
              buf[j] = j * a
            end

            acc2 =
              for b <- 1..a//1, reduce: acc do
                acc2 ->
                  for c <- 1..b//1, reduce: acc2 do
                    acc3 -> rem(acc3 + buf[c] * b + c, 1_000_000_007)
                  end
              end

            for j <- 0..n//1, reduce: acc2 do
              z -> rem(z + buf[j], 1_000_000_007)
            end
        end
      end

      # long flat loops, which run in strips with one safepoint per strip
      defk unquote(n.(:flat))(a :: [f64], reps :: i64) :: f64, unquote(opts) do
        for _r <- 1..reps//1, reduce: 0.0 do
          acc ->
            s1 =
              for x <- a, reduce: 0.0 do
                z -> z + x * 0.5
              end

            s2 =
              for i <- 0..(len(a) - 1)//1, reduce: 0.0 do
                z -> z + a[i]
              end

            acc + s1 - s2 * 0.5 + 1.0
        end
      end

      # loops in callees, up to three calls deep: an array returned by a call,
      # calls in a filter, in an `and`, in a range bound and as a statement
      defk unquote(n.(:calls))(a :: [i64], reps :: i64) :: i64, unquote(opts) do
        for r <- 1..reps//1, reduce: 0 do
          acc ->
            w = weights(a, r)

            kept =
              for x <- a, keep?(x), reduce: 0 do
                z -> rem(z + x * r, 1_000_000_007)
              end

            bonus = if r > 1 and dot_mod(a, w) > 7, do: 1, else: 0

            tail =
              for i <- 0..chain(rem(r, 3) + 1, r)//1, reduce: 0 do
                z -> z + i
              end

            rem(
              acc + dot_mod(a, w) + kept + bonus + tail + chain(min(len(a), 2500), r),
              1_000_000_007
            )
        end
      end

      # body temporaries (defk-zep): `held` is bound before the nested loops
      # and read in and after them, so their safepoints spill it; `hot` is the
      # inner loop's own, left out of every spill list
      defk unquote(n.(:temps))(a :: [i64], reps :: i64) :: i64, unquote(opts) do
        for r <- 1..reps//1, reduce: 0 do
          acc ->
            base = rem(acc * 7 + r, 1_000_003)
            held = base * 3 + 1

            {s, t} =
              for x <- a, reduce: {base, 1} do
                {s, t} ->
                  hot = bxor(s, x)
                  {rem(hot * held + t, 1_000_000_007), rem(t + hot, 1_000_003)}
              end

            w =
              for i <- 0..(rem(r, 4) + 1)//1, reduce: 0 do
                z -> z + held * i
              end

            rem(acc + s + t + base + held + w, 1_000_000_007)
        end
      end

      # a callee raises after its caller has yielded and resumed many times
      defk unquote(n.(:calls_raise))(n :: i64, at :: i64) :: i64, unquote(opts) do
        for i <- 1..n//1, reduce: 0 do
          acc -> acc + fail_at(i, at)
        end
      end
    end
  end
end

defmodule Defk.ResumeTest.K do
  use Defk
  require Defk.ResumeTest.Shapes
  Defk.ResumeTest.Shapes.shapes("", [])
  Defk.ResumeTest.Shapes.shapes("_nb", yield: false)

  # callees: inlined into both forms above, so they yield only in the first

  defk weights(a :: [i64], r :: i64) :: [i64] do
    w = alloc(i64, len(a))

    for i <- 0..(len(a) - 1)//1 do
      w[i] = rem(a[i] * r, 97)
    end

    w
  end

  defk dot_mod(a :: [i64], b :: [i64]) :: i64 do
    for i <- 0..(min(len(a), len(b)) - 1)//1, reduce: 0 do
      acc -> rem(acc + a[i] * b[i], 1_000_000_007)
    end
  end

  defk keep?(x :: i64) :: bool do
    rem(x, 3) != 0
  end

  defk chain(n :: i64, r :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc -> rem(acc + level2(i, r), 1_000_000_007)
    end
  end

  # level3's flat loop sometimes runs long enough for strips (> DEFK_STRIP)
  defk level2(i :: i64, r :: i64) :: i64 do
    for j <- 1..(rem(i, 5) + 1)//1, reduce: i do
      acc -> rem(acc + level3(j * rem(i, 700) + rem(r, 50)), 1_000_000_007)
    end
  end

  defk level3(x :: i64) :: i64 do
    for k <- 1..x//1, reduce: 0 do
      z -> z + k * x
    end
  end

  defk fail_at(i :: i64, at :: i64) :: i64 do
    s =
      for k <- 1..300//1, reduce: 0 do
        z -> z + level3(rem(k + i, 7) + 1)
      end

    a = alloc(i64, 1)
    if i == at, do: a[1], else: s
  end
end

# Two flat loops in strips, so safepoints 1 and 2 dispatch from the top
# level. The lost-resume tests break this kernel's dispatch in its C source.
defmodule Defk.ResumeTest.Lost do
  use Defk

  defk two_loops(n :: i64) :: i64 do
    s =
      for i <- 1..n//1, reduce: 0 do
        acc -> acc + i
      end

    for i <- 1..n//1, reduce: s do
      acc -> acc + 2 * i
    end
  end
end

defmodule Defk.ResumeTest do
  use ExUnit.Case, async: false

  # A resume that misses its safepoint raises (defk_lost_resume in the
  # runtime). This backstop fails any other endless resume loop before it
  # exhausts memory: each restart re-runs alloc/2 and keeps the binary until
  # the kernel ends, which got the VM OOM-killed in about 25 s (defk-juw).
  # The tests take about a second.
  @moduletag timeout: 10_000

  alias Defk.ResumeTest.K
  alias FuzzySearch.Kernels, as: F

  use Defk.Properties

  defp i64s(list), do: for(x <- list, into: <<>>, do: <<x::64-signed-native>>)
  defp f64s(list), do: for(x <- list, into: <<>>, do: <<x::float-64-native>>)

  # synthetic catalog in the fuzzy_search layout: one blob plus an offset table
  defp catalog(n) do
    :rand.seed(:exsss, {7, 8, 9})

    words =
      for _ <- 1..n, do: for(_ <- 1..Enum.random(3..12), into: "", do: <<Enum.random(?a..?z)>>)

    {offs, total} = Enum.map_reduce(words, 0, fn w, at -> {at, at + byte_size(w)} end)
    {IO.iodata_to_binary(words), i64s(offs ++ [total])}
  end

  # {name, module, yielding, blocking}, sized to run for well over a clock period
  defp cases(:natural) do
    a = i64s(for i <- 1..20_000, do: rem(i * 7919, 100_003))
    f = f64s(for i <- 1..1_000_000, do: i / 3)
    {blob, offs} = catalog(40_000)

    [
      {"mix", K, fn -> K.mix(a, 400) end, fn -> K.mix_nb(a, 400) end},
      {"deep", K, fn -> K.deep(260) end, fn -> K.deep_nb(260) end},
      {"flat", K, fn -> K.flat(f, 60) end, fn -> K.flat_nb(f, 60) end},
      {"calls", K, fn -> K.calls(a, 20) end, fn -> K.calls_nb(a, 20) end},
      {"temps", K, fn -> K.temps(a, 300) end, fn -> K.temps_nb(a, 300) end},
      {"fuzzy", F, fn -> F.search("elixir", blob, offs, 10) end,
       fn -> F.search_blocking("elixir", blob, offs, 10) end}
    ]
  end

  # smaller inputs: every clock read yields
  defp cases(:forced) do
    a = i64s(for i <- 1..2_000, do: rem(i * 7919, 100_003))
    # longer than DEFK_STRIP, so the callees' flat loops run in strips
    c = i64s(for i <- 1..3_000, do: rem(i * 7919, 100_003))
    f = f64s(for i <- 1..200_000, do: i / 3)
    {blob, offs} = catalog(2_000)

    [
      {"mix", K, fn -> K.mix(a, 6) end, fn -> K.mix_nb(a, 6) end},
      {"deep", K, fn -> K.deep(60) end, fn -> K.deep_nb(60) end},
      {"flat", K, fn -> K.flat(f, 3) end, fn -> K.flat_nb(f, 3) end},
      {"calls", K, fn -> K.calls(c, 3) end, fn -> K.calls_nb(c, 3) end},
      {"temps", K, fn -> K.temps(c, 4) end, fn -> K.temps_nb(c, 4) end},
      {"fuzzy", F, fn -> F.search("elixir", blob, offs, 10) end,
       fn -> F.search_blocking("elixir", blob, offs, 10) end}
    ]
  end

  for mode <- [:natural, :forced] do
    test "yielding kernels match yield: false (#{mode} yields)" do
      for {name, mod, yielding, blocking} <- cases(unquote(mode)) do
        mod.__defk_force_yields__(unquote(mode) == :forced)

        try do
          y0 = mod.__defk_stats__().yields
          got = yielding.()
          yields = mod.__defk_stats__().yields - y0

          assert got == blocking.(), "#{name}: yielding result differs from yield: false"
          assert yields > 0, "#{name}: never yielded, so resume was not tested"
        after
          mod.__defk_force_yields__(false)
        end
      end
    end

    test "an error in a callee after resuming raises like yield: false (#{mode} yields)" do
      K.__defk_force_yields__(unquote(mode) == :forced)
      n = if unquote(mode) == :forced, do: 300, else: 30_000

      try do
        y0 = K.__defk_stats__().yields
        e = assert_raise Enum.OutOfBoundsError, fn -> K.calls_raise(n, n - 1) end
        assert K.__defk_stats__().yields - y0 > 0, "never yielded before the error"
        assert e == assert_raise(Enum.OutOfBoundsError, fn -> K.calls_raise_nb(n, n - 1) end)
        assert K.calls_raise(n, n + 1) == K.calls_raise_nb(n, n + 1)
      after
        K.__defk_force_yields__(false)
      end
    end
  end

  # A safepoint spills the locals live where it resumes (defk-zep): the
  # strip safepoint of temps/2's inner loop spills `held`, and no safepoint
  # spills `hot`, so the C compiler need not keep it alive out of its loop.
  test "safepoints spill only the locals live where they resume" do
    saves =
      Regex.scan(~r/^#define DEFK_SAVE(\d+) (.*)$/m, kernel_c("temps/2"), capture: :all_but_first)
      |> Enum.map(fn [n, list] -> {n, list} end)

    assert Enum.any?(saves, fn {_, l} -> l =~ ~r/F->v_held_\d+ = / end)
    refute Enum.any?(saves, fn {_, l} -> l =~ ~r/F->v_hot_\d+ = / end)
    # the outer loop's own safepoint: neither (both are bound in its body)
    assert Enum.any?(saves, fn {_, l} -> not (l =~ ~r/v_held_|v_hot_/) end)
  end

  defp kernel_c(name) do
    [_, rest] = String.split(K.__defk_c_source__(), "/* ---- #{name} (yielding) ---- */\n")
    rest |> String.split("/* ---- ") |> hd()
  end

  # A missing or wrong resume dispatch case raises defk_lost_resume's
  # RuntimeError at once instead of recomputing or never finishing. Defk
  # never generates such a case, so each test breaks the generated C of
  # Defk.ResumeTest.Lost and builds it as another module: no test-only
  # option reaches the compiler.
  @lost_case "case 2: defk_rs = F->resume = 0; goto defk_l2;\n"
  @lost_return "*result = enif_make_int64(env, v_acc_7);\n"

  describe "a lost resume raises" do
    test "when the kernel yields at another safepoint first" do
      # missing case: the resume at safepoint 2 restarts the kernel, which
      # yields at safepoint 1 under forced yields
      lost = lost_mutant(LostMissing, &String.replace(&1, @lost_case, ""))

      assert {:raised, %RuntimeError{message: msg}} = run_lost(lost)

      assert msg =~
               "defk bug: kernel resumed at safepoint 2 but yielded at safepoint 1 without reaching it"
    end

    test "when the kernel returns without reaching the safepoint" do
      # wrong case: the resume at safepoint 2 jumps straight to the return
      lost =
        lost_mutant(LostReturn, fn src ->
          src
          |> String.replace(@lost_case, "case 2: goto defk_lost_ret;\n")
          |> String.replace(@lost_return, "defk_lost_ret:;\n" <> @lost_return)
        end)

      assert {:raised, %RuntimeError{message: msg}} = run_lost(lost)
      assert msg =~ "defk bug: kernel resumed at safepoint 2 but returned without reaching it"
    end
  end

  # Builds Defk.ResumeTest.Lost's C source, changed by `edit`, as the NIF of a
  # new module `name` with a stub for each NIF, and returns the module and a
  # function that calls the kernel.
  defp lost_mutant(name, edit) do
    src = Defk.ResumeTest.Lost.__defk_c_source__()

    assert String.contains?(src, @lost_case) and String.contains?(src, @lost_return),
           "the generated C changed shape; update the lost-resume tests"

    mod = Module.concat(Defk.ResumeTest, name)

    src =
      src
      |> edit.()
      |> String.replace("ERL_NIF_INIT(Elixir.Defk.ResumeTest.Lost,", "ERL_NIF_INIT(#{mod},")

    lib = Defk.Build.build!(mod, src, __ENV__.file)
    nifs = Regex.scan(~r/\{"(\w+)", (\d+), (\w+), 0\}/, src, capture: :all_but_first)

    stubs =
      for [f, a, _] <- nifs do
        args = for i <- 1..String.to_integer(a)//1, do: Macro.var(:"_a#{i}", nil)

        quote do:
                def(unquote(String.to_atom(f))(unquote_splicing(args)),
                  do: :erlang.nif_error(:not_loaded)
                )
      end

    load = quote do: def(__load__(lib), do: :erlang.load_nif(lib, 0))
    Module.create(mod, [load | stubs], Macro.Env.location(__ENV__))
    :ok = mod.__load__(String.to_charlist(lib))
    # the kernel yields, so its NIF takes the run-queue hint last (defk-04y)
    [kernel] = for [f, "2", "nif_" <> _] <- nifs, do: String.to_atom(f)
    {mod, &apply(mod, kernel, [&1, 0])}
  end

  # Runs the broken kernel under forced yields, bounded well below the 10 s
  # backstop: without the runtime check it never finishes.
  defp run_lost({mod, kernel}) do
    mod.__defk_force_yields__(true)

    try do
      {pid, ref} =
        spawn_monitor(fn ->
          exit(
            try do
              {:returned, kernel.(10_000)}
            rescue
              e -> {:raised, e}
            end
          )
        end)

      receive do
        {:DOWN, ^ref, :process, ^pid, result} -> result
      after
        2_000 ->
          Process.exit(pid, :kill)
          flunk("a lost resume did not raise within 2 s")
      end
    after
      mod.__defk_force_yields__(false)
    end
  end

  test "recursion through kernel calls is rejected at compile time" do
    src = """
    defmodule Defk.ResumeTest.Recursive do
      use Defk
      defk ping(n :: i64) :: i64 do
        if n > 0, do: pong(n - 1), else: 0
      end
      defk pong(n :: i64) :: i64 do
        ping(n)
      end
    end
    """

    e = assert_raise CompileError, fn -> Code.compile_string(src) end
    assert Exception.message(e) =~ "ping/1 calls itself through pong/1"
  end

  # ---------------------------------------------------- agreement properties --
  # Every kernel here against its Elixir mode (defk-ne6). Trip counts are
  # bounded, with the i64 maximum as the one cheap edge (its range raises
  # before the loop starts); array elements are mostly small, so the
  # arithmetic gets past the first overflow.

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  defp small, do: G.i64(-1_000..1_000)
  defp reps(n), do: G.i64(-2..n, [@min, @max])
  defp small_array(max), do: G.array(:i64, of: small(), max_length: max, strip: false)

  defp at_or_any(n_gen) do
    bind(n_gen, fn n ->
      fixed_list([
        constant(n),
        frequency([{3, integer((min(n, 50) - 2)..(min(n, 50) + 2))}, {1, G.i64()}])
      ])
    end)
  end

  defp mix, do: fixed_list([small_array(32), reps(4)])
  defp deep, do: fixed_list([G.alloc_len(8, -3..25)])
  defp flat, do: fixed_list([G.array(:f64), reps(3)])
  defp calls, do: fixed_list([small_array(24), reps(3)])
  defp calls_raise, do: at_or_any(G.i64(-2..8, [@min, @max]))

  agreement(K,
    mix: [args: mix()],
    mix_nb: [args: mix()],
    deep: [args: deep()],
    deep_nb: [args: deep()],
    flat: [args: flat()],
    flat_nb: [args: flat()],
    calls: [args: calls()],
    calls_nb: [args: calls()],
    calls_raise: [args: calls_raise()],
    calls_raise_nb: [args: calls_raise()],
    temps: [args: mix()],
    temps_nb: [args: mix()],
    weights: [args: fixed_list([G.array(:i64, of: small()), G.i64()])],
    dot_mod: [],
    keep?: [],
    chain: [args: fixed_list([G.i64(-3..40, [@min, @max]), G.i64()])],
    # loops at most 5 * 3_544 times for any i64 arguments
    level2: [max_runs: 50],
    level3: [args: fixed_list([G.i64(-10..5_000, [@min, @max])])],
    fail_at: [args: at_or_any(G.i64())]
  )

  agreement(Defk.ResumeTest.Lost,
    two_loops: [args: fixed_list([G.i64(-5..5_000, [@min, @max])])]
  )
end
