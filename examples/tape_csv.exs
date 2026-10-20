# tape_csv: CSV to rows of binaries through a tape: a kernel scans and
# emits flat field events, Elixir builds the rows
#
# The question (examples/README.md, "Where a wrapper is the right choice"):
# parsers whose product is terms stay out of the catalog because building
# the terms is the cost. What would reopen the row: a tape output (flat
# events of start and length) plus Elixir tree building that beats
# NimbleCSV end to end. This example measures that, for CSV to the lists
# of binaries NimbleCSV.RFC4180.parse_string/2 returns. The numeric form,
# which builds no terms, is numeric_loader.exs.
#
#   elixir examples/tape_csv.exs
#
# Pre-registered: marginal (the research: Elixir still builds every
# sub-binary). Measured: good, and the expected verdict below says so.
#
# Two tape forms, both from the same RFC 4180 grammar as NimbleCSV
# (quoted fields with commas, doubled quotes and line breaks; \n or \r\n):
#   [i64] tape  scan/2: two words per field (start; length plus a "row
#               ends" and a "has doubled quotes" flag), sized by a vectorised
#               count of ',' and '\n'. Elixir walks it with binary matching
#               and takes binary_part of the input per field.
#   copy        normalize/1: a cleaned copy of the input, separating commas
#               as byte 31, row ends as byte 30, quotes removed and doubled
#               quotes written once. Elixir splits it twice with
#               :binary.split/3 (C), rows then fields. Bytes 30 and 31 in
#               the input raise ArgumentError (this form's limit).
# The copy is the faster form and the verdict's defk side.
#
# Elixir baseline: optimised. E1 NimbleCSV.RFC4180 (it already splits
# unquoted runs with :binary.split); E2 lines by :binary.split, a line
# without a quote split on commas, a quoted line walked with :binary.match
# (the baseline: 5-7% faster than E1); E3 E2 with quoted lines split on
# commas and the pieces joined (no gain). Native: rusty_csv 0.4.6 (Rust
# NIF, precompiled; SIMD scan, then sub-binary terms built in C on a dirty
# scheduler).
#
# Agreement: both tape forms, their Elixir mode (`elixir_mode: true`,
# Tape.Kernels.__defk_elixir__/2) and rusty_csv return exactly NimbleCSV's
# rows on 49 inputs (empty input, empty fields and lines, \r\n, quoted
# commas, doubled quotes and line breaks, 1 to 3000 rows); 6 bad inputs (a
# quote inside an unquoted field, an unclosed quote, a byte after a closing
# quote) raise on every side.
#
# Realistic size: 20 MB, a 200k-row customer export (id, name, email, city,
# amount, date, a note quoted in a third of the rows), with a sweep of 2k,
# 20k and 1M rows (100 MB).
#
# Timing: every timed parse runs in a fresh process (spawn, parse, exit),
# as a request handler or a Task per file would. Measured first in one
# long-lived process, best of 15, the answer depended on the heap the
# earlier runs left: with a GC before each run (as Defk.Bench.report/1
# does) NimbleCSV 201-358 ms and the copy 172-257 ms, 0.81x to 2.08x
# between runs; with no GC between runs NimbleCSV 134-138 ms and the copy
# 96-113 ms. In a fresh process every run grows its heap from nothing,
# and the spread is 2% (median against best).
#
# Measured (M-series Mac, OTP 29, Elixir 1.20, 2026-10-20, fresh process
# per run; the report best of 15, the variant lines best of 5; three runs
# with E2, provisional until the stored run):
#
#   20 MB           E1 308-315 ms, E2 288-299 ms, E3 300-305 ms;
#                   the copy 130.7-141.9 ms        2.23x over E2  good
#                   rusty_csv 49.6-53.5 ms: 5.8x E2, 2.6x the copy.
#   The parts       pass 1 4.8-5.1 ms, scan to the [i64] tape 28 ms, rows
#   (best of 5)     from it 119-127 ms (the tape 152-158 ms end to end);
#                   the copy 36 ms, its two splits 125-131 ms.
#   Sweep           2k rows 1.7x, 20k 1.7x, 1M rows (100 MB) 2.5x.
#
# What it means: a kernel scans CSV at 0.5-0.7 GB/s, and Elixir then
# spends 3.5-4.5x the scan building the rows. The cleaned copy, split by
# the BIFs, beats the best Elixir by about 2.2x in a fresh process, so a
# tape does reopen the wrapper table's row, narrowly. rusty_csv builds the
# same sub-binaries in C, 2.6x faster again, on a dirty scheduler: where
# the speed matters, it is still the choice. The kernel route needs no
# extra NIF, and its call yields on a normal scheduler.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:nimble_csv, "~> 1.3"},
  {:rusty_csv, "~> 0.4"}
])

defmodule Tape.Source do
  # The kernels, as a `use` block for Tape.Kernels, compiled with
  # `elixir_mode: true` (native by default; `__defk_elixir__/2` is the
  # agreement check's oracle).
  defmacro __using__(_) do
    quote location: :keep do
      # Flags in a field's second tape word, above its length
      @esc 1_099_511_627_776
      @eol 2_199_023_255_552

      # Pass 1: an upper bound on the fields: one per ',' or '\n', plus one.
      defk count_separators(s :: [u8]) :: i64 do
        for c <- s, reduce: 1 do
          acc -> if c == 44 or c == 10, do: wrap64(acc + 1), else: acc
        end
      end

      # Pass 2: RFC 4180 as NimbleCSV.RFC4180 reads it. Each field is two
      # words: its start, and its length plus @esc (a quoted field with
      # doubled quotes, to unescape) plus @eol (the last field of a row).
      # Rows end in "\n" or "\r\n". A quote inside an unquoted field, or
      # anything but a separator after a closing quote, raises ArgumentError.
      # States: 0 row start, 1 unquoted field, 2 quoted field, 3 after a
      # quote in a quoted field, 4 '\r' after a closing quote, 5 field
      # start after ','.
      defk scan(s :: [u8], cap :: i64) :: {[i64], i64} do
        if length(s) >= @esc, do: raise(ArgumentError, "an input of 1 TiB or more")
        tape = alloc(i64, 2 * cap)
        n = length(s)

        {st, fs, qe, esc, k} =
          for i <- 0..(n - 1)//1, reduce: {0, 0, 0, false, 0} do
            {st, fs, qe, esc, k} ->
              c = s[i]

              cond do
                st == 2 ->
                  if c == 34, do: {3, fs, i, esc, k}, else: {2, fs, qe, esc, k}

                st == 3 and c == 34 ->
                  {2, fs, qe, true, k}

                st == 3 and c == 13 ->
                  {4, fs, qe, esc, k}

                st == 3 or st == 4 ->
                  if c != 44 and c != 10, do: raise(ArgumentError, "a byte after a closing quote")

                  if st == 4 and c != 10,
                    do: raise(ArgumentError, "a '\\r' after a closing quote")

                  tape[2 * k] = fs
                  w = qe - fs
                  w = if esc, do: w + @esc, else: w
                  tape[2 * k + 1] = if c == 10, do: w + @eol, else: w
                  {if(c == 10, do: 0, else: 5), i + 1, qe, false, k + 1}

                c == 34 ->
                  if st == 1, do: raise(ArgumentError, "a quote inside an unquoted field")
                  {2, i + 1, qe, false, k}

                c == 44 ->
                  tape[2 * k] = if st == 1, do: fs, else: i
                  tape[2 * k + 1] = if st == 1, do: i - fs, else: 0
                  {5, i + 1, qe, false, k + 1}

                c == 10 ->
                  f = if st == 1, do: fs, else: i
                  e = if i > f and s[i - 1] == 13, do: i - 1, else: i
                  tape[2 * k] = f
                  tape[2 * k + 1] = e - f + @eol
                  {0, i + 1, qe, false, k + 1}

                true ->
                  {1, if(st == 1, do: fs, else: i), qe, esc, k}
              end
          end

        if st == 2 or st == 4, do: raise(ArgumentError, "the input ends inside a quoted field")

        k =
          cond do
            st == 1 ->
              tape[2 * k] = fs
              tape[2 * k + 1] = n - fs + @eol
              k + 1

            st == 3 ->
              tape[2 * k] = fs
              w = qe - fs
              tape[2 * k + 1] = if(esc, do: w + @esc, else: w) + @eol
              k + 1

            st == 5 ->
              tape[2 * k] = n
              tape[2 * k + 1] = @eol
              k + 1

            true ->
              k
          end

        {tape, k}
      end

      # The other tape form: a cleaned copy. Separating commas become 31
      # (US), row ends 30 (RS, also after the last row), the quotes around
      # a quoted field go and a doubled quote is written once; a "\r"
      # before "\n" outside quotes goes. Returns {buffer, length}. A 30 or
      # 31 byte in the input raises ArgumentError (this form's limit); the
      # rest of the grammar is scan/2's. States as in scan/2.
      defk normalize(s :: [u8]) :: {[u8], i64} do
        n = length(s)
        out = alloc(u8, n + 1)

        {st, j} =
          for i <- 0..(n - 1)//1, reduce: {0, 0} do
            {st, j} ->
              c = s[i]
              if c == 30 or c == 31, do: raise(ArgumentError, "a 30 or 31 byte in the input")

              cond do
                st == 2 ->
                  if c == 34 do
                    {3, j}
                  else
                    out[j] = c
                    {2, j + 1}
                  end

                st == 3 and c == 34 ->
                  out[j] = 34
                  {2, j + 1}

                st == 3 and c == 13 ->
                  {4, j}

                st == 3 or st == 4 ->
                  if c != 44 and c != 10, do: raise(ArgumentError, "a byte after a closing quote")

                  if st == 4 and c != 10,
                    do: raise(ArgumentError, "a '\\r' after a closing quote")

                  out[j] = if c == 10, do: 30, else: 31
                  {if(c == 10, do: 0, else: 5), j + 1}

                c == 34 ->
                  if st == 1, do: raise(ArgumentError, "a quote inside an unquoted field")
                  {2, j}

                c == 44 ->
                  out[j] = 31
                  {5, j + 1}

                c == 10 ->
                  out[j] = 30
                  {0, j + 1}

                c == 13 and i + 1 < n and s[i + 1] == 10 ->
                  {st, j}

                true ->
                  out[j] = c
                  {1, j + 1}
              end
          end

        if st == 2 or st == 4, do: raise(ArgumentError, "the input ends inside a quoted field")
        closes = st == 1 or st == 3 or st == 5
        if closes, do: out[j] = 30
        {out, if(closes, do: j + 1, else: j)}
      end
    end
  end
end

defmodule Tape.Kernels do
  use Defk, elixir_mode: true
  use Tape.Source
end

defmodule Tape.Build do
  import Bitwise

  @len 1_099_511_627_775
  @esc 1_099_511_627_776
  @eol 2_199_023_255_552

  # The rows NimbleCSV.RFC4180.parse_string(csv, skip_headers: false)
  # returns: lists of sub-binaries of csv, a quoted field with doubled
  # quotes unescaped into a new binary.
  def rows(csv, {tape, k}), do: build(binary_part(tape, 0, 16 * k), csv, [], [])

  defp build(<<s::signed-native-64, w::signed-native-64, rest::binary>>, csv, row, acc) do
    f = binary_part(csv, s, w &&& @len)
    f = if (w &&& @esc) != 0, do: :binary.replace(f, "\"\"", "\"", [:global]), else: f

    if (w &&& @eol) != 0,
      do: build(rest, csv, [], [:lists.reverse([f | row]) | acc]),
      else: build(rest, csv, [f | row], acc)
  end

  defp build(<<>>, _csv, [], acc), do: :lists.reverse(acc)
end

defmodule Tape.Calls do
  def parse(csv), do: Tape.Build.rows(csv, scan(csv))
  def scan(csv), do: Tape.Kernels.scan(csv, Tape.Kernels.count_separators(csv))

  # The cleaned copy, split by the :binary BIFs: rows at 30, fields at 31.
  def parse_normalized(csv), do: split_normalized(Tape.Kernels.normalize(csv))

  def split_normalized({_out, 0}), do: []

  def split_normalized({out, j}) do
    for row <- :binary.split(binary_part(out, 0, j - 1), <<30>>, [:global]),
        do: :binary.split(row, <<31>>, [:global])
  end
end

defmodule Tape.Elixir do
  # The :binary BIFs do the scanning. Lines by :binary.split; a line
  # without a quote is split on commas. A line with one is joined with the
  # next while a quote is open, then E2 walks it field by field with
  # :binary.match, and E3 splits it on commas and joins the pieces of each
  # quoted field. The same rows as NimbleCSV.RFC4180.
  def parse(csv), do: parse(csv, :walk)
  def parse_merge(csv), do: parse(csv, :merge)

  defp parse("", _mode), do: []

  # The last line is open when the input does not end in "\n": NimbleCSV
  # keeps a "\r" there.
  defp parse(csv, mode) do
    lines = :binary.split(csv, "\n", [:global])

    if :binary.last(csv) == ?\n,
      do: rows(:lists.droplast(lines), true, mode, []),
      else: rows(lines, false, mode, [])
  end

  defp rows([], _closed, _mode, acc), do: :lists.reverse(acc)

  defp rows([l | rest], closed, mode, acc) do
    case :binary.match(l, "\"") do
      :nomatch ->
        rows(rest, closed, mode, [:binary.split(strip_cr(l, rest, closed), ",", [:global]) | acc])

      _ ->
        record(l, rest, closed, mode, acc)
    end
  end

  # join lines until the record's quotes balance
  defp record(l, rest, closed, mode, acc) do
    if rem(length(:binary.matches(l, "\"")), 2) == 0 do
      r = strip_cr(l, rest, closed)

      row =
        if mode == :walk, do: fields(r, 0, []), else: merge(:binary.split(r, ",", [:global]), [])

      rows(rest, closed, mode, [row | acc])
    else
      case rest do
        [next | rest] -> record(<<l::binary, ?\n, next::binary>>, rest, closed, mode, acc)
        [] -> raise ArgumentError, "the input ends inside a quoted field"
      end
    end
  end

  # E3: pieces between commas; a piece that opens a quote takes the next
  # pieces until its quotes balance and it ends in a quote
  defp merge([], acc), do: :lists.reverse(acc)
  defp merge([<<?", _::binary>> = p | rest], acc), do: collect(p, rest, acc)

  defp merge([p | rest], acc) do
    if :binary.match(p, "\"") != :nomatch,
      do: raise(ArgumentError, "a quote inside an unquoted field")

    merge(rest, [p | acc])
  end

  defp collect(buf, rest, acc) do
    n = byte_size(buf)

    if n >= 2 and :binary.last(buf) == ?" and rem(length(:binary.matches(buf, "\"")), 2) == 0 do
      inner = binary_part(buf, 1, n - 2)

      case :binary.match(inner, "\"") do
        :nomatch ->
          merge(rest, [inner | acc])

        _ ->
          # a quote that is not doubled ends the field early: NimbleCSV raises
          if :binary.match(:binary.replace(inner, "\"\"", "", [:global]), "\"") != :nomatch,
            do: raise(ArgumentError, "a byte after a closing quote")

          merge(rest, [:binary.replace(inner, "\"\"", "\"", [:global]) | acc])
      end
    else
      case rest do
        [p | rest] -> collect(<<buf::binary, ?,, p::binary>>, rest, acc)
        [] -> raise ArgumentError, "a byte after a closing quote"
      end
    end
  end

  defp strip_cr(l, [], false), do: l

  defp strip_cr(l, _rest, _closed) do
    n = byte_size(l)
    if n > 0 and :binary.at(l, n - 1) == ?\r, do: binary_part(l, 0, n - 1), else: l
  end

  defp fields(r, p, acc) do
    n = byte_size(r)

    if p < n and :binary.at(r, p) == ?" do
      {f, q} = quoted(r, p + 1, p + 1, false)

      cond do
        q == n -> :lists.reverse([f | acc])
        :binary.at(r, q) == ?, -> next(r, q + 1, [f | acc])
        true -> raise ArgumentError, "a byte after a closing quote"
      end
    else
      case :binary.match(r, ",", scope: {p, n - p}) do
        {c, 1} -> next(r, c + 1, [unquoted(r, p, c - p) | acc])
        :nomatch -> :lists.reverse([unquoted(r, p, n - p) | acc])
      end
    end
  end

  # after a ',' a field always follows, empty at the end of the record
  defp next(r, p, acc) when p == byte_size(r), do: :lists.reverse(["" | acc])
  defp next(r, p, acc), do: fields(r, p, acc)

  defp unquoted(r, p, len) do
    f = binary_part(r, p, len)

    if :binary.match(f, "\"") != :nomatch,
      do: raise(ArgumentError, "a quote inside an unquoted field")

    f
  end

  # from s, the field's first byte; returns {field, index after the closing quote}
  defp quoted(r, s, p, esc) do
    case :binary.match(r, "\"", scope: {p, byte_size(r) - p}) do
      :nomatch ->
        raise ArgumentError, "the input ends inside a quoted field"

      {q, 1} ->
        if q + 1 < byte_size(r) and :binary.at(r, q + 1) == ?" do
          quoted(r, s, q + 2, true)
        else
          f = binary_part(r, s, q - s)
          {if(esc, do: :binary.replace(f, "\"\"", "\"", [:global]), else: f), q + 1}
        end
    end
  end
end

defmodule Tape.Data do
  # A customer export: id, name, email, city, amount, signup date, and a
  # free-text note that is quoted in a third of the rows (commas inside),
  # with doubled quotes in a tenth and a line break in one row of 200.
  @first ~w(Anna Bo Carlos Dana Emil Fatima Gustav Hana Ivan Jade Karl Lena)
  @last ~w(Svensson Okafor Lindqvist Moreau Tanaka Novak Haddad Berg Costa Ito)
  @city ["Stockholm", "Malmö", "Göteborg", "Uppsala", "Valletta", "London", "São Paulo", "Kraków"]
  @words ~w(called about the invoice wants a refund new address prefers email VIP late payment)

  def csv(rows, seed \\ 1) do
    :rand.seed(:exsss, {seed, 3, 5})

    IO.iodata_to_binary(
      for id <- 1..rows//1 do
        fst = Enum.random(@first)
        lst = Enum.random(@last)

        [
          Integer.to_string(id),
          ?,,
          fst,
          " ",
          lst,
          ?,,
          String.downcase(fst),
          ?.,
          String.downcase(lst),
          "@example.com,",
          Enum.random(@city),
          ?,,
          :erlang.float_to_binary(:rand.uniform() * 5000, decimals: 2),
          ?,,
          "2026-",
          pad(:rand.uniform(12)),
          ?-,
          pad(:rand.uniform(28)),
          ?,,
          note(),
          "\r\n"
        ]
      end
    )
  end

  defp pad(n) when n < 10, do: [?0, Integer.to_string(n)]
  defp pad(n), do: Integer.to_string(n)

  defp note do
    words = Enum.join(Enum.take_random(@words, :rand.uniform(6)), " ")

    case :rand.uniform(200) do
      r when r <= 20 -> [?", words, ", said \"\"ok\"\"", ?"]
      r when r <= 21 -> [?", words, "\nsecond line", ?"]
      r when r <= 67 -> [?", words, ", ", words, ?"]
      _ -> words
    end
  end
end

alias Tape.{Calls, Data, Kernels}

nimble = &NimbleCSV.RFC4180.parse_string(&1, skip_headers: false)
rusty = &RustyCSV.RFC4180.parse_string(&1, skip_headers: false)

# ---- agreement ----

raises? = fn f ->
  try do
    f.()
    false
  rescue
    _ -> true
  end
end

oracle = fn csv ->
  Tape.Build.rows(csv, Kernels.__defk_elixir__(:scan, [csv, Kernels.count_separators(csv)]))
end

cases =
  [
    "",
    "a",
    "a,b",
    "a,b\n",
    "a,b\r\n",
    "a,b\n\nc,d\n",
    "a,\n,b\n",
    ",",
    ",\n",
    "\n",
    "\r\n",
    "\"a,1\",\"x\"\"y\",\"\"\n",
    "\"q\"",
    "\"q\"\r\n",
    "\"multi\nline\",x\n",
    "\"\"\"\"",
    "a\r",
    "x,\"y\"",
    Data.csv(3000, 9)
  ] ++ for(r <- 1..30, do: Data.csv(r, r))

agree =
  Enum.all?(cases, fn c ->
    (p = Calls.parse(c)) == nimble.(c) and p == oracle.(c) and p == Calls.parse_normalized(c) and
      p == Calls.split_normalized(Kernels.__defk_elixir__(:normalize, [c])) and
      p == Tape.Elixir.parse(c) and p == Tape.Elixir.parse_merge(c)
  end)

bad = ["a\"b,c\n", "\"a\"b,c\n", "\"open\n", "\"open", "\"a\"\rb", "x,\"y\"z"]

bad_ok =
  Enum.all?(bad, fn c ->
    raises?.(fn -> Calls.parse(c) end) and raises?.(fn -> oracle.(c) end) and
      raises?.(fn -> nimble.(c) end) and raises?.(fn -> Calls.parse_normalized(c) end) and
      raises?.(fn -> Tape.Elixir.parse(c) end) and raises?.(fn -> Tape.Elixir.parse_merge(c) end)
  end)

csv = Data.csv(200_000)
rows = nimble.(csv)
rusty_agree = rusty.(csv) == rows

IO.puts("""
agreement: tape == NimbleCSV and Elixir mode on #{length(cases)} inputs #{agree}, \
bad input raises on every side #{bad_ok} (#{length(bad)} cases), rusty_csv agrees #{rusty_agree}
""")

# Every timed parse runs in a fresh process, as a request handler would,
# and the time includes its exit. Building 1.4M terms in one long-lived
# process gave answers that depended on the heap the earlier runs left:
# NimbleCSV 134-358 ms, the copy 96-264 ms, the verdict 0.8x to 2.1x.
fresh = fn f ->
  fn ->
    {_pid, ref} = spawn_monitor(fn -> f.() end)

    receive do
      {:DOWN, ^ref, :process, _, :normal} -> :ok
      {:DOWN, ^ref, :process, _, reason} -> exit(reason)
    end
  end
end

best = fn f, runs ->
  g = fresh.(f)
  for(_ <- 1..runs, do: elem(:timer.tc(g), 0)) |> Enum.min() |> Kernel./(1000) |> Float.round(3)
end

tape = Calls.scan(csv)
norm = Kernels.normalize(csv)

IO.puts(
  "csv, #{Float.round(byte_size(csv) / 1_000_000, 1)} MB (#{length(rows)} rows x 7 fields), best of 5:"
)

for {label, f} <- [
      {"E1 NimbleCSV.RFC4180.parse_string", fn -> nimble.(csv) end},
      {"E2 :binary.split, quoted lines walked", fn -> Tape.Elixir.parse(csv) end},
      {"E3 :binary.split, quoted pieces joined", fn -> Tape.Elixir.parse_merge(csv) end},
      {"rusty_csv parse_string (Rust NIF)", fn -> rusty.(csv) end},
      {"defk pass 1 (count separators)", fn -> Kernels.count_separators(csv) end},
      {"defk pass 2 (scan to tape)", fn -> Kernels.scan(csv, elem(tape, 1) + 1) end},
      {"Elixir rows from the tape", fn -> Tape.Build.rows(csv, tape) end},
      {"tape end to end", fn -> Calls.parse(csv) end},
      {"defk normalize (cleaned copy)", fn -> Kernels.normalize(csv) end},
      {"Elixir rows from the copy (2 splits)", fn -> Calls.split_normalized(norm) end},
      {"cleaned copy end to end", fn -> Calls.parse_normalized(csv) end}
    ] do
  IO.puts("  #{String.pad_trailing(label, 36)} #{best.(f, 5)} ms")
end

# ---- the verdict: the cleaned copy (the faster tape form) against
# NimbleCSV, with rusty_csv's NIF beside it ----

sweep = fn rows ->
  c = Data.csv(rows, 17)
  {fresh.(fn -> Tape.Elixir.parse(c) end), fresh.(fn -> Calls.parse_normalized(c) end)}
end

Defk.Bench.report(
  name: "tape_csv",
  expected: :good,
  baseline: :optimized,
  runs: 15,
  realistic_size: "20 MB: a 200k-row customer export",
  elixir: fresh.(fn -> Tape.Elixir.parse(csv) end),
  defk: fresh.(fn -> Calls.parse_normalized(csv) end),
  native: {fresh.(fn -> rusty.(csv) end), "rusty_csv 0.4.6"},
  check: fn -> agree and bad_ok and rusty_agree and Calls.parse_normalized(csv) == rows end,
  sweep: for(r <- [2_000, 20_000, 1_000_000], do: Tuple.insert_at(sweep.(r), 0, "#{r} rows")),
  sweep_runs: 3,
  reason:
    "the kernel cleans 20 MB in 36 ms and two :binary.split passes build the rows, with less garbage than a parser in Elixir; rusty_csv builds them in C, 2.7x faster still"
)
