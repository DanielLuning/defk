# The builtin signature table (ADR-0008): one typing, consumed by both
# emitters. These units pin the matcher's resolution rules; the generated
# agreement kernels (same file family) pin that both emitters implement
# every row.
defmodule Defk.BuiltinsTypingTest do
  use ExUnit.Case, async: true

  alias Defk.Builtins

  test "concrete rows resolve as written" do
    assert {:ok, :i64, []} = Builtins.typing(:bit_size, [:bitstring])
    assert {:ok, :i64, []} = Builtins.typing(:u32_le, [{:arr, :u8}, :i64])
    assert {:ok, :i64, []} = Builtins.typing(:mulhi, [:i64, :i64])
  end

  test "classes admit exactly their members" do
    assert {:ok, :i64, _} = Builtins.typing(:clz, [:u64])
    assert :error = Builtins.typing(:clz, [:f64])
    assert {:ok, :f64, [{0, :f64, "sqrt/1"}]} = Builtins.typing(:sqrt, [:i64])
    assert :error = Builtins.typing(:sqrt, [:bitstring])
  end

  test "the same-scalar variable binds one type across operands" do
    assert {:ok, :f64, []} = Builtins.typing(:min, [:f64, :f64])
    assert {:ok, :i64, []} = Builtins.typing(:max, [:i64, :i64])
    # mixed ints fall through to the ordered u64 row; a float mix does not
    assert {:ok, :u64, []} = Builtins.typing(:min, [:i64, :u64])
    assert :error = Builtins.typing(:min, [:i64, :f64])
  end

  test "the same-element array variable binds across operands" do
    assert {:ok, {:arr, :f64}, coerce} =
             Builtins.typing(:copy, [{:arr, :f64}, :i64, {:arr, :f64}, :i64, :u64])

    assert [{1, :i64, "index"}, {3, :i64, "source index"}, {4, :i64, "length"}] = coerce
    assert :error = Builtins.typing(:copy, [{:arr, :f64}, :i64, {:arr, :u8}, :i64, :i64])
  end

  test "an operand-reference result gives the operand's type before coercion" do
    assert {:ok, :u64, _} = Builtins.typing(:rotl, [:u64, :i64, :u64])
    assert {:ok, :i64, _} = Builtins.typing(:rotl, [:i64, :u64, :i64])
    assert {:ok, :u64, []} = Builtins.typing(:trunc, [:u64])
    assert {:ok, :i64, []} = Builtins.typing(:trunc, [:f64])
  end

  test "rows are ordered: the first match per name wins" do
    assert {:ok, :i64, []} = Builtins.typing(:div, [:i64, :i64])
    assert {:ok, :u64, []} = Builtins.typing(:div, [:u64, :i64])
  end

  test "names typed outside the table say so; unknown shapes are errors" do
    assert :bespoke = Builtins.typing(:alloc, [:i64, :i64])
    assert :bespoke = Builtins.typing(:band, [:i64, :i64])
    assert :error = Builtins.typing(:length, [:i64])
    assert :error = Builtins.typing(:crc32c, [:i64, :i64])
  end

  test "every table row's shapes are well-formed" do
    scalars = [:i64, :u64, :f64]

    for {name, pats, result, coerce} <- Builtins.typing() do
      assert Builtins.builtin?(name)

      for p <- pats do
        assert p in ([:bitstring, :int, :number, :t, {:arr, :u8}, {:arr, :e}] ++ scalars),
               "unknown pattern #{inspect(p)} in #{name}"
      end

      assert result in ([:t, {:arr, :e}, {:arr, :u8}] ++ scalars) or
               match?({:arg, i} when i < length(pats), result)

      for {i, to, label} <- coerce do
        assert i < length(pats) and to in [:i64, :f64] and is_binary(label)
      end
    end
  end
end
