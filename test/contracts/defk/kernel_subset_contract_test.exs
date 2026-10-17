defmodule Defk.Contract.KernelSubsetTest do
  # The kernel subset (test/contracts/defk/kernel_subset.obligations.md): every
  # release's frozen kernels keep compiling and keep their recorded results,
  # and kernels agree with Elixir. Like every contract test it calls only
  # defk's public API and Defk.ContractKit (test/contracts/README.md). The
  # agreement of the catalog's and each feature's kernels is in the test files
  # of those features (test/agreement_test.exs and others), beside the
  # kernels they cover.
  use Covenant.Case, component: "defk.kernel_subset", async: true
  use ExUnitProperties

  alias Defk.ContractKit, as: Kit

  @kernels Kit.frozen(:kernels)
  for path <- Kit.frozen_paths(:kernels), do: @external_resource(path)

  # every frozen example's module, compiled concurrently: %{file => result}
  setup_all do
    %{compiled: Kit.compile_frozen(@kernels, :kernels)}
  end

  describe "I1: a frozen kernel keeps compiling and keeps its results" do
    for {file, exs} <- @kernels do
      @path file
      @exs exs

      @tag obligation: "defk.kernel_subset.I1"
      test "#{file} #{Kit.label(exs)}", %{compiled: compiled} do
        assert [ex] = @exs, "#{@path}: a frozen file holds one example, not #{length(@exs)}"

        assert Kit.frozen_kernel?(ex),
               "#{@path}: a frozen example runs or compiles, this one is #{inspect(ex.check)}"

        case Kit.exception(:fixed, @path) do
          nil ->
            Kit.verify_frozen!(@path, ex, Map.fetch!(compiled, @path))

          words ->
            assert Kit.changelog?(words),
                   "#{@path}: no CHANGELOG entry contains #{inspect(words)}"

            assert_raise ExUnit.AssertionError, fn ->
              Kit.verify_frozen!(@path, ex, Map.fetch!(compiled, @path))
            end
        end
      end
    end

    @tag obligation: "defk.kernel_subset.I1"
    test "the corpus holds every release's kernels" do
      assert @kernels != [], "no frozen kernels under test/stability/*/kernels/"
    end

    @tag obligation: "defk.kernel_subset.I1"
    test "every exception names a frozen file and its CHANGELOG entry" do
      fixed = Kit.exceptions(:fixed)
      assert Kit.not_frozen(fixed, @kernels) == [], "fixed names files that are not frozen"

      for {file, words} <- fixed do
        assert Kit.changelog?(words), "#{file}: no CHANGELOG entry contains #{inspect(words)}"
      end
    end
  end

  # Kernels over the core of the subset, compiled with Elixir mode. Only this
  # file calls them, so the forced-yields flag (module-wide) is safe in an
  # async test.
  defmodule K do
    @moduledoc false
    use Defk, elixir_mode: true

    defk mix(x :: i64, y :: i64) :: i64 do
      a = x * 3 + y
      b = div(a, if(y == 0, do: 1, else: y))

      cond do
        a > b -> a - b
        a == b -> 0
        true -> rem(b, 7)
      end
    end

    defk mean(xs :: [f64]) :: f64 do
      s =
        for x <- xs, reduce: 0.0 do
          acc -> acc + x
        end

      s / length(xs)
    end

    defk first_over(xs :: [i64], t :: i64) :: i64 do
      Enum.find(xs, -1, fn x -> x > t end)
    end

    defk window(xs :: [i64], i :: i64, w :: i64) :: i64 do
      for j <- i..(i + w - 1)//1, reduce: 0 do
        acc -> acc + xs[j]
      end
    end

    defk bits(x :: i64) :: i64 do
      case band(x, 3) do
        0 -> bxor(x, bsl(1, 5))
        1 -> bor(x, 1) - 1
        _ -> bsr(x, 2) + popcount(x)
      end
    end

    defk scale(xs :: [f64], k :: f64) :: [f64] do
      out = alloc(f64, length(xs))

      for i <- 0..(length(xs) - 1)//1 do
        out[i] = xs[i] * k
      end

      out
    end
  end

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  # integers: uniform small and large, and the i64 edges
  defp i64,
    do:
      one_of([
        integer(-1000..1000),
        integer(@min..@max),
        member_of([@min, @min + 1, -1, 0, 1, @max - 1, @max])
      ])

  # floats: ordinary, huge (sums overflow to inf, which raises) and edges
  defp f64,
    do: one_of([float(min: -1.0e6, max: 1.0e6), float(), member_of([0.0, -0.0, 1.0e308])])

  defp pack_i64(xs), do: for(x <- xs, into: <<>>, do: <<x::signed-64-native>>)
  defp pack_f64(xs), do: for(x <- xs, into: <<>>, do: <<x::float-64-native>>)

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args, forced_yields: true)

  describe "I2: a kernel agrees with Elixir" do
    @tag obligation: "defk.kernel_subset.I2"
    property "integer arithmetic, division and cond" do
      check(all(x <- i64(), y <- i64(), do: agrees(:mix, [x, y])))
    end

    @tag obligation: "defk.kernel_subset.I2"
    property "a float reduction over an array, empty arrays included" do
      check(all(xs <- list_of(f64(), max_length: 40), do: agrees(:mean, [pack_f64(xs)])))
    end

    @tag obligation: "defk.kernel_subset.I2"
    property "early exit from a search" do
      check all(xs <- list_of(i64(), max_length: 40), t <- i64()) do
        agrees(:first_over, [pack_i64(xs), t])
      end
    end

    @tag obligation: "defk.kernel_subset.I2"
    property "array reads in and out of bounds" do
      check all(
              xs <- list_of(integer(-1000..1000), max_length: 20),
              i <- integer(-3..25),
              w <- integer(-2..10)
            ) do
        agrees(:window, [pack_i64(xs), i, w])
      end
    end

    @tag obligation: "defk.kernel_subset.I2"
    property "case on bits and the bitwise builtins" do
      check(all(x <- i64(), do: agrees(:bits, [x])))
    end

    @tag obligation: "defk.kernel_subset.I2"
    property "an allocated array returned" do
      check all(xs <- list_of(f64(), max_length: 30), k <- f64()) do
        agrees(:scale, [pack_f64(xs), k])
      end
    end
  end
end
