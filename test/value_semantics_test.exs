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

    for i <- 0..(length(a) - 1)//1 do
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
    for i <- 0..(length(a) - 1)//1 do
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
    for k <- 0..(min(length(idx), length(ranks)) - 1)//1 do
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
    for j <- 0..(length(out) - 1)//1 do
      out[j] = v
    end

    {out, length(out)}
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

    for i <- 0..(length(a) - 1)//1 do
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

  # so is a binary literal
  defk lit_write(i :: i64) :: [u8] do
    t = "abc"
    t[i] = 65
    t
  end

  # a binary attribute is copied before a write
  @table <<1, 2, 3, 4>>
  defk attr_write(i :: i64) :: {[u8], i64} do
    t = @table
    t[i] = 9
    {t, @table[i]}
  end

  # A helper call in one branch whose other branch reads the array
  # (defk-33b): the caller rebinds the array to the result, so the old buffer
  # is not read again and the helper writes in place. Reading it in the other
  # branch, which runs instead, is not a read after the call.
  defk put1(out :: [u8], i :: i64) :: [u8] do
    out[i] = 1
    out
  end

  # the ticket's reproduction: quadratic time and memory before the fix
  defk halt_reads(n :: i64) :: i64 do
    out = alloc(u8, n)

    {out, s} =
      Enum.reduce_while(0..(n - 1)//1, {out, 0}, fn i, {out, s} ->
        if i == n - 1 do
          {:halt, {out, s + out[0]}}
        else
          out = put1(out, i)
          {:cont, {out, s}}
        end
      end)

    s + out[1]
  end

  # the same with the call hoisted out of the branch (never copied)
  defk halt_reads_hoisted(n :: i64) :: i64 do
    out = alloc(u8, n)

    {out, s} =
      Enum.reduce_while(0..(n - 1)//1, {out, 0}, fn i, {out, s} ->
        out = put1(out, rem(i, n))

        if i == n - 1 do
          {:halt, {out, s + out[0]}}
        else
          {:cont, {out, s}}
        end
      end)

    s + out[1]
  end

  # the call in the halt arm's tuple, the read in a case arm
  defk case_cont(n :: i64) :: i64 do
    out = alloc(u8, n)

    {out, s} =
      Enum.reduce_while(0..(n - 1)//1, {out, 0}, fn i, {out, s} ->
        case rem(i, 3) do
          0 -> {:cont, {out, s + out[i]}}
          _ -> {:cont, {put1(out, i), s}}
        end
      end)

    s + out[n - 1]
  end

  defk if_cont(n :: i64) :: i64 do
    out = alloc(u8, n)

    {out, s} =
      Enum.reduce_while(0..(n - 1)//1, {out, 0}, fn i, {out, s} ->
        if rem(i, 2) == 0 do
          {:cont, {out, s + out[i] + out[0]}}
        else
          out = put1(out, i)
          out[0] = 1
          {:cont, {out, s}}
        end
      end)

    s + out[n - 1]
  end

  defk cond_cont(n :: i64) :: i64 do
    out = alloc(u8, n)

    {out, s} =
      Enum.reduce_while(0..(n - 1)//1, {out, 0}, fn i, {out, s} ->
        cond do
          rem(i, 3) == 0 -> {:cont, {put1(out, i), s}}
          rem(i, 3) == 1 -> {:cont, {out, s + out[i - 1]}}
          true -> {:cont, {out, s + 2 * out[0]}}
        end
      end)

    s + out[0]
  end

  # for ..., reduce: with its helper call in the body and the read in a
  # branch after it
  defk for_reduce(n :: i64) :: i64 do
    out = alloc(u8, n)

    {out, s} =
      for i <- 0..(n - 1)//1, reduce: {out, 0} do
        {out, s} ->
          out = put1(out, i)
          {out, if(rem(i, 2) == 0, do: s + out[i - div(i, 2)], else: s)}
      end

    s + out[0]
  end

  # Negative cases: the pre-call buffer is read later, so the helper copies.
  # An array bound outside the loop and rebound in a branch of its body is
  # the old array again in the next iteration.
  defk outer_in_branch(n :: i64) :: i64 do
    out = alloc(u8, n)

    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        if i > 2 do
          out = put1(out, i)
          acc + out[i] + out[0] + out[i - 1]
        else
          acc + out[0]
        end
    end
  end

  # rebound in a branch and read after the if, where the rebinding is not seen
  defk read_after_if(n :: i64, c :: bool) :: i64 do
    out = alloc(u8, n)

    x =
      if c do
        out = put1(out, 0)
        out[0]
      else
        out[1]
      end

    x + 10 * out[0]
  end

  # read in the same statement, after the if
  defk read_after_in_stmt(n :: i64, c :: bool) :: i64 do
    out = alloc(u8, n)

    x =
      if c do
        out = put1(out, 0)
        out[0]
      else
        0
      end + 10 * out[0]

    x
  end

  # an alias of the accumulator read after the call in the same branch
  defk alias_in_branch(n :: i64) :: i64 do
    out = alloc(u8, n)

    {_, s} =
      Enum.reduce_while(0..(n - 1)//1, {out, 0}, fn i, {out, s} ->
        if rem(i, 2) == 0 do
          {:cont, {out, s + out[0]}}
        else
          old = out
          out = put1(out, 0)
          {:cont, {out, s + old[0] + out[0]}}
        end
      end)

    s
  end

  # A helper call in one branch whose condition reads the array, and whose
  # other branch's tail hands it on (defk-tif): the condition ran before the
  # call, the other branch runs instead of it, and the next iteration reads
  # the helper's result, so the helper writes in place. (`step/1` is below.)
  defk halt_on(n :: i64, m :: i64) :: [i64] do
    a0 = alloc(i64, 4)

    Enum.reduce_while(0..n//1, a0, fn _, a ->
      if a[0] == m do
        {:halt, a}
      else
        a = step(a)
        {:cont, a}
      end
    end)
  end

  defk halt_on_tuple(n :: i64, m :: i64) :: i64 do
    a0 = alloc(i64, 4)

    {a, s} =
      Enum.reduce_while(0..n//1, {a0, 0}, fn i, {a, s} ->
        if a[0] >= m do
          {:halt, {a, s}}
        else
          a = step(a)
          {:cont, {a, s + i}}
        end
      end)

    s + 1000 * a[0]
  end

  defk halt_on_cond(n :: i64, m :: i64) :: [i64] do
    a0 = alloc(i64, 4)

    Enum.reduce_while(0..n//1, a0, fn i, a ->
      cond do
        a[0] >= m -> {:halt, a}
        a[1] > i -> {:cont, a}
        true -> {:cont, step(a)}
      end
    end)
  end

  defk halt_on_case(n :: i64, m :: i64) :: [i64] do
    a0 = alloc(i64, 4)

    Enum.reduce_while(0..n//1, a0, fn _, a ->
      case a[0] - m do
        0 ->
          {:halt, a}

        _ ->
          a = step(a)
          {:cont, a}
      end
    end)
  end

  # the call is an inner reduce_while whose initial tuple holds the
  # accumulator, in one branch of the outer body
  defk halt_on_nested(n :: i64, m :: i64) :: [i64] do
    a0 = alloc(i64, 4)

    Enum.reduce_while(0..n//1, a0, fn _, a ->
      if a[0] >= m do
        {:halt, a}
      else
        {a, _, _} =
          Enum.reduce_while(0..3//1, {a, -1, 0}, fn j, {b, x, y} ->
            b[j] = b[j] + 1
            b = step(b)
            {:cont, {b, x + j, y}}
          end)

        {:cont, a}
      end
    end)
  end

  # Negative cases: the buffer before the call is read later, so it copies.
  # An alias read after the call: old[0] is the value before step/1.
  defk halt_on_alias(n :: i64, m :: i64) :: [i64] do
    a0 = alloc(i64, 4)

    Enum.reduce_while(0..n//1, a0, fn _, a ->
      if a[0] >= m do
        {:halt, a}
      else
        old = a
        a = step(a)
        a[1] = a[1] + old[0]
        {:cont, a}
      end
    end)
  end

  # a condition after the arm, in the same statement, reads the array from
  # before the call (in place, it would see the write)
  defk cond_after_arm(c :: bool) :: i64 do
    a = alloc(i64, 2)

    x =
      if c do
        a = step(a)
        a[0]
      else
        0
      end + if(a[0] > 0, do: 10, else: 20)

    x
  end

  # bound outside the loop: the condition reads the outer, unchanged array
  # in every iteration (in place, it would halt after one)
  defk halt_on_outer(n :: i64) :: i64 do
    a = alloc(i64, 4)

    Enum.reduce_while(0..n//1, 0, fn _, s ->
      if a[0] > 0 do
        {:halt, s}
      else
        a = step(a)
        {:cont, s + a[0]}
      end
    end)
  end

  # A loop whose range or initial value reads the array its body writes and
  # returns (defk-8tw): the first generator's range and the initial value are
  # evaluated once, before the first iteration, and later iterations read the
  # accumulator, so the array is not copied.
  defk range_bound(n :: i64, r :: i64) :: [i64] do
    st0 = alloc(i64, 8)
    st0[0] = 2

    for _ <- 0..r//1, reduce: st0 do
      st ->
        st =
          for k <- 1..(st[0] - 1)//1, reduce: st do
            st ->
              st[k] = st[k] + n
              st
          end

        st[0] = min(st[0] + 1, 8)
        st
    end
  end

  defk range_top(n :: i64) :: [i64] do
    st = alloc(i64, 8)
    st[0] = min(max(n, 1), 8)

    for k <- 0..(st[0] - 1)//1, reduce: st do
      st ->
        st[k] = st[k] + k
        st
    end
  end

  defk range_len(r :: i64) :: [i64] do
    st0 = alloc(i64, 8)

    for _ <- 0..r//1, reduce: st0 do
      st ->
        for k <- 0..(length(st) - 1)//1, reduce: st do
          st ->
            st[k] = st[k] + k
            st
        end
    end
  end

  defk range_step(r :: i64) :: [i64] do
    st0 = alloc(i64, 8)

    for _ <- 0..r//1, reduce: st0 do
      st ->
        for k <- 1..7//(rem(st[0], 3) + 1), reduce: st do
          st ->
            st[k] = st[k] + 1
            st[0] = st[0] + 1
            st
        end
    end
  end

  # an inner reduce_while whose range and initial value read the array, in
  # one branch of an outer reduce_while chosen by reading it
  defk range_init(n :: i64, m :: i64) :: [i64] do
    st0 = alloc(i64, 8)
    st0[0] = 3

    Enum.reduce_while(0..n//1, st0, fn _, st ->
      if st[1] >= m do
        {:halt, st}
      else
        {st, _} =
          Enum.reduce_while(1..(st[0] - 1)//1, {st, st[0]}, fn j, {st, x} ->
            st[j] = st[j] + x
            {:cont, {st, x - 1}}
          end)

        st[0] = min(st[0] + 1, 8)
        {:cont, st}
      end
    end)
  end

  defk init_reads(r :: i64) :: [i64] do
    st0 = alloc(i64, 8)

    for _ <- 0..r//1, reduce: st0 do
      st ->
        {st, _} =
          for j <- 0..3//1, reduce: {st, st[0]} do
            {st, x} ->
              st[j] = band(st[j] + x + 1, 0xFFFF)
              {st, x + 1}
          end

        st
    end
  end

  # Negative cases: the buffer before the loop is read while it runs or
  # after it, so it copies. An alias read after the loop: old[0] is 3.
  defk range_old_after(n :: i64) :: i64 do
    st = alloc(i64, 8)
    st[0] = 3
    old = st

    st2 =
      for k <- 0..(st[0] - 1)//1, reduce: st do
        st ->
          st[k] = st[k] + n
          st
      end

    old[0] * 1000 + st2[0]
  end

  # a later generator's range is evaluated again for each i: it reads the
  # outer st (in place, it would see the writes)
  defk range_second_gen(r :: i64) :: i64 do
    st = alloc(i64, 4)
    st[0] = 2

    st =
      for _ <- 0..r//1, k <- 0..st[0]//1, reduce: st do
        st ->
          st[1] = st[1] + k
          st[0] = st[0] + 1
          st
      end

    st[0]
  end

  # the generator walks the array while the loop writes the accumulator
  defk range_walks(n :: i64) :: [i64] do
    st = alloc(i64, 4)
    st[0] = n

    for x <- st, reduce: st do
      st ->
        st[1] = st[1] + x + 1
        st
    end
  end

  # a filter reads the outer st on every iteration
  defk range_filter(r :: i64) :: i64 do
    st = alloc(i64, 4)

    st =
      for _ <- 0..r//1, st[0] < 2, reduce: st do
        st ->
          st[0] = st[0] + 1
          st
      end

    st[0]
  end

  # A helper that writes its array parameter, then binds the name again from
  # a call or a reduce loop and returns the new binding (defk-3z5): the array
  # returned carries the write, so nothing is lost and nothing is copied.
  defk step(a :: [i64]) :: [i64] do
    a[0] = a[0] + 1
    a
  end

  defk bump(a :: [i64]) :: [i64] do
    a[1] = 7
    a = step(a)
    a
  end

  # the ticket's reproduction
  defk rebind_call(n :: i64) :: [i64] do
    bump(alloc(i64, n))
  end

  defk swap2(r :: [i64], base :: i64) :: [i64] do
    x = r[base]
    r[base] = r[base + 1] * 3
    r[base + 1] = x
    r
  end

  # argon2's fill/6: r written in a for, then `r = for ..., reduce: r`
  defk fill_shape(mem :: [i64], r :: [i64], cb :: i64) :: {[i64], [i64]} do
    for k <- 0..7//1 do
      r[k] = band(mem[k], 0xFFFF) + k
    end

    r =
      for i <- 0..3//1, reduce: r do
        r -> swap2(r, 2 * i)
      end

    for k <- 0..7//1 do
      mem[cb + k] = band(mem[cb + k] + r[k], 0xFFFFFF)
    end

    {mem, r}
  end

  defk rebind_reduce(a :: [i64]) :: {[i64], [i64]} do
    mem = alloc(i64, 16)

    for k <- 0..(min(length(a), 16) - 1)//1 do
      mem[k] = a[k]
    end

    fill_shape(mem, alloc(i64, 8), 8)
  end

  # argon2's segment/12: mem written directly, then
  # `{mem, r} = for ..., reduce: {mem, r}`
  defk seg_shape(mem :: [i64], r :: [i64], n :: i64) :: {[i64], [i64]} do
    mem[0] = n
    mem[1] = n + 1

    {mem, r} =
      for k <- 0..(n - 1)//1, reduce: {mem, r} do
        {mem, r} ->
          r[rem(k, 8)] = mem[rem(k, 16)] + k
          fill_shape(mem, r, 8)
      end

    {mem, r}
  end

  defk rebind_tuple(n :: i64) :: {[i64], [i64]} do
    seg_shape(alloc(i64, 16), alloc(i64, 8), n)
  end

  # the same helpers on the caller's arrays: copied once, on entry
  defk rebind_input(mem :: [i64], r :: [i64], n :: i64) :: {[i64], [i64]} do
    seg_shape(mem, r, n)
  end
end

defmodule Defk.ValueSemanticsTest do
  use ExUnit.Case, async: true
  use Defk.Properties
  import Defk.TestKit, only: [compile: 2, f64s: 1, forced: 2, i64s: 1, kernel_c: 2]

  alias Defk.ValueSemanticsTest.K

  defp agree(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

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
      assert agree(:lit_write, [2]) == {:ok, "abA"}
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

    test "the catalog's kernels have none, except one deliberate copy" do
      mods = [
        Examples.Kernels,
        FuzzySearch.Kernels,
        Geo.Kernels,
        Rolling.Kernels,
        Blur.Kernels,
        Gorilla.Kernels,
        LzSnappy.Kernels,
        Hashes.Kernels,
        Cosine.Kernels
      ]

      for mod <- mods do
        assert copies(mod.__defk_c_source__()) == 0, inspect(mod)
      end

      # Hll.Kernels.update_many writes into its input state: one copy, made
      # before the loop (the caller's binary is never changed)
      assert copies(Hll.Kernels.__defk_c_source__()) == 1
    end
  end

  describe "a helper call in one branch (defk-33b)" do
    @in_branch [:halt_reads, :halt_reads_hoisted, :case_cont, :if_cont, :cond_cont, :for_reduce]
    @still_copied [:outer_in_branch, :read_after_if, :read_after_in_stmt, :alias_in_branch]

    defp copy_notes(kernel) do
      for {{^kernel, _}, _, {:copy, :copied, why}} <- K.__defk_report__(), do: why
    end

    # no copy note and no copy in the C, for each kernel
    defp assert_in_place(kernels) do
      for k <- kernels do
        assert copy_notes(k) == [], "#{k}: #{inspect(copy_notes(k))}"
        assert copies(kernel_c(K, k)) == 0, "#{k}"
      end
    end

    # a copy note and a copy in the C, for each kernel
    defp assert_copied(kernels) do
      for k <- kernels do
        assert [_ | _] = copy_notes(k), "#{k}"
        assert copies(kernel_c(K, k)) > 0, "#{k}"
      end
    end

    test "writes in place when the other branch reads the array" do
      assert_in_place(@in_branch)
    end

    test "still copies when the buffer before the call is read later" do
      assert_copied(@still_copied)
    end

    test "the reproduction is linear: one buffer, however long the loop" do
      assert agree(:halt_reads, [100_000]) == {:ok, 2}
      # in place, out[3] would be 1 again at i = 4, giving 3
      assert agree(:outer_in_branch, [5]) == {:ok, 2}
      assert agree(:read_after_if, [2, true]) == {:ok, 1}
      assert agree(:read_after_in_stmt, [2, true]) == {:ok, 1}

      forced(K, fn ->
        for k <- @in_branch, do: agree(k, [2_000])
      end)
    end
  end

  describe "a helper call in a branch chosen by reading the array (defk-tif)" do
    @chosen [:halt_on, :halt_on_tuple, :halt_on_cond, :halt_on_case, :halt_on_nested]
    @chosen_copied [:halt_on_alias, :halt_on_outer, :cond_after_arm]

    test "writes in place when the condition reads it and the other tail returns it" do
      assert_in_place(@chosen)
    end

    test "still copies when the buffer before the call is read later" do
      assert_copied(@chosen_copied)
    end

    test "agrees with Elixir mode, also under forced yields" do
      assert agree(:halt_on, [100_000, 5]) == {:ok, i64s([5, 0, 0, 0])}
      assert agree(:halt_on, [100_000, -1]) == {:ok, i64s([100_001, 0, 0, 0])}
      assert agree(:halt_on_tuple, [10, 3]) == {:ok, 3003}
      assert {:ok, _} = agree(:halt_on_cond, [50, 20])
      assert agree(:halt_on_case, [50, 7]) == {:ok, i64s([7, 0, 0, 0])}
      assert {:ok, _} = agree(:halt_on_nested, [50, 30])
      # in place, old[0] would be the value after step/1
      assert agree(:halt_on_alias, [3, 10]) == {:ok, i64s([4, 6, 0, 0])}
      assert agree(:halt_on_outer, [5]) == {:ok, 6}
      assert agree(:cond_after_arm, [true]) == {:ok, 21}

      forced(K, fn ->
        for k <- @chosen ++ [:halt_on_alias], m <- [-1, 7, 2_000] do
          assert {:ok, _} = agree(k, [2_000, m])
        end

        assert agree(:halt_on_outer, [2_000]) == {:ok, 2_001}
      end)
    end
  end

  describe "a loop whose range or init reads the array it writes (defk-8tw)" do
    @once [:range_bound, :range_top, :range_len, :range_step, :range_init, :init_reads]
    @once_copied [:range_old_after, :range_second_gen, :range_walks, :range_filter]

    test "writes in place: the range and init are evaluated before the first write" do
      assert_in_place(@once)
    end

    test "still copies when the buffer before the loop is read while it runs or after it" do
      assert_copied(@once_copied)
    end

    test "agrees with Elixir mode, also under forced yields" do
      assert agree(:range_bound, [1, 0]) == {:ok, i64s([3, 1, 0, 0, 0, 0, 0, 0])}
      assert {:ok, _} = agree(:range_bound, [3, 20])
      assert agree(:range_top, [4]) == {:ok, i64s([4, 1, 2, 3, 0, 0, 0, 0])}
      assert agree(:range_len, [1]) == {:ok, i64s(for k <- 0..7, do: 2 * k)}
      assert {:ok, _} = agree(:range_step, [10])
      assert {:ok, _} = agree(:range_init, [100, 40])
      assert {:ok, _} = agree(:init_reads, [10])
      # in place, old[0] would be 3 + n
      assert agree(:range_old_after, [5]) == {:ok, 3008}
      # in place, the second range would grow with st[0]
      assert agree(:range_second_gen, [1]) == {:ok, 8}
      # in place, x would see st[1] after the first write
      assert agree(:range_walks, [1]) == {:ok, i64s([1, 5, 0, 0])}
      # in place, the filter would stop at st[0] = 2
      assert agree(:range_filter, [5]) == {:ok, 6}

      forced(K, fn ->
        for k <- [:range_bound, :range_init], m <- [-1, 7, 2_000] do
          assert {:ok, _} = agree(k, [2_000, m])
        end

        for k <- [:range_len, :range_step, :init_reads, :range_second_gen, :range_filter] do
          assert {:ok, _} = agree(k, [2_000])
        end

        for k <- [:range_top, :range_old_after, :range_walks],
            do: assert({:ok, _} = agree(k, [7]))
      end)
    end
  end

  describe "a written parameter bound again and returned (defk-3z5)" do
    @rebound [:rebind_call, :rebind_reduce, :rebind_tuple]

    test "is returned, and nothing is copied" do
      assert agree(:rebind_call, [2]) == {:ok, i64s([1, 7])}
      assert {:ok, _} = agree(:rebind_reduce, [i64s(Enum.to_list(1..16))])
      assert {:ok, _} = agree(:rebind_tuple, [5])

      assert_in_place(@rebound)
    end

    test "the caller's arrays are copied, and stay unchanged" do
      mem = i64s(Enum.to_list(1..16))
      r = i64s(List.duplicate(0, 8))
      assert {:ok, _} = agree(:rebind_input, [mem, r, 3])
      assert mem == i64s(Enum.to_list(1..16))
      assert r == i64s(List.duplicate(0, 8))
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

      forced(K, fn ->
        for {f, args} <- [
              hll_update: [regs, idx, ranks],
              snapshot_loop: [a],
              write_input_loop: [f64s(for k <- 1..n, do: k * 1.0)],
              iter_write: [n],
              keep_fill: [n, 3]
            ] do
          assert {:ok, _} = agree(f, args)
        end
      end)

      assert regs == :binary.copy(<<0>>, 1024)
    end
  end

  describe "compile errors" do
    test "a helper that writes a parameter it doesn't return" do
      msg =
        compile(__MODULE__, """
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

    test "a written parameter bound again to a new array (defk-3z5)" do
      msg =
        compile(__MODULE__, """
          defk g(a :: [i64]) :: [i64] do
            a[0] = 1
            a = alloc(i64, 4)
            a
          end

          defk f(n :: i64) :: [i64] do
            g(alloc(i64, n))
          end
        """)

      assert msg =~ "g/1 writes to its array parameter a but doesn't return it"
      assert msg =~ "a is bound again after this write"
      refute msg =~ "{a, a}"
      assert msg =~ "(defk write-not-returned"
    end

    test "a written parameter bound again from a helper's new array" do
      msg =
        compile(__MODULE__, """
          defk fresh(a :: [i64]) :: [i64] do
            b = alloc(i64, length(a))
            b[0] = a[0]
            b
          end

          defk g(a :: [i64]) :: {[i64], i64} do
            a[0] = 1
            a = fresh(a)
            {a, 2}
          end

          defk f(n :: i64) :: [i64] do
            {a, _} = g(alloc(i64, n))
            a
          end
        """)

      assert msg =~ "g/1 writes to its array parameter a but doesn't return it"
      assert msg =~ "a is bound again after this write"
      refute msg =~ "{a, a"
    end

    test "a written parameter bound again from a reduce loop that replaces it" do
      msg =
        compile(__MODULE__, """
          defk g(a :: [i64]) :: [i64] do
            a[0] = 1

            a =
              for i <- 0..3//1, reduce: a do
                a ->
                  b = alloc(i64, 4)
                  b[0] = a[0] + i
                  b
              end

            a
          end

          defk f(n :: i64) :: [i64] do
            g(alloc(i64, n))
          end
        """)

      assert msg =~ "g/1 writes to its array parameter a but doesn't return it"
    end

    test "a written parameter returned under another name is fine" do
      assert :ok ==
               compile(__MODULE__, """
                 defk step(a :: [i64]) :: [i64] do
                   a[0] = a[0] + 1
                   a
                 end

                 defk g(a :: [i64]) :: [i64] do
                   a[1] = 7
                   b = step(a)
                   b
                 end

                 defk f(n :: i64) :: [i64] do
                   g(alloc(i64, n))
                 end
               """)
    end

    test "an array bound again in a loop body and read after the loop" do
      msg =
        compile(__MODULE__, """
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
               compile(__MODULE__, """
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
    :step,
    :bump,
    :swap2,
    :fill_shape,
    snapshot_alloc: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    swap_rows: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    same_twice: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    iter_write: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    use_fill: [args: StreamData.fixed_list([StreamData.integer(0..100), G.i64()])],
    keep_fill: [args: StreamData.fixed_list([StreamData.integer(0..100), G.i64()])],
    attr_write: [args: StreamData.fixed_list([G.i64(-2..6)])],
    lit_write: [args: StreamData.fixed_list([G.i64(-2..6)])],
    alias_per_iter: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    nested_hoist: [args: StreamData.fixed_list([StreamData.integer(0..60)])],
    branch_in_loop: [args: StreamData.fixed_list([G.array(:i64), G.i64(-1..2)])],
    zero_until: [args: StreamData.fixed_list([G.array(:i64), G.i64()])],
    write_then_read: [args: StreamData.fixed_list([G.array(:i64), G.array(:i64)])],
    two_args: [args: StreamData.fixed_list([StreamData.integer(0..20)])],
    helper_in_loop: [args: StreamData.fixed_list([StreamData.integer(0..60)])],
    put1: [args: StreamData.fixed_list([G.array(:u8), G.i64(-2..8)])],
    halt_reads: [args: StreamData.fixed_list([StreamData.integer(0..300)])],
    halt_reads_hoisted: [args: StreamData.fixed_list([StreamData.integer(0..300)])],
    case_cont: [args: StreamData.fixed_list([StreamData.integer(0..300)])],
    if_cont: [args: StreamData.fixed_list([StreamData.integer(0..300)])],
    cond_cont: [args: StreamData.fixed_list([StreamData.integer(0..300)])],
    for_reduce: [args: StreamData.fixed_list([StreamData.integer(0..300)])],
    outer_in_branch: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    alias_in_branch: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    read_after_if: [
      args: StreamData.fixed_list([StreamData.integer(0..4), StreamData.boolean()])
    ],
    read_after_in_stmt: [
      args: StreamData.fixed_list([StreamData.integer(0..4), StreamData.boolean()])
    ],
    halt_on: [
      args: StreamData.fixed_list([StreamData.integer(-1..200), StreamData.integer(-1..60)])
    ],
    halt_on_tuple: [
      args: StreamData.fixed_list([StreamData.integer(-1..200), StreamData.integer(-1..60)])
    ],
    halt_on_cond: [
      args: StreamData.fixed_list([StreamData.integer(-1..200), StreamData.integer(-1..60)])
    ],
    halt_on_case: [
      args: StreamData.fixed_list([StreamData.integer(-1..200), StreamData.integer(-1..60)])
    ],
    halt_on_nested: [
      args: StreamData.fixed_list([StreamData.integer(-1..200), StreamData.integer(-1..60)])
    ],
    halt_on_alias: [
      args: StreamData.fixed_list([StreamData.integer(-1..200), StreamData.integer(-1..60)])
    ],
    halt_on_outer: [args: StreamData.fixed_list([StreamData.integer(-1..200)])],
    cond_after_arm: [args: StreamData.fixed_list([StreamData.boolean()])],
    range_bound: [
      args: StreamData.fixed_list([StreamData.integer(-1..200), StreamData.integer(-1..60)])
    ],
    range_top: [args: StreamData.fixed_list([G.i64(-2..12)])],
    range_len: [args: StreamData.fixed_list([StreamData.integer(-1..200)])],
    range_step: [args: StreamData.fixed_list([StreamData.integer(-1..200)])],
    range_init: [
      args: StreamData.fixed_list([StreamData.integer(-1..200), StreamData.integer(-1..60)])
    ],
    init_reads: [args: StreamData.fixed_list([StreamData.integer(-1..200)])],
    range_old_after: [args: StreamData.fixed_list([G.i64()])],
    range_second_gen: [args: StreamData.fixed_list([StreamData.integer(-1..60)])],
    range_walks: [args: StreamData.fixed_list([G.i64()])],
    range_filter: [args: StreamData.fixed_list([StreamData.integer(-1..200)])],
    rebind_call: [args: StreamData.fixed_list([StreamData.integer(0..20)])],
    rebind_reduce: [args: StreamData.fixed_list([G.array(:i64)])],
    rebind_tuple: [args: StreamData.fixed_list([StreamData.integer(0..50)])],
    seg_shape: [
      args:
        StreamData.fixed_list([
          G.array(:i64, of: StreamData.integer(-1000..1000)),
          G.array(:i64, of: StreamData.integer(-1000..1000)),
          StreamData.integer(-1..20)
        ])
    ],
    rebind_input: [
      args:
        StreamData.fixed_list([
          G.array(:i64, of: StreamData.integer(-1000..1000)),
          G.array(:i64, of: StreamData.integer(-1000..1000)),
          StreamData.integer(0..50)
        ])
    ],
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
