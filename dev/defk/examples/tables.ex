defmodule Defk.Examples.Tables do
  @moduledoc false
  # Renders the catalog's result tables from the stored scoreboard
  # (`Defk.Examples.Snapshot`) and the hand-written text in
  # examples/_tables.exs, and writes them between marker comments:
  #
  #   examples/README.md  <!-- scoreboard:start --> ... <!-- scoreboard:end -->
  #   README.md           <!-- summary:start --> ... <!-- summary:end -->
  #
  # The numbers come only from the snapshot, so a number a report measures is
  # never typed into a table.

  @text "examples/_tables.exs"
  @targets [{"examples/README.md", "scoreboard"}, {"README.md", "summary"}]

  @doc "The files and marker names the tables are written to."
  def targets, do: @targets

  @doc "The hand-written table text."
  def text(file \\ Path.join(Defk.Examples.root(), @text)) do
    {text, _} = Code.eval_file(file)
    text
  end

  @doc """
  `{:ok, %{marker => markdown}}` for `snapshot` and `text`, or `{:error,
  problems}` listing every problem: an example without text, text without an
  example, a placeholder naming no report, a value a report did not record,
  a summary group whose examples disagree on the verdict.
  """
  def render(snapshot, text) do
    rows = rows(snapshot)
    index = index(snapshot)
    {scoreboard, p1} = scoreboard(snapshot, rows, index, text)
    {summary, p2} = summary(snapshot, rows, index, text)

    case coverage(rows, text) ++ p1 ++ p2 do
      [] -> {:ok, %{"scoreboard" => scoreboard, "summary" => summary}}
      problems -> {:error, Enum.uniq(problems)}
    end
  end

  @doc "`content` with the block between `marker`'s comments replaced by `block`."
  def put(content, marker, block) do
    case split(content, marker) do
      {:ok, before, _old, after_} -> {:ok, before <> block <> after_}
      :error -> {:error, "no #{start_tag(marker)} ... #{end_tag(marker)} pair"}
    end
  end

  @doc "The block between `marker`'s comments in `content`, or `:error`."
  def get(content, marker) do
    case split(content, marker) do
      {:ok, _, old, _} -> {:ok, old}
      :error -> :error
    end
  end

  defp split(content, marker) do
    with [before, rest] <- String.split(content, start_tag(marker) <> "\n", parts: 2),
         [old, after_] <- String.split(rest, end_tag(marker), parts: 2) do
      {:ok, before <> start_tag(marker) <> "\n", old, end_tag(marker) <> after_}
    else
      _ -> :error
    end
  end

  defp start_tag(marker), do: "<!-- #{marker}:start -->"
  defp end_tag(marker), do: "<!-- #{marker}:end -->"

  # ---- the snapshot ---------------------------------------------------

  # example name => its first report (the line the runner reads)
  defp rows(snapshot) do
    for %{"name" => name, "results" => [first | _]} <- snapshot["examples"],
        into: %{},
        do: {name, first}
  end

  # report name => report; an example name no report has => its first report
  defp index(snapshot) do
    reports = for e <- snapshot["examples"], r <- e["results"], into: %{}, do: {r["example"], r}
    Map.merge(rows(snapshot), reports)
  end

  defp coverage(rows, text) do
    measured = Map.keys(rows)
    written = Map.keys(text.examples)

    Enum.map(measured -- written, &"#{&1}: measured, but examples/_tables.exs has no text for it") ++
      Enum.map(
        written -- measured,
        &"#{&1}: examples/_tables.exs has text, but the scoreboard has no result"
      )
  end

  # ---- examples/README.md ---------------------------------------------

  defp scoreboard(snapshot, rows, index, text) do
    runs = Map.new(snapshot["examples"], &{&1["name"], &1["run"]})
    quiet = Map.new(snapshot["examples"], &{&1["name"], &1["quiet"]})
    newest = newest_run(snapshot)
    loaded = loaded(snapshot)

    {measured, problems} =
      rows
      |> Enum.filter(fn {name, _} -> Map.has_key?(text.examples, name) end)
      |> Enum.map_reduce([], fn {name, r}, acc ->
        t = text.examples[name]
        {native, p1} = fill(Map.get(t, :native, "–"), name, index)
        {line, p2} = fill(t.line, name, index)

        cells = [
          mark(r["verdict"]),
          "[`#{name}`](#{name}.exs)" <>
            note(r, runs[name], newest, loaded == :some and quiet[name] != true),
          t.job,
          speedup_cell(r),
          native,
          line
        ]

        {{{rank(r["verdict"]), 0, -(r["speedup"] || 0)}, cells}, acc ++ p1 ++ p2}
      end)

    # an app's row comes after the measured rows of its verdict
    apps =
      for a <- text.apps do
        {{rank(a.verdict), 1, 0},
         [
           mark(a.verdict),
           "[`#{a.name}/`](#{a.name})",
           a.job,
           a.value,
           Map.get(a, :native, "–"),
           a.line
         ]}
      end

    lines =
      (measured ++ apps)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_, cells} -> "| " <> Enum.join(cells, " | ") <> " |" end)

    block =
      conditions(snapshot) <>
        "\n\n| | Example | The job | defk vs best Elixir | vs the package's NIF | In one line |\n" <>
        "|---|---|---|---|---|---|\n" <> Enum.join(lines, "\n") <> "\n"

    {block, problems}
  end

  # One run: its conditions. Several (rows replaced with --snapshot --only):
  # the span and the newest run's conditions; each older row says when.
  defp conditions(s) do
    machine = "#{s["machine"]} (#{s["logical_cores"]} logical cores)"
    n = newest_run(s)

    newest =
      "OTP #{n["otp"]}, Elixir #{n["elixir"]}: `#{n["command"]}`. A quiet measurement: " <>
        "other processes used at most #{n["quiet_limit"]} cores before and after it."

    head =
      case runs(s) do
        [_] ->
          "Measured on #{day(n)} at commit `#{n["commit"]}` on #{machine}, " <> newest

        runs ->
          "Measured on #{machine} in #{length(runs)} runs, #{span(s)}. The newest at commit " <>
            "`#{n["commit"]}`, " <>
            newest <> " A row from an earlier run says when it was measured, and at which commit."
      end

    head <>
      case loaded(s) do
        :none -> ""
        :all -> " **No row was measured quietly: every number is provisional.**"
        :some -> " **A row not measured quietly says provisional.**"
      end
  end

  defp runs(s), do: s["examples"] |> Enum.map(& &1["run"]) |> Enum.uniq()

  defp newest_run(s), do: s |> runs() |> Enum.max_by(& &1["measured_at"])

  defp span(s) do
    case s |> runs() |> Enum.map(&day/1) |> Enum.uniq() |> Enum.sort() do
      [d] -> "on #{d}"
      days -> "from #{hd(days)} to #{List.last(days)}"
    end
  end

  # whether the rows were measured quietly
  defp loaded(s) do
    case s["examples"] |> Enum.map(&(&1["quiet"] == true)) |> Enum.uniq() do
      [true] -> :none
      [false] -> :all
      _ -> :some
    end
  end

  defp day(%{"measured_at" => at}), do: String.slice(at, 0, 10)

  # A row not measured in the newest run (an older run's row, or a result
  # the cache reused) says when it was measured and at which commit, from
  # its report's stamp; a row not measured quietly among quiet ones says
  # provisional.
  defp note(r, run, newest, provisional?) do
    earlier? = run != newest or r["cache"] == "reused"

    parts =
      if(earlier?, do: ["measured " <> measured(r, run)], else: []) ++
        if provisional?, do: ["provisional"], else: []

    if parts == [], do: "", else: " (" <> Enum.join(parts, ", ") <> ")"
  end

  defp measured(%{"stamp" => %{"measured_at" => at} = stamp}, _run),
    do: String.slice(at, 0, 10) <> at_commit(stamp["commit"])

  defp measured(%{"cache" => "reused", "measured_at" => at}, _run), do: String.slice(at, 0, 10)
  defp measured(_r, run), do: day(run) <> at_commit(run["commit"])

  defp at_commit(nil), do: ""
  defp at_commit(commit), do: " at `#{commit}`"

  defp speedup_cell(%{"speedup" => s, "verdict" => "good"}) when is_number(s),
    do: "**#{times(s)}**"

  defp speedup_cell(%{"speedup" => s}) when is_number(s), do: times(s)
  defp speedup_cell(_), do: "–"

  # ---- README.md ------------------------------------------------------

  defp summary(snapshot, rows, index, text) do
    {lines, problems} =
      Enum.map_reduce(text.summary, [], fn g, acc ->
        {verdict, value, p1} = group(g, rows, text)
        {job, p2} = fill(g.text, nil, index)
        {"| #{mark(verdict)} | #{job} | #{value} |", acc ++ p1 ++ p2}
      end)

    block =
      "Speedups over an optimised Elixir baseline, measured end to end on " <>
        "#{snapshot["machine"]} #{span(snapshot)} (one machine, so measure your own job). " <>
        "✅ defk helps; 🟡 and ❌ use Elixir.\n\n| | The job | defk vs best Elixir |\n|---|---|---|\n" <>
        Enum.join(lines, "\n") <> "\n"

    {block, problems}
  end

  defp group(%{app: app} = g, _rows, text) do
    case Enum.find(text.apps, &(&1.name == app)) do
      nil -> {nil, "?", ["summary: no app #{app} in examples/_tables.exs"]}
      a -> {a.verdict, Map.get(g, :value, a.value), []}
    end
  end

  defp group(%{examples: names} = g, rows, _text) do
    case Enum.reject(names, &Map.has_key?(rows, &1)) do
      [] ->
        found = Enum.map(names, &rows[&1])

        case Enum.uniq(Enum.map(found, & &1["verdict"])) do
          [verdict] ->
            {verdict, Map.get_lazy(g, :value, fn -> range(found) end), []}

          verdicts ->
            {nil, "?",
             [
               "summary: #{Enum.join(names, ", ")} have different verdicts (#{Enum.join(verdicts, ", ")})"
             ]}
        end

      missing ->
        {nil, "?", Enum.map(missing, &"summary: #{&1} is not in the scoreboard")}
    end
  end

  defp range(reports) do
    case reports |> Enum.map(& &1["speedup"]) |> Enum.filter(&is_number/1) |> Enum.sort() do
      [] ->
        "–"

      [lo | _] = all ->
        hi = List.last(all)
        if number(lo) == number(hi), do: times(lo), else: number(lo) <> "–" <> times(hi)
    end
  end

  # ---- placeholders and formats ---------------------------------------

  @placeholder ~r/\{(speedup|native|crossover)(?::([a-z0-9_]+))?\}/

  # `{filled_text, problems}`; `own` is the example a bare placeholder means
  defp fill(text, own, index) do
    @placeholder
    |> Regex.split(text, include_captures: true)
    |> Enum.map_reduce([], fn part, acc ->
      case Regex.run(@placeholder, part) do
        nil ->
          {part, acc}

        [whole, field | name] ->
          name = if name in [[], [""]], do: own, else: hd(name)

          case value(field, name && index[name]) do
            {:ok, v} -> {v, acc}
            {:error, why} -> {"?", acc ++ ["#{inspect(text)}: #{whole} #{why}"]}
          end
      end
    end)
    |> then(fn {parts, problems} -> {Enum.join(parts), problems} end)
  end

  defp value(_field, nil), do: {:error, "names no report"}

  defp value("crossover", r) do
    case Map.fetch(r, "crossover") do
      {:ok, nil} -> {:ok, "none"}
      {:ok, c} -> {:ok, to_string(c)}
      :error -> {:error, "but report #{r["example"]} has no sweep"}
    end
  end

  defp value(field, r) do
    key = if field == "native", do: "native_speedup", else: "speedup"

    case r[key] do
      x when is_number(x) -> {:ok, times(x)}
      _ -> {:error, "but report #{r["example"]} recorded no #{key}"}
    end
  end

  @doc false
  # 209×, 7.3×, 0.28×: whole numbers from 10, one decimal from 1, two below
  def times(x), do: number(x) <> "×"

  defp number(x) when x >= 10, do: Integer.to_string(round(x))
  defp number(x) when x >= 1, do: :erlang.float_to_binary(x * 1.0, decimals: 1)
  defp number(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)

  defp rank("good"), do: 0
  defp rank("marginal"), do: 1
  defp rank("poor"), do: 2
  defp rank("out_of_scope"), do: 3
  defp rank(_), do: 4

  defp mark("good"), do: "✅"
  defp mark("marginal"), do: "🟡"
  defp mark("poor"), do: "❌"
  defp mark("out_of_scope"), do: "⛔"
  defp mark(other), do: "#{other || "?"}"
end
