defmodule Defk.Report do
  @moduledoc """
  The fast-path report: for each kernel, what the compiler did to its hot
  path, to explain a measurement. It is a tool, not part of the kernel
  subset: a kernel's meaning never depends on it.

  Every module that uses `Defk` gets `__defk_report__/0`, a list of
  `{kernel, line, fact}`: `kernel` is `{name, arity}` of a kernel called from
  Elixir, `line` a line of the module's source file, and `fact` is
  `{topic, verdict, text}`:

    * `{:kernel, :yield | :no_yield, "dot/2"}` at the `defk` line
    * `{:bounds, :dropped | :kept, text}` for each array access and word
      load; a kept check names the fact that would drop it
      (`"a[i + 1]: bounds check kept; nothing proves i + 1 < len(a)"`)
    * `{:branch, :select | :branch, text}` for each `if`, `cond` and `case`,
      with why it is not a select
    * `{:loop, :per_iteration | :strips | :none, text}` for each loop: a
      safepoint every iteration, strips of `DEFK_STRIP` trips with one
      safepoint per strip, or none (`yield: false`), and why
    * `{:nonfinite, :flagged | :checked, text}` for a flat loop with float
      checks: flagged (one non-finite check per strip) or not, and why
    * `{:inline, :inlined, "f/2"}` for each inlined kernel call
    * `{:copy, :copied, text}` for each copy that value semantics inserts
    * `{:alloc, :unzeroed | :zeroed | :strips, text}` for each alloc/2: not
      zeroed (the next loop writes every element first), zeroed at once
      (a small constant length, or `yield: false`), or zeroed in strips with
      a safepoint after each
    * `{:vectorize, :vectorized | :missed | :partial | :unknown, text}` for
      each loop, only with `use Defk, report: :full`

  defk's own facts are noted while the kernel is lowered, at no extra
  compiler pass. The vectorisation facts come from clang's
  `-Rpass=loop-vectorize` remarks: `report: :full` compiles the C a second
  time with remarks on (cached beside the library, which it leaves as it
  is) and maps each remark to its kernel loop. When `CC` is not clang, each
  loop reports `vectorised: unknown (CC is not clang)`.

  A note inside an inlined call is on the callee's line and belongs to the
  kernel the call is inlined into. `print/1` shows the report as margin
  notes on the kernel source.

  ## Stability

  `print/1`, `format/1` and the `report: :full` option are public. The facts
  are not: their topics, verdicts and texts grow with the compiler, so
  `__defk_report__/0`, the types below and the printed text may change in
  any version. Read the report to explain a measurement; don't make a test
  or a tool depend on its exact text.

  ## Example

      iex> defmodule MyApp.Dot do
      ...>   use Defk
      ...>
      ...>   defk dot(a :: [f64], b :: [f64]) :: f64 do
      ...>     n = min(len(a), len(b))
      ...>
      ...>     for i <- 0..(n - 1)//1, reduce: 0.0 do
      ...>       acc -> acc + a[i] * b[i]
      ...>     end
      ...>   end
      ...> end
      iex> for {{:dot, 2}, _line, {topic, verdict, _text}} <- MyApp.Dot.__defk_report__(),
      ...>   do: {topic, verdict}
      [kernel: :yield, loop: :strips, nonfinite: :flagged, bounds: :dropped, bounds: :dropped]

  The loop runs in strips with one safepoint each, its float checks are
  flagged, and both array reads lost their bounds checks, because `i` stays
  below `len(a)` and `len(b)`. `Defk.Report.print(MyApp.Dot)` shows the
  same notes beside the source lines. When a kernel is slower than you
  expect, [Measuring](measuring.md#5-explain-the-number) and
  [Making a defk kernel fast](performance.md#6-making-a-defk-kernel-fast)
  say what to do with them.
  """

  @typedoc "A kernel called from Elixir, as `{name, arity}`. Unstable."
  @type kernel :: {atom(), arity()}

  @typedoc "A note, `{topic, verdict, text}` (see the module docs). Unstable."
  @type fact :: {atom(), atom(), String.t()}

  @typedoc """
  The value of `__defk_report__/0`: `{kernel, line, fact}` for each note,
  where `line` is a line of the module's source file. Unstable.
  """
  @type t :: [{kernel(), pos_integer() | nil, fact()}]

  @doc """
  Prints each kernel of `module` with its report as margin notes beside its
  source lines; notes in inlined code follow the kernel.

  `module` is a module that uses `Defk`, and its source file must be
  readable for the source lines to show. The text is `format/1`'s.
  """
  @spec print(module()) :: :ok
  def print(module), do: IO.write(format(module))

  @doc """
  The text `print/1` prints, as a string.

      iex> defmodule MyApp.Scale do
      ...>   use Defk
      ...>
      ...>   defk scale(a :: [f64], k :: f64) :: [f64] do
      ...>     out = alloc(f64, len(a))
      ...>
      ...>     for i <- 0..(len(a) - 1)//1 do
      ...>       out[i] = a[i] * k
      ...>     end
      ...>
      ...>     out
      ...>   end
      ...> end
      iex> text = Defk.Report.format(MyApp.Scale)
      iex> text =~ "scale/2"
      true
      iex> text =~ "out[i]: no bounds check"
      true
  """
  @spec format(module()) :: String.t()
  def format(module) do
    report = module.__defk_report__()
    file = module.module_info(:compile)[:source] |> to_string()
    lines = read_lines(file)

    report
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map_join("\n", fn k ->
      notes = for {^k, line, fact} <- report, do: {line, fact}
      format_kernel(k, notes, file, lines)
    end)
  end

  defp read_lines(file) do
    case File.read(file) do
      {:ok, src} -> src |> String.split(["\r\n", "\n"]) |> List.to_tuple()
      _ -> nil
    end
  end

  defp format_kernel({name, arity}, notes, file, lines) do
    {start, yield} =
      Enum.find_value(notes, {nil, :yield}, fn
        {line, {:kernel, y, _}} -> {line, y}
        _ -> nil
      end)

    extent = extent(start, lines, notes)
    {inside, outside} = Enum.split_with(notes, fn {l, _} -> l in extent end)
    title = "#{name}/#{arity}#{if yield == :no_yield, do: " (yield: false)"}"
    where = if start, do: "  #{Path.relative_to_cwd(file)}:#{start}", else: ""

    [
      title <> where <> "\n",
      listing(extent, inside, lines),
      if(outside == [],
        do: [],
        else: ["  in inlined code:\n", listing(outside |> line_set(), outside, lines)]
      )
    ]
    |> IO.iodata_to_binary()
  end

  # the kernel's lines: from its defk line to the `end` at the same indent
  defp extent(nil, _lines, notes), do: line_set(notes)
  defp extent(start, nil, notes), do: line_set(notes) |> Enum.filter(&(&1 >= start))

  defp extent(start, lines, _notes) do
    head = line(lines, start)

    if head =~ ~r/\bdo:/ do
      [start]
    else
      indent = indent(head)

      stop =
        Enum.find(start..tuple_size(lines), start, fn n ->
          n > start and Regex.match?(~r/^#{indent}end\b/, line(lines, n))
        end)

      Enum.to_list(start..stop)
    end
  end

  defp line_set(notes),
    do: notes |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

  defp indent(text),
    do:
      text
      |> String.length()
      |> Kernel.-(String.length(String.trim_leading(text)))
      |> then(&String.duplicate(" ", &1))

  defp line(nil, _n), do: ""
  defp line(lines, n) when n >= 1 and n <= tuple_size(lines), do: elem(lines, n - 1)
  defp line(_lines, _n), do: ""

  defp listing(numbers, notes, lines) do
    by_line = Enum.group_by(notes, &elem(&1, 0), &describe(elem(&1, 1)))
    texts = Map.new(numbers, &{&1, line(lines, &1)})

    margin =
      min(60, texts |> Map.values() |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)) + 2

    width = numbers |> Enum.max(fn -> 0 end) |> Integer.to_string() |> String.length()

    Enum.map(numbers, fn n ->
      text = texts[n]
      num = String.pad_leading(Integer.to_string(n), width + 2)
      blank = String.duplicate(" ", width + 2)

      case Enum.reject(Map.get(by_line, n, []), &is_nil/1) do
        [] ->
          "#{num} | #{text}\n" |> trim_line()

        [first | rest] ->
          col = max(margin, String.length(text) + 2)

          [
            "#{num} | #{String.pad_trailing(text, col)}# #{first}\n",
            Enum.map(rest, &"#{blank} | #{String.duplicate(" ", col)}# #{&1}\n")
          ]
      end
    end)
  end

  defp trim_line(s), do: String.trim_trailing(s) <> "\n"

  defp describe({:kernel, _, _}), do: nil
  defp describe({:bounds, :dropped, t}), do: "#{t}: no bounds check"
  defp describe({:loop, _, t}), do: "loop: #{t}"
  defp describe({:nonfinite, _, t}), do: "non-finite: #{t}"
  defp describe({:inline, _, t}), do: "inlined #{t}"
  defp describe({:copy, _, t}), do: "copy: #{t}"
  defp describe({:alloc, _, t}), do: "alloc: #{t}"
  defp describe({_, _, t}), do: t

  # ------------------------------------------------------- report: :full --

  @doc false
  # `report` with a :vectorize fact after each loop's, from clang's remarks
  # on `c_src`, the C of the library at `base` (Defk.Build.build!/3).
  @spec full(t(), binary(), String.t()) :: t()
  def full(report, c_src, base) do
    loops = for {k, line, {:loop, _, _}} <- report, do: {k, line}

    vec =
      if Defk.Build.clang?() do
        case Defk.Build.remarks!(c_src, base) do
          {:ok, remarks} -> vectorization(loops, c_src, Path.basename(base <> ".c"), remarks)
          {:error, _} -> unknown(loops, "vectorised: unknown (clang's remark pass failed)")
        end
      else
        unknown(loops, "vectorised: unknown (CC is not clang)")
      end

    Enum.flat_map(report, fn
      {k, line, {:loop, _, _}} = n ->
        {verdict, text} = vec[{k, line}]
        [n, {k, line, {:vectorize, verdict, text}}]

      n ->
        [n]
    end)
  end

  defp unknown(loops, text), do: Map.new(loops, &{&1, {:unknown, text}})

  # Each loop/5 form in the C is between `/* defk:loop name/arity line */`
  # and `/* defk:end */` (Defk.Compiler.note_loop/2), and a flagged loop's
  # replay, which runs only after a non-finite value, follows
  # `/* defk:replay */`. clang reports a loop at its header, after the
  # analysis remarks that give its reasons; a remark is the innermost
  # form's, and the replay's are left out.
  defp vectorization(loops, c_src, c_file, remarks) do
    names = Map.new(loops, fn {{n, a}, l} = loop -> {"#{n}/#{a} #{l}", loop} end)
    {regions, replays} = regions(c_src, names)

    {_, found} =
      Enum.reduce(remarks, {[], %{}}, fn
        {_, _, :analysis, msg}, {why, acc} ->
          {[msg | why], acc}

        {^c_file, l, kind, msg}, {why, acc} ->
          case region_at(regions, replays, l) do
            nil -> {[], acc}
            loop -> {[], Map.update(acc, loop, [{kind, msg, why}], &[{kind, msg, why} | &1])}
          end

        _, {_, acc} ->
          {[], acc}
      end)

    Map.new(loops, fn loop -> {loop, verdict(Enum.reverse(Map.get(found, loop, [])))} end)
  end

  defp regions(c_src, names) do
    {_, regions, replays} =
      c_src
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], []}, fn {text, n}, {stack, done, replays} ->
        case text do
          "/* defk:loop " <> rest ->
            {[{names[String.trim_trailing(rest, " */")], n} | stack], done, replays}

          "/* defk:end */" ->
            [{loop, start} | stack] = stack
            {stack, [{start, n, loop} | done], replays}

          "/* defk:replay */" ->
            {stack, done, [n | replays]}

          _ ->
            {stack, done, replays}
        end
      end)

    {regions, replays}
  end

  defp region_at(regions, replays, l) do
    inner =
      regions
      |> Enum.filter(fn {start, stop, _} -> start <= l and l <= stop end)
      |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    case inner do
      nil -> nil
      {start, _, loop} -> if Enum.any?(replays, &(&1 > start and &1 <= l)), do: nil, else: loop
    end
  end

  @not_vectorized "loop not vectorized: "

  defp verdict([]), do: {:unknown, "vectorised: unknown (clang gave no remark for this loop)"}

  defp verdict(forms) do
    passed =
      for {:passed, msg, _} <- forms, do: String.replace_prefix(msg, "vectorized loop ", "")

    why =
      for {:missed, _, why} <- forms,
          w <- Enum.reverse(why),
          uniq: true,
          do: String.replace_prefix(w, @not_vectorized, "")

    missed = Enum.count(forms, &match?({:missed, _, _}, &1))
    reasons = if why == [], do: "clang gave no reason", else: Enum.join(why, "; ")

    cond do
      missed == 0 ->
        {:vectorized, "vectorised #{passed |> Enum.uniq() |> Enum.join("; ")}"}

      passed == [] ->
        {:missed, "not vectorised: #{reasons}"}

      true ->
        {:partial,
         "vectorised in #{length(passed)} of #{length(forms)} of its C loops #{Enum.uniq(passed) |> Enum.join("; ")}; not in the rest: #{reasons}"}
    end
  end
end
