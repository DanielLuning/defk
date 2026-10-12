defmodule Defk.Builtins do
  @moduledoc false
  # The functions a kernel calls without defining them: one list for the
  # compiler, Elixir mode and the compile errors.

  # f64 -> f64 math, also callable as :math.sqrt/1 and so on
  @math1 [:sqrt, :exp, :log, :log2, :log10, :sin, :cos]
  # i64 -> i64 bitwise, as Elixir's Bitwise; each also has an operator form
  @bitwise [:band, :bor, :bxor, :bnot, :bsl, :bsr]
  @bitwise_ops %{&&&: :band, |||: :bor, "^^^": :bxor, "~~~": :bnot, <<<: :bsl, >>>: :bsr}
  # [u8], i64 -> i64 word loads: unsigned w-byte integers at a byte offset
  @loads [:u64_le, :u64_be, :u32_le, :u32_be, :u16_le, :u16_be]
  # range copies into an array: copy/5 (memmove) and copy_back/4 (an LZ match)
  @copies [:copy, :copy_back]
  # bit builtins with a plain Elixir meaning in Defk.Bits (clz and ctz also
  # take a width: clz/2, ctz/2)
  @bits [:mulhi, :clz, :ctz, :popcount, :rotl64, :rotr64, :rotl, :rotr, :f64_to_u64, :crc32c]
  @all [:len, :bit_size, :min, :max, :abs, :float, :trunc, :round, :div, :rem] ++
         @math1 ++ [:pow] ++ @bitwise ++ [:wrap64] ++ @loads ++ @copies ++ [:alloc] ++ @bits

  @doc "Every builtin name."
  def all, do: @all

  @doc "The one-argument math builtins."
  def math1, do: @math1

  @doc "The bitwise builtins (band/2, bor/2, bxor/2, bnot/1, bsl/2, bsr/2)."
  def bitwise, do: @bitwise

  @doc "The bitwise operators (&&&, |||, ^^^, ~~~, <<<, >>>)."
  def bitwise_ops, do: Map.keys(@bitwise_ops)

  @doc "The bitwise builtin an operator or bitwise function name stands for."
  def bitwise_fun(name), do: Map.get(@bitwise_ops, name, name)

  @doc "The arity of bitwise builtin `f`."
  def bitwise_arity(:bnot), do: 1
  def bitwise_arity(_f), do: 2

  @doc "The word loads from a [u8] (u64_le/2, u32_be/2, ...)."
  def loads, do: @loads

  @doc "The width in bytes of word load `f`."
  def load_width(f) when f in [:u64_le, :u64_be], do: 8
  def load_width(f) when f in [:u32_le, :u32_be], do: 4
  def load_width(f) when f in [:u16_le, :u16_be], do: 2

  @doc "The range copies into an array (copy/5, copy_back/4)."
  def copies, do: @copies

  @doc """
  The bit builtins (mulhi/2, clz/1,2, ctz/1,2, popcount/1, rotl64/2,
  rotr64/2, rotl/3, rotr/3, f64_to_u64/1, crc32c/3).
  """
  def bits, do: @bits

  # -------------------------------------------------------------- typing ---
  # The builtin signature table (ADR-0008, defk-o49): name and operand type
  # patterns in, result type and coercions out, consumed by both the C
  # lowering and Elixir mode so the two cannot drift. SEMANTICS stay written
  # twice on purpose: Elixir mode is the oracle (see the ADR before
  # deduplicating further).
  #
  # A pattern is a concrete type (:i64, :u64, :f64, :bitstring, {:arr, :u8}),
  # a class (:int = i64 | u64; :number = int | f64), the same-scalar variable
  # :t (every :t operand has one type, from [:i64, :u64, :f64]), or the
  # same-element array {:arr, :e}. A result is a type, {:arg, i} (the type of
  # operand i after coercion), :t or {:arr, :e}. Coercions widen an operand
  # before emission: {index, to, label}, the label exactly as the rejection
  # names the argument. Rows are ordered: the first match per name wins.
  # A row's acceptance is structural; a fact-dependent rejection (mixing a
  # possibly-negative i64 into u64 min/max) stays with the emitters.
  @typing [
            {:len, [arr: :e], :i64, []},
            {:bit_size, [:bitstring], :i64, []}
          ] ++
            for(f <- @loads, do: {f, [{:arr, :u8}, :i64], :i64, []}) ++
            [
              {:copy, [{:arr, :e}, :int, {:arr, :e}, :int, :int], {:arr, :e},
               [{1, :i64, "index"}, {3, :i64, "source index"}, {4, :i64, "length"}]},
              {:copy_back, [{:arr, :e}, :int, :int, :int], {:arr, :e},
               [{1, :i64, "index"}, {2, :i64, "offset"}, {3, :i64, "length"}]},
              {:clz, [:int], :i64, []},
              {:ctz, [:int], :i64, []},
              {:popcount, [:int], :i64, []},
              {:mulhi, [:i64, :i64], :i64, []},
              {:rotl64, [:i64, :i64], :i64, []},
              {:rotr64, [:i64, :i64], :i64, []},
              {:clz, [:int, :int], :i64, [{1, :i64, "clz/2 width"}]},
              {:ctz, [:int, :int], :i64, [{1, :i64, "ctz/2 width"}]},
              {:rotl, [:int, :int, :int], {:arg, 0},
               [{1, :i64, "rotl/3 count"}, {2, :i64, "rotl/3 width"}]},
              {:rotr, [:int, :int, :int], {:arg, 0},
               [{1, :i64, "rotr/3 count"}, {2, :i64, "rotr/3 width"}]},
              {:crc32c, [:int, :int, :int], :i64, [{2, :i64, "crc32c/3 width"}]},
              {:f64_to_u64, [:number], :u64, [{0, :f64, "f64_to_u64/1"}]},
              {:div, [:i64, :i64], :i64, []},
              {:rem, [:i64, :i64], :i64, []},
              {:div, [:int, :int], :u64, []},
              {:rem, [:int, :int], :u64, []},
              {:float, [:f64], :f64, []},
              {:float, [:int], :f64, []},
              {:trunc, [:int], {:arg, 0}, []},
              {:round, [:int], {:arg, 0}, []},
              {:trunc, [:f64], :i64, []},
              {:round, [:f64], :i64, []},
              {:abs, [:i64], :i64, []},
              {:abs, [:u64], :u64, []},
              {:abs, [:f64], :f64, []},
              {:min, [:t, :t], :t, []},
              {:max, [:t, :t], :t, []},
              {:min, [:int, :int], :u64, []},
              {:max, [:int, :int], :u64, []}
            ] ++
            for(f <- @math1, do: {f, [:number], :f64, [{0, :f64, "#{f}/1"}]}) ++
            [{:pow, [:number, :number], :f64, [{0, :f64, "pow/2"}, {1, :f64, "pow/2"}]}]

  # typed outside the table: alloc's element-type literal, the bitwise
  # builtins' own lowering, and wrap64 (masked arithmetic)
  @bespoke_typing [:alloc, :wrap64] ++ @bitwise

  @doc false
  def typing, do: @typing

  @doc false
  # The one typing of builtin `name` applied to operand types `types`:
  # {:ok, result_type, coercions} with classes and variables resolved,
  # :bespoke for a name typed outside the table, or :error (no row).
  def typing(name, types) do
    cond do
      name in @bespoke_typing ->
        :bespoke

      true ->
        @typing
        |> Enum.filter(fn {n, pats, _, _} -> n == name and length(pats) == length(types) end)
        |> Enum.find_value(:error, fn {_, pats, result, coerce} ->
          case binds(pats, types, %{}) do
            :error -> nil
            binds -> {:ok, resolve(result, binds, types, coerce), coerce}
          end
        end)
    end
  end

  defp binds([], [], binds), do: binds

  defp binds([pat | pats], [t | ts], binds) do
    case bind(pat, t, binds) do
      :error -> :error
      binds -> binds(pats, ts, binds)
    end
  end

  defp binds(_pats, _ts, _binds), do: :error

  defp bind(:int, t, binds) when t in [:i64, :u64], do: binds
  defp bind(:number, t, binds) when t in [:i64, :u64, :f64], do: binds

  defp bind(:t, t, binds) when t in [:i64, :u64, :f64] do
    case binds do
      %{t: ^t} -> binds
      %{t: _} -> :error
      _ -> Map.put(binds, :t, t)
    end
  end

  defp bind({:arr, :e}, {:arr, e}, binds) do
    case binds do
      %{e: ^e} -> binds
      %{e: _} -> :error
      _ -> Map.put(binds, :e, e)
    end
  end

  defp bind(t, t, binds), do: binds
  defp bind(_pat, _t, _binds), do: :error

  # the result type, with the coercions already applied to operand types
  defp resolve({:arg, i}, _binds, types, coerce) do
    case List.keyfind(coerce, i, 0) do
      {^i, to, _label} -> to
      nil -> Enum.at(types, i)
    end
  end

  defp resolve(:t, binds, _types, _coerce), do: Map.fetch!(binds, :t)
  defp resolve({:arr, :e}, binds, _types, _coerce), do: {:arr, Map.fetch!(binds, :e)}
  defp resolve(t, _binds, _types, _coerce), do: t

  @doc "Whether `name` is a builtin."
  def builtin?(name), do: name in @all

  @doc """
  Whether a call of `name` with `arity` arguments is a builtin. A kernel may
  reuse a builtin's name at an arity the builtin does not take: calls are
  looked up by name and arity.
  """
  def builtin?(name, arity), do: arity in arities(name)

  @doc "The arities builtin `name` takes (none for a name that is not a builtin)."
  def arities(name) when name in [:len, :bit_size, :abs, :float, :trunc, :round, :wrap64], do: [1]
  def arities(name) when name in [:min, :max, :div, :rem, :pow, :alloc], do: [2]
  def arities(name) when name in @math1, do: [1]
  def arities(name) when name in @bitwise, do: [bitwise_arity(name)]
  def arities(name) when name in @loads, do: [2]
  def arities(:copy), do: [5]
  def arities(:copy_back), do: [4]
  def arities(name) when name in [:clz, :ctz], do: [1, 2]
  def arities(name) when name in [:mulhi, :rotl64, :rotr64], do: [2]
  def arities(name) when name in [:rotl, :rotr, :crc32c], do: [3]
  def arities(name) when name in [:popcount, :f64_to_u64], do: [1]
  def arities(_name), do: []

  # Enum.all?/any? with a predicate are the same fold with a different bool
  # accumulator: {init, if kw} for `reduce_while` over the predicate.
  @doc "The {init, if kw} that lowers Enum.all?/any? to a bool-accumulator reduce."
  def bool_reduce(f) when f in [:all?, :any?] do
    if f == :all?,
      do: {true, [do: {:cont, true}, else: {:halt, false}]},
      else: {false, [do: {:halt, true}, else: {:cont, false}]}
  end
end
