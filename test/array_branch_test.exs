# Arrays through if/cond/case branches, and returning input arrays
# (defk-gqk). The value of a branch may be any of its arms' arrays, input or
# owned: natively the branch's temporary holds that array's view, no elements
# copied. A view of an input array is re-bound after every resume, like the
# parameter it came from (the binary may have moved in a GC between two
# steps), and a write to it copies it first (value semantics). A returned
# array the kernel never wrote is the caller's own binary.

defmodule Defk.ArrayBranchTest.K do
  use Defk

  defk total(x :: [i64]) :: i64 do
    for v <- x, reduce: 0 do
      s -> band(s + band(v, 0xFFFF), 0xFFFFFFFF)
    end
  end

  # walks x `reps` times: under forced yields it yields (and resumes) inside
  # every walk
  defk walk(x :: [i64], reps :: i64) :: i64 do
    for r <- 1..reps//1, reduce: 0 do
      acc -> band(acc + total(x) * r, 0xFFFFFFFF)
    end
  end

  defk two_inputs(c :: bool, a :: [i64], b :: [i64], reps :: i64) :: i64 do
    x = if c, do: a, else: b
    walk(x, reps)
  end

  # returned after the walk: the caller's binary when it is the input
  defk input_or_alloc(c :: bool, a :: [i64], n :: i64, reps :: i64) :: {[i64], i64} do
    x = if c, do: a, else: alloc(i64, n)
    s = walk(x, reps)
    {x, s}
  end

  defk alloc_or_alloc(c :: bool, n :: i64) :: [i64] do
    o = alloc(i64, n)
    o[0] = 1
    p = alloc(i64, n + 1)
    p[0] = 2
    x = if c, do: o, else: p
    x[1] = 3
    x
  end

  # o and p are read after x is written: x's write copies
  defk alloc_or_alloc_kept(c :: bool, n :: i64) :: {[i64], [i64], [i64]} do
    o = alloc(i64, n)
    p = alloc(i64, n)
    x = if c, do: o, else: p
    x[0] = 5
    {x, o, p}
  end

  # o is written after x took it: x keeps the array from before the write
  defk write_source_after(c :: bool, n :: i64, reps :: i64) :: {[i64], [i64]} do
    o = alloc(i64, n)
    p = alloc(i64, n)
    x = if c, do: o, else: p

    for i <- 0..(n - 1)//1 do
      o[i] = i + reps
    end

    {x, o}
  end

  defk nested(c :: bool, d :: bool, a :: [i64], b :: [i64], reps :: i64) :: {[i64], i64} do
    x =
      if c do
        if d, do: a, else: b
      else
        o = alloc(i64, 3)
        o[0] = 7
        o
      end

    {x, walk(x, reps)}
  end

  defk cond_case(k :: i64, a :: [i64], b :: [i64], reps :: i64) :: {[i64], i64} do
    x =
      cond do
        k < 0 -> a
        k < 10 -> b
        true -> alloc(i64, 2)
      end

    y =
      case rem(k, 3) do
        0 -> x
        1 -> a
        _ -> b
      end

    {y, walk(x, reps) + walk(y, 1)}
  end

  # an array as an element of a branch's tuples
  defk in_tuple(c :: bool, a :: [i64], b :: [u8], reps :: i64) :: {[i64], [u8], i64} do
    {x, y, k} = if c, do: {a, b, 1}, else: {alloc(i64, 2), b, 2}
    {x, y, walk(x, reps) * k}
  end

  # writes after the branch: a and b stay the caller's, unchanged
  defk write_after(c :: bool, a :: [i64], b :: [i64], v :: i64) :: {[i64], [i64], [i64]} do
    x = if c, do: a, else: b
    x[0] = v
    {x, a, b}
  end

  # a write in a loop after the branch: x is copied before the loop
  defk write_loop_after(c :: bool, a :: [i64], n :: i64) :: [i64] do
    x = if c, do: a, else: alloc(i64, n)

    for i <- 0..(len(x) - 1)//1 do
      x[i] = band(x[i], 0xFFFF) + i
    end

    x
  end

  defk return_input(a :: [i64]) :: [i64] do
    a
  end

  defk return_inputs(a :: [i64], b :: [u8], reps :: i64) :: {[i64], [u8], [i64], i64} do
    {a, b, a, walk(a, reps)}
  end

  defk return_branch(c :: bool, a :: [i64], n :: i64) :: [i64] do
    if c, do: a, else: alloc(i64, n)
  end

  defk return_literal(c :: bool, b :: [u8]) :: [u8] do
    if c, do: b, else: "defk"
  end

  defk return_empty(c :: bool, b :: [u8]) :: [u8] do
    if c, do: b, else: ""
  end

  defk id(a :: [i64]) :: [i64] do
    a
  end

  # a helper returning its unwritten argument
  defk via_helper(a :: [i64], reps :: i64) :: {[i64], i64} do
    x = id(a)
    {x, walk(x, reps)}
  end

  # a loop accumulator that is one of two inputs
  defk acc_branch(a :: [i64], b :: [i64], n :: i64) :: [i64] do
    for i <- 1..n//1, reduce: a do
      acc -> if rem(i, 3) == 0, do: b, else: acc
    end
  end
end

defmodule Defk.ArrayBranchTest do
  use ExUnit.Case, async: false
  use Defk.Properties
  import Defk.Test.Frames

  alias Defk.ArrayBranchTest.K

  @timeout 60_000

  defp i64s(list), do: for(x <- list, into: <<>>, do: <<x::64-signed-native>>)
  defp agree(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  defp forced(f) do
    K.__defk_force_yields__(true)

    try do
      f.()
    after
      K.__defk_force_yields__(false)
    end
  end

  # Runs `f` in a new process under forced yields, garbage-collecting that
  # process for as long as the call runs: every safepoint yields, so the GCs
  # land between two steps of the kernel and may move its heap binaries.
  # `f` builds its inputs itself, so heap binaries are on that process's heap.
  defp with_gcs(f) do
    forced(fn ->
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          result =
            try do
              {:ok, f.()}
            rescue
              e -> {:error, e, __STACKTRACE__}
            end

          send(parent, {:done, self(), result})
        end)

      gcs = gc_loop(pid, ref, 0)

      case assert_receive({:done, ^pid, _}, @timeout) do
        {_, _, {:ok, result}} -> {result, gcs}
        {_, _, {:error, e, st}} -> reraise e, st
      end
    end)
  end

  defp gc_loop(pid, ref, n) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> n
    after
      0 ->
        :erlang.garbage_collect(pid)
        gc_loop(pid, ref, n + 1)
    end
  end

  # inputs: heap binaries (<= 64 bytes, which a GC moves) and refc binaries
  defp small(seed), do: i64s(for k <- 1..7, do: k * seed)
  defp large(seed), do: i64s(for k <- 1..2_049, do: rem(k * seed, 70_000))

  describe "an array from a branch" do
    test "between two inputs" do
      for c <- [true, false], {a, b} <- [{small(3), small(5)}, {large(3), large(5)}] do
        assert {:ok, _} = agree(:two_inputs, [c, a, b, 3])
      end
    end

    test "input or alloc, returned: the input is the caller's own binary" do
      a = large(7)
      {x, _} = K.input_or_alloc(true, a, 4, 2)
      assert :erts_debug.same(x, a)
      assert {:ok, {x, _}} = agree(:input_or_alloc, [false, a, 4, 2])
      assert x == i64s([0, 0, 0, 0])
      assert {:ok, _} = agree(:input_or_alloc, [true, small(2), 4, 2])
    end

    test "alloc or alloc, written after the branch" do
      assert agree(:alloc_or_alloc, [true, 3]) == {:ok, i64s([1, 3, 0])}
      assert agree(:alloc_or_alloc, [false, 3]) == {:ok, i64s([2, 3, 0, 0])}

      # o and p are read after the write: they keep their zeros
      for c <- [true, false] do
        assert agree(:alloc_or_alloc_kept, [c, 2]) ==
                 {:ok, {i64s([5, 0]), i64s([0, 0]), i64s([0, 0])}}
      end
    end

    test "a write to an arm's array after the branch is not seen through it" do
      assert agree(:write_source_after, [true, 3, 10]) ==
               {:ok, {i64s([0, 0, 0]), i64s([10, 11, 12])}}

      assert agree(:write_source_after, [false, 3, 10]) ==
               {:ok, {i64s([0, 0, 0]), i64s([10, 11, 12])}}
    end

    test "nested branches, cond and case" do
      for c <- [true, false], d <- [true, false] do
        assert {:ok, _} = agree(:nested, [c, d, small(1), small(2), 2])
      end

      a = large(1)
      {x, _} = K.nested(true, true, a, small(2), 1)
      assert :erts_debug.same(x, a)

      for k <- [-5, 0, 1, 2, 4, 5, 12, 13, 14] do
        assert {:ok, _} = agree(:cond_case, [k, small(1), large(2), 2])
      end
    end

    test "as an element of the branch's tuples" do
      a = large(3)
      b = :binary.copy("bytes", 20)
      assert {:ok, {x, y, _}} = agree(:in_tuple, [true, a, b, 2])
      assert :erts_debug.same(x, a) and :erts_debug.same(y, b)
      assert {:ok, {x, y, _}} = agree(:in_tuple, [false, a, b, 2])
      assert x == i64s([0, 0]) and :erts_debug.same(y, b)
    end

    test "written after the branch: the caller's binaries are unchanged" do
      for {a, b} <- [{small(1), small(2)}, {large(1), large(2)}], c <- [true, false] do
        {a0, b0} = {:binary.copy(a), :binary.copy(b)}
        assert {:ok, {x, a1, b1}} = agree(:write_after, [c, a, b, 99])
        assert a == a0 and b == b0
        assert :erts_debug.same(a1, a) and :erts_debug.same(b1, b)
        <<99::64-signed-native, rest::binary>> = x
        assert rest == binary_part(if(c, do: a, else: b), 8, byte_size(a) - 8)
      end

      a = large(4)
      a0 = :binary.copy(a)
      assert {:ok, _} = agree(:write_loop_after, [true, a, 3])
      assert {:ok, _} = agree(:write_loop_after, [false, a, 3])
      assert a == a0
    end

    test "a loop accumulator taking one of two inputs" do
      for n <- [0, 1, 2, 3, 7] do
        assert {:ok, _} = agree(:acc_branch, [small(1), small(2), n])
      end
    end

    test "copies nothing where nothing is written" do
      for k <- [:two_inputs, :input_or_alloc, :nested, :cond_case, :in_tuple, :return_branch] do
        refute kernel_c(k) =~ "defk_copy_", "#{k}"
      end
    end
  end

  describe "returning an input array" do
    test "unwritten, it is the caller's own binary" do
      for a <- [<<>>, small(1), large(1)] do
        assert :erts_debug.same(K.return_input(a), a)
      end

      a = large(2)
      b = :binary.copy("x", 100)
      {a1, b1, a2, _} = K.return_inputs(a, b, 2)
      assert :erts_debug.same(a1, a) and :erts_debug.same(a2, a) and :erts_debug.same(b1, b)
      assert {:ok, _} = agree(:return_inputs, [a, b, 2])
    end

    test "from a branch, from a helper, and a literal" do
      a = large(3)
      assert :erts_debug.same(K.return_branch(true, a, 2), a)
      assert agree(:return_branch, [false, a, 2]) == {:ok, i64s([0, 0])}

      {x, _} = K.via_helper(a, 2)
      assert :erts_debug.same(x, a)
      assert {:ok, _} = agree(:via_helper, [small(1), 2])

      assert agree(:return_literal, [false, "abc"]) == {:ok, "defk"}
      assert agree(:return_empty, [false, "abc"]) == {:ok, ""}
      assert agree(:return_empty, [true, "abc"]) == {:ok, "abc"}
      b = :binary.copy("abc", 30)
      assert :erts_debug.same(K.return_literal(true, b), b)
    end

    test "an unaligned input is returned as the caller's binary" do
      <<_::8, a::binary-size(56), _::binary>> = :binary.copy(<<1>>, 64)
      assert :erts_debug.same(K.return_input(a), a)
    end
  end

  describe "under forced yields with GCs between resumes" do
    @reps 400

    test "agrees with Elixir mode, heap and refc inputs" do
      {results, gcs} =
        with_gcs(fn ->
          for {a, b} <- [{small(3), small(5)}, {large(3), large(5)}],
              c <- [true, false] do
            [
              agree(:two_inputs, [c, a, b, @reps]),
              agree(:input_or_alloc, [c, a, 4, @reps]),
              agree(:nested, [c, not c, a, b, @reps]),
              agree(:nested, [c, c, a, b, @reps]),
              agree(:cond_case, [if(c, do: -1, else: 3), a, b, @reps]),
              agree(:in_tuple, [c, a, "bytes", @reps]),
              agree(:write_after, [c, a, b, 7]),
              agree(:write_loop_after, [c, a, 9]),
              agree(:write_source_after, [c, 9, @reps]),
              agree(:return_inputs, [a, "b", @reps]),
              agree(:via_helper, [a, @reps]),
              agree(:acc_branch, [a, b, 50])
            ]
          end
        end)

      assert gcs > 0
      assert results |> List.flatten() |> Enum.all?(&match?({:ok, _}, &1))
    end

    test "a returned input is still the caller's binary after the resumes" do
      {same?, _} =
        with_gcs(fn ->
          a = small(9)
          {x, _} = K.input_or_alloc(true, a, 4, @reps)
          {y, _} = K.via_helper(a, @reps)
          {z, _, w, _} = K.return_inputs(a, "b", @reps)
          Enum.all?([x, y, z, w], &:erts_debug.same(&1, a))
        end)

      assert same?
    end

    test "killing the call mid-run leaves no frame" do
      forced(fn ->
        a = large(1)
        y0 = K.__defk_stats__().yields
        pid = spawn(fn -> K.two_inputs(true, a, a, 1_000_000) end)
        wait_until(fn -> K.__defk_stats__().yields > y0 + 20 end)
        Process.exit(pid, :kill)
        assert_frames_live(K)
      end)
    end
  end

  # the generated C of kernel `name`
  defp kernel_c(name) do
    [_ | chunks] = String.split(K.__defk_c_source__(), "/* ---- ")
    Enum.find(chunks, &String.starts_with?(&1, "#{name}/")) || flunk("no kernel #{name}")
  end

  defp wait_until(f, deadline \\ System.monotonic_time(:millisecond) + @timeout) do
    cond do
      f.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out")

      true ->
        Process.sleep(1)
        wait_until(f, deadline)
    end
  end

  # ---------------------------------------------------- agreement properties --

  defp arr(opts \\ []), do: G.array(:i64, Keyword.merge([max_length: 12], opts))
  defp reps, do: G.i64(0..3)

  agreement(K,
    total: [],
    walk: [args: fixed_list([arr(), reps()])],
    two_inputs: [args: fixed_list([G.bool(), arr(), arr(), reps()])],
    input_or_alloc: [args: fixed_list([G.bool(), arr(), G.i64(0..8), reps()])],
    alloc_or_alloc: [args: fixed_list([G.bool(), G.i64(-1..8)])],
    alloc_or_alloc_kept: [args: fixed_list([G.bool(), G.i64(-1..8)])],
    write_source_after: [args: fixed_list([G.bool(), G.i64(-1..8), reps()])],
    nested: [args: fixed_list([G.bool(), G.bool(), arr(), arr(), reps()])],
    cond_case: [args: fixed_list([G.i64(-20..20), arr(), arr(), reps()])],
    in_tuple: [args: fixed_list([G.bool(), arr(), G.array(:u8, max_length: 12), reps()])],
    write_after: [args: fixed_list([G.bool(), arr(), arr(), G.i64()])],
    write_loop_after: [args: fixed_list([G.bool(), arr(), G.i64(0..8)])],
    return_input: [],
    return_inputs: [args: fixed_list([arr(), G.array(:u8, max_length: 12), reps()])],
    return_branch: [args: fixed_list([G.bool(), arr(), G.i64(-1..8)])],
    return_literal: [],
    return_empty: [],
    id: [],
    via_helper: [args: fixed_list([arr(), reps()])],
    acc_branch: [args: fixed_list([arr(), arr(), G.i64(0..10)])]
  )

  property "agrees with Elixir mode under forced yields" do
    forced(fn ->
      check all(
              {c, d} <- tuple({G.bool(), G.bool()}),
              a <- arr(),
              b <- arr(),
              v <- G.i64(),
              max_runs: 100
            ) do
        agree(:two_inputs, [c, a, b, 2])
        agree(:input_or_alloc, [c, a, 3, 2])
        agree(:nested, [c, d, a, b, 2])
        agree(:in_tuple, [c, a, b, 2])
        agree(:write_after, [c, a, b, v])
        agree(:write_loop_after, [c, a, 4])
        agree(:return_branch, [c, a, 2])
        agree(:via_helper, [a, 2])
        agree(:acc_branch, [a, b, 5])
      end
    end)
  end
end
