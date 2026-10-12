# The enforcement half of the builtin signature table (ADR-0008, defk-o49):
# every table row is instantiated into tiny kernels — one per bounded
# combination of its classes and variables — compiled through the full
# pipeline and checked for agreement between native and Elixir mode. A
# missing emission clause in either emitter, a wrong coercion, or a
# semantic drift all fail here, by construction, for every row.
#
# u64 operands are built with f64_to_u64/1 of an f64 parameter (u64 is not
# a parameter type). The :bitstring row (bit_size/1) is not generated: a
# bitstring parameter makes the kernel a helper (inlined only), and
# bitstring_test.exs covers it end to end.
defmodule Defk.BuiltinsTableKernelsTest do
  use ExUnit.Case, async: false

  @arr_elems [:f64, :u8, :i32]

  # bounded concrete combinations for a row's patterns
  defp combos(pats) do
    cond do
      Enum.any?(pats, &(&1 == :bitstring)) ->
        []

      :t in pats ->
        for t <- [:i64, :u64, :f64], do: Enum.map(pats, fn :t -> t end)

      {:arr, :e} in pats ->
        for e <- @arr_elems do
          for p <- pats do
            case p do
              {:arr, :e} -> {:arr, e}
              :int -> :i64
              other -> other
            end
          end
        end

      :int in pats or :number in pats ->
        base = fn fill ->
          Enum.map(pats, fn
            p when p in [:int, :number] -> fill.(p)
            p -> p
          end)
        end

        all_i = base.(fn _ -> :i64 end)
        all_u = base.(fn p -> if p == :number, do: :f64, else: :u64 end)
        mixed = base.(fn p -> if p == :number, do: :i64, else: :u64 end) |> mix_first(pats)
        Enum.uniq([all_i, all_u, mixed])

      true ->
        [pats]
    end
  end

  defp mix_first(types, pats) do
    case Enum.find_index(pats, &(&1 in [:int, :number])) do
      nil -> types
      i -> List.replace_at(types, i, :i64)
    end
  end

  defp param_decl(:u64, i), do: "p#{i} :: f64"
  defp param_decl({:arr, e}, i), do: "p#{i} :: [#{e}]"
  defp param_decl(t, i), do: "p#{i} :: #{t}"

  defp arg_expr(:u64, i, _mixed?), do: "f64_to_u64(p#{i})"

  # mixing an i64 that may be negative into a u64 operation is rejected by
  # the emitters (u64-mix, a fact-dependent refinement the table leaves to
  # them): a mixed row's i64 operands are made provably non-negative with
  # the documented band idiom
  defp arg_expr(:i64, i, true), do: "band(p#{i}, 0x7FFFFFFFFFFFFFFF)"
  defp arg_expr(_t, i, _mixed?), do: "p#{i}"

  defp ret_decl({:arr, e}), do: "[#{e}]"
  defp ret_decl(t), do: "#{t}"

  defp input(:i64), do: [7, -3]
  defp input(:f64), do: [2.5, -1.25]
  # becomes a u64 via f64_to_u64 inside the kernel
  defp input(:u64), do: [4.0, -2.0]

  defp input({:arr, :f64}),
    do: [for(x <- [1.0, 2.5, -3.0, 4.0], into: <<>>, do: <<x::float-64-native>>)]

  defp input({:arr, :u8}), do: [<<1, 2, 3, 250>>]

  defp input({:arr, :i32}),
    do: [for(x <- [1, -2, 3, 40], into: <<>>, do: <<x::integer-32-native>>)]

  # every argument tuple for the kernel: the cartesian product, capped
  defp inputs(types) do
    all =
      types
      |> Enum.map(&input/1)
      |> Enum.reduce([[]], fn vals, acc -> for args <- acc, v <- vals, do: args ++ [v] end)

    Enum.uniq(Enum.take(all, 3) ++ Enum.take(all, -1))
  end

  defp rows do
    rows =
      for {name, pats, _result, _coerce} <- Defk.Builtins.typing(),
          types <- combos(pats) do
        case Defk.Builtins.typing(name, types) do
          {:ok, res, _} ->
            {name, types, res}

          other ->
            raise "row #{name} #{inspect(types)} does not match its own table: #{inspect(other)}"
        end
      end

    Enum.with_index(rows, fn {name, types, res}, i -> {:"k#{i}_#{name}", name, types, res} end)
  end

  defp module_src(rows) do
    src =
      for {kname, name, types, res} <- rows do
        params =
          types |> Enum.with_index() |> Enum.map_join(", ", fn {t, i} -> param_decl(t, i) end)

        mixed? = :i64 in types and :u64 in types

        args =
          types
          |> Enum.with_index()
          |> Enum.map_join(", ", fn {t, i} -> arg_expr(t, i, mixed?) end)

        "  defk #{kname}(#{params}) :: #{ret_decl(res)} do\n    #{name}(#{args})\n  end\n"
      end

    """
    defmodule Defk.BuiltinsTableKernelsTest.K do
      use Defk

    #{Enum.join(src, "\n")}
    end
    """
  end

  test "every table row's kernels compile in both modes and agree" do
    rows = rows()
    tmp = Path.join(System.tmp_dir!(), "defk_builtins_table_test")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "k.ex")
    File.write!(path, module_src(rows))
    [{mod, _} | _] = Code.compile_file(path)

    for {kname, _name, types, _res} <- rows,
        args <- inputs(types) do
      Defk.Test.assert_agrees(mod, kname, args)
    end
  end
end
