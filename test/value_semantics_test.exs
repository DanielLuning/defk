# Arrays are values, as in Elixir (defk-auo): a write `a[i] = v` gives `a`
# a new array, and every other variable keeps what it had. Natively a write
# is in place unless another binding of the same buffer is read later, or the
# array is the caller's binary; then the buffer is copied once, before the
# first write (defk_copy_* in the generated C). Each kernel here is checked
# against Elixir mode, which has value semantics by construction, and the
# generated C is checked for where copies are (and are not) inserted.

Code.require_file("../examples/fuzzy_search/lib/fuzzy_search/kernels.ex", __DIR__)

defmodule Defk.ValueSemanticsTest.K do
  use Defk

  # the ticket's snapshot: b keeps the array from before the write
  defk snapshot_alloc(n :: i64) :: i64 do
    a = alloc(i64, n)
    b = a
    a[0] = 7
    b[0]
  end

  defk snapshot_input(a :: [i64]) :: {i64, i64} do
    b = a
    a[0] = 7
    {b[0], a[0]}
  end

  # a loop writes a while b, its snapshot, is read after it: one copy before the loop
  defk snapshot_loop(a :: [i64]) :: {i64, i64} do
    b = a

    for i <- 0..(len(a) - 1)//1 do
      a[i] = band(a[i], 0xFFFF) * 2
    end

    {sum(b), sum(a)}
  end

  defk sum(a :: [i64]) :: i64 do
    for x <- a, reduce: 0 do
      acc -> band(acc + band(x, 0xFFFF), 0xFFFFFFFF)
    end
  end

  # writing an input: the caller's binary is unchanged, the result returned
  defk write_input(a :: [i64], v :: i64) :: [i64] do
    a[0] = v
    a
  end

  defk write_input_loop(a :: [f64]) :: [f64] do
    for i <- 0..(len(a) - 1)//1 do
      a[i] = a[i] * 0.5
    end

    a
  end

  # a write in a branch: the input is copied before the if
  defk write_in_branch(a :: [u8], c :: bool) :: [u8] do
    if c do
      a[0] = 255
    end

    a
  end

  # HyperLogLog-style register update of an input array, no manual alloc+copy
  defk hll_update(regs :: [u8], idx :: [i64], ranks :: [i64]) :: [u8] do
    for k <- 0..(min(len(idx), len(ranks)) - 1)//1 do
      j = idx[k]
      regs[j] = max(regs[j], ranks[k])
    end

    regs
  end

  # swaps copy nothing: they rename buffers
  defk swap_rows(n :: i64) :: {[i64], [i64]} do
    prev = alloc(i64, n)
    cur = alloc(i64, n)

    for j <- 0..(n - 1)//1 do
      prev[j] = j
    end

    {prev, cur} = {cur, prev}

    for j <- 0..(n - 1)//1 do
      cur[j] = cur[j] + prev[j] + 1
    end

    {prev, cur} = {cur, prev}

    for j <- 0..(n - 1)//1 do
      cur[j] = prev[j] * 3
    end

    {prev, cur}
  end

  # one buffer under two names, both returned
  defk same_twice(n :: i64) :: {[i64], [i64]} do
    a = alloc(i64, n)
    b = a
    {a, b}
  end

  # the generator walks the array as it was when the loop started
  defk iter_write(n :: i64) :: [i64] do
    a = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      a[i] = i
    end

    for x <- a do
      a[n - 1 - x] = x * 10 + a[n - 1 - x]
    end

    a
  end

  # a helper writes its parameter and returns it
  defk fill(out :: [i64], v :: i64) :: {[i64], i64} do
    for j <- 0..(len(out) - 1)//1 do
      out[j] = v
    end

    {out, len(out)}
  end

  # the caller rebinds the result: the helper writes in place, no copy
  defk use_fill(n :: i64, v :: i64) :: [i64] do
    out = alloc(i64, n)
    {out, k} = fill(out, v)
    out[0] = k
    out
  end

  # the caller keeps reading the array it passed: the helper copies
  defk keep_fill(n :: i64, v :: i64) :: {[i64], [i64]} do
    out = alloc(i64, n)
    {o2, _} = fill(out, v)
    {out, o2}
  end

  # an input passed to a helper that writes it
  defk fill_input(a :: [i64], v :: i64) :: [i64] do
    {a, _} = fill(a, v)
    a
  end

  # an alias made in a loop body: the write copies, every iteration
  defk alias_per_iter(n :: i64) :: i64 do
    a = alloc(i64, n)

    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        b = a
        a[i] = i + 1
        acc + b[i] + a[i]
    end
  end

  # an inner loop writes an array bound outside both loops while a snapshot
  # taken in the outer body is read after it: copied before the inner loop
  defk nested_hoist(n :: i64) :: i64 do
    a = alloc(i64, n)

    for _ <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        b = a

        for j <- 0..(n - 1)//1 do
          a[j] = a[j] + 1
        end

        acc + b[0] * 1000 + a[0]
    end
  end

  defk branch_in_loop(a :: [i64], c :: i64) :: {[i64], i64} do
    b = a

    for i <- 0..(len(a) - 1)//1 do
      if rem(i, 2) == c do
        a[i] = -1
      end
    end

    {a, b[0]}
  end

  # writes in an early-exit fold over the array it writes
  defk zero_until(a :: [i64], t :: i64) :: {[i64], i64} do
    n =
      Enum.reduce_while(a, 0, fn x, i ->
        if x > t do
          {:halt, i}
        else
          a[i] = 0
          {:cont, i + 1}
        end
      end)

    {a, n}
  end

  defk write_then_read(x :: [i64], y :: [i64]) :: {[i64], i64} do
    x[0] = 5
    {x, y[0]}
  end

  # one array passed twice: the write to one parameter copies
  defk two_args(n :: i64) :: {[i64], i64} do
    a = alloc(i64, n)
    {p, s} = write_then_read(a, a)
    {p, s + a[0]}
  end

  # a helper writing an array the caller reads in later iterations copies
  defk helper_in_loop(n :: i64) :: i64 do
    a = alloc(i64, n)

    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        {t, _} = fill(a, i)
        acc + t[0] + a[0]
    end
  end

  # a binary attribute is copied before a write
  @table <<1, 2, 3, 4>>
  defk attr_write(i :: i64) :: {[u8], i64} do
    t = @table
    t[i] = 9
    {t, @table[i]}
  end
end

defmodule Defk.ValueSemanticsTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.ValueSemanticsTest.K

  @dir Path.join(System.tmp_dir!(), "defk_value_semantics_test")

  defp i64s(list), do: for(x <- list, into: <<>>, do: <<x::64-signed-native>>)
  defp f64s(list), do: for(x <- list, into: <<>>, do: <<x::float-64-native>>)

  defp agree(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # the generated C of kernel `name` in `mod`
  defp kernel_c(mod, name) do
    [_ | chunks] = String.split(mod.__defk_source__(), "/* ---- ")
    Enum.find(chunks, &String.starts_with?(&1, "#{name}/")) || flunk("no kernel #{name}")
  end

  defp copies(c), do: length(String.split(c, "defk_copy_")) - 1

  describe "snapshots" do
    test "b = a; a[0] = 7; b[0] gives the value before the write" do
      assert agree(:snapshot_alloc, [3]) == {:ok, 0}
      assert {:raise, %Enum.OutOfBoundsError{}} = agree(:snapshot_alloc, [0])
    end

    test "for an input array" do
      assert agree(:snapshot_input, [i64s([1, 2])]) == {:ok, {1, 7}}
      assert {:raise, %Enum.OutOfBoundsError{}} = agree(:snapshot_input, [<<>>])
    end

    test "a loop writes the array, the snapshot keeps the old one" do
      a = i64s(Enum.to_list(1..100))
      assert {:ok, {5050, 10_100}} = agree(:snapshot_loop, [a])
    end
  end

  describe "writing an input array" do
    test "leaves the caller's binary unchanged and returns the result" do
      a = i64s([1, 2, 3])
      before = :binary.copy(a)
      assert agree(:write_input, [a, 9]) == {:ok, i64s([9, 2, 3])}
      assert a == before

      b = f64s([1.0, 4.0])
      assert agree(:write_input_loop, [b]) == {:ok, f64s([0.5, 2.0])}
      assert b == f64s([1.0, 4.0])
    end

    test "an unaligned input" do
      a = Defk.Generators.unaligned(i64s([5, 6]))
      assert agree(:write_input, [a, 1]) == {:ok, i64s([1, 6])}
      assert a == i64s([5, 6])
    end

    test "a non-finite input element still raises when read from the copy" do
      bad = <<0x7FF0000000000000::64-native>>
      assert {:raise, %ArgumentError{}} = agree(:write_input_loop, [f64s([1.0]) <> bad])
    end

    test "written in a branch" do
      a = <<1, 2>>
      assert agree(:write_in_branch, [a, true]) == {:ok, <<255, 2>>}
      assert agree(:write_in_branch, [a, false]) == {:ok, <<1, 2>>}
      assert a == <<1, 2>>
    end

    test "an HLL-style register update" do
      regs = <<0, 3, 1, 0>>

      assert agree(:hll_update, [regs, i64s([0, 1, 2, 0]), i64s([2, 1, 5, 1])]) ==
               {:ok, <<2, 3, 5, 0>>}

      assert regs == <<0, 3, 1, 0>>
      assert {:raise, _} = agree(:hll_update, [regs, i64s([0]), i64s([256])])
      assert {:raise, %Enum.OutOfBoundsError{}} = agree(:hll_update, [regs, i64s([4]), i64s([1])])
    end

    test "a binary attribute" do
      assert agree(:attr_write, [1]) == {:ok, {<<1, 9, 3, 4>>, 2}}
    end
  end

  describe "renaming copies nothing" do
    test "swapped rows" do
      assert agree(:swap_rows, [3]) == {:ok, {i64s([1, 2, 3]), i64s([3, 6, 9])}}
    end

    test "one buffer under two names is returned twice" do
      assert agree(:same_twice, [2]) == {:ok, {i64s([0, 0]), i64s([0, 0])}}
    end

    test "a generator over an array its loop writes walks the old array" do
      assert agree(:iter_write, [4]) == {:ok, i64s([30, 21, 12, 3])}
      assert agree(:iter_write, [0]) == {:ok, <<>>}
    end
  end

  describe "helpers" do
    test "a helper writes its parameter and returns it" do
      assert agree(:fill, [i64s([1, 2]), 4]) == {:ok, {i64s([4, 4]), 2}}
      assert agree(:use_fill, [3, 5]) == {:ok, i64s([3, 5, 5])}
      assert agree(:keep_fill, [2, 5]) == {:ok, {i64s([0, 0]), i64s([5, 5])}}

      a = i64s([1, 2])
      assert agree(:fill_input, [a, 8]) == {:ok, i64s([8, 8])}
      assert a == i64s([1, 2])
    end
  end

  describe "where copies are" do
    test "none for renames, a rebound helper result or a written alloc/2 array" do
      for k <- [:swap_rows, :same_twice, :use_fill] do
        assert copies(kernel_c(K, k)) == 0, "#{k}"
      end

      # the snapshot case copies once, at the write
      assert copies(kernel_c(K, :snapshot_alloc)) == 1
    end

    test "once for a written input, before its loop" do
      for k <- [:write_input, :write_input_loop, :write_in_branch, :hll_update, :snapshot_loop] do
        assert copies(kernel_c(K, k)) == 1, "#{k}"
      end

      [before_loop, _] = String.split(kernel_c(K, :hll_update), "while (", parts: 2)
      assert before_loop =~ "defk_copy_u8"
    end

    test "the catalog's kernels have none" do
      mods = [
        Examples.Kernels,
        FuzzySearch.Kernels,
        Geo.Kernels,
        Rolling.Kernels,
        Blur.Kernels,
        Orders.Kernels,
        Clamp.Kernels,
        Example.Kernels
      ]

      for mod <- mods do
        assert copies(mod.__defk_source__()) == 0, inspect(mod)
      end
    end
  end

  describe "under forced yields" do
    # every safepoint yields and resumes; the copy made before the loop is
    # in an owned binary, which the resumed kernel keeps writing
    test "writes after a copy resume where they left off" do
      n = 5_000
      regs = :binary.copy(<<0>>, 1024)
      idx = i64s(for k <- 0..(n - 1), do: rem(k * 7919, 1024))
      ranks = i64s(for k <- 0..(n - 1), do: rem(k * 31, 50))
      a = i64s(Enum.to_list(1..n))

      K.__defk_force_yields__(true)

      try do
        for {f, args} <- [
              hll_update: [regs, idx, ranks],
              snapshot_loop: [a],
              write_input_loop: [f64s(for k <- 1..n, do: k * 1.0)],
              iter_write: [n],
              keep_fill: [n, 3]
            ] do
          assert {:ok, _} = agree(f, args)
        end
      after
        K.__defk_force_yields__(false)
      end

      assert regs == :binary.copy(<<0>>, 1024)
    end
  end

  describe "compile errors" do
    defp compile(body) do
      File.mkdir_p!(@dir)
      mod = "Defk.ValueSemanticsTest.M#{System.unique_integer([:positive])}"
      path = Path.join(@dir, "#{String.replace(mod, ".", "_")}.ex")
      File.write!(path, "defmodule #{mod} do\n  use Defk\n\n#{body}\nend\n")

      try do
        Code.compile_file(path)
        :ok
      rescue
        e in CompileError -> Exception.message(e)
      end
    end

    test "a helper that writes a parameter it doesn't return" do
      msg =
        compile("""
          defk emit(out :: [i64], at :: i64) :: i64 do
            out[at] = 1
            at + 1
          end

          defk f(n :: i64) :: [i64] do
            out = alloc(i64, n)
            _ = emit(out, 0)
            out
          end
        """)

      assert msg =~ "emit/2 writes to its array parameter out but doesn't return it"
      assert msg =~ "{out, at + 1}"
      assert msg =~ "(defk write-not-returned"
    end

    test "an array bound again in a loop body and read after the loop" do
      msg =
        compile("""
          defk f(n :: i64) :: [i64] do
            prev = alloc(i64, n)
            cur = alloc(i64, n)

            for _ <- 1..3//1 do
              {prev, cur} = {cur, prev}
              cur[0] = prev[0] + 1
            end

            cur
          end
        """)

      assert msg =~ "the array cur is bound again inside this loop body"
      assert msg =~ "(defk array-rebind-in-loop"
    end

    test "bound again in a loop body but not read after it is fine" do
      assert :ok ==
               compile("""
                 defk f(n :: i64) :: i64 do
                   a = alloc(i64, n)

                   for i <- 0..(n - 1)//1, reduce: 0 do
                     acc ->
                       a = alloc(i64, n)
                       a[i] = i
                       acc + a[i]
                   end
                 end
               """)
    end
  end

  agreement(K, [
    :snapshot_input,
    :snapshot_loop,
    :sum,
    :write_input,
    :write_input_loop,
    :write_in_branch,
    :fill,
    :fill_input,
    snapshot_alloc: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    swap_rows: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    same_twice: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    iter_write: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    use_fill: [args: StreamData.fixed_list([StreamData.integer(0..100), G.i64()])],
    keep_fill: [args: StreamData.fixed_list([StreamData.integer(0..100), G.i64()])],
    attr_write: [args: StreamData.fixed_list([G.i64(-2..6)])],
    alias_per_iter: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    nested_hoist: [args: StreamData.fixed_list([StreamData.integer(0..60)])],
    branch_in_loop: [args: StreamData.fixed_list([G.array(:i64), G.i64(-1..2)])],
    zero_until: [args: StreamData.fixed_list([G.array(:i64), G.i64()])],
    write_then_read: [args: StreamData.fixed_list([G.array(:i64), G.array(:i64)])],
    two_args: [args: StreamData.fixed_list([StreamData.integer(0..20)])],
    helper_in_loop: [args: StreamData.fixed_list([StreamData.integer(0..60)])],
    hll_update: [
      args:
        StreamData.bind(StreamData.integer(1..64), fn m ->
          StreamData.fixed_list([
            G.array(:u8, length: m),
            G.array(:i64, of: StreamData.integer(0..(m - 1))),
            G.array(:i64, of: StreamData.integer(0..255))
          ])
        end)
    ]
  ])
end
