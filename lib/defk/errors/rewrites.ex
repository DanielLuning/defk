defmodule Defk.Errors.Rewrites do
  # The rewrite-suggestion engine: the rejection and suggested
  # kernel-subset rewrite for a construct outside the subset (unsupported/2),
  # a call the subset has an idiom for (unsupported_local/2, the
  # call_rejection table), and the for/alloc fill and collect rewrites. Pure
  # AST to text, given a type_of callback.
  @moduledoc false

  @math Enum.join(Defk.Builtins.math1(), ", ") <> " and pow"

  # ------------------------------------------------- constructs not in it --

  @doc false
  # The rejection for a construct outside the kernel subset: {code, what,
  # opts}. Used for expressions the compiler has no clause for. `type_of`
  # gives the kernel type of an expression where the construct is, or nil.
  #
  # A `rewrite:` is one candidate or a list of them, written from the
  # developer's code; the compiler shows the first one that compiles where the
  # construct is, and only the hint if none does. A rewrite never names
  # anything the developer has to fill in.
  def unsupported(node, type_of \\ fn _ -> nil end)

  def unsupported({:**, _, [a, b]} = n, type_of) do
    {"unsupported-expression",
     "the power operator in #{Macro.to_string(n)} is not in the kernel subset",
     hint:
       "use pow/2, which returns a float like :math.pow/2, or multiply for a small integer power",
     rewrite: power_rewrite(a, b, type_of.(a), type_of.(b))}
  end

  def unsupported(node, _type_of), do: form(node)

  # Elixir's ** gives an integer for two integers and a float otherwise
  defp power_rewrite(_a, 0, :i64, :i64), do: "1"

  defp power_rewrite(a, b, :i64, :i64) when is_integer(b) and b in 1..8,
    do: a |> List.duplicate(b) |> Enum.reduce(&{:*, [], [&2, &1]}) |> Macro.to_string()

  defp power_rewrite(a, b, ta, tb)
       when ta in [:i64, :f64] and tb in [:i64, :f64] and :f64 in [ta, tb],
       do: Macro.to_string({:pow, [], [a, b]})

  defp power_rewrite(_a, _b, _ta, _tb), do: nil

  defp form({:%{}, _, _}), do: map()

  defp form({:%, _, [{:__aliases__, _, parts} | _]}),
    do: map("structs (%#{Enum.join(parts, ".")}{})")

  defp form({:%, _, _}), do: map("structs")

  defp form({:<>, _, _}), do: string("string concatenation with <>")
  defp form({sigil, _, _}) when sigil in [:sigil_s, :sigil_S], do: string("the sigil ~s")

  defp form({:<<>>, _, _} = node) do
    case Defk.BinaryLiteral.bytes(node) do
      {:error, why, opts} -> {"binary-literal", Defk.BinaryLiteral.message(node, why), opts}
      _ -> {"binary-literal", "#{Macro.to_string(node)} is not a binary literal", []}
    end
  end

  defp form(nil), do: {"unsupported-atom", "nil is not in the kernel subset", []}

  defp form(a) when is_atom(a),
    do: {"unsupported-atom", "atoms such as #{inspect(a)} are not in the kernel subset", []}

  # 'abc' is the list [97, 98, 99]: a charlist is a likely intent
  defp form(list) when is_list(list) do
    if list != [] and Enum.all?(list, &(is_integer(&1) and &1 in 32..126)),
      do:
        {"binary-literal",
         "the list #{Macro.to_string(list)} is not in the kernel subset; if it is a charlist, a kernel takes a string literal",
         hint: ~s(use a string literal, "#{List.to_string(list)}"),
         rewrite: inspect(List.to_string(list))},
      else:
        {"unsupported-list",
         "lists such as #{Macro.to_string(list)} are not in the kernel subset", []}
  end

  defp form({op, _, _}) when op in [:++, :--],
    do: {"unsupported-list", "list operator #{op} is not in the kernel subset", []}

  defp form({:fn, _, _}),
    do: {"unsupported-fn", "anonymous functions are not in the kernel subset", []}

  defp form({:&, _, _} = n),
    do: {"unsupported-fn", "the capture #{Macro.to_string(n)} is not in the kernel subset", []}

  defp form({:|>, _, [_, _]} = node) do
    {"pipe", "the pipe operator |> is not in the kernel subset",
     rewrite: Macro.to_string(unpipe(node))}
  end

  # map.field
  defp form({{:., _, [{v, _, ctx}, field]}, m, []})
       when is_atom(v) and is_atom(ctx) and is_atom(field) do
    if m[:no_parens],
      do: map("field access #{v}.#{field} (maps and structs)"),
      else: call_rejection(nil, field, [], nil)
  end

  defp form({{:., _, [mod, fun]}, _, args} = node) when is_atom(fun) and is_list(args) do
    call_rejection(module_name(mod), fun, args, node)
  end

  defp form({range, _, _} = n) when range in [:.., :..//],
    do:
      {"unsupported-expression",
       "the range #{Macro.to_string(n)} as a value is not in the kernel subset",
       hint:
         "use the range as the generator of a for, Enum.reduce_while/3, Enum.all?/2 or Enum.any?/2"}

  defp form({:in, _, [x, list]} = n) when is_list(list) and list != [] do
    rewrite =
      list
      |> Enum.map(&{:==, [], [x, &1]})
      |> Enum.reduce(&{:or, [], [&2, &1]})
      |> Macro.to_string()

    {"unsupported-expression", "#{Macro.to_string(n)} is not in the kernel subset",
     hint: "compare with each value", rewrite: rewrite}
  end

  defp form({:=, _, _} = n) do
    {"unsupported-expression",
     "the match #{Macro.to_string(n)} used as a value is not in the kernel subset",
     hint: "bind it on its own line, then use the variable"}
  end

  defp form({:unless, _, [c, kw]}) when is_list(kw) do
    rewrite = Macro.to_string({:if, [], [{:not, [], [c]}, kw]})

    {"unsupported-construct", "unless is not in the kernel subset",
     hint: "write if not", rewrite: rewrite}
  end

  defp form({name, _, args}) when name in [:reraise, :throw, :exit] and is_list(args) do
    {"unsupported-construct", "#{name} is not in the kernel subset",
     why:
       "a kernel raises Elixir's own errors where Elixir would, and its own with raise Module, \"message\" (Module ArgumentError, ArithmeticError or RuntimeError)",
     hint: "use raise, or check the arguments in Elixir before the call"}
  end

  defp form({name, _, args})
       when name in [
              :with,
              :try,
              :receive,
              :send,
              :spawn,
              :quote,
              :unquote,
              :import,
              :alias,
              :require,
              :def,
              :defp,
              :defk,
              :__block__
            ] and is_list(args) do
    {"unsupported-construct", "#{name} is not in the kernel subset", []}
  end

  defp form({name, _, args} = node) when is_atom(name) and is_list(args) do
    case local_hint(name, args) do
      nil ->
        {"unsupported-expression", "#{Macro.to_string(node)} is not in the kernel subset", []}

      found ->
        found
    end
  end

  defp form(node),
    do: {"unsupported-expression", "#{Macro.to_string(node)} is not in the kernel subset", []}

  @doc false
  # A local call to `name` that isn't a builtin or a kernel: a construct
  # outside the subset, checked before its arguments are compiled.
  def unsupported_local({name, _, args} = node, type_of) do
    cond do
      name in [
        :%{},
        :%,
        :<<>>,
        :<>,
        :++,
        :--,
        :fn,
        :&,
        :|>,
        :@,
        :..,
        :..//,
        :in,
        :**,
        :=,
        :unless
      ] ->
        unsupported(node, type_of)

      name in [
        :reraise,
        :throw,
        :exit,
        :with,
        :try,
        :receive,
        :send,
        :spawn,
        :quote,
        :unquote,
        :import,
        :alias,
        :require,
        :def,
        :defp,
        :defk
      ] ->
        unsupported(node, type_of)

      String.starts_with?(Atom.to_string(name), "sigil_") ->
        cond do
          name in [:sigil_s, :sigil_S] ->
            string("the sigil ~s")

          name in [:sigil_c, :sigil_C] ->
            {"binary-literal", "a charlist sigil is not in the kernel subset",
             hint: ~s(use a string literal, "abc")}

          true ->
            {"unsupported-expression",
             "sigil ~#{String.trim_leading(Atom.to_string(name), "sigil_")} is not in the kernel subset",
             []}
        end

      true ->
        local_hint(name, args)
    end
  end

  # Elixir functions a developer reaches for that have a builtin form
  defp local_hint(name, [a]) when name in [:byte_size, :tuple_size] do
    {"undefined-function", "#{name}/1 is not a kernel builtin",
     why: "the length of a kernel array is length/1",
     hint: "use length/1",
     rewrite: Macro.to_string({:length, [], [a]})}
  end

  defp local_hint(:elem, [_t, i]) do
    {"undefined-function", "elem/2 is not a kernel builtin",
     why: "a kernel takes a tuple apart where it is bound",
     hint:
       "destructure the tuple where it is bound, e.g. {a, b} = ..., and use element #{Macro.to_string(i)} by name"}
  end

  defp local_hint(_name, _args), do: nil

  defp map(what \\ "maps"), do: {"unsupported-map", "#{what} are not in the kernel subset", []}

  defp string(what),
    do: {"unsupported-string", "#{what} is not in the kernel subset", []}

  defp unpipe({:|>, _, [l, r]}) do
    l = unpipe(l)

    case r do
      {{:., _, _} = f, m, args} -> {f, m, [l | args]}
      {f, m, args} when is_atom(f) and is_list(args) -> {f, m, [l | args]}
      {f, m, ctx} when is_atom(f) and is_atom(ctx) -> {f, m, [l]}
      other -> {{:., [], [other]}, [], [l]}
    end
  end

  defp unpipe(other), do: other

  defp module_name({:__aliases__, _, parts}), do: Enum.join(parts, ".")
  defp module_name(a) when is_atom(a), do: inspect(a)
  defp module_name(other), do: Macro.to_string(other)

  # ------------------------------------------------- calls not in subset --

  @list_why "a kernel has no lists, and"
  @loop "write the for loop it stands for"

  defp call_rejection(nil, fun, args, _node),
    do:
      {"unsupported-expression",
       "#{fun}/#{length(args)} called on a value is not in the kernel subset", []}

  defp call_rejection("Enum", :map, [src, {:fn, _, [{:->, _, [[x], body]}]}], _node) do
    {"unsupported-call", "Enum.map/2 is not in the kernel subset",
     why: "Enum.map/2 builds a list, and kernels have no lists",
     hint: "allocate the output array and fill it in a for loop",
     rewrite: fill_rewrites(src, x, body)}
  end

  defp call_rejection("Enum", fun, [src], _node) when fun in [:sum, :product] do
    zero = if fun == :sum, do: 0, else: 1

    {"unsupported-call", "Enum.#{fun}/1 is not in the kernel subset",
     why:
       "Enum.#{fun}/1 takes a list or a range; #{@list_why} the for ..., reduce: loop is the form a kernel compiles",
     hint: "write the for ..., reduce: loop (start from #{zero}.0 if the values are floats)",
     rewrite: fold_rewrites(src, if(fun == :sum, do: :+, else: :*), zero)}
  end

  defp call_rejection("Enum", fun, [[_, _ | _] = list], _node) when fun in [:min, :max] do
    rewrite = list |> Enum.reduce(&{fun, [], [&2, &1]}) |> Macro.to_string()

    {"unsupported-call", "Enum.#{fun}/1 over a list is not in the kernel subset",
     why: "#{String.trim_trailing(@list_why, ", and")}; #{fun}/2 is a builtin",
     hint: "nest #{fun}/2",
     rewrite: rewrite}
  end

  defp call_rejection("Enum", fun, [src], _node) when fun in [:min, :max] do
    rewrite =
      if var?(src) do
        [i, acc] = fresh_names(~w(i acc), [src])

        "for #{i} <- 1..(length(#{s(src)}) - 1)//1, reduce: #{s(src)}[0] do\n  #{acc} -> #{fun}(#{acc}, #{s(index(src, i))})\nend"
      end

    {"unsupported-call", "Enum.#{fun}/1 is not in the kernel subset",
     why:
       "Enum.#{fun}/1 takes a list or a range; #{@list_why} the for ..., reduce: loop is the form a kernel compiles",
     hint:
       "#{@loop}, starting from the first element (Enum.#{fun}/1 raises on an empty list; decide what an empty array gives)",
     rewrite: rewrite}
  end

  defp call_rejection("Enum", fun, args, _node) when fun in [:min_by, :max_by, :min_max] do
    {"unsupported-call", "Enum.#{fun}/#{length(args)} is not in the kernel subset",
     why:
       "Enum.#{fun}/#{length(args)} takes a list or a range; #{@list_why} the for ..., reduce: loop is the form a kernel compiles",
     hint: "#{@loop}, with a tuple accumulator",
     rewrite: extreme_rewrite(fun, args)}
  end

  defp call_rejection("Enum", :with_index, [src | _] = args, _node) do
    a = if var?(src), do: s(src), else: "a"

    {"unsupported-call", "Enum.with_index/#{length(args)} is not in the kernel subset",
     why: "Enum.with_index builds a list of tuples, and a kernel has no lists",
     hint: "walk the index with i <- 0..(length(#{a}) - 1)//1 and read #{a}[i]"}
  end

  defp call_rejection("Enum", :reduce, [src, init, {:fn, _, [{:->, _, [[x, acc], body]}]}], _node) do
    rewrite = "for #{s(x)} <- #{s(src)}, reduce: #{s(init)} do\n  #{s(acc)} -> #{s(body)}\nend"
    {"enum-reduce", "Enum.reduce/3 is not supported yet", rewrite: rewrite}
  end

  defp call_rejection("Enum", :reduce, args, _node),
    do: {"enum-reduce", "Enum.reduce/#{length(args)} is not supported yet", []}

  defp call_rejection("Enum", fun, args, _node) when fun in [:find, :find_index, :find_value] do
    {"enum-find", "Enum.#{fun}/#{length(args)} is not supported yet",
     rewrite: find_index_rewrite(fun, args)}
  end

  defp call_rejection("Enum", :count, [src, {:fn, _, [{:->, _, [[x], pred]}]}], _node) do
    rewrite = "for #{s(x)} <- #{s(src)}, #{s(pred)}, reduce: 0 do\n  acc -> acc + 1\nend"

    {"unsupported-call", "Enum.count/2 is not in the kernel subset",
     why:
       "Enum.count/2 takes a list or a range; #{@list_why} the for ..., reduce: loop with a filter is the form a kernel compiles",
     hint: "count with a filtered for ..., reduce: loop",
     rewrite: rewrite}
  end

  defp call_rejection("Enum", :each, [src, {:fn, _, [{:->, _, [[x], body]}]}], _node) do
    rewrite = "for #{s(x)} <- #{s(src)} do\n  #{s(body)}\nend"

    {"unsupported-call", "Enum.each/2 is not in the kernel subset",
     why: "a for loop is the form a kernel compiles", hint: "write the for loop", rewrite: rewrite}
  end

  defp call_rejection("Enum", fun, args, _node) do
    {"unsupported-call", "Enum.#{fun}/#{length(args)} is not in the kernel subset",
     why:
       "Enum functions take and build lists, and a kernel has none; Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2 are the ones that compile, to loops",
     hint: "write it as a for loop over the array or range"}
  end

  defp call_rejection(":math", fun, args, _node) do
    {"unsupported-call", ":math.#{fun}/#{length(args)} is not in the kernel subset",
     why: "a kernel's math builtins are #{@math} (also as :math.sqrt/1 and so on)",
     hint: "compute it from those, or in Elixir"}
  end

  defp call_rejection(mod, fun, args, _node) do
    {"unsupported-call", "#{mod}.#{fun}/#{length(args)} is not in the kernel subset", []}
  end

  # ------------------------------------------------------------- rewrites --

  # Enum.sum/product over a comprehension, an array or a range as a
  # for ..., reduce: loop, from an integer zero or a float one
  defp fold_rewrites(src, op, zero) do
    {quals, body} =
      case src do
        {:for, _, args} ->
          {kw, quals} = Enum.split_with(args, &(is_list(&1) and Keyword.keyword?(&1)))
          kw = Enum.concat(kw)
          if Keyword.keys(kw) == [:do], do: {quals, kw[:do]}, else: {nil, nil}

        src ->
          [x] = fresh_names(~w(x), [src])
          {[{:<-, [], [var(x), src]}], var(x)}
      end

    if quals do
      [acc] = fresh_names(~w(acc), [quals, body])
      head = "for #{Enum.map_join(quals, ", ", &s/1)}, reduce: "
      step = s({op, [], [var(acc), body]})
      for z <- [zero, zero * 1.0], do: "#{head}#{z} do\n  #{acc} -> #{step}\nend"
    end
  end

  # Enum.min_max/1, min_by/2 and max_by/2 over an array variable, from its
  # first element; the comparison is strict, so the first extreme element
  # wins, as in Elixir
  defp extreme_rewrite(:min_max, [src]) do
    if var?(src) do
      [i, lo, hi] = fresh_names(~w(i lo hi), [src])
      ai = s(index(src, i))

      "for #{i} <- 1..(length(#{s(src)}) - 1)//1, reduce: {#{s(src)}[0], #{s(src)}[0]} do\n  {#{lo}, #{hi}} -> {min(#{lo}, #{ai}), max(#{hi}, #{ai})}\nend"
    end
  end

  defp extreme_rewrite(fun, [src, {:fn, _, [{:->, _, [[x], key]}]}])
       when fun in [:min_by, :max_by] do
    if var?(src) do
      [i, best, k, ki, better] = fresh_names(~w(i best k ki better), [src, key])
      key_at = &s(subst(key, x, index(src, &1)))
      cmp = if fun == :min_by, do: "<", else: ">"

      # (each element gets its own if: an if gives a number, not a tuple)
      """
      {#{best}, _} =
        for #{i} <- 1..(length(#{s(src)}) - 1)//1, reduce: {#{s(src)}[0], #{key_at.(0)}} do
          {#{best}, #{k}} ->
            #{ki} = #{key_at.(i)}
            #{better} = #{ki} #{cmp} #{k}
            {if(#{better}, do: #{s(index(src, i))}, else: #{best}), if(#{better}, do: #{ki}, else: #{k})}
        end

      #{best}\
      """
    end
  end

  defp extreme_rewrite(_fun, _args), do: nil

  # Enum.find_index/2 over an array variable as Enum.reduce_while/3, with -1
  # for not found
  defp find_index_rewrite(:find_index, [src, {:fn, _, [{:->, _, [[x], pred]}]}]) do
    if var?(src) do
      [i] = fresh_names(~w(i), [src, pred])

      "Enum.reduce_while(0..(length(#{s(src)}) - 1)//1, -1, fn #{i}, _ ->\n  if #{s(subst(pred, x, index(src, i)))}, do: {:halt, #{i}}, else: {:cont, -1}\nend)"
    end
  end

  defp find_index_rewrite(_fun, _args), do: nil

  @doc false
  # Filling a new array with `body` for each element `x` of the array variable
  # `src` or of a range `lo..hi` (step 1): the loop Enum.map/2 or a collecting
  # for stands for. One candidate per element type (`type_of` gives the body's
  # type when the compiler knows it, else `elems` are tried), or nil when `src`
  # is neither, or `body` is more than one expression.
  def fill_rewrites(src, x, body, elems \\ [:i64, :f64], type_of \\ fn _ -> nil end) do
    cond do
      not var?(x) or match?({:__block__, _, _}, body) -> nil
      var?(src) -> array_fill(src, x, body, elems, type_of)
      true -> range_fill(range_parts(src), x, body, elems, type_of)
    end
  end

  defp array_fill(src, x, body, elems, type_of) do
    [i, out] = fresh_names(~w(i out), [src, body])
    v = s(subst(body, x, index(src, i)))
    n = "length(#{s(src)})"

    for e <- element_types(subst(body, x, index(src, 0)), elems, type_of),
        do:
          "#{out} = alloc(#{e}, #{n})\n\nfor #{i} <- 0..(#{n} - 1)//1 do\n  #{out}[#{i}] = #{v}\nend\n\n#{out}"
  end

  # the loop over the range with the author's variable and body, writing at
  # the position of the variable in the range
  defp range_fill({lo, hi}, x, body, elems, type_of) do
    [out] = fresh_names(~w(out), [lo, hi, body, x])
    {n, at} = range_length(lo, hi, x)

    for e <- element_types(subst(body, x, 0), elems, type_of),
        do:
          "#{out} = alloc(#{e}, #{n})\n\nfor #{s(x)} <- #{range_text(lo, hi)} do\n  #{out}[#{at}] = #{s(body)}\nend\n\n#{out}"
  end

  defp range_fill(nil, _x, _body, _elems, _type_of), do: nil

  # lo..hi//1; hi is parenthesised unless it is a variable or a number
  defp range_text(lo, hi) do
    hi = if var?(hi) or is_integer(hi), do: s(hi), else: "(#{s(hi)})"
    "#{s(lo)}..#{hi}//1"
  end

  # {lo, hi} of `lo..hi` and `lo..hi//1` when lo is a number or a variable
  defp range_parts({:.., _, [lo, hi]}), do: range_parts(lo, hi)
  defp range_parts({:..//, _, [lo, hi, 1]}), do: range_parts(lo, hi)
  defp range_parts(_), do: nil

  defp range_parts(lo, hi), do: if(is_integer(lo) or var?(lo), do: {lo, hi})

  # {length, index of x} of the range
  defp range_length(0, {:-, _, [n, 1]}, x), do: {s(n), s(x)}
  defp range_length(0, hi, x), do: {s({:+, [], [hi, 1]}), s(x)}
  defp range_length(1, hi, x), do: {s(hi), s({:-, [], [x, 1]})}
  defp range_length(lo, hi, x), do: {s({:+, [], [{:-, [], [hi, lo]}, 1]}), s({:-, [], [x, lo]})}

  # the body's own type when the compiler knows it (`probe` is the body at the
  # first element), else the candidates
  defp element_types(probe, elems, type_of) do
    case type_of.(probe) do
      t when is_atom(t) and t != nil -> [t]
      _ -> elems
    end
  end

  @doc false
  # The rewrites of a collecting `for x <- src, into: into, do: body` (into is
  # nil without into:). `into: <<>>` with one native-endian segment per
  # element is an array of that element type; other into: have none.
  def collect_rewrites(src, x, body, into, type_of \\ fn _ -> nil end)

  def collect_rewrites(src, x, body, nil, type_of),
    do: fill_rewrites(src, x, body, [:i64, :f64], type_of)

  def collect_rewrites(src, x, {:<<>>, _, [seg]}, {:<<>>, _, []}, _type_of) do
    case segment(seg) do
      {v, e} -> fill_rewrites(src, x, v, [e])
      nil -> nil
    end
  end

  def collect_rewrites(_src, _x, _body, _into, _type_of), do: nil

  # {value, element type} of a binary segment with an array's layout
  defp segment({:"::", _, [v, spec]}) do
    parts = spec_parts(spec)

    size =
      Enum.find_value(parts, fn
        n when is_integer(n) -> n
        {:size, n} -> n
        _ -> nil
      end)

    names = for p <- parts, is_atom(p), do: p

    cond do
      :float in names ->
        if size in [nil, 64] and names -- [:float, :native] == [] and :native in names,
          do: {v, :f64}

      size == 64 ->
        if names -- [:integer, :signed, :unsigned, :native] == [] and :native in names,
          do: {v, :i64}

      size in [nil, 8] ->
        if names -- [:integer, :unsigned, :big, :little, :native] == [], do: {v, :u8}

      true ->
        nil
    end
  end

  defp segment(v), do: {v, :u8}

  defp spec_parts({:-, _, [a, b]}), do: spec_parts(a) ++ spec_parts(b)
  defp spec_parts({:size, _, [n]}) when is_integer(n), do: [{:size, n}]
  defp spec_parts({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: [name]
  defp spec_parts(n) when is_integer(n), do: [n]
  defp spec_parts(_), do: [:unknown]

  defp s(ast), do: Macro.to_string(ast)
  defp var(name), do: {String.to_atom(name), [], nil}

  defp var?({v, _, ctx}) when is_atom(v) and is_atom(ctx), do: true
  defp var?(_), do: false

  # a[i] for the array variable `a` and an index name or literal
  defp index(a, i) do
    m = [from_brackets: true]
    {{:., m, [Access, :get]}, m, [a, if(is_integer(i), do: i, else: var(i))]}
  end

  # `bases`, each renamed (i2, i3, ...) if a variable in `asts` has its name
  defp fresh_names(bases, asts) do
    {_, used} =
      Macro.prewalk(asts, MapSet.new(), fn
        {n, _, ctx} = v, acc when is_atom(n) and is_atom(ctx) ->
          {v, MapSet.put(acc, Atom.to_string(n))}

        other, acc ->
          {other, acc}
      end)

    Enum.map(bases, fn b -> Enum.find([b | Enum.map(2..9, &"#{b}#{&1}")], &(&1 not in used)) end)
  end

  defp subst(ast, {x, _, ctx}, with) when is_atom(x) and is_atom(ctx) do
    Macro.prewalk(ast, fn
      {^x, _, c} when is_atom(c) -> with
      other -> other
    end)
  end
end
