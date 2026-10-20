# numeric_loader: load a numeric CSV, or a JSON array of numbers, straight
# into packed [f64] values
#
# The job: a metrics export or an ML feature table (10-500 MB of numeric
# CSV), or an embeddings response (a JSON array of floats per vector), read
# into packed f64s that the next kernel, Nx or Explorer consumes. People
# reach for a NIF (rusty_csv: SIMD scan, "3.5x" NimbleCSV on simple input;
# ecsv; jaxon) because NimbleCSV and Jason build a binary or a float term
# per field first. The research (docs/research/string-workloads.md, ranked
# #5) found that a kernel that only scans cannot beat :binary's BIFs and
# leaves Elixir to build the terms; it pays only as a fused loader that
# parses the digits straight into packed values. This example is that form.
# General CSV or JSON to terms stays with NimbleCSV and Jason.
#
#   elixir examples/numeric_loader.exs
#
# Two DEFK_RESULT lines: numeric_loader_csv (the one mix defk.examples
# reads), then numeric_loader_json; the script exits 1 itself when the JSON
# one is incorrect or misses its expected verdict.
#
# Pre-registered (ticket): good for the fused loader on numeric data.
# Expected verdicts, as measured: CSV good, JSON good.
#
# The grammar (a limit, stated before the numbers). A CSV field is
# -?[0-9]+\.[0-9]+, the form String.to_float/1 accepts without an exponent;
# a JSON number is -?(0|[1-9][0-9]*)(\.[0-9]+)?. Both: at most 18 digits
# and a mantissa of at most 2^53, so mantissa / 10^k is one correctly
# rounded division of two exact doubles, the bits String.to_float/1 gives
# (Clinger's fast path). Rows end in \n or \r\n and have exactly ncols
# fields; JSON whitespace is space, \t, \n, \r. Everything else raises
# ArgumentError: quotes, empty fields, integers in CSV, exponents, more
# digits, a nested JSON value. A loader for a wider grammar would hand the
# fields it cannot parse to String.to_float/1; that is not tried here.
#
# Two passes, no growable output: pass 1 counts newlines (CSV) or commas
# (JSON) and pass 2 parses into an alloc of that size. Pass 1 is a
# vectorised byte count: 2.8 ms of the CSV's 50 ms (6%), 0.23 ms of the
# JSON's 2.1 ms (11%), under the 20% that would call for a growable [f64].
# Its `acc + 1` needs wrap64 (the count is at most the input length): with
# the overflow check the loop did not vectorise and took 12.9 ms. The parse
# digits use wrap64 too, safe below 18 digits (69 -> 64 ms).
#
# Kernel shapes tried: one byte-at-a-time state machine (kept), and a loop
# over the rows x ncols fields with an Enum.reduce_while over each field's
# digits (15% slower: 56.5 against 49.1 ms for pass 2).
#
# Elixir baselines (optimised; all timed in each run; the fastest is the
# baseline):
#   CSV  E1 NimbleCSV.parse_string + String.to_float, packed through an
#        iolist (appending to one binary was about 2x slower here);
#        E2 :binary.split into lines and fields + :erlang.binary_to_float;
#        E3 one pass of binary matching with the kernel's algorithm and
#        grammar, appending each f64 to one binary (an iolist of 8-byte
#        binaries was 1.7-1.9x slower). E3 is the baseline. Also tried:
#        :binary.match for the next delimiter + binary_to_float per field
#        (324 ms, 2.3x E3).
#   JSON J1 Jason.decode! + pack; J2 OTP's :json.decode + pack; J3 binary
#        matching like E3. J3 is the baseline; J2 is within 25% of it.
#   Not tried: splitting the input at newlines across schedulers (both
#   sides could; the kernel yields on a normal scheduler like Elixir).
#
# Realistic sizes: CSV 26 MB (400k rows x 8 columns of 1-6 decimals, the
# low end of a metrics export), with a sweep of 4k, 40k and 1.6M rows
# (106 MB); JSON 2.2 MB (100 embeddings of 1536 floats with ten decimals,
# ", " between them), with a sweep of 1, 10 and 1000 vectors.
#
# Agreement: every Elixir side, the kernels and their Elixir mode
# (`elixir_mode: true`, Loader.Kernels.__defk_elixir__/2) give the same
# packed bytes and row count on 26 CSV inputs (1 to 2000 rows, 1 to 8
# columns, no trailing newline, empty) and 28 JSON inputs (to 5000
# numbers, empty arrays, whitespace, -0 and -0.0); 411 edge fields (every
# digit count to 17, zeros, -0.0, leading zeros, mantissas at 2^53, \r\n
# rows) are bit-exact with String.to_float/1. 23 bad CSV and 26 bad JSON
# inputs raise ArgumentError on every side that has the grammar; Jason
# rejects 19 of the 26 (the rest are exponents and long mantissas, this
# loader's limits).
#
# Measured (M-series Mac, OTP 29, Elixir 1.20, 2026-10-20; the reports
# best of 15 in eight runs, six of them through mix defk.examples; the
# variant lines best of 5 in the two direct runs). The last stored run
# passed the quiet test for both reports (other processes 0.3-0.6 cores);
# the CSV numbers of the others are provisional (up to 1.9 cores after).
#
#   CSV, 26 MB      E1 788-845 ms, E2 385-403 ms, E3 (best of 15)
#                   138.8-143.7 ms; defk 50.5-53.0 ms
#                   (pass 1 2.8-2.9 ms)                 2.68-2.78x  good
#                   Sweep 4k rows 2.8-3.5x, 40k 2.7-3.1x, 1.6M 2.75-3.2x.
#                   Slicing one column out of the packed result in Elixir:
#                   2.9-3.4 ms.
#   JSON, 2.2 MB    J1 26.2-27.5 ms, J2 16.4-16.8 ms, J3 13.7-17.1 ms
#                   (best of 15: 9.0-12.4 ms, median 17.8-19.8; the best
#                   is a rare run without a GC); defk 2.08-2.34 ms
#                                                       3.90-5.87x  good
#                   Sweep (five runs, best of 3, noisy) 1 vector 7.4-9.0x,
#                   10 vectors 4.1-11.4x, 1000 vectors (22 MB) 4.0-5.5x.
#
# Recommendation: to load numeric CSV or JSON number arrays into packed
# values, a fused kernel is 2.7x (CSV) and 3.9-5.9x (JSON) faster than the
# best Elixir, and 15-16x NimbleCSV with String.to_float. Write the grammar
# down and reject the rest. For anything with quotes, strings, mixed types or
# a tree, NimbleCSV and Jason (or :json) stay the tools: the product is
# terms, and a kernel cannot build them.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:nimble_csv, "~> 1.3"},
  {:jason, "~> 1.4"}
])

defmodule Loader.Source do
  # The kernels, as a `use` block for Loader.Kernels, compiled with
  # `elixir_mode: true` (native by default; `__defk_elixir__/2` is the
  # agreement check's oracle).
  defmacro __using__(_) do
    quote location: :keep do
      # 2^53: the largest mantissa a double holds exactly
      @two53 9_007_199_254_740_992

      # Pass 1 of both loaders: how many times byte b occurs.
      defk count_byte(s :: [u8], b :: i64) :: i64 do
        for c <- s, reduce: 0 do
          acc -> if c == b, do: wrap64(acc + 1), else: acc
        end
      end

      # m / scale with both exact (m <= 2^53, scale a power of ten up to
      # 10^18) is one correctly rounded division: the double nearest the
      # decimal, as String.to_float/1 gives.
      defk decimal(m :: i64, scale :: i64, neg :: bool) :: f64 do
        if m > @two53, do: raise(ArgumentError, "a mantissa above 2^53")
        v = m / scale
        if neg, do: -v, else: v
      end

      # ---- CSV: rows of ncols fields, each -?[0-9]+\.[0-9]+ ----
      #
      # Fields: at most 18 digits, a mantissa of at most 2^53. Rows end in
      # "\n" or "\r\n"; the last may end without one. Anything else raises
      # ArgumentError: a quote, an empty field, an integer, an exponent.
      # States: 0 field start, 1 after '-', 2 integer digits, 3 after '.',
      # 4 fraction digits, 5 after '\r'.
      defk parse_csv(s :: [u8], ncols :: i64, rows :: i64) :: [f64] do
        if ncols < 1, do: raise(ArgumentError, "ncols must be at least 1")
        if rows < 0, do: raise(ArgumentError, "rows must not be negative")
        out = alloc(f64, rows * ncols)
        n = length(s)

        {m, scale, _nd, st, neg, col, idx} =
          for i <- 0..(n - 1)//1, reduce: {0, 1, 0, 0, false, 0, 0} do
            {m, scale, nd, st, neg, col, idx} ->
              c = s[i]

              cond do
                c >= 48 and c <= 57 ->
                  if st == 5, do: raise(ArgumentError, "a '\\r' not followed by '\\n'")
                  # 18 digits keep m * 10 + 9 and scale * 10 inside i64
                  if nd >= 18, do: raise(ArgumentError, "a number with more than 18 digits")

                  if st >= 3 do
                    {wrap64(m * 10 + (c - 48)), wrap64(scale * 10), nd + 1, 4, neg, col, idx}
                  else
                    {wrap64(m * 10 + (c - 48)), scale, nd + 1, 2, neg, col, idx}
                  end

                c == 46 ->
                  if st != 2, do: raise(ArgumentError, "a '.' not after a digit")
                  {m, scale, nd, 3, neg, col, idx}

                c == 45 ->
                  if st != 0, do: raise(ArgumentError, "a '-' inside a number")
                  {m, scale, nd, 1, true, col, idx}

                c == 44 ->
                  if st != 4, do: raise(ArgumentError, "a field that is not a decimal number")
                  if col + 1 >= ncols, do: raise(ArgumentError, "a row with too many fields")
                  out[idx] = decimal(m, scale, neg)
                  {0, 1, 0, 0, false, col + 1, idx + 1}

                c == 10 and st == 5 ->
                  {0, 1, 0, 0, false, 0, idx}

                c == 10 or c == 13 ->
                  if st != 4, do: raise(ArgumentError, "a field that is not a decimal number")
                  if col != ncols - 1, do: raise(ArgumentError, "a row with too few fields")
                  out[idx] = decimal(m, scale, neg)
                  {0, 1, 0, if(c == 13, do: 5, else: 0), false, 0, idx + 1}

                true ->
                  raise(ArgumentError, "a byte outside the number grammar")
                  {m, scale, nd, st, neg, col, idx}
              end
          end

        if st != 0 and st != 4, do: raise(ArgumentError, "the input ends inside a field")
        if st == 4 and col != ncols - 1, do: raise(ArgumentError, "a row with too few fields")
        if st == 4, do: out[idx] = decimal(m, scale, neg)
        out
      end

      # ---- JSON: one flat array of numbers ----
      #
      # Each number is -?(0|[1-9][0-9]*)(\.[0-9]+)?, at most 18 digits and
      # a mantissa of at most 2^53; whitespace is space, \t, \n, \r. An
      # exponent, a string, a nested value raise ArgumentError. An integer
      # is the float of its value, as Jason's integer packed into an f64
      # (so "-0" is 0.0, and "-0.0" is -0.0). Returns {values, count}.
      # States: 0 before '[', 1 after '[', 2 after ',', 3 after '-',
      # 4 integer digits, 5 after '.', 6 fraction digits, 7 after a number
      # and whitespace, 8 after ']'.
      defk parse_json(s :: [u8], cap :: i64) :: {[f64], i64} do
        out = alloc(f64, cap)
        n = length(s)

        {_m, _scale, _nd, st, _neg, k} =
          for i <- 0..(n - 1)//1, reduce: {0, 1, 0, 0, false, 0} do
            {m, scale, nd, st, neg, k} ->
              c = s[i]
              ws = c == 32 or c == 10 or c == 13 or c == 9

              cond do
                c >= 48 and c <= 57 ->
                  if nd >= 18, do: raise(ArgumentError, "a number with more than 18 digits")

                  cond do
                    st == 5 or st == 6 ->
                      {wrap64(m * 10 + (c - 48)), wrap64(scale * 10), nd + 1, 6, neg, k}

                    st == 4 ->
                      if m == 0, do: raise(ArgumentError, "a number with a leading zero")
                      {wrap64(m * 10 + (c - 48)), scale, nd + 1, 4, neg, k}

                    st >= 1 and st <= 3 ->
                      {c - 48, 1, 1, 4, neg, k}

                    true ->
                      raise(ArgumentError, "a number outside the array")
                      {m, scale, nd, st, neg, k}
                  end

                c == 46 ->
                  if st != 4, do: raise(ArgumentError, "a '.' not after a digit")
                  {m, scale, nd, 5, neg, k}

                c == 45 ->
                  if st != 1 and st != 2, do: raise(ArgumentError, "a '-' inside a number")
                  {m, scale, nd, 3, true, k}

                st == 4 and (c == 44 or c == 93 or ws) ->
                  out[k] = float(if neg, do: -m, else: m)
                  {0, 1, 0, if(c == 44, do: 2, else: if(c == 93, do: 8, else: 7)), false, k + 1}

                st == 6 and (c == 44 or c == 93 or ws) ->
                  out[k] = decimal(m, scale, neg)
                  {0, 1, 0, if(c == 44, do: 2, else: if(c == 93, do: 8, else: 7)), false, k + 1}

                ws ->
                  if st == 3 or st == 5, do: raise(ArgumentError, "whitespace inside a number")
                  {m, scale, nd, st, neg, k}

                c == 44 ->
                  if st != 7, do: raise(ArgumentError, "a ',' not after a number")
                  {m, scale, nd, 2, neg, k}

                c == 93 ->
                  if st != 7 and not (st == 1 and k == 0),
                    do: raise(ArgumentError, "a ']' not after a number")

                  {m, scale, nd, 8, neg, k}

                c == 91 ->
                  if st != 0, do: raise(ArgumentError, "a nested array")
                  {m, scale, nd, 1, neg, k}

                true ->
                  raise(ArgumentError, "a byte outside the number grammar")
                  {m, scale, nd, st, neg, k}
              end
          end

        if st != 8, do: raise(ArgumentError, "the input is not one closed array")
        {out, k}
      end
    end
  end
end

defmodule Loader.Kernels do
  use Defk, elixir_mode: true
  use Loader.Source
end

defmodule Loader.Calls do
  alias Loader.Kernels

  # The two-pass loaders: pass 1 counts rows (newlines, plus a last line
  # without one) or values (commas plus one), pass 2 parses into an alloc of
  # that size. Returns {packed f64 values in row-major order, rows}.
  def load_csv(csv, ncols) do
    rows = count_rows(csv)
    {Kernels.parse_csv(csv, ncols, rows), rows}
  end

  def count_rows(<<>>), do: 0

  def count_rows(csv) do
    lines = Kernels.count_byte(csv, ?\n)
    if :binary.last(csv) == ?\n, do: lines, else: lines + 1
  end

  def load_json(json) do
    {vals, k} = Kernels.parse_json(json, Kernels.count_byte(json, ?,) + 1)
    {binary_part(vals, 0, 8 * k), k}
  end

  # A column of a row-major load: column j of ncols.
  def column(vals, ncols, j) do
    {before, rest} = {8 * j, 8 * (ncols - 1 - j)}

    for <<_::binary-size(^before), x::binary-size(8), _::binary-size(^rest) <- vals>>,
      into: <<>>,
      do: x
  end
end

defmodule Loader.Elixir do
  NimbleCSV.define(Loader.CSV, separator: ",", escape: "\"")

  # ---- CSV ----

  # E1: NimbleCSV to rows of binaries, String.to_float on each field, an
  # iolist (appending to one binary here was about 2x slower)
  def csv_nimble(csv, ncols) do
    rows = Loader.CSV.parse_string(csv, skip_headers: false)

    bin =
      IO.iodata_to_binary(
        for row <- rows do
          length(row) == ncols || raise ArgumentError, "a row with the wrong field count"
          for f <- row, do: <<String.to_float(f)::float-64-native>>
        end
      )

    {bin, length(rows)}
  end

  # E2: :binary.split into lines, then fields, then :erlang.binary_to_float
  def csv_split(csv, ncols) do
    lines = :binary.split(csv, "\n", [:global, :trim])

    bin =
      for line <- lines, reduce: <<>> do
        acc ->
          fields = :binary.split(line, ",", [:global])
          length(fields) == ncols || raise ArgumentError, "a row with the wrong field count"

          for f <- fields,
              reduce: acc,
              do: (acc -> <<acc::binary, :erlang.binary_to_float(f)::float-64-native>>)
      end

    {bin, length(lines)}
  end

  # E3: one pass of binary matching with the kernel's algorithm and grammar,
  # appending to one binary (an iolist of 8-byte binaries was 1.7-1.9x slower)
  def csv_match(csv, ncols), do: field(csv, ncols, 0, <<>>, 0)

  defp field(<<>>, _ncols, 0, acc, rows), do: {acc, rows}

  defp field(<<?-, rest::binary>>, ncols, col, acc, rows),
    do: int(rest, ncols, col, acc, rows, true, 0, 0)

  defp field(<<c, _::binary>> = s, ncols, col, acc, rows) when c in ?0..?9,
    do: int(s, ncols, col, acc, rows, false, 0, 0)

  defp field(_, _, _, _, _), do: raise(ArgumentError, "a field that is not a decimal number")

  defp int(<<c, rest::binary>>, ncols, col, acc, rows, neg, m, nd) when c in ?0..?9 and nd < 18,
    do: int(rest, ncols, col, acc, rows, neg, m * 10 + (c - ?0), nd + 1)

  defp int(<<?., c, rest::binary>>, ncols, col, acc, rows, neg, m, nd)
       when c in ?0..?9 and nd > 0 and nd < 18,
       do: frac(rest, ncols, col, acc, rows, neg, m * 10 + (c - ?0), 10, nd + 1)

  defp int(_, _, _, _, _, _, _, _),
    do: raise(ArgumentError, "a field that is not a decimal number")

  defp frac(<<c, rest::binary>>, ncols, col, acc, rows, neg, m, scale, nd)
       when c in ?0..?9 and nd < 18,
       do: frac(rest, ncols, col, acc, rows, neg, m * 10 + (c - ?0), scale * 10, nd + 1)

  defp frac(s, ncols, col, acc, rows, neg, m, scale, _nd) do
    acc = <<acc::binary, decimal(m, scale, neg)::float-64-native>>

    case s do
      <<?,, rest::binary>> when col + 1 < ncols -> field(rest, ncols, col + 1, acc, rows)
      <<?\n, rest::binary>> when col == ncols - 1 -> field(rest, ncols, 0, acc, rows + 1)
      <<?\r, ?\n, rest::binary>> when col == ncols - 1 -> field(rest, ncols, 0, acc, rows + 1)
      <<>> when col == ncols - 1 -> {acc, rows + 1}
      _ -> raise ArgumentError, "a field that is not a decimal number"
    end
  end

  defp decimal(m, _scale, _neg) when m > 9_007_199_254_740_992,
    do: raise(ArgumentError, "a mantissa above 2^53")

  defp decimal(m, scale, true), do: -(m / scale)
  defp decimal(m, scale, false), do: m / scale

  # ---- JSON ----

  # J1: Jason, then pack
  def json_jason(json), do: pack(Jason.decode!(json))

  # J2: OTP's :json, then pack
  def json_otp(json), do: pack(:json.decode(json))

  defp pack(list) when is_list(list) do
    {for(x <- list, reduce: <<>>, do: (acc -> <<acc::binary, x::float-64-native>>)), length(list)}
  end

  # J3: one pass of binary matching with the kernel's grammar
  def json_match(json) do
    case skip_ws(json) do
      <<?[, rest::binary>> ->
        case skip_ws(rest) do
          <<?], tail::binary>> -> closed(tail, <<>>, 0)
          rest -> jvalue(rest, <<>>, 0)
        end

      _ ->
        raise ArgumentError, "the input is not one closed array"
    end
  end

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\n, ?\r, ?\t], do: skip_ws(rest)
  defp skip_ws(s), do: s

  defp jvalue(<<?-, rest::binary>>, acc, k), do: jint(rest, acc, k, true)
  defp jvalue(s, acc, k), do: jint(s, acc, k, false)

  defp jint(<<?0, c, _::binary>>, _acc, _k, _neg) when c in ?0..?9,
    do: raise(ArgumentError, "a number with a leading zero")

  defp jint(<<c, rest::binary>>, acc, k, neg) when c in ?0..?9,
    do: jdigits(rest, acc, k, neg, c - ?0, 1)

  defp jint(_, _, _, _), do: raise(ArgumentError, "a value that is not a number")

  defp jdigits(<<c, rest::binary>>, acc, k, neg, m, nd) when c in ?0..?9 and nd < 18,
    do: jdigits(rest, acc, k, neg, m * 10 + (c - ?0), nd + 1)

  defp jdigits(<<?., c, rest::binary>>, acc, k, neg, m, nd) when c in ?0..?9 and nd < 18,
    do: jfrac(rest, acc, k, neg, m * 10 + (c - ?0), 10, nd + 1)

  defp jdigits(s, acc, k, neg, m, _nd) when m <= 9_007_199_254_740_992 do
    jnext(s, <<acc::binary, if(neg, do: -m, else: m)::float-64-native>>, k + 1)
  end

  defp jdigits(_, _, _, _, _, _), do: raise(ArgumentError, "a mantissa above 2^53")

  defp jfrac(<<c, rest::binary>>, acc, k, neg, m, scale, nd) when c in ?0..?9 and nd < 18,
    do: jfrac(rest, acc, k, neg, m * 10 + (c - ?0), scale * 10, nd + 1)

  defp jfrac(s, acc, k, neg, m, scale, _nd),
    do: jnext(s, <<acc::binary, decimal(m, scale, neg)::float-64-native>>, k + 1)

  defp jnext(s, acc, k) do
    case skip_ws(s) do
      <<?,, rest::binary>> -> jvalue(skip_ws(rest), acc, k)
      <<?], rest::binary>> -> closed(rest, acc, k)
      _ -> raise ArgumentError, "a ',' or ']' expected after a number"
    end
  end

  defp closed(rest, acc, k) do
    if skip_ws(rest) == <<>>, do: {acc, k}, else: raise(ArgumentError, "bytes after the array")
  end
end

defmodule Loader.Data do
  # A metrics export: ncols columns of fixed-point decimals with 1-6
  # fraction digits and 1-6 integer digits, some negative.
  def csv(rows, ncols, seed \\ 1) do
    :rand.seed(:exsss, {seed, 2, 3})

    IO.iodata_to_binary(
      for _ <- 1..rows//1 do
        [Enum.map_intersperse(1..ncols, ",", fn _ -> csv_field() end), ?\n]
      end
    )
  end

  defp csv_field do
    x = (:rand.uniform() - 0.3) * :math.pow(10, :rand.uniform(6) - 1)
    :erlang.float_to_binary(x, decimals: :rand.uniform(6))
  end

  # Embedding vectors as an API returns them, flattened: values near 0 with
  # ten decimals, ", " between them (json.dumps' default).
  def json(count, seed \\ 1) do
    :rand.seed(:exsss, {seed, 5, 7})
    vals = for _ <- 1..count//1, do: :erlang.float_to_binary(:rand.normal() * 0.03, decimals: 10)
    IO.iodata_to_binary([?[, Enum.intersperse(vals, ", "), ?]])
  end

  # Fields that probe the grammar's edges: every digit count, zeros, -0.0,
  # leading zeros, mantissas at 2^53.
  def edge_fields do
    fixed =
      ~w(0.0 -0.0 0.5 -0.5 007.25 1.000000000000000 123456789012345.6 9007199254740.992 -9007199254740.992 0.00000000000000001 9999999.99999999)

    random =
      for _ <- 1..400 do
        # 17 digits at most: a "0" is put before a fraction with no integer digits
        nd = :rand.uniform(17)
        fd = :rand.uniform(nd)
        digits = for _ <- 1..nd, into: "", do: <<?0 + :rand.uniform(10) - 1>>
        {i, f} = String.split_at(digits, nd - fd)
        i = if i == "", do: "0", else: i
        sign = if :rand.uniform(2) == 1, do: "-", else: ""
        f = sign <> i <> "." <> f
        if mantissa(f) <= 9_007_199_254_740_992, do: f, else: "1.5"
      end

    fixed ++ random
  end

  defp mantissa(f), do: f |> String.replace(["-", "."], "") |> String.to_integer()
end

alias Loader.{Calls, Data, Kernels}

# ---- agreement ----

bits = fn bin -> for <<x::binary-size(8) <- bin>>, do: x end

raises? = fn f ->
  try do
    f.()
    false
  rescue
    ArgumentError -> true
  end
end

oracle_csv = fn csv, ncols ->
  rows = Calls.count_rows(csv)
  {Kernels.__defk_elixir__(:parse_csv, [csv, ncols, rows]), rows}
end

oracle_json = fn json ->
  {vals, k} = Kernels.__defk_elixir__(:parse_json, [json, Kernels.count_byte(json, ?,) + 1])
  {binary_part(vals, 0, 8 * k), k}
end

edges = Data.edge_fields()

edge_csv =
  Enum.map_join(
    Enum.chunk_every(edges, 3, 3, ["1.5", "1.5"]),
    "",
    &(Enum.join(&1, ",") <> "\r\n")
  )

edge_expected = for f <- edges, into: <<>>, do: <<String.to_float(f)::float-64-native>>

csv_cases =
  [
    {Data.csv(2000, 8, 7), 8},
    {Data.csv(1, 1, 3), 1},
    {"1.5", 1},
    {"1.5\n", 1},
    {"", 3},
    {edge_csv, 3}
  ] ++
    for(r <- 1..20, do: {Data.csv(r, rem(r, 5) + 1, r), rem(r, 5) + 1})

csv_agree =
  Enum.all?(csv_cases, fn {csv, ncols} ->
    k = Calls.load_csv(csv, ncols)

    k == Loader.Elixir.csv_match(csv, ncols) and k == oracle_csv.(csv, ncols) and
      (csv == edge_csv or
         (k == Loader.Elixir.csv_nimble(csv, ncols) and k == Loader.Elixir.csv_split(csv, ncols)))
  end)

{edge_vals, _} = Calls.load_csv(edge_csv, 3)
csv_edges = bits.(binary_part(edge_vals, 0, byte_size(edge_expected))) == bits.(edge_expected)

bad_csv =
  [
    {"1", 1},
    {"1.", 1},
    {".5", 1},
    {"1e5", 1},
    {"1.0e5", 1},
    {"\"1.5\"", 1},
    {"1.5,", 1},
    {",1.5", 2},
    {"1.5,2.5\n3.5", 2},
    {"1.5\n2.5,3.5\n", 1},
    {"a", 1},
    {"1.5\r", 1},
    {"1.5\r2.5", 1},
    {"--1.0", 1},
    {"1.2.3", 1},
    {"-.5", 1},
    {"1.5\n\n", 1},
    {"1234567890.123456789", 1},
    {"9007199254740.993", 1},
    {"1.5 ", 1},
    {" 1.5", 1},
    {"1.5", 0},
    {"+1.5", 1}
  ]

csv_bad =
  Enum.all?(bad_csv, fn {csv, ncols} ->
    raises?.(fn -> Calls.load_csv(csv, ncols) end) and raises?.(fn -> oracle_csv.(csv, ncols) end) and
      raises?.(fn -> Loader.Elixir.csv_match(csv, ncols) end)
  end)

json_cases =
  [
    Data.json(5000, 2),
    Data.json(1, 1),
    "[]",
    " [ ] ",
    "[1.5]",
    "[0, -0, -0.0, 3, 10]",
    "\n[1.25,\t-2.5 ,3.0]\r\n"
  ] ++
    ["[" <> Enum.join(Enum.reject(edges, &String.match?(&1, ~r/^-?0\d/)), ",") <> "]"] ++
    for(c <- 1..20, do: Data.json(c, c))

json_agree =
  Enum.all?(json_cases, fn json ->
    k = Calls.load_json(json)

    bits.(elem(k, 0)) == bits.(elem(Loader.Elixir.json_jason(json), 0)) and
      k == Loader.Elixir.json_jason(json) and k == Loader.Elixir.json_otp(json) and
      k == Loader.Elixir.json_match(json) and k == oracle_json.(json)
  end)

bad_json =
  ~w(1.5 [ ] [1.5 [1.5,] [,1.5] [01] [-01.5] [1e5] [1.0E5] [1.] [.5] [-] [--1] ["1.5"] [[1.5]] [1.5]x [1.5]] [1,,2] [null] [9007199254740.993] [1234567890123456789]) ++
    ["[1 2]", "[- 1]", "[1. 5]", ""]

json_bad =
  Enum.all?(bad_json, fn json ->
    raises?.(fn -> Calls.load_json(json) end) and raises?.(fn -> oracle_json.(json) end) and
      raises?.(fn -> Loader.Elixir.json_match(json) end)
  end)

# Jason rejects every bad input above except the exponents and the long
# mantissas, which are this loader's limits
jason_rejects = Enum.count(bad_json, &(not match?({:ok, l} when is_list(l), Jason.decode(&1))))

IO.puts("""
agreement:
  csv   values #{csv_agree}, edges bit-exact with String.to_float #{csv_edges}, bad input #{csv_bad} (#{length(bad_csv)} cases)
  json  values #{json_agree}, bad input #{json_bad} (#{length(bad_json)} cases, Jason rejects #{jason_rejects})
""")

# ---- inputs ----

ncols = 8
csv = Data.csv(400_000, ncols)
json = Data.json(153_600)
{csv_vals, csv_rows} = Calls.load_csv(csv, ncols)
{json_vals, json_n} = Calls.load_json(json)

best = fn f, runs ->
  for(_ <- 1..runs, do: elem(:timer.tc(f), 0)) |> Enum.min() |> Kernel./(1000) |> Float.round(3)
end

show = fn title, rows ->
  IO.puts(title)
  for {label, f} <- rows, do: IO.puts("  #{String.pad_trailing(label, 40)} #{best.(f, 5)} ms")
end

show.(
  "csv, #{div(byte_size(csv), 1_000_000)} MB (#{csv_rows} rows x #{ncols} columns), best of 5:",
  [
    {"E1 NimbleCSV + String.to_float", fn -> Loader.Elixir.csv_nimble(csv, ncols) end},
    {"E2 :binary.split + binary_to_float", fn -> Loader.Elixir.csv_split(csv, ncols) end},
    {"E3 binary matching, one binary", fn -> Loader.Elixir.csv_match(csv, ncols) end},
    {"defk pass 1 (count rows)", fn -> Calls.count_rows(csv) end},
    {"defk pass 2 (parse)", fn -> Kernels.parse_csv(csv, ncols, csv_rows) end},
    {"defk both passes", fn -> Calls.load_csv(csv, ncols) end},
    {"column 3 of the packed values (Elixir)", fn -> Calls.column(csv_vals, ncols, 3) end}
  ]
)

show.("json, #{Float.round(byte_size(json) / 1_000_000, 1)} MB (#{json_n} numbers), best of 5:", [
  {"J1 Jason.decode! + pack", fn -> Loader.Elixir.json_jason(json) end},
  {"J2 :json.decode + pack", fn -> Loader.Elixir.json_otp(json) end},
  {"J3 binary matching, one binary", fn -> Loader.Elixir.json_match(json) end},
  {"defk pass 1 (count commas)", fn -> Kernels.count_byte(json, ?,) end},
  {"defk both passes", fn -> Calls.load_json(json) end}
])

# ---- the verdicts: CSV first (the one mix defk.examples reads), then JSON;
# the script fails itself if JSON misses ----

csv_sweep = fn rows ->
  c = Data.csv(rows, ncols, 11)
  {fn -> Loader.Elixir.csv_match(c, ncols) end, fn -> Calls.load_csv(c, ncols) end}
end

_rc =
  Defk.Bench.report(
    name: "numeric_loader_csv",
    expected: :good,
    baseline: :optimized,
    runs: 15,
    realistic_size: "26 MB: 400k rows x 8 columns",
    elixir: fn -> Loader.Elixir.csv_match(csv, ncols) end,
    defk: fn -> Calls.load_csv(csv, ncols) end,
    check: fn ->
      csv_agree and csv_edges and csv_bad and
        {csv_vals, csv_rows} == Loader.Elixir.csv_match(csv, ncols)
    end,
    sweep:
      for(r <- [4_000, 40_000, 1_600_000], do: Tuple.insert_at(csv_sweep.(r), 0, "#{r} rows")),
    sweep_runs: 3,
    reason:
      "the kernel parses the digits straight into packed f64s; Elixir pays a function clause per byte, and NimbleCSV a sub-binary and a String.to_float per field"
  )

json_sweep = fn count ->
  j = Data.json(count, 13)
  {fn -> Loader.Elixir.json_match(j) end, fn -> Calls.load_json(j) end}
end

rj =
  Defk.Bench.report(
    name: "numeric_loader_json",
    expected: :good,
    baseline: :optimized,
    runs: 15,
    realistic_size: "2.2 MB: 100 embeddings of 1536 numbers",
    elixir: fn -> Loader.Elixir.json_match(json) end,
    defk: fn -> Calls.load_json(json) end,
    check: fn ->
      json_agree and json_bad and {json_vals, json_n} == Loader.Elixir.json_match(json)
    end,
    sweep:
      for(c <- [1536, 15_360, 1_536_000], do: Tuple.insert_at(json_sweep.(c), 0, "#{c} numbers")),
    sweep_runs: 3,
    reason:
      "Jason and :json build a list of floats the caller then packs; the kernel writes the packed f64s and builds no term per number"
  )

if not rj.correct or rj.verdict != rj.expected do
  IO.puts("#{rj.example}: verdict #{rj.verdict}, expected #{rj.expected}, correct #{rj.correct}")
  System.halt(1)
end
