# Resuming a yielded kernel must give the same answer as never yielding.
# Each kernel shape is compiled twice (yielding and `yield: false`) and run
# with natural yields and with a yield forced at every clock read, which
# exercises the resume path of every safepoint.

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
    end
  end
end

defmodule Defk.ResumeTest.K do
  use Defk
  require Defk.ResumeTest.Shapes
  Defk.ResumeTest.Shapes.shapes("", [])
  Defk.ResumeTest.Shapes.shapes("_nb", yield: false)
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
      {"fuzzy", F, fn -> F.search("elixir", blob, offs, 10) end,
       fn -> F.search_blocking("elixir", blob, offs, 10) end}
    ]
  end

  # smaller inputs: every clock read yields
  defp cases(:forced) do
    a = i64s(for i <- 1..2_000, do: rem(i * 7919, 100_003))
    f = f64s(for i <- 1..200_000, do: i / 3)
    {blob, offs} = catalog(2_000)

    [
      {"mix", K, fn -> K.mix(a, 6) end, fn -> K.mix_nb(a, 6) end},
      {"deep", K, fn -> K.deep(60) end, fn -> K.deep_nb(60) end},
      {"flat", K, fn -> K.flat(f, 3) end, fn -> K.flat_nb(f, 3) end},
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
  end
end
