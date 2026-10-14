defmodule Defk.Clauses do
  @moduledoc false
  # Multi-clause kernels: one bodiless typed head, then clauses as
  # Elixir writes a multi-clause function,
  #
  #     defk dod_bits(acc :: bitstring, dod :: i64) :: bitstring
  #     defk dod_bits(acc, 0), do: <<acc::bitstring, 0::1>>
  #     defk dod_bits(acc, dod) when dod >= -63 and dod <= 64, do: ...
  #
  # merge/1 turns each head and its clauses into one kernel whose body is a
  # `case` over the parameters, before the compiler and Elixir mode see it,
  # so both give it the meaning of the case they already share:
  #
  #   * the subject is the first parameter some clause matches with a literal
  #     (`true` if none does); its literals are the case patterns, and a
  #     literal at another parameter is a `param === literal` test in front
  #     of the clause's guard (Elixir matches every pattern before the guard,
  #     and `and` short-circuits, so a guard error still fails the clause)
  #   * a clause variable is renamed to the head parameter at its position,
  #     in its guard and body, and a head parameter's name that the clause
  #     does not bind is renamed to a name no Elixir variable has, so a
  #     clause sees only its own variables (an unbound use is
  #     undefined-variable) and nothing is copied
  #   * the case carries `defk_clauses: {name, arity}` in its meta: no clause
  #     matching raises FunctionClauseError for that function (natively and
  #     in Elixir mode) instead of CaseClauseError
  #
  # A rejection (a clause with no head, types in a clause, a pattern outside
  # the subset) is a kernel entry `%{head:, reject: {at, code, what, opts}}`,
  # which the compiler reports as any other rejection.

  @lit_types %{i64: :integer, bool: :boolean}

  @doc false
  # The kernels with each head and its clauses merged into one kernel.
  def merge(kernels) do
    heads =
      kernels
      |> Enum.filter(&head?/1)
      |> Enum.group_by(&key(&1.head))

    {out, _} =
      Enum.flat_map_reduce(kernels, MapSet.new(), fn k, done ->
        key = key(k.head)

        cond do
          head?(k) and key in done ->
            {[duplicate_head(k)], done}

          head?(k) ->
            clauses = Enum.filter(kernels, &(not head?(&1) and key(&1.head) == key))
            {merged(k, clauses), MapSet.put(done, key)}

          Map.has_key?(heads, key) and key in done ->
            {[], done}

          Map.has_key?(heads, key) ->
            {[before_head(k, hd(heads[key]))], done}

          clause?(k.head) and key in done ->
            {[], done}

          clause?(k.head) ->
            {no_head(k, Enum.filter(kernels, &(key(&1.head) == key))), MapSet.put(done, key)}

          true ->
            {[k], done}
        end
      end)

    out
  end

  defp head?(k), do: Map.get(k, :head?, false)

  # {name, arity} of a head or clause, or nil
  @doc false
  def key(head) do
    case call(head) do
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> {name, 0}
      _ -> nil
    end
  end

  defp call({:"::", _, [call, _]}), do: call
  defp call({:when, _, [call, _]}), do: call
  defp call(call), do: call

  defp args(head) do
    case call(head) do
      {_, _, args} when is_list(args) -> args
      _ -> []
    end
  end

  defp typed?({:"::", _, [_, _]}), do: true
  defp typed?(_), do: false

  # a definition with a body and no return type whose parameters are not all
  # `name :: type`: a clause (one that types them all is a kernel missing its
  # return type, which the compiler reports as kernel-head)
  defp clause?(head) do
    match?({:when, _, _}, head) or
      (not typed?(head) and key(head) != nil and not Enum.all?(args(head), &typed?/1))
  end

  defp reject(k, at, code, what, opts),
    do: Map.put(k, :reject, {at, code, what, opts})

  defp duplicate_head(k) do
    {name, arity} = key(k.head)

    reject(k, k.head, "duplicate-kernel", "#{name}/#{arity} has more than one head",
      hint: "keep one bodiless head, then the clauses"
    )
  end

  # the head to suggest names each parameter after a clause variable at its
  # position, if there is one
  defp no_head(k, clauses) do
    {name, arity} = key(k.head)

    params =
      Enum.map_join(0..(arity - 1)//1, ", ", fn i ->
        v =
          Enum.find_value(clauses, "x#{i + 1}", fn c ->
            case Enum.at(args(c.head), i) do
              {v, _, ctx} when is_atom(v) and is_atom(ctx) and v != :_ -> v
              _ -> nil
            end
          end)

        "#{v} :: #{guess_type(clauses, i)}"
      end)

    ret = if Enum.any?(clauses, &unsupported_pattern?/1), do: "type", else: "i64"

    head =
      reject(k, k.head, "clause-head", "#{name}/#{arity} has clauses but no head",
        hint:
          "a multi-clause kernel starts with a bodiless head that types its parameters and result, such as `defk #{name}(#{params}) :: #{ret}`, written before the clauses"
      )

    # the patterns outside the subset are blockers the head would not fix
    [head | Enum.flat_map(clauses, &pattern_errors(&1, List.duplicate({nil, nil}, arity)))]
  end

  # the type to suggest for the parameter at i: [u8] where a clause matches
  # it with a binary pattern, `type` (for the user to fill in) where a clause
  # matches it with a list or map, i64 otherwise
  defp guess_type(clauses, i) do
    pats = Enum.map(clauses, &Enum.at(args(&1.head), i))

    cond do
      Enum.any?(pats, &match?({:<<>>, _, _}, &1)) -> "[u8]"
      Enum.any?(pats, &unsupported?/1) -> "type"
      true -> "i64"
    end
  end

  defp unsupported_pattern?(k), do: Enum.any?(args(k.head), &unsupported?/1)

  defp unsupported?(pat),
    do:
      match?({:<<>>, _, _}, pat) or is_list(pat) or match?({:%{}, _, _}, pat) or
        match?({:|, _, _}, pat)

  defp before_head(k, head) do
    {name, arity} = key(k.head)

    reject(
      k,
      k.head,
      "clause-head",
      "this clause comes before the head of #{name}/#{arity} (line #{head.line})",
      hint: "move the head `defk #{Macro.to_string(head.head)}` above the first clause"
    )
  end

  # ------------------------------------------------------------- merging --

  defp merged(head, []) do
    {name, arity} = key(head.head)

    [
      reject(head, head.head, "no-body", "#{name}/#{arity} has a head but no clauses",
        hint: "write the clauses after the head, or give the head a do block"
      )
    ]
  end

  defp merged(head, clauses) do
    params = params(head.head)

    case Enum.flat_map(clauses, &clause_errors(&1, head, params)) do
      [] -> [%{head | body: body(head, clauses, params), attrs: %{}}]
      errors -> errors
    end
  end

  # [{name, type atom | nil}] of the head's parameters; a parameter that is
  # not `name :: type` (the compiler rejects the head) gets a name no clause
  # can refer to
  defp params(head) do
    head
    |> args()
    |> Enum.with_index()
    |> Enum.map(fn
      {{:"::", _, [{p, _, ctx}, {t, _, tctx}]}, _}
      when is_atom(p) and is_atom(ctx) and is_atom(tctx) ->
        {p, t}

      {{:"::", _, [{p, _, ctx}, _]}, _} when is_atom(p) and is_atom(ctx) ->
        {p, nil}

      {_, i} ->
        {:"defk param #{i}", nil}
    end)
  end

  defp clause_errors(k, head, params) do
    {name, arity} = key(head.head)
    fun = "#{name}/#{arity}"

    types =
      cond do
        typed?(k.head) ->
          [{k.head, "this clause of #{fun} has a return type"}]

        p = Enum.find(args(k.head), &typed?/1) ->
          [{p, "the clause parameter #{Macro.to_string(p)} of #{fun} has a type"}]

        true ->
          []
      end

    case types do
      [{at, what}] ->
        [
          reject(k, at, "clause-types", "#{what}; types go on the head",
            hint:
              "write the clause without types, `defk #{Macro.to_string(untyped(k.head))}`: the head `defk #{Macro.to_string(head.head)}` declares them"
          )
        ]

      [] ->
        opts_errors(k, fun) ++ pattern_errors(k, params)
    end
  end

  defp opts_errors(%{opts: []}, _fun), do: []

  defp opts_errors(k, fun),
    do: [
      reject(
        k,
        k.head,
        "unknown-option",
        "this clause of #{fun} has options; options go on the head",
        hint:
          "write #{Enum.map_join(k.opts, ", ", &Macro.to_string([&1]))} after the head's return type"
      )
    ]

  defp untyped(head) do
    Macro.prewalk(head, fn
      {:"::", _, [p, _]} -> p
      other -> other
    end)
  end

  defp pattern_errors(k, params) do
    {errors, _} =
      k.head
      |> args()
      |> Enum.zip(params)
      |> Enum.flat_map_reduce(MapSet.new(), fn {pat, {_, t}}, seen ->
        case pattern(pat, t) do
          {:var, v} ->
            if v in seen do
              what = "#{v} appears twice in this clause, which is not in the kernel subset"
              hint = "name each parameter once, and compare in the guard: `when #{v} == other`"
              {[reject(k, pat, "clause-pattern", what, hint: hint)], seen}
            else
              {[], MapSet.put(seen, v)}
            end

          {:error, what, hint} ->
            {[reject(k, pat, "clause-pattern", what, hint: hint)], seen}

          _ ->
            {[], seen}
        end
      end)

    errors
  end

  # :any | {:var, name} | {:lit, value} | {:error, what, hint} for a clause
  # parameter of type t (nil when the head does not say)
  defp pattern(pat, t) do
    case pat do
      {:_, _, ctx} when is_atom(ctx) ->
        :any

      {v, _, ctx} when is_atom(v) and is_atom(ctx) ->
        {:var, v}

      n when is_integer(n) ->
        literal(n, :integer, t)

      {:-, _, [n]} when is_integer(n) ->
        literal(-n, :integer, t)

      b when is_boolean(b) ->
        literal(b, :boolean, t)

      {:<<>>, _, _} = bin ->
        {:error,
         "the clause pattern #{Macro.to_string(bin)} is a binary pattern, which is not in the kernel subset",
         "take the bytes as a `[u8]` parameter and read them by index (`bytes[i]`) or with a `for` over the bytes; a clause matches only integer and bool literals, variables and _"}

      l when is_list(l) ->
        {:error,
         "the clause pattern #{Macro.to_string(l)} is a list pattern, which is not in the kernel subset",
         "take the values as a packed array parameter such as `[i64]` and read them by index, or loop over them with a `for`"}

      {:%{}, _, _} = m ->
        {:error,
         "the clause pattern #{Macro.to_string(m)} is a map pattern, which is not in the kernel subset",
         "a kernel has no maps; pass the values as separate parameters or a packed array"}

      {:^, _, [{v, _, _}]} ->
        {:error, "the clause pattern ^#{v} pins a variable, and a function head has none to pin",
         "match a variable and compare it in the guard: `when x == ...`"}

      other ->
        {:error, "the clause pattern #{Macro.to_string(other)} is not in the kernel subset",
         "match an integer or boolean literal, a variable or _, and test the rest in the guard"}
    end
  end

  defp literal(v, kind, t) do
    if t == nil or @lit_types[t] == kind do
      {:lit, v}
    else
      {:error, "the clause pattern #{inspect(v)} never matches the #{t} parameter",
       "a clause matches an i64 parameter with an integer and a bool with true or false; test other values in the guard"}
    end
  end

  # the case over the parameters (see the module comment)
  defp body(head, clauses, params) do
    pats = Enum.map(clauses, fn k -> Enum.map(args(k.head), &pattern(&1, nil)) end)
    pvars = Enum.map(params, fn {p, _} -> {p, [], nil} end)

    subject_at =
      Enum.find(0..(length(params) - 1)//1, fn i ->
        Enum.any?(pats, &match?({:lit, _}, Enum.at(&1, i)))
      end)

    subject = if subject_at, do: Enum.at(pvars, subject_at), else: true
    arms = for {k, ps} <- Enum.zip(clauses, pats), do: arm(k, ps, subject_at, pvars)
    {name, arity} = key(head.head)
    {:case, [defk_clauses: {name, arity}] ++ meta(hd(clauses)), [subject, [do: arms]]}
  end

  # clause `k` with patterns `ps` as a case clause on the parameter at
  # `subject_at` (nil: the subject is `true`)
  defp arm(k, ps, subject_at, pvars) do
    head_names = Enum.map(pvars, &elem(&1, 0))
    renames = for {{:var, v}, p} <- Enum.zip(ps, head_names), into: %{}, do: {v, p}

    renames =
      for h <- head_names, not Map.has_key?(renames, h), into: renames, do: {h, hidden(h)}

    tests =
      for {{:lit, v}, i} <- Enum.with_index(ps), i != subject_at do
        {:===, [], [Enum.at(pvars, i), v]}
      end

    guard =
      case k.head do
        {:when, _, [_, g]} -> [rename(g, renames)]
        _ -> []
      end

    pat =
      case subject_at && Enum.at(ps, subject_at) do
        {:lit, v} -> v
        _ -> {:_, [], nil}
      end

    lhs =
      case tests ++ guard do
        [] -> pat
        [g | gs] -> {:when, meta(k), [pat, Enum.reduce(gs, g, &{:and, [], [&2, &1]})]}
      end

    {:->, meta(k), [[lhs], rename(k.body, renames)]}
  end

  defp meta(k), do: [line: k.line]

  # a name no Elixir variable can have, standing for head parameter `h` in a
  # clause that does not bind it; an unbound use is reported as `h`
  defp hidden(h), do: {:"defk unbound #{h}", h}

  # every variable of `ast` renamed by `renames` at once (a consistent
  # renaming: binding and shadowing inside keep their meaning), except in
  # module attributes and the types of binary segments
  defp rename({:@, _, _} = attr, _renames), do: attr

  defp rename({:"::", m, [v, spec]}, renames),
    do: {:"::", m, [rename(v, renames), spec_vars(spec, renames)]}

  defp rename({name, m, ctx} = var, renames) when is_atom(name) and is_atom(ctx) do
    case Map.get(renames, name) do
      nil -> var
      {to, shown} -> {to, [defk_name: shown] ++ m, nil}
      to -> {to, m, nil}
    end
  end

  defp rename({f, m, args}, renames) when is_list(args),
    do: {rename(f, renames), m, Enum.map(args, &rename(&1, renames))}

  defp rename({a, b}, renames), do: {rename(a, renames), rename(b, renames)}
  defp rename(list, renames) when is_list(list), do: Enum.map(list, &rename(&1, renames))
  defp rename(other, _renames), do: other

  # only the size expression of a segment type has variables
  defp spec_vars({:size, m, [n]}, renames), do: {:size, m, [rename(n, renames)]}

  defp spec_vars({:-, m, [a, b]}, renames),
    do: {:-, m, [spec_vars(a, renames), spec_vars(b, renames)]}

  defp spec_vars(spec, _renames), do: spec
end
