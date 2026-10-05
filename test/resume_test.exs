# Resuming a yielded kernel must give the same answer as never yielding.
# Each kernel shape is compiled twice (yielding and `yield: false`) and run
# with natural yields and with a yield forced at every clock read, which
# exercises the resume path of every safepoint, including those in loops of
# inlined kernel calls (defk-jaj).

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
            kept = for x <- a, keep?(x), reduce: 0 do
              z -> rem(z + x * r, 1_000_000_007)
            end

            bonus = if r > 1 and dot_mod(a, w) > 7, do: 1, else: 0
            tail = for i <- 0..chain(rem(r, 3) + 1, r)//1, reduce: 0 do
              z -> z + i
            end

            rem(acc + dot_mod(a, w) + kept + bonus + tail + chain(min(len(a), 2500), r), 1_000_000_007)
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

defmodule Defk.ResumeTest do
  use ExUnit.Case, async: false

  alias Defk.ResumeTest.K
  alias FuzzySearch.Kernels, as: F

  defp i64s(list), do: for(x <- list, into: <<>>, do: <<x::64-signed-native>>)
  defp f64s(list), do: for(x <- list, into: <<>>, do: <<x::float-64-native>>)

  # synthetic catalog in the fuzzy_search layout: one blob plus an offset table
  defp catalog(n) do
    :rand.seed(:exsss, {7, 8, 9})
    words = for _ <- 1..n, do: for(_ <- 1..Enum.random(3..12), into: "", do: <<Enum.random(?a..?z)>>)
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
    assert Exception.message(e) =~ "is recursive"
  end
end
