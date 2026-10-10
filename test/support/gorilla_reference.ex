defmodule Defk.GorillaReference do
  @moduledoc false
  # The value encoder of gorilla_stream 3.0.3, ported as the reference for the
  # Gorilla kernel in test/bitstring_test.exs (defk-cmr): the logic of
  # GorillaStream.Compression.Encoder.ValueCompression.compress/1 (Elixir
  # path), output bits only. Ported rather than added as a dependency because
  # gorilla_stream builds a C++ NIF through elixir_make, fine and
  # cc_precompiler, far heavier than these lines.
  #
  # gorilla_stream is Copyright (c) 2025 Mark Cotner, MIT License
  # (https://github.com/awksedgreep/gorilla_stream).
  #
  # Kept as written there, quirks included: the first XOR always takes the
  # "previous window" branch (the window starts as 0 leading, 0 trailing
  # zeros, so it writes all 64 bits), and a new window stores its leading
  # zeros capped at 31 while it writes 64 - leading - trailing meaningful bits
  # with the uncapped count.

  import Bitwise

  def compress([]), do: <<>>
  def compress([value]), do: <<float_to_bits(value)::64>>

  def compress([first | rest]) do
    first_bits = float_to_bits(first)

    state = %{
      bits: [<<first_bits::64>>],
      prev_value_bits: first_bits,
      prev_leading_zeros: 0,
      prev_trailing_zeros: 0
    }

    :erlang.list_to_bitstring(Enum.reduce(rest, state, &encode_value/2).bits)
  end

  defp encode_value(value, state) do
    current_bits = float_to_bits(value)
    xor_result = bxor(current_bits, state.prev_value_bits)

    if xor_result == 0,
      do: %{state | bits: [state.bits, <<0::1>>], prev_value_bits: current_bits},
      else: encode_xor_result(xor_result, current_bits, state)
  end

  defp encode_xor_result(xor_result, current_bits, state) do
    leading_zeros = count_leading_zeros(xor_result)
    trailing_zeros = count_trailing_zeros(xor_result)
    meaningful_bits = 64 - leading_zeros - trailing_zeros
    meaningful_length = 64 - state.prev_leading_zeros - state.prev_trailing_zeros

    if leading_zeros >= state.prev_leading_zeros and trailing_zeros >= state.prev_trailing_zeros and
         meaningful_bits > 0 and meaningful_length > 0 do
      meaningful_value =
        bsr(xor_result, state.prev_trailing_zeros) &&& (1 <<< meaningful_length) - 1

      %{
        state
        | bits: [state.bits, <<1::1, 0::1, meaningful_value::size(meaningful_length)>>],
          prev_value_bits: current_bits
      }
    else
      encode_new_window(xor_result, current_bits, state, leading_zeros, trailing_zeros)
    end
  end

  defp encode_new_window(xor_result, current_bits, state, leading_zeros, trailing_zeros) do
    adjusted_meaningful_bits = max(1, min(64, 64 - leading_zeros - trailing_zeros))
    adjusted_leading_zeros = max(0, min(31, leading_zeros))
    meaningful_value = bsr(xor_result, trailing_zeros) &&& (1 <<< adjusted_meaningful_bits) - 1

    %{
      state
      | bits: [
          state.bits,
          <<1::1, 1::1, adjusted_leading_zeros::5, adjusted_meaningful_bits - 1::6,
            meaningful_value::size(adjusted_meaningful_bits)>>
        ],
        prev_value_bits: current_bits,
        prev_leading_zeros: adjusted_leading_zeros,
        prev_trailing_zeros: trailing_zeros
    }
  end

  defp float_to_bits(value) when is_float(value) do
    <<bits::64>> = <<value::float-64>>
    bits
  end

  defp count_leading_zeros(0), do: 64
  defp count_leading_zeros(value), do: count_leading_zeros(value, 0)
  defp count_leading_zeros(value, count) when (value &&& 1 <<< 63) != 0, do: count

  defp count_leading_zeros(value, count) when count < 64,
    do: count_leading_zeros(value <<< 1, count + 1)

  defp count_leading_zeros(_, count), do: count

  defp count_trailing_zeros(0), do: 64
  defp count_trailing_zeros(value), do: count_trailing_zeros(value, 0)
  defp count_trailing_zeros(value, count) when (value &&& 1) != 0, do: count

  defp count_trailing_zeros(value, count) when count < 64,
    do: count_trailing_zeros(bsr(value, 1), count + 1)

  defp count_trailing_zeros(_, count), do: count
end
