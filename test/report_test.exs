# The fast-path report (defk-6cn): __defk_report__/0 lists what the compiler
# did to each kernel's hot path as {kernel, line, fact}, and
# Defk.Report.print/1 shows it as margin notes on the kernel source.
#
# The clang part (`report: :full`, vectorisation from clang's remarks) is
# tagged :clang; test_helper.exs excludes the tag when CC is not clang, and
# `mix test --only clang` runs just that part.

defmodule Defk.ReportTest.K do
  use Defk

  defk at(a :: [i64], i :: i64) :: i64 do
    a[i]
  end

  defk next_sum(a :: [i64]) :: i64 do
    for i <- 0..(len(a) - 1)//1, reduce: 0 do
      acc -> acc + a[i + 1]
    end
  end

  defk pick(c :: bool, x :: i64) :: i64 do
    if c, do: x + 1, else: -x
  end

  defk classify(x :: i64) :: i64 do
    case x do
      0 -> 10
      1 -> 20
    end
  end

  defk stepped(n :: i64, s :: i64) :: i64 do
    for i <- 0..n//s, reduce: 0 do
      acc -> acc + i
    end
  end

  defk pairs(n :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc ->
        for j <- 1..n//1, reduce: acc do
          acc2 -> acc2 + i * j
        end
    end
  end

  defk total(a :: [i64]) :: i64 do
    for x <- a, reduce: 0 do
      acc -> acc + x
    end
  end

  defk total_nb(a :: [i64]) :: i64, yield: false do
    for x <- a, reduce: 0 do
      acc -> acc + x
    end
  end

  defk twice_total(a :: [i64]) :: i64 do
    total(a) * 2
  end

  defk bump(a :: [i64]) :: [i64] do
    a[0] = a[0] + 1
    a
  end

  # no float operation: nothing to flag (defk-60q)
  defk spread(a :: [u8]) :: [u8] do
    out = alloc(u8, 2 * len(a))

    for j <- 0..(len(a) - 1)//1 do
      out[2 * j] = a[j]
    end

    out
  end
end

defmodule Defk.ReportTest.Full do
  use Defk, report: :full

  # Examples.Kernels.dot
  defk dot(a :: [f64], b :: [f64]) :: f64 do
    n = min(len(a), len(b))

    for i <- 0..(n - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end
end

defmodule Defk.ReportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Defk.ReportTest.{Full, K}

  # the facts for kernel {name, arity} on the source line containing `text`
  defp facts(mod, kernel, text) do
    line = line_of(mod, text)
    for {^kernel, ^line, fact} <- mod.__defk_report__(), do: fact
  end

  defp kernel_facts(mod, kernel), do: for({^kernel, _, fact} <- mod.__defk_report__(), do: fact)

  defp line_of(mod, text) do
    src = mod.module_info(:compile)[:source] |> to_string() |> File.read!()
    lines = String.split(src, "\n")
    1 + Enum.find_index(lines, &String.contains?(&1, text))
  end

  describe "__defk_report__/0" do
    test "dot's hot loop keeps no bounds checks" do
      facts = facts(Examples.Kernels, {:dot, 2}, "acc + a[i] * b[i]")
      assert {:bounds, :dropped, "a[i]"} in facts
      assert {:bounds, :dropped, "b[i]"} in facts

      refute Enum.any?(
               kernel_facts(Examples.Kernels, {:dot, 2}),
               &match?({:bounds, :kept, _}, &1)
             )
    end

    test "dot's loop runs in flagged strips" do
      [{:loop, :strips, why}] =
        for {:loop, _, _} = f <- facts(Examples.Kernels, {:dot, 2}, "for i <- 0..(n - 1)//1"),
            do: f

      assert why =~ "DEFK_STRIP"
      assert why =~ "flagged"

      assert Enum.any?(
               facts(Examples.Kernels, {:dot, 2}, "for i <- 0..(n - 1)//1"),
               &match?({:nonfinite, :flagged, _}, &1)
             )
    end

    test "a loop with no float operation is not flagged" do
      facts = facts(K, {:spread, 1}, "for j <- 0..(len(a) - 1)//1")
      assert [{:loop, :strips, why}] = for({:loop, _, _} = f <- facts, do: f)
      refute why =~ "flagged"
      refute Enum.any?(kernel_facts(K, {:spread, 1}), &match?({:nonfinite, _, _}, &1))
      # and its C has no flag or replay path (no kernel in K has a float)
      c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
      refute c =~ "defk:replay"
      refute c =~ "int defk_nf;"
    end

    test "a kept bounds check names its missing fact" do
      assert [{:bounds, :kept, at}] = facts(K, {:at, 2}, "    a[i]")
      assert at =~ "a[i]"
      assert at =~ "0 <= i"
      assert at =~ "i < len(a)"

      assert [{:bounds, :kept, next}] = facts(K, {:next_sum, 1}, "acc + a[i + 1]")
      assert next =~ "i + 1 < len(a)"
      refute next =~ "0 <="
    end

    test "an if of pure arms is a select; a case with no catch-all is a branch, with why" do
      assert {:branch, :select, _} =
               List.keyfind(facts(K, {:pick, 2}, "if c, do: x + 1"), :branch, 0)

      assert {:branch, :branch, why} =
               List.keyfind(facts(K, {:classify, 1}, "case x do"), :branch, 0)

      assert why =~ "catch-all"
    end

    test "loops: per-iteration safepoints, strips, or none, with why" do
      assert {:loop, :per_iteration, why} =
               List.keyfind(facts(K, {:stepped, 2}, "0..n//s"), :loop, 0)

      assert why =~ "step"

      assert {:loop, :per_iteration, why} =
               List.keyfind(facts(K, {:pairs, 1}, "for i <- 1..n//1"), :loop, 0)

      assert why =~ "nested loop"

      assert {:loop, :strips, _} =
               List.keyfind(facts(K, {:pairs, 1}, "for j <- 1..n//1"), :loop, 0)

      assert [{:loop, :strips, _}] =
               for({:loop, _, _} = f <- kernel_facts(K, {:total, 1}), do: f)

      assert [{:loop, :none, why}] =
               for({:loop, _, _} = f <- kernel_facts(K, {:total_nb, 1}), do: f)

      assert why =~ "yield: false"
    end

    test "inlined kernel calls and copy-on-write copies" do
      assert {:inline, :inlined, "total/1"} in facts(K, {:twice_total, 1}, "total(a) * 2")

      assert [{:copy, :copied, why}] =
               for({:copy, _, _} = f <- facts(K, {:bump, 1}, "a[0] = a[0] + 1"), do: f)

      assert why =~ "a"
    end

    test "every kernel has a header fact at its defk line" do
      assert {:kernel, :yield, "dot/2"} in facts(
               Examples.Kernels,
               {:dot, 2},
               "defk dot(a :: [f64]"
             )

      assert {:kernel, :no_yield, "total_nb/1"} in facts(K, {:total_nb, 1}, "defk total_nb(")
    end

    test "without report: :full there are no vectorisation facts and no remark pass" do
      refute Enum.any?(
               Examples.Kernels.__defk_report__(),
               &match?({_, _, {:vectorize, _, _}}, &1)
             )

      base = String.trim_trailing(Examples.Kernels.__defk_lib__(), ".so")
      assert Path.wildcard(base <> "*.remarks") == []
    end

    test "rejects options it does not know" do
      assert_raise ArgumentError, ~r/report: :full/, fn ->
        Code.compile_string("defmodule Defk.ReportTest.BadOpt do\n use Defk, report: :all\nend")
      end
    end
  end

  describe "report: :full" do
    @describetag :clang

    test "dot's hot loop vectorises" do
      assert [{:vectorize, :vectorized, why}] =
               for(
                 {:vectorize, _, _} = f <- facts(Full, {:dot, 2}, "for i <- 0..(n - 1)//1"),
                 do: f
               )

      assert why =~ "width"
      refute Enum.any?(kernel_facts(Full, {:dot, 2}), &match?({:bounds, :kept, _}, &1))
    end

    test "the remark pass leaves the cached .so as it was" do
      src = Full.__defk_c_source__()
      base = String.trim_trailing(Full.__defk_lib__(), ".so")
      before = File.read!(base <> ".so")
      stat = File.stat!(base <> ".so")
      assert base == Defk.Build.build!(Full, src, nil)
      Defk.Build.remarks!(src, base)
      assert File.read!(base <> ".so") == before
      assert File.stat!(base <> ".so").mtime == stat.mtime
    end
  end

  describe "report: :full, a torn cache" do
    @describetag :clang

    test "an empty cached .remarks file is a miss, not the answer" do
      src = Full.__defk_c_source__()
      base = String.trim_trailing(Full.__defk_lib__(), ".so")
      [cached] = Path.wildcard(base <> "-*.remarks")
      good = File.read!(cached)
      on_exit(fn -> File.write!(cached, good) end)

      File.write!(cached, "")
      assert {:ok, [_ | _]} = Defk.Build.remarks!(src, base)
      assert File.read!(cached) == good
    end
  end

  describe "report: :full when CC is not clang" do
    setup do
      saved = System.get_env("CC")
      on_exit(fn -> if saved, do: System.put_env("CC", saved), else: System.delete_env("CC") end)

      dir = Path.join(System.tmp_dir!(), "defk-report-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      cc = Path.join(dir, "fakecc")
      real = System.find_executable(saved || "cc")

      File.write!(cc, """
      #!/bin/sh
      if [ "$1" = "--version" ]; then echo "gcc (fake) 14.1.0"; exit 0; fi
      exec #{real} "$@"
      """)

      File.chmod!(cc, 0o755)
      System.put_env("CC", cc)
      :ok
    end

    test "vectorisation is reported as unknown, never guessed" do
      mod = :"Elixir.Defk.ReportTest.NotClang#{System.unique_integer([:positive])}"

      [{^mod, _}] =
        Code.compile_string("""
        defmodule #{inspect(mod)} do
          use Defk, report: :full

          defk total(a :: [i64]) :: i64 do
            for x <- a, reduce: 0 do
              acc -> acc + x
            end
          end
        end
        """)

      assert [{_, 5, {:vectorize, :unknown, "vectorised: unknown (CC is not clang)"}}] =
               for({_, _, {:vectorize, _, _}} = f <- mod.__defk_report__(), do: f)
    end
  end

  describe "Defk.Report.print/1" do
    test "prints the kernel source with margin notes" do
      out = capture_io(fn -> assert :ok == Defk.Report.print(Examples.Kernels) end)
      assert out =~ "dot/2"
      [line] = for l <- String.split(out, "\n"), l =~ "acc -> acc + a[i] * b[i]", do: l
      assert line =~ "a[i]: no bounds check"
      assert out =~ "strips of DEFK_STRIP"
    end

    test "prints inlined code's notes after the kernel" do
      out = capture_io(fn -> Defk.Report.print(K) end)
      assert out =~ "twice_total/1"
      assert out =~ "inlined total/1"
    end
  end
end
