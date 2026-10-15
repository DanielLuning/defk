defmodule Defk.Messages do
  @moduledoc false
  # The runtime error messages, in one place. Each entry is a template with
  # named holes, `"index {i} out of bounds for array of length {len}"`, the
  # exception module it is raised as, and the reason agreement compares
  # (`Defk.Test.agreement_reason/1`).
  #
  # Three consumers read it:
  #
  #   * `header/0` renders `priv/defk_messages.h`, one `DEFK_MSG_<NAME>`
  #     define per entry with each hole as its C conversion (`%lld`, `%s`,
  #     ...). The runtime header's raise sites use the defines, never a
  #     literal. `mix defk.messages` writes the file; `test/messages_test.exs`
  #     fails when it is out of date.
  #   * `text/2`, a macro, gives Elixir mode (`Defk.ElixirMode.Ops`,
  #     `Defk.Bits`) the template as a compile-time interpolation, so a site
  #     cannot drift from the kernel's text. A `:str` hole prints with
  #     `to_string/1`, any other with `inspect/1`.
  #   * `reason/1` maps an exception back to its entry's reason by matching
  #     the template's literal segments in order: the match keys the
  #     taxonomy once kept by hand in `Defk.Test` are derived from the same
  #     templates the sites raise with.
  #
  # The two modes cannot share bytes where a message carries a formatted
  # value: C prints a float as `%.17g` or `%g`, Elixir mode with `inspect/1`.
  # Where the text differs in more than that (`trunc/1` under `round/1` in
  # the kernel), both templates are listed with the same reason. An entry
  # with reason `nil` has no reason: agreement needs the identical message
  # (`{:other, message}`). The two prefixes at the end are Elixir's own
  # exceptions, which Elixir mode lets through; they have no define and no
  # `text/2`.

  @c_formats %{
    i64: "%lld",
    u64: "%llu",
    size: "%zu",
    int: "%d",
    str: "%s",
    char: "%c",
    # a float as C prints it: %.17g round-trips, %g is short
    f64: "%.17g",
    f64_short: "%g"
  }

  # {name, exception, text, holes, reason} or the same with an options
  # keyword list: `c: false` for a template no runtime header site raises
  # (Elixir mode only, or the compiler writing the literal into kernel C).
  @entries [
    # -- ArithmeticError (DEFK_E_ARITH) ----------------------------------
    {:i64_overflow, ArithmeticError, "i64 overflow in {a} {op} {b}", [a: :i64, op: :str, b: :i64],
     :overflow},
    {:i64_overflow_shift, ArithmeticError, "i64 overflow in {f}({a}, {n})",
     [f: :str, a: :i64, n: :i64], :overflow},
    {:i64_overflow_div, ArithmeticError, "i64 overflow in div/2", [], :overflow},
    {:div_by_zero, ArithmeticError, "div/2 by zero", [], :zero_divisor},
    {:rem_by_zero, ArithmeticError, "rem/2 by zero", [], :zero_divisor},
    {:u64_overflow, ArithmeticError, "u64 overflow in {a} {op} {b}", [a: :u64, op: :str, b: :u64],
     :overflow},
    {:u64_overflow_shift, ArithmeticError, "u64 overflow in {f}({a}, {n})",
     [f: :str, a: :u64, n: :i64], :overflow},
    {:u64_to_i64, ArithmeticError, "{a} does not fit in i64", [a: :u64], :overflow},
    {:i64_to_u64, ArithmeticError, "{a} does not fit in u64", [a: :i64], :overflow},
    {:wbsl_negative, ArithmeticError, "bsl/2 by the negative count {n} inside a mask", [n: :i64],
     :negative_shift},
    {:range_limit, ArithmeticError,
     "range element {last} is within one step of the i64 limit (stepping past it overflows)",
     [last: :i64], :range_limit},
    {:trunc_fit, ArithmeticError, "trunc/1: {a} does not fit in i64", [a: :f64_short], :overflow},
    # the kernel's round/1 raises as trunc/1 (defk_round rounds, then truncates)
    {:round_fit, ArithmeticError, "round/1: {a} does not fit in i64", [a: :f64_short], :overflow,
     c: false},
    {:float_div_zero, ArithmeticError, "bad argument in arithmetic expression: division by zero",
     [], :non_finite},
    {:float_nonfinite, ArithmeticError, "float result of {a} {op} {b} is inf or NaN",
     [a: :f64, op: :char, b: :f64], :non_finite},
    {:float_nonfinite_lost, ArithmeticError, "float result is inf or NaN", [], :non_finite},
    {:float_call_nonfinite_1, ArithmeticError, "float result of {f}({a}) is inf or NaN",
     [f: :str, a: :f64], :non_finite},
    {:float_call_nonfinite_2, ArithmeticError, "float result of {f}({a}, {b}) is inf or NaN",
     [f: :str, a: :f64, b: :f64], :non_finite},
    {:sqrt_negative, ArithmeticError, "sqrt of negative number {a}", [a: :f64_short],
     :non_finite},
    {:log_non_positive, ArithmeticError, "log of non-positive number {a}", [a: :f64_short],
     :non_finite},
    {:log2_non_positive, ArithmeticError, "log2 of non-positive number {a}", [a: :f64_short],
     :non_finite},
    {:log10_non_positive, ArithmeticError, "log10 of non-positive number {a}", [a: :f64_short],
     :non_finite},
    {:nonfinite_result, ArithmeticError, "kernel produced a non-finite float", [], :non_finite},

    # -- ArgumentError (DEFK_E_ARG) --------------------------------------
    {:arg_binary, ArgumentError, "argument {n} ({p}) must be a binary of packed {t}",
     [n: :int, p: :str, t: :str], :badarg},
    {:arg_size, ArgumentError,
     "argument {n} ({p}): byte size {size} is not a multiple of {esz} ({t})",
     [n: :int, p: :str, size: :size, esz: :size, t: :str], :badarg},
    {:arg_i64, ArgumentError, "argument {n} ({p}) must be an integer fitting in i64",
     [n: :int, p: :str], :badarg},
    {:arg_f64, ArgumentError, "argument {n} ({p}) must be a number", [n: :int, p: :str], :badarg},
    {:arg_u64, ArgumentError, "argument {n} ({p}) must be an integer fitting in u64",
     [n: :int, p: :str], :badarg},
    {:arg_bool, ArgumentError, "argument {n} ({p}) must be a boolean", [n: :int, p: :str],
     :badarg},
    {:alloc_negative, ArgumentError, "alloc/2: negative length {n}", [n: :i64], :negative_length},
    {:alloc_too_large, ArgumentError, "alloc/2: length too large", [], :length_too_large},
    {:out_of_memory, ArgumentError, "out of memory", [], :out_of_memory},
    {:out_of_memory_bytes, ArgumentError, "out of memory (allocating {bytes} bytes)",
     [bytes: :size], :out_of_memory},
    {:over_budget, ArgumentError,
     "out of memory (allocating {bytes} bytes would take this call's buffers past max_owned_bytes, {max} bytes)",
     [bytes: :size, max: :u64], :out_of_memory},
    # raised with the kind of the kernel's own raise statement
    {:raise_message_oom, ArgumentError, "out of memory building a raise message", [],
     :out_of_memory},
    {:copy_negative, ArgumentError, "{f}: negative length {n}", [f: :str, n: :i64],
     :negative_length},
    {:copy_back_offset, ArgumentError, "copy_back/4: offset {off} is not positive", [off: :i64],
     nil},
    {:bits_width, ArgumentError, "Defk.Bits.{f}: width {w} is not in 1..64", [f: :str, w: :i64],
     :bits_width},
    {:bits_field, ArgumentError, "Defk.Bits.{f}: {x} does not fit in a {w}-bit field",
     [f: :str, x: :i64, w: :i64], :bits_range},
    {:bits_field_u64, ArgumentError, "Defk.Bits.{f}: {x} does not fit in a {w}-bit field",
     [f: :str, x: :u64, w: :i64], :bits_range},
    {:crc32c_width, ArgumentError, "Defk.Bits.crc32c/3: width {w} is not 8, 16, 32 or 64",
     [w: :i64], :bits_width},
    {:nonfinite_input, ArgumentError,
     "non-finite float (inf or NaN) read from an input array at index {i}", [i: :i64],
     :non_finite_input},
    {:value_u8, ArgumentError, "value {v} does not fit in u8", [v: :i64], :element_range},
    {:value_i16, ArgumentError, "value {v} does not fit in i16", [v: :i64], :element_range},
    {:value_i32, ArgumentError, "value {v} does not fit in i32", [v: :i64], :element_range},
    {:value_u64, ArgumentError, "value {v} does not fit in u64", [v: :i64], :element_range},
    {:value_i64, ArgumentError, "value {v} does not fit in i64", [v: :u64], :element_range},
    {:value_f32, ArgumentError, "value {v} does not fit in f32", [v: :f64], :element_range},
    {:bitstring_too_large, ArgumentError, "bitstring too large", [], nil},
    {:segment_size, ArgumentError, "bitstring segment size {n} is outside 0..64", [n: :i64],
     :segment_size},
    # signed is "" or " signed"
    {:segment_fit, ArgumentError, "bitstring segment value {v} does not fit in {n}{signed} bits",
     [v: :i64, n: :i64, signed: :str], :segment_fit},
    {:segment_fit_u64, ArgumentError, "bitstring segment value {v} does not fit in {n} bits",
     [v: :u64, n: :i64], :segment_fit},
    # written into kernel C by the compiler (a range loop with a variable step)
    {:range_step_zero, ArgumentError, "range step cannot be zero", [], :zero_step, c: false},
    {:foreign_frame, ArgumentError,
     "defk: suspended kernel frame has a foreign layout (layout tag mismatch)", [], nil},

    # -- Enum.OutOfBoundsError (DEFK_E_OOB): the reason is always :index ----
    {:oob, Enum.OutOfBoundsError, "index {i} out of bounds for array of length {len}",
     [i: :i64, len: :i64], :index},
    {:oob_load, Enum.OutOfBoundsError,
     "{w}-byte load at index {i} out of bounds for array of length {len}",
     [w: :int, i: :i64, len: :i64], :index},
    {:copy_oob, Enum.OutOfBoundsError,
     "{f}: {n} elements {where} index {i} out of bounds for {what} of length {len}",
     [f: :str, n: :i64, where: :str, i: :i64, what: :str, len: :i64], :index},
    {:copy_back_before_start, Enum.OutOfBoundsError,
     "copy_back/4: offset {off} from index {at} is before the start of the array",
     [off: :i64, at: :i64], :index},

    # -- RuntimeError: defk bugs the runtime contains (DEFK_E_RESUME, DEFK_E_FAULT)
    {:lost_resume_yielded, RuntimeError,
     "defk bug: kernel resumed at safepoint {from} but yielded at safepoint {at} without reaching it (missing or wrong resume dispatch)",
     [from: :int, at: :int], nil},
    {:lost_resume_returned, RuntimeError,
     "defk bug: kernel resumed at safepoint {from} but returned without reaching it (missing or wrong resume dispatch)",
     [from: :int], nil},
    {:fault, RuntimeError,
     "defk bug: {what} inside kernel native code (signal {sig}, code {code}, address {addr}, pc +0x{pc}); the call was aborted and the node kept running",
     [what: :str, sig: :int, code: :int, addr: "%p", pc: "%lx"], nil}
  ]

  # Elixir's own exceptions that reach agreement through Elixir mode, by
  # message prefix: float arithmetic giving inf or NaN (also :math), and a
  # range with a zero step
  @elixir_own [
    {ArithmeticError, "bad argument in arithmetic expression", :non_finite},
    {ArgumentError, "ranges (first..last//step) expect", :zero_step}
  ]

  @type hole :: :i64 | :u64 | :size | :int | :str | :char | :f64 | :f64_short | String.t()
  @type entry :: %{
          name: atom(),
          exception: module(),
          text: String.t(),
          holes: [{atom(), hole()}],
          reason: atom() | nil,
          c: boolean()
        }

  @doc false
  @spec entries() :: [entry()]
  def entries, do: Enum.map(@entries, &entry/1)

  defp entry({name, exception, text, holes, reason}),
    do: entry({name, exception, text, holes, reason, []})

  defp entry({name, exception, text, holes, reason, opts}) do
    %{
      name: name,
      exception: exception,
      text: text,
      holes: holes,
      reason: reason,
      c: Keyword.get(opts, :c, true)
    }
  end

  @doc false
  @spec entry!(atom()) :: entry()
  def entry!(name) do
    Enum.find(entries(), &(&1.name == name)) ||
      raise ArgumentError, "no runtime message named #{inspect(name)} (lib/defk/messages.ex)"
  end

  @doc false
  # The literal and hole segments of a template, in order:
  # [{:lit, "index "}, {:hole, :i}, {:lit, " out of bounds ..."}, ...]. The
  # first and last segments are literals (possibly empty).
  @spec segments(String.t()) :: [{:lit, String.t()} | {:hole, atom()}]
  def segments(text) do
    text
    |> String.split(["{", "}"])
    |> Enum.with_index()
    |> Enum.map(fn
      {s, i} when rem(i, 2) == 0 -> {:lit, s}
      {h, _} -> {:hole, String.to_atom(h)}
    end)
  end

  # ------------------------------------------------------------- C side --

  @doc false
  # The text of priv/defk_messages.h: a define per entry raised from the
  # runtime header, its holes as C conversions.
  @spec header() :: String.t()
  def header do
    defines =
      entries()
      |> Enum.filter(& &1.c)
      |> Enum.group_by(& &1.exception)
      |> Enum.sort_by(fn {exception, _} -> order(exception) end)
      |> Enum.map_join("\n", fn {exception, entries} ->
        "/* #{inspect(exception)} */\n" <>
          Enum.map_join(entries, "\n", &"#define #{define(&1.name)} #{c_format(&1)}") <> "\n"
      end)

    """
    /*
     * The runtime's error messages, generated from Defk.Messages
     * (lib/defk/messages.ex) by `mix defk.messages`: do not edit. Each define
     * is a printf format; the runtime header passes it to defk_fail with the
     * values of its holes.
     */
    #ifndef DEFK_MESSAGES_H
    #define DEFK_MESSAGES_H

    #{defines}
    #endif
    """
  end

  defp order(ArithmeticError), do: 0
  defp order(ArgumentError), do: 1
  defp order(Enum.OutOfBoundsError), do: 2
  defp order(_), do: 3

  @doc false
  @spec define(atom()) :: String.t()
  def define(name), do: "DEFK_MSG_" <> String.upcase(Atom.to_string(name))

  @doc false
  # The template of a message without holes as a C string literal, for the
  # compiler to write into kernel C.
  @spec c_literal(atom()) :: String.t()
  def c_literal(name) do
    %{holes: [], text: text} = entry!(name)
    c_string(text)
  end

  defp c_format(%{text: text, holes: holes}) do
    text
    |> segments()
    |> Enum.map_join(fn
      {:lit, s} -> s |> String.replace("%", "%%") |> escape_c()
      {:hole, h} -> c_conversion(Keyword.fetch!(holes, h))
    end)
    |> then(&"\"#{&1}\"")
  end

  defp c_conversion(raw) when is_binary(raw), do: raw
  defp c_conversion(type), do: Map.fetch!(@c_formats, type)

  defp c_string(s), do: "\"" <> escape_c(String.replace(s, "%", "%%")) <> "\""

  defp escape_c(s), do: s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  # -------------------------------------------------------- Elixir side --

  @doc false
  # The message as a compile-time interpolation of the template, `text(:oob,
  # i: i, len: len)`. Every hole must be given, and nothing else.
  defmacro text(name, args \\ []) do
    %{holes: holes, text: template} = entry!(name)
    keys = Keyword.keys(holes)
    given = Keyword.keys(args)

    Enum.sort(given) == Enum.sort(keys) ||
      raise ArgumentError,
            "Defk.Messages.text(#{inspect(name)}, ...) takes #{inspect(keys)}, got #{inspect(given)}"

    if keys == [] do
      template
    else
      parts =
        template
        |> segments()
        |> Enum.map(fn
          {:lit, s} -> s
          {:hole, h} -> interpolation(Keyword.fetch!(args, h), Keyword.fetch!(holes, h))
        end)

      quote do: <<unquote_splicing(parts)>>
    end
  end

  defp interpolation(expr, :str), do: quote(do: Kernel.to_string(unquote(expr)) :: binary)
  defp interpolation(expr, _type), do: quote(do: Kernel.inspect(unquote(expr)) :: binary)

  @doc false
  # The same at run time, for tests: the template with its holes filled.
  @spec render(atom(), keyword()) :: String.t()
  def render(name, args) do
    %{holes: holes, text: template} = entry!(name)

    template
    |> segments()
    |> Enum.map_join(fn
      {:lit, s} -> s
      {:hole, h} -> shown(Keyword.fetch!(args, h), Keyword.fetch!(holes, h))
    end)
  end

  defp shown(v, :str), do: to_string(v)
  defp shown(v, _type), do: inspect(v)

  @doc false
  # The reason of an exception, as agreement compares it: the reason of the
  # first entry of its module whose template matches, or `{:other, message}`.
  @spec reason(Exception.t()) :: atom() | {:other, String.t()}
  def reason(%Enum.OutOfBoundsError{}), do: :index
  def reason(%CaseClauseError{}), do: :clause

  def reason(%{__struct__: exception, message: m})
      when exception in [ArgumentError, ArithmeticError] do
    found =
      Enum.find_value(entries(), fn e ->
        if e.exception == exception and matches?(m, segments(e.text)), do: {:found, e.reason}
      end) ||
        Enum.find_value(@elixir_own, fn {ex, prefix, reason} ->
          if ex == exception and String.starts_with?(m, prefix), do: {:found, reason}
        end)

    case found do
      {:found, nil} -> {:other, m}
      {:found, reason} -> reason
      nil -> {:other, m}
    end
  end

  def reason(e), do: {:other, Exception.message(e)}

  # the template's literal segments appear in the message in order, the
  # first at its start and the last at its end
  defp matches?(m, [{:lit, only}]), do: m == only

  defp matches?(m, [{:lit, first} | rest]) do
    String.starts_with?(m, first) and
      inner_matches?(binary_slice(m, byte_size(first)..-1//1), rest)
  end

  defp inner_matches?(m, [{:hole, _}, {:lit, last}]), do: String.ends_with?(m, last)
  # two holes side by side ("{n}{signed}"): nothing to find between them
  defp inner_matches?(m, [{:hole, _}, {:lit, ""} | rest]), do: inner_matches?(m, rest)

  defp inner_matches?(m, [{:hole, _}, {:lit, lit} | rest]) do
    case :binary.match(m, lit) do
      {at, len} -> inner_matches?(binary_slice(m, (at + len)..-1//1), rest)
      :nomatch -> false
    end
  end
end
