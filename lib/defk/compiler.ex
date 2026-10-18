defmodule Defk.Compiler do
  @moduledoc false
  # Typecheck defk kernels and lower them to one C translation unit.
  #
  # Every kernel body is lowered to C text over plain locals and emitted as a
  # resumable state machine called from Elixir. Locals live in registers; at a
  # safepoint that decides to yield the ones live there are spilled into a
  # frame struct and restored on resume (safepoint_saves/2). A call to another kernel is inlined (see "calls"), so
  # the callee's loops are the caller's loops and yield like them.
  #
  # Types:  :i64 | :u64 | :f64 | :bool | {:arr, elem} | {:tuple, [type]}
  #         | :bitstring (the bitstring accumulator, see "bitstrings")
  # elem:   :f64 | :i64 | :u64 | :u8 | :i16 | :i32 | :f32; the narrow ones
  #         (u8, i16, i32, f32) exist only in arrays: a read widens to i64 or
  #         f64, a write must fit (see "element types"); u64 is a scalar too

  @scalars [:i64, :u64, :f64, :bool]
  @elems [:f64, :i64, :u64, :u8, :i16, :i32, :f32]
  @elems_text "f64, f32, i64, i32, i16, u8 and u64"
  @ints [:i64, :u64]
  alias Defk.Compiler.Ctx
  alias Defk.Copies
  alias Defk.Facts

  # the one process-dictionary key: see Defk.Compiler.Ctx
  @ctx :defk_ctx

  defp ctx, do: Process.get(@ctx)
  defp ctx(key), do: Map.fetch!(ctx(), key)
  defp ctx_put(key, value), do: Process.put(@ctx, Map.put(ctx(), key, value))
  defp ctx_update(key, fun), do: Process.put(@ctx, Map.update!(ctx(), key, fun))

  defp low(key), do: Map.fetch!(ctx(:lowering), key)
  defp low_put(key, value), do: ctx_update(:lowering, &Map.put(&1, key, value))
  defp low_update(key, fun), do: ctx_update(:lowering, &Map.update!(&1, key, fun))

  # the copy analysis's tracking state (Defk.Copies is pure)
  defp copies, do: low(:copies)
  defp copies_put(st), do: low_put(:copies, st)

  # buffer `new` holds what `old` held; recorded in the tracking state
  defp carried(new, old) do
    {b, st} = Copies.carried(copies(), new, old)
    copies_put(st)
    b
  end

  # Map.pop on lowering.halted: whether loop `id` emitted a halt label
  defp low_halted_pop(id) do
    {was, halted} = Map.pop(low(:halted), id)
    low_put(:halted, halted)
    was
  end

  # the whole-ctx snapshot: probing and backtracking restore one value
  defp ctx_swap(new) do
    old = ctx()
    Process.put(@ctx, new)
    old
  end

  # A rejection's literal code is checked against the registry while the
  # compiler itself compiles: a typo'd code fails mix compile
  # here instead of a test later. A code built at run time passes through.
  defmacrop err!(node, code, what, opts \\ []) do
    Defk.Errors.validate_code!(code)
    quote do: reject!(unquote(node), unquote(code), unquote(what), unquote(opts))
  end

  defmacrop attempt_err!(key, head, code, what, opts \\ []) do
    Defk.Errors.validate_code!(code)

    quote do
      attempt_reject!(unquote(key), unquote(head), unquote(code), unquote(what), unquote(opts))
    end
  end

  @max_u64 0xFFFFFFFFFFFFFFFF
  @max_i64 0x7FFFFFFFFFFFFFFF
  @float_ops %{+: "fadd", -: "fsub", *: "fmul"}
  @math1 Defk.Builtins.math1()
  # band/2 ... and the operators that are the same functions (&&& ...)
  @bitwise Defk.Builtins.bitwise()
  @bitwise_names Defk.Builtins.bitwise() ++ Defk.Builtins.bitwise_ops()
  # u64_le/2 ... word loads from a [u8]
  @loads Defk.Builtins.loads()
  # clz, rotl, ... with a plain Elixir meaning in Defk.Bits
  @bits Defk.Builtins.bits()
  # range facts carried by values (see "range facts" below)

  # forms that never yield: safepoints vanish and resume dispatch is dead code
  @no_yield_macros "#define DEFK_SP(N, W)\n#define DEFK_SHORT(R) ((void)(R), 1)\n#define DEFK_TICKS(W)\n#define DEFK_RESUMING 0\nint defk_rs = 0;\n"
  @undef_macros "#undef DEFK_SP\n#undef DEFK_SHORT\n#undef DEFK_TICKS\n#undef DEFK_RESUMING\n"

  # ---------------------------------------------------------------- entry ---

  # Every rejection in the module is collected (see "rejections") and raised
  # together as one CompileError after all kernels are compiled.
  # opts: nif_name - the name each kernel's NIF is registered under;
  #       fault_hooks - register the test-only `__defk_corrupt_tags__/1` and
  #         `__defk_inject_fault__/1`, and compile the fault injection in (default false);
  #       adaptive_slice - a yielding kernel's NIF is `__defk_native_<name>__`
  #         with the run-queue hint as an extra last argument (default false);
  #       max_owned_bytes - the byte budget of a call's owned buffers (DEFK_MAX_OWNED
  #         in priv/defk_runtime.h; default nil: half of physical memory)
  def compile(module, raw_kernels, file, opts \\ []) do
    Process.put(@ctx, Ctx.new(file, module, source_lines(file)))

    kernels =
      raw_kernels
      |> Enum.with_index()
      |> Enum.flat_map(fn {raw, _} = r ->
        case attempt(head_name(raw.head), raw.head, fn -> parse_kernel(r) end) do
          {:ok, k} -> [k]
          :error -> broken(head_name(raw.head))
        end
      end)

    {kernels, _} =
      Enum.flat_map_reduce(kernels, MapSet.new(), fn k, seen ->
        key = {k.name, k.arity}

        cond do
          Defk.Builtins.builtin?(k.name, k.arity) ->
            builtin_name!(key, k)
            broken(key)
            {[], seen}

          key in seen ->
            attempt_err!(
              key,
              k.head,
              "duplicate-kernel",
              "#{k.name}/#{k.arity} is defined more than once"
            )

            {[], seen}

          true ->
            {[k], MapSet.put(seen, key)}
        end
      end)

    sigs = Map.new(kernels, &{{&1.name, &1.arity}, &1})

    # per kernel, the names it appends to or passes to a helper's bitstring
    # parameter: `<<>>` bound to one is a bitstring
    bits_params = Defk.Bitstring.bits_params(kernels)

    ctx_put(
      :bits_names,
      Map.new(
        kernels,
        &{{&1.name, &1.arity}, Defk.Bitstring.accumulator_names(&1.body, bits_params)}
      )
    )

    # a kernel taking a bitstring is a helper: only inlined, never an entry
    {helpers, entries} = Enum.split_with(kernels, &Defk.Bitstring.helper?/1)
    unreached_helpers!(helpers, entries, sigs)

    lowered =
      Enum.flat_map(entries, fn k ->
        case attempt({k.name, k.arity}, k.head, fn -> lower_kernel(k, sigs) end) do
          {:ok, l} -> [l]
          :error -> []
        end
      end)

    case ctx(:diags) do
      [] -> :ok
      diags -> raise Defk.Errors.Diagnostics.compile_error(module, file, diags)
    end

    entries_c = Enum.map(lowered, &IO.iodata_to_binary(emit_entry(&1)))

    # each entry inlines its callees once per call site: warn when that makes
    # its C large, before the C compiler spends minutes on it
    Defk.InlineSize.check(Enum.zip(lowered, entries_c), kernels, file)

    body =
      [
        entries_c,
        emit_init(
          module,
          lowered,
          Keyword.get(opts, :nif_name, & &1),
          Keyword.get(opts, :fault_hooks, false),
          Keyword.get(opts, :adaptive_slice, false)
        )
      ]
      |> IO.iodata_to_binary()

    c =
      [
        "/* Generated by defk for #{inspect(module)} - do not edit */\n",
        "#define DEFK_HEADER_HASH #{Defk.Build.header_hash()}ULL\n",
        max_owned_define(Keyword.get(opts, :max_owned_bytes)),
        if(Keyword.get(opts, :fault_hooks, false), do: "#define DEFK_FAULT_HOOKS 1\n", else: ""),
        "#include \"defk_runtime.h\"\n\n",
        emit_statics(body),
        body
      ]
      |> IO.iodata_to_binary()

    # every kernel's signature, helpers included (Elixir mode defines them
    # too); `yields`: its NIF yields (so it takes the run-queue hint)
    yielding = for k <- lowered, yields?(k), into: MapSet.new(), do: {k.name, k.arity}

    sigs =
      Enum.map(
        kernels,
        &(&1
          |> Map.take([:name, :arity, :params, :ret])
          |> Map.put(:yields, MapSet.member?(yielding, {&1.name, &1.arity})))
      )

    {c, sigs, report()}
  end

  defp max_owned_define(nil), do: ""
  defp max_owned_define(n) when is_integer(n), do: "#define DEFK_MAX_OWNED #{n}ULL\n"

  # A helper (a kernel with a bitstring parameter) has no NIF: it
  # is compiled only where a kernel inlines it, since only a kernel has a
  # bitstring to pass. One that no entry kernel reaches would be an entry
  # kernel taking a bitstring from Elixir, so it is rejected.
  defp unreached_helpers!(helpers, entries, sigs) do
    reached = reach(Enum.map(entries, &{&1.name, &1.arity}), sigs, %{})

    for k <- helpers, not Map.has_key?(reached, {k.name, k.arity}) do
      {p, _} = Enum.find(k.params, &match?({_, :bitstring}, &1))
      param = Enum.find(params_ast(k.head), &match?({:"::", _, [{^p, _, _}, _]}, &1))

      attempt_err!(
        {k.name, k.arity},
        k.head,
        "bitstring-use",
        "#{k.name}/#{k.arity} takes the bitstring #{p}, so only a kernel can call it, and no kernel called from Elixir does: Elixir cannot pass a bitstring accumulator to an entry kernel",
        at: param,
        hint:
          "call #{k.name}/#{k.arity} from the kernel that builds the accumulator, which inlines it; a kernel called from Elixir takes bytes as a [u8] parameter"
      )
    end
  end

  # `keys` and the kernels they call, directly or through other kernels, as
  # the keys of `seen` (a map, not a MapSet: dialyzer treats a MapSet built
  # up in a recursion as opaque)
  defp reach([], _sigs, seen), do: seen

  defp reach([key | rest], sigs, seen) do
    if Map.has_key?(seen, key) do
      reach(rest, sigs, seen)
    else
      reach(callees(sigs[key].body, sigs) ++ rest, sigs, Map.put(seen, key, true))
    end
  end

  defp callees(body, sigs) do
    {_, keys} =
      Macro.prewalk(body, [], fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          key = {name, length(args)}
          {node, if(Map.has_key?(sigs, key), do: [key | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    keys
  end

  defp params_ast({:"::", _, [{_, _, params}, _]}) when is_list(params), do: params
  defp params_ast(_head), do: []

  # ---------------------------------------------------------- rejections ---
  # err!/4 throws a rejection with a code from Defk.Errors. A rejected
  # statement is recorded and compilation goes on with the next one, so one
  # compile reports every rejection in the module. To keep out errors caused by
  # an earlier one, the variables a rejected statement binds are poisoned (a
  # use of one abandons its statement silently), a call to a kernel whose head
  # was rejected is silent too, and a rejection already recorded at the same
  # place (an inlined kernel repeats its callee's) is dropped.

  # no_return(): err! always throws, which is how a rejection is recorded.
  @spec reject!(term(), term(), term(), keyword()) :: no_return()
  defp reject!(node, code, what, opts) do
    {line, col, width, text} =
      Defk.Errors.Diagnostics.locate(node, ctx(:where), ctx(:lines))

    d =
      Map.merge(Map.new(opts), %{
        code: code,
        what: what,
        file: ctx(:file),
        module: ctx(:module),
        fun: ctx(:fun),
        line: line,
        col: col,
        width: width,
        text: text
      })

    throw({:defk_reject, Map.put_new(d, :key, {code, line, col})})
  end

  defp record(d) do
    diags = ctx(:diags)
    unless Enum.any?(diags, &(&1.key == d.key)), do: ctx_put(:diags, [d | diags])
  end

  # Run `fun` as kernel `key` ({name, arity}, or nil for a head that has
  # none), with `head` as the statement literals are located in: {:ok,
  # result}, or :error once a rejection is recorded. Only defk's own
  # rejections are caught; any other exception is a compiler bug and
  # propagates with its stacktrace, whatever was rejected before it.
  defp attempt(key, head, fun) do
    ctx_put(:fun, key)
    ctx_put(:where, head)
    {:ok, fun.()}
  catch
    {:defk_reject, d} ->
      record(d)
      :error

    :defk_poison ->
      :error
  end

  # `attempt/3` for a rejection that is the whole action: records it and
  # returns nil. The throwing call is written inline rather than in a fun,
  # which Dialyzer would flag as a no-return anonymous function.
  # opts: `at:` the node to report at (default: the head), and err!/4's
  defp attempt_reject!(key, head, code, what, opts) do
    ctx_put(:fun, key)
    ctx_put(:where, head)
    {at, opts} = Keyword.pop(opts, :at)

    try do
      err!(at || head, code, what, opts)
    catch
      {:defk_reject, d} -> record(d)
    end
  end

  # A construct outside the kernel subset (Defk.Errors.unsupported/2), shown
  # with the first of its rewrites that compiles here, if any.
  @spec unsupported!(term(), term(), term()) :: no_return()
  defp unsupported!(node, {code, what, opts}, env),
    do: err!(node, code, what, checked_rewrite(opts, env))

  defp checked_rewrite(opts, env) do
    {candidates, opts} = Keyword.pop(opts, :rewrite)

    case Enum.find(List.wrap(candidates), &compiles?(&1, env)) do
      nil -> opts
      rewrite -> Keyword.put(opts, :rewrite, rewrite)
    end
  end

  # Whether the statements in `src` compile in `env`; nothing is recorded.
  defp compiles?(src, env) do
    case Code.string_to_quoted(src) do
      # the statements are lowered in the block of the statement env is at
      {:ok, ast} ->
        probe(fn -> stmt_list(exprs(ast), Copies.live_after(exprs(ast)), env) end) != :error

      _ ->
        false
    end
  end

  # The type of expression `ast` in `env`, or nil if it doesn't compile.
  defp type_in(ast, env) do
    case probe(fn -> lower_expr(ast, env) end) do
      {:ok, {_, v}} -> v[:t]
      :error -> nil
    end
  end

  # {:ok, result} of `fun`, or :error if it rejected anything; its rejections
  # are not recorded.
  defp probe(fun) do
    snap = ctx_swap(%{ctx() | diags: []})

    try do
      result = fun.()
      if ctx(:diags) == [], do: {:ok, result}, else: :error
    catch
      {:defk_reject, _} -> :error
      :defk_poison -> :error
    after
      ctx_swap(snap)
    end
  end

  # Lower statement `e` with `fun`; a rejection is recorded, and the variables
  # `e` binds are poisoned.
  defp recover(e, env, fun) do
    in_ctx(e, fun)
  catch
    {:defk_reject, d} ->
      record(d)
      {[], poison(e, env)}

    :defk_poison ->
      {[], poison(e, env)}
  end

  defp poison({:=, _, [lhs, _]}, env) do
    {_, names} =
      Macro.prewalk(lhs, [], fn
        {n, _, ctx} = v, acc when is_atom(n) and is_atom(ctx) -> {v, [n | acc]}
        other, acc -> {other, acc}
      end)

    %{env | vars: Enum.reduce(names, env.vars, &Map.put(&2, &1, %{t: :poison}))}
  end

  defp poison(_e, env), do: env

  defp positioned?({_, m, _}) when is_list(m), do: Keyword.has_key?(m, :line)
  defp positioned?(_), do: false

  defp broken(nil), do: []

  defp broken(key) do
    ctx_update(:broken, &MapSet.put(&1, key))
    []
  end

  # a kernel named like a builtin at the builtin's arity: calls to it would
  # reach the builtin (see Defk.Builtins), so the definition is rejected
  defp builtin_name!(key, k) do
    renamed = :"my_#{k.name}"
    name = "#{k.name}/#{k.arity}"

    attempt_err!(
      key,
      k.head,
      "builtin-name",
      "#{name} is a builtin, so a kernel of that name and arity is rejected",
      why:
        "`#{name}` is a builtin, so calls to it would reach the builtin, not this kernel; a new builtin would silently change what a module computes",
      hint: "rename the kernel and its calls, for example to #{renamed}/#{k.arity}",
      rewrite: "defk " <> Macro.to_string(rename_head(k.head, renamed))
    )
  end

  defp rename_head({op, m, [call | rest]}, to) when op in [:"::", :when],
    do: {op, m, [rename_head(call, to) | rest]}

  defp rename_head({_name, m, args}, to), do: {to, m, args}

  defp head_name(head) do
    call =
      case head do
        {:"::", _, [call, _]} -> call
        {:when, _, [call, _]} -> call
        call -> call
      end

    case call do
      {name, _, args} when is_atom(name) and is_list(args) -> {name, length(args)}
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> {name, 0}
      _ -> nil
    end
  end

  defp source_lines(file) do
    case File.read(file || "") do
      {:ok, src} -> src |> String.split(["\r\n", "\n"]) |> List.to_tuple()
      _ -> nil
    end
  end

  # ------------------------------------------------------------ parsing ----

  # a definition Defk.Clauses rejected (a clause with no head, say)
  defp parse_kernel({%{reject: {at, code, what, opts}}, _idx}), do: err!(at, code, what, opts)

  defp parse_kernel({%{head: head, opts: opts, body: body}, idx}) do
    {call, ret_ast} =
      case head do
        {:"::", _, [call, ret]} ->
          {call, ret}

        _ ->
          err!(head, "kernel-head", "the kernel head #{Macro.to_string(head)} has no return type",
            rewrite: "#{Macro.to_string(head)} :: i64"
          )
      end

    {name, params} =
      case call do
        {name, _, args} when is_atom(name) and is_list(args) ->
          {name, args}

        {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
          {name, []}

        _ ->
          err!(
            call,
            "kernel-head",
            "#{Macro.to_string(call)} is not a kernel name and parameter list"
          )
      end

    params = Enum.map(params, &parse_param/1)

    for k <- Keyword.keys(opts), k != :yield do
      err!(head, "unknown-option", "#{k}: is not a defk option")
    end

    body || err!(head, "no-body", "kernel #{name}/#{length(params)} has no body")

    %{
      name: name,
      arity: length(params),
      params: params,
      ret: parse_type(ret_ast, head),
      head: head,
      body: body,
      yield: Keyword.get(opts, :yield, true),
      cid: "k#{idx}_#{sanitize(name)}"
    }
  end

  defp parse_param({:"::", _, [{p, _, ctx}, t]} = param) when is_atom(p) and is_atom(ctx) do
    ty = parse_type(t, param)

    if match?({:tuple, _}, ty) do
      {:tuple, ts} = ty

      split =
        ts
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {t, i} -> "#{p}#{i} :: #{fmt(t)}" end)

      err!(
        param,
        "tuple-parameter",
        "tuple parameters such as #{p} :: #{fmt(ty)} are not in the kernel subset",
        rewrite: split
      )
    end

    {p, ty}
  end

  defp parse_param({p, _, ctx} = other) when is_atom(p) and is_atom(ctx) do
    err!(other, "untyped-parameter", "parameter #{p} has no type", rewrite: "#{p} :: i64")
  end

  defp parse_param(other) do
    err!(
      other,
      "untyped-parameter",
      "#{Macro.to_string(other)} is not a parameter `name :: type`"
    )
  end

  # `at` is the node an unknown type is reported at when the type has no position
  defp parse_type({t, _, ctx}, _) when t in @scalars and is_atom(ctx), do: t
  defp parse_type({:bitstring, _, ctx}, _) when is_atom(ctx), do: :bitstring
  defp parse_type([{t, _, ctx}], _) when t in @elems and is_atom(ctx), do: {:arr, t}
  defp parse_type({a, b}, at), do: {:tuple, [parse_type(a, at), parse_type(b, at)]}
  defp parse_type({:{}, _, ts}, at), do: {:tuple, Enum.map(ts, &parse_type(&1, at))}

  defp parse_type(t, at) do
    node = if positioned?(t), do: t, else: at

    instead = %{
      integer: "i64",
      float: "f64",
      boolean: "bool",
      number: "f64",
      binary: "[u8]",
      bits: "bitstring",
      pos_integer: "i64",
      non_neg_integer: "i64"
    }

    hint =
      case t do
        {n, _, ctx} when is_atom(n) and (is_atom(ctx) or ctx == []) and is_map_key(instead, n) ->
          [hint: "the kernel type for #{n} is #{instead[n]}"]

        {:list, _, ctx} when is_atom(ctx) or is_list(ctx) ->
          [
            hint:
              "a list is passed as a packed array, [f64] for floats or [i64] for integers, built in Elixir with for x <- xs, into: <<>>, do: <<x::float-64-native>>"
          ]

        {{:., _, [{:__aliases__, _, [:String]}, :t]}, _, []} ->
          [hint: "text is a [u8]: a binary in Elixir, in and out of a kernel"]

        [{n, _, ctx}] when is_atom(n) and is_atom(ctx) ->
          [hint: "array element types are #{@elems_text}"]

        _ ->
          []
      end

    err!(node, "unknown-type", "#{Macro.to_string(t)} is not a kernel type", hint)
  end

  # ------------------------------------------------------------ kernels ----

  defp lower_kernel(k, sigs) do
    ctx_put(:lowering, %Ctx.Lowering{report_kernel: {{k.name, k.arity}, k.yield}})
    note(:kernel, k.head, if(k.yield, do: :yield, else: :no_yield), "#{k.name}/#{k.arity}")

    vars =
      Map.new(k.params, fn {p, t} ->
        c = "p_#{sanitize(p)}"
        {p, Map.merge(%{c: c, t: t, owned: false, var: c}, array_ids(t))}
      end)

    env =
      Map.merge(
        %{
          vars: vars,
          sigs: sigs,
          inlining: [{k.name, k.arity}],
          ret: k.ret,
          ret_fors: returned_fors(k.body)
        },
        scope(MapSet.new())
      )

    {stmts, val} = lower_block(k.body, env)
    {ret_stmts, ret_vals} = coerce_return(val, k)
    # only a kernel that yields anyway (its body has a safepoint) copies a
    # misaligned input in strips: the prologue's safepoint would otherwise
    # make a loop-free kernel pay the yielding machinery on every call
    prologue = if k.yield and low(:sp) > 0, do: bind_strips(k), else: []

    # a returned array the kernel may not own (an input, a binary literal or
    # attribute, or a branch giving one of them) is resolved when it returns
    # (emit_result/1)
    views =
      Enum.zip_with(Map.get(val, :elems, [val]), ret_vals, fn v, {_, t} ->
        match?({:arr, _}, t) and v.owned == false
      end)

    Map.merge(k, %{
      stmts: [prologue, stmts, ret_stmts],
      ret_vals: ret_vals,
      ret_views: views,
      decls: Enum.reverse(low(:decls)),
      decl_loop: low(:decl_loop),
      sp_count: low(:sp),
      sps: low(:sps)
    })
  end

  # The collecting fors that are the kernel's value: its last expression, or
  # the one a variable bound to a for, returned last, was assigned.
  defp returned_fors(body) do
    es = exprs(body)

    case List.last(es) do
      {:for, _, _} = f ->
        [f]

      {v, _, ctx} when is_atom(v) and is_atom(ctx) ->
        for {:=, _, [{^v, _, c}, {:for, _, _} = f]} <- es, is_atom(c), do: f

      _ ->
        []
    end
  end

  # The kernel's value `v` as its declared return type; reported at the body's
  # last expression.
  defp coerce_return(v, k) do
    last = k.body |> exprs() |> List.last()
    at = with {:=, _, [_, rhs]} <- last, do: rhs

    case {v, k.ret} do
      {%{t: {:tuple, ts}, elems: elems}, {:tuple, rts}} when length(ts) == length(rts) ->
        items = tuple_items(at) || List.duplicate(at, length(rts))

        vals =
          Enum.zip_with([elems, rts, items], fn [v, rt, item] ->
            coerce!(v, rt, item, "#{k.name}/#{k.arity} returns", k.ret).c
          end)

        {[], Enum.zip(vals, rts)}

      {%{t: {:arr, _} = t}, t} ->
        {[], [{v.c, t}]}

      _ ->
        {[], [{coerce!(v, k.ret, at, "#{k.name}/#{k.arity} returns", k.ret).c, k.ret}]}
    end
  end

  # `v` as type `t` (an i64 widens to f64). `what` names the position, e.g.
  # "array index"; for a kernel's result, `ret` is its declared return type.
  defp coerce!(v, t, at, what, ret \\ nil)
  defp coerce!(%{t: t} = v, t, _at, _what, _ret), do: v

  defp coerce!(%{t: t} = v, :f64, _at, _what, _ret) when t in @ints,
    do: %{v | c: to_f(v), t: :f64}

  # a u64 where an i64 is expected and back: checked (u64_to_i64/1)
  defp coerce!(%{t: :u64} = v, :i64, _at, _what, _ret), do: u64_to_i64(v)
  defp coerce!(%{t: :i64} = v, :u64, _at, _what, _ret), do: i64_to_u64(v)
  defp coerce!(%{bits0: true}, :bitstring, _at, _what, _ret), do: empty_bits()

  defp coerce!(v, t, at, what, nil) do
    subject = Enum.join([what | describe(at)], " ")

    err!(
      at,
      "type-mismatch",
      "#{subject} has type #{fmt(v.t)}, expected #{fmt(t)}",
      convert_hint(v.t, t, at)
    )
  end

  defp coerce!(v, t, at, what, _ret) do
    hint =
      case convert_hint(v.t, t, at) do
        [] -> [hint: "change the declared return type to #{fmt(v.t)}"]
        h -> Keyword.update!(h, :rewrite, &"#{&1}    # or declare :: #{fmt(v.t)}")
      end

    why =
      if {v.t, t} == {:f64, :i64},
        do: [why: "defk never converts a float to an integer implicitly"],
        else: []

    err!(at, "return-type", "#{what} #{fmt(v.t)} but is declared :: #{fmt(t)}", hint ++ why)
  end

  # the explicit conversion from type `from` to `to`, applied to `at`
  defp convert_hint(:f64, :i64, at),
    do: [
      hint: "convert explicitly with trunc/1 or round/1",
      rewrite: "trunc(#{Macro.to_string(at)})"
    ]

  defp convert_hint(:bool, t, at) when t in [:i64, :f64] do
    {one, zero} = if t == :i64, do: {"1", "0"}, else: {"1.0", "0.0"}

    [
      hint: "booleans are not numbers; choose the number with if",
      rewrite: "if #{Macro.to_string(at)}, do: #{one}, else: #{zero}"
    ]
  end

  defp convert_hint(t, :bool, at) when t in [:i64, :f64],
    do: [
      hint: "compare it to get a boolean",
      rewrite: "#{Macro.to_string(at)} != #{if t == :i64, do: "0", else: "0.0"}"
    ]

  defp convert_hint(_from, _to, _at), do: []

  # [name] of a variable, or nothing for an expression the caret already shows
  defp describe({n, _, ctx}) when is_atom(n) and is_atom(ctx) do
    # (a case subject is renamed to a name no source variable has)
    if String.contains?(Atom.to_string(n), " "), do: [], else: ["#{n}"]
  end

  defp describe(_), do: []

  # ------------------------------------------------------------- blocks ----

  defp exprs({:__block__, _, []} = b) do
    err!(
      if(positioned?(b), do: b, else: ctx(:where)),
      "empty-block",
      "this block is empty"
    )
  end

  defp exprs({:__block__, _, es}), do: es
  defp exprs(e), do: [e]

  # A block whose last expression is its value. It is nested in the statement
  # `env` is at (see "array values"), or is a kernel's body.
  defp lower_block(ast, env) do
    {s, v, _env} = lower_block_env(ast, env)
    {s, v}
  end

  # lower_block/2 and the env the block ends in (nested, see leave/2)
  defp lower_block_env(ast, env) do
    es = exprs(ast)
    {init, [last]} = Enum.split(es, -1)
    lives = Copies.live_after(es)
    {s1, env} = stmt_list(init, lives, nested(env, ast))

    {s2, v, env} =
      in_ctx(last, fn ->
        {sh, env} = enter(last, List.last(lives), env)
        {s, v, env} = last_value(last, env)
        {[sh, s], v, env}
      end)

    {[s1, s2], v, env}
  end

  # A nested plain block binds into the scope around it, as in Elixir: `env`
  # is the block's env at its end, `outer` the env the block is nested in.
  # What the block bound is now bound in `outer`'s block, so it is at its depth.
  defp leave(env, outer) do
    vars =
      Map.new(env.vars, fn
        {n, %{depth: d} = b} when d == env.depth -> {n, %{b | depth: outer.depth}}
        kv -> kv
      end)

    %{outer | vars: vars}
  end

  # a nested block's value, and the env with its bindings; any other expression
  # binds nothing
  defp lower_expr_env({:__block__, _, _} = b, env) do
    {s, v, inner} = lower_block_env(b, env)
    {s, v, leave(inner, env)}
  end

  defp lower_expr_env(e, env) do
    {s, v} = lower_expr(e, env)
    {s, v, env}
  end

  defp last_value({:=, _, [{{:., _, [Access, :get]}, _, [arr, _]}, _]} = last, _env) do
    err!(
      last,
      "write-as-value",
      "the array write #{Macro.to_string(last)} ends a block that needs a value",
      rewrite: "#{Macro.to_string(last)}\n#{Macro.to_string(arr)}"
    )
  end

  defp last_value({:=, _, [lhs, rhs]} = last, env) do
    match?({:<<>>, _, _}, lhs) && bitstring_match!(last)
    {s, v, env} = lower_expr_env(rhs, env)
    {s2, env} = bind(lhs, v, env, last)
    {[s, s2], v, env}
  end

  defp last_value(last, env), do: lower_expr_env(last, env)

  # A block evaluated only for effect, nested like lower_block's.
  defp lower_stmts(ast, env) do
    es = exprs(ast)
    stmt_list(es, Copies.live_after(es), nested(env, ast))
  end

  # statements `es` of one block; `lives` has the names read after each
  defp stmt_list(es, lives, env) do
    Enum.zip(unzeroed_allocs(es), lives)
    |> Enum.reduce({[], env}, fn {e, live}, {acc, env} ->
      {s, env} =
        recover(e, env, fn ->
          {sh, env} = enter(e, live, env)
          {s, env} = lower_stmt(e, env)
          {[sh, s], env}
        end)

      {[acc, s], env}
    end)
  end

  # run `fun` with `e` as the statement that literals inside it are located in
  defp in_ctx(e, fun) do
    if positioned?(e) do
      prev = ctx(:where)
      ctx_put(:where, e)

      try do
        fun.()
      after
        ctx_put(:where, prev)
      end
    else
      fun.()
    end
  end

  # --------------------------------------------------------- statements ----

  defp lower_stmt({:=, _, [{{:., _, [Access, :get]}, _, [arr, idx]} = target, rhs]}, env) do
    {sa, a} = lower_expr(arr, env)
    match?({:arr, _}, a.t) || not_an_array!(target, arr, a)
    {si, i} = lower_expr(idx, env)
    i = coerce!(i, :i64, idx, "array index")
    {[sa, si, sv], [a, i, v]} = in_order([{sa, a}, {si, i}, lower_expr(rhs, env)], env, :stmt)
    {:arr, e} = a.t
    stored = "value stored in [#{e}]"

    vc =
      if v.t in @ints and wide(e) != :f64,
        do: int_stored(v, e),
        else: narrowed(coerce!(v, wide(e), rhs, stored), e)

    # value semantics: the array is copied first if another binding may still
    # see its buffer (see "array values")
    {sc, a, env} = before_write(arr, a, env)
    a[:id] && copies_put(Copies.record_write(copies(), a.id, a[:buf], target))

    proven = Facts.check(a, i, 1, env)

    store =
      case proven do
        {:proven, _} ->
          srec_proven(:index, a, i, proven)
          srec(%{k: :elem_write, arr: a.c, checked: false})
          "(#{a.c}).data[#{i.c}] = #{vc};\n"

        {:unproven, _} ->
          srec(%{k: :elem_write, arr: a.c, checked: true})
          "defk_put_#{e}(ctx, #{a.c}, #{i.c}, #{vc});\n"
      end

    note_bounds(target, 1, proven, {a, i, env})
    {[sa, si, sv, sc, store], env}
  end

  defp lower_stmt({:=, _, [lhs, rhs]} = match, env) do
    match?({:<<>>, _, _}, lhs) && bitstring_match!(match)
    {s, v, env} = lower_expr_env(rhs, env)
    {s2, env} = bind(lhs, v, env, match)
    {[s, s2], env}
  end

  defp lower_stmt({:if, _, [cond, kw]} = node, env) when is_list(kw) do
    note_branch_stmt(node, "a statement, and a select is for a value")
    ref = make_ref()
    {sc, c, rel} = lower_test(cond, env)
    do_ast = Keyword.fetch!(kw, :do)
    {sa, _} = srec_arm(ref, 0, fn -> lower_stmts(do_ast, narrow(env, rel, true)) end)
    after_env = guarded(env, rel, do_ast, kw[:else])

    case Keyword.fetch(kw, :else) do
      {:ok, e} ->
        {sb, _} = srec_arm(ref, 1, fn -> lower_stmts(e, narrow(env, rel, false)) end)
        {[sc, "if (#{c}) {\n", sa, "} else {\n", sb, "}\n"], after_env}

      :error ->
        {[sc, "if (#{c}) {\n", sa, "}\n"], after_env}
    end
  end

  defp lower_stmt({:case, _, [subject, [do: clauses]]} = node, env) do
    note_branch_stmt(node, "a statement, and a select is for a value")
    {ss, arms, cenv} = case_arms(subject, clauses, node, env)
    {[ss, branch_chain(arms, cenv, &elem(lower_stmts(&1, &2), 0))], env}
  end

  defp lower_stmt({:for, _, args} = ast, env) do
    case parse_for(args, ast, env) do
      {quals, nil, body} ->
        lenv = loop_env(env, ast)
        loops = lower_quals(quals, lenv, fn env -> elem(lower_stmts(body, env), 0) end)
        {loops, env}

      _reduce ->
        {s, v} = lower_expr(ast, env)
        {[s, discard(v)], env}
    end
  end

  # raise Module, "literal" / raise Module / raise "literal": the exception
  # Elixir would raise, its message a C string literal (see "raise")
  defp lower_stmt({:raise, _, args} = node, env) when is_list(args) do
    case Defk.Raise.parse!(node, &reject!/4) do
      {mod, {:ints, strings, exprs}} -> {raise_ints(mod, strings, exprs, env), env}
      {mod, msg} -> {raise_literal(mod, Defk.Raise.message(mod, msg)), env}
    end
  end

  defp lower_stmt(e, env) do
    {s, v, env} = lower_expr_env(e, env)
    {[s, discard(v)], env}
  end

  defp raise_literal(mod, msg),
    do:
      "defk_user_raise(ctx, #{Defk.Raise.kind(mod)}, #{Defk.Raise.c_string(msg)}, #{byte_size(msg)});\n"

  # raise Module, "text #{i} text": the integers evaluated left to right, each
  # into a local (one may raise before the next runs, as in Elixir), then the
  # message formatted at run time
  defp raise_ints(mod, strings, exprs, env) do
    {stmts, vals} =
      exprs
      |> Enum.map(fn e ->
        {s, v} = lower_expr(e, env)
        v.t in @ints || Defk.Raise.not_integer!(e, fmt(v.t), &reject!/4)
        t = fresh("msg", v.t)
        {[s, "#{t} = #{v.c};\n"], %{v | c: t}}
      end)
      |> Enum.unzip()

    list = fn ty, xs -> "(const #{ty}[]){#{Enum.join(xs, ", ")}}" end

    [
      stmts,
      "defk_user_raise_ints(ctx, #{Defk.Raise.kind(mod)}, #{length(exprs)}, ",
      list.("char *const", Enum.map(strings, &Defk.Raise.c_string/1)),
      ", ",
      list.("size_t", Enum.map(strings, &byte_size/1)),
      ", ",
      list.("int64_t", Enum.map(vals, &"(int64_t)#{&1.c}")),
      ", ",
      list.("unsigned char", Enum.map(vals, &if(&1.t == :u64, do: "1", else: "0"))),
      ");\n"
    ]
  end

  defp discard(%{elems: elems}), do: Enum.map(elems, &discard/1)
  defp discard(%{c: c}), do: "(void)(#{c});\n"

  # Bind pattern `pat` to value `v`; `match` is the whole `pat = rhs`.
  defp bind({name, _, ctx} = var, v, env, match) when is_atom(name) and is_atom(ctx) do
    cond do
      # `_ = rhs` still evaluates rhs, as Elixir does: its raise lives in the value
      String.starts_with?(Atom.to_string(name), "_") ->
        {discard(v), env}

      match?({:tuple, _}, v.t) ->
        {:tuple, ts} = v.t
        names = ts |> Enum.with_index() |> Enum.map_join(", ", fn {_, i} -> "#{name}#{i}" end)
        rhs = with {:=, _, [_, rhs]} <- match, do: Macro.to_string(rhs)

        err!(
          var,
          "tuple-binding",
          "binding the tuple #{fmt(v.t)} to the variable #{name} is not in the kernel subset",
          rewrite: "{#{names}} = #{rhs}"
        )

      # `acc = <<>>` where the kernel appends to acc (see "bitstrings");
      # otherwise the empty [u8], which may still be returned as a bitstring
      v[:bits0] && name in bits_names() ->
        bind(var, empty_bits(), env, match)

      v[:bits0] ->
        name in env.guard && array_rebind_in_loop!(var, match)
        {s, env} = bind_array(name, v, env)
        {s, put_in(env.vars[name][:bits0], true)}

      match?({:arr, _}, v.t) ->
        name in env.guard && array_rebind_in_loop!(var, match)
        bind_array(name, v, env)

      true ->
        c = fresh(name, v.t)
        b = %{c: c, t: v.t, owned: v[:owned] || false, var: c, facts: Facts.bound(v)}
        srec_assign(c, v.c)
        {"#{c} = #{v.c};\n", put_var(env, name, b)}
    end
  end

  defp bind(pat, %{elems: elems} = v, env, match) when is_tuple(pat) do
    pats = tuple_items(pat) || unsupported_pattern!(pat, v, match)

    if length(pats) != length(elems) do
      err!(
        pat,
        "tuple-size",
        "the pattern #{Macro.to_string(pat)} has #{length(pats)} elements, the tuple #{fmt(v.t)} has #{length(elems)}"
      )
    end

    Enum.zip(pats, elems)
    |> Enum.reduce({[], env}, fn {p, e}, {acc, env} ->
      {s, env} = bind(p, e, env, match)
      {[acc, s], env}
    end)
  end

  defp bind(pat, v, _env, match), do: unsupported_pattern!(pat, v, match)

  @spec unsupported_pattern!(term(), term(), term()) :: no_return()
  defp unsupported_pattern!({:<<>>, _, _}, _v, match), do: bitstring_match!(match)

  defp unsupported_pattern!(pat, v, _match) do
    rewrite =
      case v do
        %{elems: elems} when is_list(pat) and length(pat) == length(elems) ->
          [rewrite: Macro.to_string(List.to_tuple(pat)) <> " = ..."]

        _ ->
          []
      end

    err!(
      pat,
      "unsupported-pattern",
      "the pattern #{Macro.to_string(pat)} is not in the kernel subset",
      rewrite
    )
  end

  # `<<...>> = bin`: rejected before `bin` is compiled, so the pattern is what's reported
  @spec bitstring_match!(term()) :: no_return()
  defp bitstring_match!({:=, _, [{:<<>>, _, segs} = pat, rhs]}) do
    float_bits? =
      match?({:<<>>, _, [{:"::", _, [_, {:-, _, [{:float, _, _}, _]}]}]}, rhs) or
        match?({:<<>>, _, [{:"::", _, [_, {:float, _, _}]}]}, rhs)

    if float_bits? do
      rewrite =
        with [{:"::", _, [{b, _, ctx}, _]}] when is_atom(b) and is_atom(ctx) <- segs,
             {:<<>>, _, [{:"::", _, [x, _]}]} <- rhs do
          [rewrite: "#{b} = f64_bits(#{Macro.to_string(x)})"]
        else
          _ -> []
        end

      err!(
        pat,
        "bitstring-match",
        "reading a float's bits with #{Macro.to_string(pat)} = #{Macro.to_string(rhs)} is not in the kernel subset",
        [
          why: "a kernel has no bitstrings",
          hint: "f64_bits(x) (Defk.Bits.f64_bits/1) gives the bits of a float as a u64"
        ] ++ rewrite
      )
    else
      arr = Macro.to_string(rhs)

      err!(
        pat,
        "bitstring-match",
        "the binary pattern #{Macro.to_string(pat)} is not in the kernel subset",
        byte_fields(segs, arr)
      )
    end
  end

  # indexed reads for the byte-aligned fields of a binary pattern over a [u8] array
  defp byte_fields(segs, arr) do
    {lines, _} =
      Enum.reduce_while(segs, {[], 0}, fn seg, {acc, off} ->
        case seg do
          {:"::", _, [_, {t, _, _}]} when t in [:binary, :bytes, :bitstring, :bits] ->
            {:halt, {acc, off}}

          {:"::", _, [{n, _, ctx}, size]}
          when is_atom(n) and is_atom(ctx) and is_integer(size) and rem(size, 8) == 0 ->
            line =
              if String.starts_with?(Atom.to_string(n), "_"),
                do: nil,
                else: "# #{n}: bytes #{off}..#{off + div(size, 8) - 1} of #{arr}"

            {:cont, {[line | acc], off + div(size, 8)}}

          {n, _, ctx} when is_atom(n) and is_atom(ctx) ->
            line =
              if String.starts_with?(Atom.to_string(n), "_"),
                do: nil,
                else: "#{n} = #{arr}[#{off}]"

            {:cont, {[line | acc], off + 1}}

          _ ->
            {:halt, {:unknown, off}}
        end
      end)

    case lines do
      :unknown ->
        []

      lines ->
        lines
        |> Enum.reject(&is_nil/1)
        |> Enum.reverse()
        |> then(&if(&1 == [], do: [], else: [rewrite: Enum.join(&1, "\n")]))
    end
  end

  # an i64 binding's facts are also kept by its C variable (env.atoms), where
  # the prover finds an atom's (Defk.Facts); it outlives a shadowing
  # binding, as the variable is assigned once where it is in scope
  defp put_var(env, name, v) do
    env = %{env | vars: Map.put(env.vars, name, Map.put(v, :var, v.c))}

    if v.t == :i64,
      do: Map.put(env, :atoms, Map.put(env[:atoms] || %{}, v.c, Facts.facts(v))),
      else: env
  end

  defp tuple_items({a, b}), do: [a, b]
  defp tuple_items({:{}, _, items}), do: items
  defp tuple_items(_), do: nil

  # -------------------------------------------------------- array values ---
  # Arrays are values, as in Elixir: a write `a[i] = v` gives `a`
  # a new array from the write on, through enclosing branches and loops, and
  # every other variable keeps what it had. Natively a write is in place on
  # a's buffer when no other binding that may see that buffer is read later
  # (static copy-on-write, no reference count); otherwise the buffer is first
  # copied into one the kernel owns (defk_copy_* in priv/defk_runtime.h).
  #
  # An array value carries:
  #   owned - its buffer is the kernel's (alloc/2 or a copy), not the caller's
  #           binary or a binary attribute, which are never written
  #   buf   - the buffer's identity: bindings with the same buf may share it
  #   id    - the binding's identity, for a variable's value
  #   fin   - every element is finite (alloc/2 and what the kernel wrote); an
  #           input's elements, also in a copy of it, are checked when read
  # An owned array bound to a variable has a C local no other binding uses, so
  # copying it in place (`v = defk_copy(v)`) changes that variable only, and
  # the copy is seen after the branch or loop the write is in. An input array
  # bound to a variable stays the parameter's C local, which is re-bound after
  # every resume, until it is copied into a new local. An if, cond or case
  # that gives an array (branch_val/3), or a callee returning its argument
  # unwritten, leaves an input's view in a temporary instead: that local is
  # re-bound at a resume too (resume_block/3), and the arms' buffers are one
  # alias class (merge_bufs/1).
  #
  # Liveness is per block, by name: a binding is live after a statement if
  # its name is read later in the block before being bound again (live_after/1),
  # or it was live where the enclosing construct started (env.out). A
  # construct's bindings that are read anywhere in its statement are live for
  # its nested blocks (env.nest), which covers later iterations of a loop and
  # the rest of the statement; this is conservative, so it may copy where
  # Elixir would not need to. An arm of an if, cond or case leaves out what
  # its other arms read (nested/2): they run instead of it, so a helper call
  # in one arm that rebinds the array the other arm reads writes in place.
  # Inside a callee, what the caller reads after the call is live.
  #
  # Where copies go:
  #   * at a write `a[i] = v`: when a is an input array, or a binding that
  #     shares a's buffer is live after the write
  #   * before a statement whose branches or loop bodies write a variable
  #     bound outside them (hoist/3), on the same test made for the whole
  #     statement: so a loop copies once, before it starts, not per iteration
  #   * before a loop over an array that its body writes (snapshot_writes/2)
  # A swap `{a, b} = {b, a}` or `b = a` copies no elements.
  #
  # The env keys for this (scope/1):
  #   out        - {id, buf} live after the current block
  #   live       - {id, buf} live after the current statement
  #   nest       - {id, buf} live for blocks nested in the current statement
  #   live_names - the names read after the current statement in its block
  #   stmt       - the current statement
  #   guard      - array names a loop body must not bind again (read after it)
  #   loop       - the innermost loop construct
  #   depth      - block nesting, to check that an input array is copied in
  #                the block it is bound in

  defp scope(outer) do
    %{
      out: outer,
      nest: outer,
      live: outer,
      live_names: MapSet.new(),
      stmt: nil,
      guard: MapSet.new(),
      loop: nil,
      depth: 0
    }
  end

  # the env of block `ast` nested in the statement `env` is at. An arm of an
  # if, cond or case runs instead of its other arms, so what they read is not
  # read after it, and the condition, subject and clause heads that chose it
  # ran before it: its live set is what is read after the
  # statement, and what the statement reads outside those. Any other nested
  # block (a loop or fn body, run again) keeps env.nest.
  defp nested(env, ast) do
    out =
      if Copies.arm?(env.stmt, ast),
        do:
          MapSet.union(
            env.live,
            pairs(env, Copies.reads_outside(Copies.taken(env.stmt, ast), ast))
          ),
        else: env.nest

    %{env | out: out, depth: env.depth + 1}
  end

  # a parameter is bound in the kernel's body block (depth 1)
  defp array_ids({:arr, _}), do: %{id: make_ref(), buf: make_ref(), fin: false, depth: 1}
  defp array_ids(_t), do: %{}

  # {id, buf} of the array bindings of `names` in env
  defp pairs(env, names) do
    for n <- names, %{buf: buf, id: id} <- [env.vars[n]], into: MapSet.new(), do: {id, buf}
  end

  # Before statement `e` of a block, `live` the names read after it: copy
  # what its nested writes need (hoist/3), then note what is live.
  defp enter(e, live, env) do
    names = MapSet.difference(live, Copies.binds(e))
    {sh, env} = hoist(e, names, env)
    live = MapSet.union(pairs(env, names), env.out)
    nest = MapSet.union(live, pairs(env, Copies.reads(e)))
    {sh, %{env | stmt: e, live: live, live_names: names, nest: nest}}
  end

  # A variable bound outside the branches and loop bodies of `e` and written
  # in them is copied before `e` if it is an input array, or if another
  # binding of its buffer is read in `e` or after it. Inside, it is then the
  # only binding of an owned buffer, so its writes are in place, and a loop
  # copies once. An input array written in a branch is copied even when the
  # branch is not taken.
  defp hoist(e, names, env) do
    seen = MapSet.union(names, Copies.reads(e))

    Enum.reduce(Copies.nested_writes(e), {[], env}, fn n, {acc, env} ->
      case env.vars do
        %{^n => %{buf: _} = b} ->
          if not b.owned or
               Copies.shared?(copies(), b, MapSet.union(pairs(env, seen), env.out)) do
            note(
              :copy,
              e,
              :copied,
              "#{n} is copied before this statement, which writes it in a branch or loop: #{copy_why(b)}"
            )

            {s, env} = copy_var(n, b, env)
            {[acc, s], env}
          else
            {acc, env}
          end

        _ ->
          {acc, env}
      end
    end)
  end

  defp copy_var(name, b, env) do
    {s, nb} = copied(b, name)
    {s, %{env | vars: Map.put(env.vars, name, nb)}}
  end

  # {stmts, value}: array `a` copied into a buffer of the kernel's own, in
  # place when `a` is an owned array in a C local (no other binding uses it),
  # else into a new C local
  defp copied(a, base) do
    {:arr, e} = a.t

    buf = carried(make_ref(), a[:buf])

    if a.owned and a[:var] != nil do
      {copy_stmts(a.c, a.c, e), Map.put(a, :buf, buf)}
    else
      c = fresh(base, a.t)

      b =
        a
        |> Map.drop([:pure_read])
        |> Map.merge(%{c: c, var: c, owned: true, buf: buf})

      b = if a[:var], do: Facts.len_like(b, a), else: b

      {copy_stmts(c, a.c, e), b}
    end
  end

  # `dst = a copy of src` (element type `e`): at once in a yield: false
  # kernel; otherwise the buffer first, then its bytes in strips of
  # DEFK_ZERO_STRIP with a safepoint after each, like alloc/2's zeroing, so a
  # large copy does not hold the scheduler (256 MB at once: a 4-94 ms gap).
  # The strip record sees the copy as one assignment either way.
  defp copy_stmts(dst, src, e) do
    {{_, _}, yield?} = low(:report_kernel)
    srec_assign(dst, "defk_copy_#{e}(ctx, #{src})")

    if yield? do
      tmp = fresh("copy", {:arr, e})
      z = fresh("copied", {:c, "uint64_t"})
      bytes = "(uint64_t)#{tmp}.len * sizeof(*#{tmp}.data)"

      [
        "#{tmp} = defk_copy_raw_#{e}(ctx, #{src});\n#{z} = 0;\n",
        in_loop(fn id ->
          [
            "defk_l#{id}:;\nwhile (#{z} < #{bytes}) {\n",
            "uint64_t defk_z0 = #{z};\n",
            "#{z} = defk_copy_strip(#{tmp}.data, #{src}.data, #{bytes}, #{z});\n",
            safepoint("DEFK_ZERO_TICKS(#{z} - defk_z0)"),
            "}\n"
          ]
        end),
        "#{dst} = #{tmp};\n"
      ]
    else
      "#{dst} = defk_copy_#{e}(ctx, #{src});\n"
    end
  end

  # `dst = expr`, where expr may be a value-semantics copy (loop_owned/2
  # builds the C): a copy is emitted as copy_stmts/3 does
  defp assign_copy(dst, expr) do
    case Regex.run(~r/^defk_copy_(\w+)\(ctx, (.+)\)$/, expr) do
      [_, e, src] ->
        copy_stmts(dst, src, Enum.find(@elems, &(Atom.to_string(&1) == e)))

      nil ->
        srec_assign(dst, expr)
        "#{dst} = #{expr};\n"
    end
  end

  # A yielding kernel's prologue: each array input that defk_bind found
  # misaligned (F->copy[i] set) gets its buffer filled in strips with a
  # safepoint after each, so a large misaligned input does not hold the
  # scheduler at entry. A resume re-enters the loop where it left off.
  defp bind_strips(k) do
    for {{p, {:arr, _}}, i} <- Enum.with_index(k.params) do
      sp = "p_#{sanitize(p)}"
      z = fresh("bound", {:c, "uint64_t"})
      bytes = "(uint64_t)#{sp}.len * sizeof(*#{sp}.data)"

      [
        "if (F->copy[#{i}]) {\n",
        in_loop(fn id ->
          [
            "defk_l#{id}:;\nwhile (#{z} < #{bytes}) {\n",
            "uint64_t defk_z0 = #{z};\n",
            "#{z} = defk_bind_strip(env, ctx, argv[#{i}], F->copy[#{i}], #{z});\n",
            safepoint("DEFK_ZERO_TICKS(#{z} - defk_z0)"),
            "}\n"
          ]
        end),
        "}\n"
      ]
    end
  end

  # `arr[i] = v` with `arr`'s value `a`: {stmts, the array written, env}
  defp before_write(arr, a, env) do
    if a.owned and not Copies.shared?(copies(), a, env.live) do
      {[], a, env}
    else
      case arr do
        {n, _, ctx} when is_atom(n) and is_atom(ctx) ->
          # an input array written in a nested block was copied before the
          # statement holding that block (hoist/3), so this new C local is
          # bound in the block the variable is
          (a.owned or a[:depth] == env.depth) ||
            raise "defk bug: input array #{n} written in a nested block was not copied first"

          {s, b} = copied(a, n)
          note(:copy, arr, :copied, "#{n} is copied before this write: #{copy_why(a)}")
          {s, b, %{env | vars: Map.put(env.vars, n, b)}}

        _ ->
          {s, b} = copied(a, "arr")
          note(:copy, arr, :copied, "the array is copied before this write: #{copy_why(a)}")
          {s, b, env}
      end
    end
  end

  defp bind_array(name, v, env) do
    {s, b} = array_binding(name, v, env.depth)
    {s, put_var(env, name, b)}
  end

  # {stmts, binding} for `name = v`, `v` an array
  defp array_binding(name, v, depth) do
    ids = %{id: make_ref(), buf: v[:buf] || make_ref(), fin: v[:fin] || false, depth: depth}

    cond do
      # an input array stays in the C local it came in, re-bound after a resume
      not v.owned and v[:var] != nil ->
        {[], Map.merge(v, ids)}

      # a call's result in its temporary is this binding's alone
      v.owned and v[:var] != nil and v[:id] == nil ->
        {[], Map.merge(v, ids)}

      # a C local of its own (two words, no elements copied)
      true ->
        c = fresh(name, v.t)

        b =
          %{c: c, t: v.t, owned: v.owned, var: c, facts: Facts.facts(v)}
          |> Map.merge(ids)

        b = if v[:var], do: Facts.len_like(b, v), else: b

        srec_assign(c, v.c)
        {"#{c} = #{v.c};\n", b}
    end
  end

  # The env a loop's generators, filters and body are lowered in: what its
  # statement reads stays live (for the next iteration), and the arrays read
  # after the loop must not be bound again inside it.
  defp loop_env(env, node) do
    live = MapSet.new(env.live, &elem(&1, 0))
    guard = for {n, %{id: id}} <- env.vars, id in live, into: env.guard, do: n
    %{env | live: env.nest, guard: guard, loop: node}
  end

  # A generator walks array `a` while its loop writes a variable sharing a's
  # buffer: that variable is copied first (in place: it is owned).
  defp snapshot_writes(%{owned: true, buf: buf}, %{loop: loop} = env) when loop != nil do
    loop
    |> Copies.writes_in(MapSet.new())
    |> Enum.uniq()
    |> Enum.reduce({[], env}, fn n, {acc, env} ->
      with %{^n => %{buf: b_buf} = b} <- env.vars,
           true <- Copies.same_buf?(copies(), b_buf, buf) do
        note(
          :copy,
          loop,
          :copied,
          "#{n} is copied before the loop, which walks its buffer while writing it"
        )

        {s, env} = copy_var(n, b, env)
        {[acc, s], env}
      else
        _ -> {acc, env}
      end
    end)
  end

  defp snapshot_writes(_a, env), do: {[], env}

  # A callee that writes an array parameter must return it, or the write is
  # lost to the caller (valid Elixir that does nothing). The array returned
  # may be the parameter bound again, as long as it
  # carries the written buffer: a helper's result that is its argument, a
  # reduce accumulator started from it, a copy of it.
  defp unreturned_writes!(k, params, returned) do
    ids = for v <- returned, v[:id], do: v.id
    bufs = for v <- returned, v[:buf], do: v.buf
    writes = Copies.writes(copies())

    for {p, id} <- params,
        id not in ids,
        {^id, _, at} <- Enum.take(Enum.filter(writes, &lost?(&1, id, bufs)), 1) do
      last = k.body |> exprs() |> List.last()
      items = tuple_items(last) || [last]
      name = "#{k.name}"

      opts =
        if Enum.any?(items, &match?({^p, _, ctx} when is_atom(ctx), &1)),
          do: [
            hint:
              "#{p} is bound again after this write to an array that does not hold it; write the array #{p} is bound to, or give the new array another name and return #{p} as well"
          ],
          else: [
            hint:
              "return the array, and bind it again where #{name} is called: {#{p}, ...} = #{name}(#{p}, ...)",
            rewrite: Macro.to_string({:{}, [], [{p, [], nil} | items]})
          ]

      err!(
        at,
        "write-not-returned",
        "#{k.name}/#{k.arity} writes to its array parameter #{p} but doesn't return it, so the caller never sees the write",
        opts
      )
    end

    :ok
  end

  # a write to binding `id` that no returned array carries
  defp lost?({wid, buf, _at}, id, bufs),
    do:
      wid == id and
        (buf == nil or not Enum.any?(bufs, &Copies.carries?(copies(), &1, buf)))

  @spec array_rebind_in_loop!(term(), term()) :: no_return()
  defp array_rebind_in_loop!({name, _, _} = var, match) do
    rhs = with {:=, _, [_, rhs]} <- match, do: Macro.to_string(rhs)

    err!(
      var,
      "array-rebind-in-loop",
      "the array #{name} is bound again inside this loop body and read after the loop, where it is still the array from before the loop",
      rewrite: "#{name}_iter = #{rhs}"
    )
  end

  # -------------------------------------------------------- expressions ----
  # lower_expr(ast, env) :: {c_statements, value}
  # value :: %{c: c_expr, t: type, owned: bool, var: cname | nil}
  #        | %{t: {:tuple, ts}, elems: [value]}
  #
  # Elixir evaluates the operands of an operation left to right, so the first
  # error is the leftmost one, and the C must agree. C orders
  # neither the arguments of a call nor the operands of most operators (gcc
  # on x86-64 evaluates arguments right to left), and an operand's statements
  # run before the C expression that holds the operands left of it. So
  # lower_ops/2 lowers the operands of one operation, and an operand that can
  # raise is bound to a local when an operand right of it can raise too: by a
  # statement when one right of it has statements, else by the comma operator
  # in front of the C of the expression being lowered (lower_expr/2 adds it).
  defp lower_expr(ast, env) do
    outer = low(:operand_binds)
    low_put(:operand_binds, [])

    try do
      {s, v} = lower_node(ast, env)
      {s, with_binds(v, low(:operand_binds))}
    after
      low_put(:operand_binds, outer)
    end
  end

  defp with_binds(v, []), do: v
  defp with_binds(v, binds), do: %{Map.delete(v, :pure_read) | c: "(#{binds}#{v.c})"}

  # how: :comma, or :stmt where the operation's value has no C of its own to
  # put the bindings in front of (a tuple)
  defp lower_ops(asts, env, how \\ :comma),
    do: asts |> Enum.map(&lower_expr(&1, env)) |> in_order(env, how)

  # [{stmts, value}] made to run in Elixir's order: {stmts, values}. Where
  # errors set flags (a case guard, a speculated select: env.ovf) the order
  # is the replay's, which is lowered without them.
  defp in_order(lowered, env, how) do
    flags? = Map.has_key?(env, :ovf)

    {ordered, _, binds} =
      List.foldr(lowered, {[], false, []}, fn {s, v}, {acc, right, binds} ->
        raises? = not flags? and may_raise?(v)
        stmts? = IO.iodata_length(s) > 0

        {sv, binds} =
          cond do
            raises? and (right == :stmts or (right == :raises and how == :stmt)) ->
              {bind_operand(s, v), binds}

            raises? and right == :raises ->
              {t, v} = operand_local(v)
              {{s, %{v | c: t}}, ["#{t} = #{v.c}, " | binds]}

            true ->
              {{s, v}, binds}
          end

        right =
          cond do
            right == :stmts or stmts? -> :stmts
            right == :raises or raises? -> :raises
            true -> false
          end

        {[sv | acc], right, binds}
      end)

    low_update(:operand_binds, &(&1 ++ binds))
    Enum.unzip(ordered)
  end

  # every error goes through ctx (a tuple has no C of its own)
  defp may_raise?(%{c: c}), do: String.contains?(c, "ctx")
  defp may_raise?(_v), do: false

  defp bind_operand(s, v) do
    {t, v} = operand_local(v)
    {[s, "#{t} = #{v.c};\n"], %{v | c: t}}
  end

  # a local for the operand v: the local, and v with its C still the
  # operand's (the caller assigns it and then refers to the local)
  defp operand_local(v) do
    t = fresh("op", v.t)
    srec_assign(t, v.c)
    {t, Map.delete(v, :pure_read)}
  end

  # a literal is an i64; one in 2^63..2^64 - 1 is a u64
  defp lower_node(n, _env) when is_integer(n) do
    n in -0x8000000000000000..@max_u64 ||
      err!(n, "integer-literal", "the integer literal #{n} does not fit in i64 or u64",
        rewrite: "#{n * 1.0}"
      )

    v = if n > @max_i64, do: val("UINT64_C(#{n})", :u64), else: val("INT64_C(#{n})", :i64)
    {[], Facts.assert(v, lo: n, hi: n)}
  end

  # nonneg: the float is never below 0.0 (sqrt/1 of one needs no check)
  defp lower_node(f, _env) when is_float(f),
    do: {[], Map.put(val(:erlang.float_to_binary(f, [:short]), :f64), :nonneg, f >= 0)}

  defp lower_node(true, _env), do: {[], val("1", :bool)}
  defp lower_node(false, _env), do: {[], val("0", :bool)}

  defp lower_node({name, m, ctx}, env) when is_atom(name) and is_atom(ctx) do
    case env.vars do
      # bound by a rejected statement: this one is abandoned without a report
      %{^name => %{t: :poison}} ->
        throw(:defk_poison)

      %{^name => v} ->
        {[], v}

      # a head parameter's name in a clause that names it otherwise (Defk.Clauses)
      _ ->
        err!({name, m, ctx}, "undefined-variable", "undefined variable #{m[:defk_name] || name}")
    end
  end

  # a module attribute that Defk.Attributes.inline/1 did not turn into a
  # literal: a binary is a read-only [u8] in static storage, as an input array
  defp lower_node({:@, _, [{name, _, ctx}]} = node, _env) when is_atom(name) and is_atom(ctx) do
    case Defk.Attributes.of(node) do
      {:ok, b} when is_binary(b) -> {[], static_u8(b)}
      _ -> attribute!(node)
    end
  end

  # a binary literal, `"abc"` or `<<1, 2, 3>>`: the same static read-only [u8]
  # as a binary attribute; or an append to a bitstring
  # accumulator, `<<acc::bitstring, ...>>` (see "bitstrings")
  defp lower_node({:<<>>, _, segs} = node, env) do
    case Defk.Bitstring.parse(node) do
      {:append, head, parts} -> lower_append(node, head, parts, env)
      {:error, at, what, opts} -> err!(at, "bitstring-segment", what, opts)
      :error -> binary_literal(node, segs)
    end
  end

  defp lower_node(b, _env) when is_binary(b), do: {[], static_u8(b)}

  defp lower_node({:__block__, _, _} = b, env), do: lower_block(b, env)

  defp lower_node(tuple, env) when is_tuple(tuple) and tuple_size(tuple) == 2,
    do: lower_tuple(Tuple.to_list(tuple), env)

  defp lower_node({:{}, _, items}, env), do: lower_tuple(items, env)

  defp lower_node({{:., _, [Access, :get]}, _, [arr, idx]} = node, env) do
    {sa, a} = lower_expr(arr, env)
    match?({:arr, _}, a.t) || not_an_array!(node, arr, a)
    {[sa, si], [a, i]} = in_order([{sa, a}, lower_expr(idx, env)], env, :comma)
    i = coerce!(i, :i64, idx, "array index")
    {:arr, e} = a.t
    raw = widen("(#{a.c}).data[#{i.c}]", e)
    proven = Facts.check(a, i, 1, env)

    get =
      cond do
        # an f64 or f32 from an input array may hold inf or NaN bits: the read
        # raises; an alloc/2 array holds only what the kernel wrote
        # (fin), a copy of an input array still holds the input's bits
        e in [:f64, :f32] and not a[:fin] and match?({:proven, _}, proven) ->
          srec_proven(:index, a, i, proven)
          "defk_in_f64(ctx, #{raw}, #{i.c})"

        e == :f64 and not a[:fin] ->
          "defk_get_in_f64(ctx, #{a.c}, #{i.c})"

        e == :f32 and not a[:fin] ->
          "defk_in_f64(ctx, (double)defk_get_f32(ctx, #{a.c}, #{i.c}), #{i.c})"

        match?({:proven, _}, proven) ->
          srec_proven(:index, a, i, proven)
          raw

        true ->
          widen("defk_get_#{e}(ctx, #{a.c}, #{i.c})", e)
      end

    v = elem_val(get, e)

    # an in-range read cannot fail but by its inf/NaN check, which a float
    # expression may defer to its own check (float_tree)
    v = if match?({:proven, _}, proven), do: Map.put(v, :pure_read, raw), else: v
    note_bounds(node, 1, proven, {a, i, env})
    {[sa, si], v}
  end

  defp lower_node({:if, _, [cond, kw]} = node, env) when is_list(kw) do
    else_ast =
      Keyword.get(kw, :else) ||
        err!(node, "if-without-else", "this if is used as a value but has no else branch")

    lower_arms([{cond, Keyword.fetch!(kw, :do)}, {true, else_ast}], "if", node, env)
  end

  defp lower_node({:cond, _, [[do: clauses]]} = node, env) when is_list(clauses) do
    {last_cond, _} = List.last(clauses) |> clause_parts()
    last_cond == true || cond_without_true!(node)
    lower_arms(Enum.map(clauses, &clause_parts/1), "cond", node, env)
  end

  defp lower_node({:case, _, [subject, [do: clauses]]} = node, env) do
    {ss, arms, cenv} = case_arms(subject, clauses, node, env)
    {sa, v} = lower_arms(arms, "case", node, cenv)
    {[ss, sa], v}
  end

  defp lower_node({:case, _, _} = node, _env), do: case_form!(node)

  defp lower_node({{:., _, [{:__aliases__, _, [:Enum]}, :reduce_while]}, m, args} = node, env) do
    case args do
      [src, init, {:fn, _, [{:->, _, [[x, acc], body]}]}] ->
        lower_reduce_while(src, init, x, acc, body, env, m, node)

      _ ->
        fn_argument!(node, "Enum.reduce_while/3", [:x, :acc])
    end
  end

  # Enum.reduce/3 and Enum.find/3 with a literal fn were rewritten before
  # compiling (Defk.EnumForms); what is left takes some other function
  defp lower_node({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [_, _, _]} = node, _env),
    do: fn_argument!(node, "Enum.reduce/3", [:x, :acc])

  defp lower_node({{:., _, [{:__aliases__, _, [:Enum]}, :find]}, _, [_, _, _]} = node, _env),
    do: fn_argument!(node, "Enum.find/3", [:x])

  # Enum.all?/any? with a predicate fn are reduce_while with a bool accumulator
  defp lower_node({{:., _, [{:__aliases__, _, [:Enum]}, f]}, m, args} = node, env)
       when f in [:all?, :any?] do
    {src, x, pred} =
      case args do
        [src, {:fn, _, [{:->, _, [[x], pred]}]}] -> {src, x, pred}
        _ -> fn_argument!(node, "Enum.#{f}/2", [:x])
      end

    # all?: halt with false at the first false; any?: halt with true at the first true
    {init, kw} = Defk.Builtins.bool_reduce(f)

    lower_reduce_while(src, init, x, {:_, m, nil}, {:if, m, [pred, kw]}, env, m, node)
  end

  defp lower_node({:for, _, args} = node, env) do
    case parse_for(args, node, env) do
      {quals, nil, body} ->
        for_collect!(
          node,
          quals,
          body,
          nil,
          env,
          "a for without reduce: used as a value is not in the kernel subset"
        )

      {quals, {:reduce, init}, clauses} ->
        lower_reduce(quals, init, clauses, env, node)
    end
  end

  defp lower_node({:defk_guard, _, [guard]}, env), do: guard_expr(guard, env)

  defp lower_node({op, _, [a, b]} = node, env) when op in [:+, :-, :*, :/],
    do: float_tree(node, env) || lower_arith(op, a, b, node, env)

  defp lower_node({op, _, [a, b]} = node, env)
       when op in [:==, :!=, :===, :!==, :<, :>, :<=, :>=] do
    lowered = [lower_expr(a, env), lower_expr(b, env)]
    rel = relation(op, lowered, env)
    {stmts, [va, vb]} = in_order(lowered, env, :comma)
    {stmts, Map.put(val(compare_c(op, va, vb, node), :bool), :rel, rel)}
  end

  defp lower_node({op, m, [a, b]}, env) when op in [:and, :or, :&&, :||] do
    ref = make_ref()
    and? = op in [:and, :&&]
    {sa, va} = lower_expr(a, env)
    # the right side of an `and` runs only when the left holds; in a case
    # guard an overflowed left side may run it anyway (guard_short_circuit/5)
    benv = if and? and not Map.has_key?(env, :bad), do: narrow(env, va[:rel], true), else: env
    {sb, vb} = srec_arm(ref, 0, fn -> lower_expr(b, benv) end)
    bool!(va, a, op)
    bool!(vb, b, op)
    cop = if and?, do: "&&", else: "||"
    rel = if va[:rel] || vb[:rel], do: {if(and?, do: :and, else: :or), va[:rel], vb[:rel]}

    if IO.iodata_length(sb) == 0 do
      # inline right side: its rows run with the statement after all
      srec_drop_frame(ref)
      {sa, Map.put(val(guard_short_circuit(va, vb, cop, m, env), :bool), :rel, rel)}
    else
      # right side needs statements: keep short-circuit semantics explicitly
      tmp = fresh("sc", :bool)
      test = if cop == "&&", do: tmp, else: "!#{tmp}"

      srec_arm(ref, 0, fn -> srec_assign(tmp, vb.c) end)

      {[sa, "#{tmp} = #{va.c};\nif (#{test}) {\n", sb, "#{tmp} = #{vb.c};\n}\n"],
       Map.put(val(tmp, :bool, tmp), :rel, rel)}
    end
  end

  defp lower_node({op, _, [a]}, env) when op in [:not, :!] do
    {s, v} = lower_expr(a, env)
    bool!(v, a, op)
    {s, Map.put(val("(!#{v.c})", :bool), :rel, v[:rel] && {:not, v.rel})}
  end

  defp lower_node({:-, _, [a]} = node, env) do
    {s, v} = lower_expr(a, env)
    numeric!(v, a, :-)

    v.t == :u64 &&
      err!(node, "operand-type", "- takes i64 or f64, and #{Macro.to_string(a)} is u64",
        why: "the negation of a u64 is negative, and an i64 does not hold every negated u64",
        hint:
          "a negated u64 is not a u64; to wrap, negate inside a mask: band(-x, 0xFFFFFFFFFFFFFFFF)"
      )

    cond do
      # a negative literal (-32_768) is a constant, with its facts
      v.t == :i64 and v.c == "INT64_C(#{Facts.lo(v)})" and Facts.lo(v) > -0x8000000000000000 ->
        k = -Facts.lo(v)
        {s, Facts.assert(val("INT64_C(#{k})", :i64), lo: k, hi: k)}

      v.t == :i64 ->
        c = "defk_neg_i64#{checked(env)}, #{v.c})"
        {s, guarded(Facts.put(val(c, :i64), Facts.neg_facts(v)), env)}

      true ->
        {s, val("(-#{v.c})", v.t)}
    end
  end

  defp lower_node({:+, _, [a]}, env) do
    {s, v} = lower_expr(a, env)
    numeric!(v, a, :+)
    {s, v}
  end

  # dbg/IO.inspect are for Elixir mode (Defk.ElixirMode); native code ignores them
  defp lower_node({:dbg, _, [x | _]}, env), do: lower_expr(x, env)

  defp lower_node({{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, _, [x | _]}, env),
    do: lower_expr(x, env)

  # band(a, b), a &&& b, Bitwise.band(a, b) and :erlang.band(a, b) are one
  # builtin (see "bitwise"); a call of another arity may be a kernel
  defp lower_node({op, m, args} = node, env) when op in @bitwise_names and is_list(args) do
    f = Defk.Builtins.bitwise_fun(op)
    arity = Defk.Builtins.bitwise_arity(f)
    label = if op == f, do: "#{f}/#{arity}", else: "#{op}"

    if length(args) == arity,
      do: lower_bitwise(f, label, args, node, env),
      else: lower_call(op, args, m, env)
  end

  defp lower_node({{:., _, [mod, f]}, _, args} = node, env) when f in @bitwise do
    arity = Defk.Builtins.bitwise_arity(f)

    if bitwise_module?(mod) and length(args) == arity,
      do: lower_bitwise(f, "#{Macro.to_string(mod)}.#{f}/#{arity}", args, node, env),
      else: unsupported!(node, Defk.Errors.Rewrites.unsupported(node, &type_in(&1, env)), env)
  end

  # wrap64(expr): the masked-arithmetic tree of expr wrapped to the low 64
  # bits as a signed i64 (Defk.Bits.wrap64/1); a leaf is returned as it is
  defp lower_node({:wrap64, _, [x]}, env) do
    if Defk.Masked.tree_node(x) do
      lower_masked(x, -1, "wrap64/1", env)
    else
      {s, v} = lower_expr(x, env)
      int!(v, x, "wrap64/1")
      {s, if(v.t == :u64, do: val("((int64_t)#{v.c})", :i64), else: v)}
    end
  end

  # Defk.Bits.clz(x, w) etc. are the builtins (Defk.Bits is their Elixir meaning)
  defp lower_node({{:., _, [{:__aliases__, _, [:Defk, :Bits]}, f]}, m, args}, env)
       when f in [:wrap64 | @bits] and is_list(args),
       do: lower_expr({f, m, args}, env)

  # :math.sqrt(x) etc. map onto the builtins
  defp lower_node({{:., _, [:math, fun]}, m, args}, env) when fun in [:pow | @math1],
    do: lower_call(fun, args, m, env)

  # a pipe is one rejection (code pipe, the nested call as its rewrite); the
  # calls in it are checked first, as if written nested (recover_pipe/2)
  defp lower_node({:|>, _, [_, _]} = node, env) do
    recover_pipe(node, env)
    unsupported!(node, Defk.Errors.Rewrites.unsupported(node, &type_in(&1, env)), env)
  end

  defp lower_node({name, m, args}, env) when is_atom(name) and is_list(args),
    do: lower_call(name, args, m, env)

  # anything else (a map, a string, a remote call, ...) is outside the subset
  defp lower_node(other, env),
    do: unsupported!(other, Defk.Errors.Rewrites.unsupported(other, &type_in(&1, env)), env)

  # + - * / one operation at a time: i64 checked for overflow, f64 for a
  # result that is inf or NaN; see float_tree for the common case
  defp lower_arith(op, a, b, node, env) do
    {[sa, sb], [va, vb]} = lower_ops([a, b], env)
    numeric!(va, a, op)
    numeric!(vb, b, op)
    pair = if op != :/ and va.t in @ints and vb.t in @ints, do: int_pair!(va, vb, node)

    v =
      case pair || {op, va.t, vb.t} do
        {:u64, ua, ub} ->
          fun = %{+: "add", -: "sub", *: "mul"}[op]
          val("defk_#{fun}_u64#{checked(env)}, #{ua.c}, #{ub.c})", :u64)

        {:i64, va, vb} ->
          i64_arith(op, va, vb, env)

        # a float result that is inf or NaN raises, as in Elixir
        _ ->
          fun = Map.get(@float_ops, op, "fdiv")
          fs = [val(to_f(va), :f64), val(to_f(vb), :f64)]

          c =
            guard_poison(fs, 2, env, fn [a, b] ->
              "defk_#{fun}#{checked_float(env)}, #{a}, #{b})"
            end)

          val(c, :f64)
      end

    {[sa, sb], v}
  end

  # i64 + - * checked for overflow, with range facts; no check when the
  # operands' facts keep every result inside i64 (their constant bounds, or
  # the prover on the result's relative bounds and exact form). A case
  # guard's check flags and computes on (checked/1), so its result is not
  # exact.
  defp i64_arith(op, va, vb, env) do
    {fun, facts, {lo, hi}} =
      case op do
        :+ ->
          {"add", Facts.add_facts(va, vb),
           {Facts.add(Facts.lo_of(va), Facts.lo_of(vb)),
            Facts.add(Facts.hi_of(va), Facts.hi_of(vb))}}

        :- ->
          {"sub", Facts.sub_facts(va, vb),
           {Facts.add(Facts.lo_of(va), Facts.neg(Facts.hi_of(vb))),
            Facts.add(Facts.hi_of(va), Facts.neg(Facts.lo_of(vb)))}}

        :* ->
          {"mul", Facts.mul_facts(va, vb), Facts.mul_range(va, vb)}
      end

    v = Facts.put(val(nil, :i64), facts)

    if Facts.prove_i64(lo, hi) or Facts.fits_i64?(v, env),
      do: %{v | c: "(#{va.c} #{op} #{vb.c})"},
      else: guarded(%{v | c: "defk_#{fun}_i64#{checked(env)}, #{va.c}, #{vb.c})"}, env)
  end

  # a value from a check that a case guard flags and computes past has no
  # exact form
  defp guarded(v, %{ovf: _}), do: Facts.inexact(v)
  defp guarded(v, _env), do: v

  # div or rem of two integers, checked for a zero divisor (and i64 div for
  # overflow)
  defp int_div(f, a, b, node, env) do
    case {int_pair!(a, b, node), env} do
      # in a case guard: a zero divisor is flagged, unless the divisor
      # overflowed (guard_poison/4)
      {{:i64, a, b}, %{bad: bad, ovf: ovf}} when f == :div ->
        srec_addr(bad)
        srec_addr(ovf)

        c =
          guard_poison([a, b], 1, env, fn [a, b] ->
            "defk_div_i64_g(&#{bad}, &#{ovf}, #{a}, #{b})"
          end)

        val(c, :i64)

      {{:i64, a, b}, %{bad: bad}} ->
        srec_addr(bad)

        val(
          guard_poison([a, b], 1, env, fn [a, b] -> "defk_rem_i64_g(&#{bad}, #{a}, #{b})" end),
          :i64
        )

      {{:u64, a, b}, %{bad: bad}} ->
        srec_addr(bad)

        val(
          guard_poison([a, b], 1, env, fn [a, b] -> "defk_#{f}_u64_g(&#{bad}, #{a}, #{b})" end),
          :u64
        )

      {{:i64, a, b}, _} ->
        val("defk_#{f}_i64(ctx, #{a.c}, #{b.c})", :i64)

      {{:u64, a, b}, _} ->
        val("defk_#{f}_u64(ctx, #{a.c}, #{b.c})", :u64)
    end
  end

  # The integer type of an operation on `va` and `vb`:
  # {:i64 | :u64, va, vb}. Two i64 stay i64; a u64 with a u64, or with an
  # i64 its range facts prove non-negative (a literal, length(a), a mask ...),
  # is u64. A u64 with any other i64 has no type holding every result: it is
  # rejected, pointing at masked arithmetic, where the two mix.
  defp int_pair!(va, vb, node) do
    case {va.t, vb.t} do
      {t, t} -> {t, va, vb}
      {:u64, :i64} -> if Facts.nonneg?(vb), do: {:u64, va, as_u64(vb)}, else: u64_mix!(node, vb)
      {:i64, :u64} -> if Facts.nonneg?(va), do: {:u64, as_u64(va), vb}, else: u64_mix!(node, va)
    end
  end

  # an accumulator that may become a u64 (u64_accs/2) is one, rather than a mix
  @spec u64_mix!(term(), term()) :: no_return()
  defp u64_mix!(_node, %{u64_ref: ref, acc: name}), do: throw({:defk_u64_acc, ref, name})

  defp u64_mix!({op, _, _} = node, _i) do
    wrap? = op in [:+, :-, :*, :band, :bor, :bxor, :&&&, :|||, :"^^^"]

    err!(
      node,
      "u64-with-i64",
      "#{Macro.to_string(node)} mixes a u64 with an i64 that may be negative, which is not in the kernel subset outside a mask",
      if(wrap?,
        do: [rewrite: "band(#{Macro.to_string(node)}, 0xFFFFFFFFFFFFFFFF)"],
        else: []
      )
    )
  end

  defp as_u64(v), do: %{v | c: "((uint64_t)#{v.c})", t: :u64}

  # a u64 where an i64 is expected: the same integer, or ArithmeticError
  # when it is above 2^63 - 1 (no check when its range facts rule that out)
  defp u64_to_i64(v) do
    if is_integer(Facts.hi(v)) and Facts.hi(v) <= @max_i64,
      do: %{v | c: "((int64_t)#{v.c})", t: :i64},
      else: %{v | c: "defk_u64_to_i64(ctx, #{v.c})", t: :i64}
  end

  # an i64 where a u64 is expected: ArithmeticError when it is negative
  defp i64_to_u64(v) do
    if Facts.nonneg?(v),
      do: as_u64(v),
      else: %{v | c: "defk_i64_to_u64(ctx, #{v.c})", t: :u64}
  end

  # A float expression of + - * / whose operands are pure (variables,
  # literals, in-range reads) is computed with plain C operators and checked
  # once: + - * give inf or NaN whenever an operand is inf or NaN, so the
  # result shows whether any operation or input read on the way made one. Only
  # x / inf hides one (it gives 0.0), so a divisor that may be non-finite is
  # checked too. On a failed check the expression is replayed one operation at
  # a time, in Elixir's order, with the raising checks: it raises where Elixir
  # would, with the same error. One check per expression instead of
  # one per operation and read is most of the cost of matching Elixir in
  # float loops. Inside a speculated select (env.ovf) and over any other
  # operand, each operation is checked on its own (lower_arith).
  defp float_tree(_node, %{ovf: _}), do: nil

  defp float_tree(node, env) do
    {:op, fast, replay, r, divisors} = ftree(node, env)
    f = ftmp()
    bad = Enum.map_join([f | divisors], " | ", &"DEFK_NONFIN(#{&1})")

    # DEFK_FCHECK: the replay runs on a failed check, or a flagged strip
    # (flag_strip/3) flags it and skips the replay
    c =
      "({ double #{f} = #{fast}; DEFK_FCHECK(#{bad}) { #{replay}(void)#{r}; " <>
        "defk_nonfinite_lost(ctx); } #{f}; })"

    leaves = if divisors == [], do: sticky_leaves(node, env)
    srec_ftree(f, "DEFK_FCHECK(#{bad})", leaves)

    {[], val(c, :f64)}
  catch
    :impure -> nil
  end

  # The variables (C names) whose inf or NaN would make the expression's
  # result inf or NaN: + - * keep one, and so does a numerator (flag_strip/3
  # uses this to check a reduce accumulator once per strip).
  defp sticky_leaves({op, _, [a, b]}, env) when op in [:+, :-, :*],
    do: sticky_leaves(a, env) ++ sticky_leaves(b, env)

  defp sticky_leaves({:/, _, [a, _]}, env), do: sticky_leaves(a, env)
  defp sticky_leaves({:-, _, [a]}, env), do: sticky_leaves(a, env)

  defp sticky_leaves({name, _, ctx}, env) when is_atom(name) and is_atom(ctx) do
    case env.vars do
      %{^name => %{c: c, t: :f64}} -> [c]
      _ -> []
    end
  end

  defp sticky_leaves(_, _env), do: []

  # {:leaf, type, fast_c, replay_c, finite?} for a pure operand, or
  # {:op, fast_c, replay_stmts, replay_var, divisors} for a float operation
  defp ftree({op, _, [a, b]}, env) when op in [:+, :-, :*, :/] do
    ta = ftree(a, env)
    tb = ftree(b, env)
    # i64 + - * may overflow: not pure
    op == :/ or ftype(ta) == :f64 or ftype(tb) == :f64 or throw(:impure)
    {fa, ra, sa, da} = fparts(ta)
    {fb, rb, sb, db} = fparts(tb)
    t = ftmp()
    fop = Map.get(@float_ops, op, "fdiv")
    # x / inf is 0.0: check a divisor that may be inf or NaN itself
    dd = if op == :/ and not finite?(tb), do: [fb], else: []

    {:op, "(#{fa} #{op} #{fb})", [sa, sb, "double #{t} = defk_#{fop}(ctx, #{ra}, #{rb});\n"], t,
     da ++ db ++ dd}
  end

  defp ftree({:-, _, [a]}, env) do
    case ftree(a, env) do
      {:leaf, :f64, fast, replay, fin?} -> {:leaf, :f64, "(-#{fast})", "(-#{replay})", fin?}
      {:op, fast, replay, r, ds} -> {:op, "(-#{fast})", replay, "(-#{r})", ds}
      _ -> throw(:impure)
    end
  end

  defp ftree(x, _env) when is_float(x) do
    c = :erlang.float_to_binary(x, [:short])
    {:leaf, :f64, c, c, true}
  end

  defp ftree(x, env) when is_integer(x) or (is_tuple(x) and tuple_size(x) == 3) do
    {s, v} = pure_operand(x, env)
    IO.iodata_length(s) == 0 || throw(:impure)

    case v do
      %{t: t, pure_read: raw} when t in [:i64, :f64] ->
        {:leaf, t, raw, v.c, t == :i64 or raw == v.c}

      %{t: t} when t in [:i64, :f64] ->
        {:leaf, t, v.c, v.c, true}

      _ ->
        throw(:impure)
    end
  end

  defp ftree(_x, _env), do: throw(:impure)

  # a variable, literal or in-range read; anything else may raise
  defp pure_operand({name, _, ctx} = x, env) when is_atom(name) and is_atom(ctx),
    do: lower_expr(x, env)

  defp pure_operand({{:., _, [Access, :get]}, _, [_, idx]} = x, env) do
    pure_index?(idx) || throw(:impure)
    {s, v} = lower_expr(x, env)
    if Map.has_key?(v, :pure_read), do: {s, v}, else: throw(:impure)
  end

  defp pure_operand(n, env) when is_integer(n), do: lower_expr(n, env)
  defp pure_operand(_x, _env), do: throw(:impure)

  # an index whose computation cannot raise (once proved in range)
  defp pure_index?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp pure_index?(n) when is_integer(n), do: true
  defp pure_index?(_), do: false

  defp ftype({:leaf, t, _, _, _}), do: t
  defp ftype({:op, _, _, _, _}), do: :f64

  defp finite?({:leaf, _, _, _, fin?}), do: fin?
  defp finite?(_), do: false

  # {fast_c, replay value, replay statements, divisors}, as f64. A checked
  # read is replayed as its own statement, so it raises in Elixir's order.
  defp fparts({:leaf, :i64, fast, _, _}), do: {"((double)#{fast})", "((double)#{fast})", [], []}
  defp fparts({:leaf, :f64, fast, fast, _}), do: {fast, fast, [], []}

  defp fparts({:leaf, :f64, fast, replay, _}) do
    t = ftmp()
    {fast, t, ["double #{t} = #{replay};\n"], []}
  end

  defp fparts({:op, fast, replay, r, ds}), do: {fast, r, replay, ds}

  # a C local of a float_tree check, scoped to its statement expression
  defp ftmp do
    n = low(:n) + 1
    low_put(:n, n)
    "f_#{n}"
  end

  defp lower_tuple(items, env) do
    lowered =
      Enum.map(items, fn item ->
        {s, v} = lower_expr(item, env)

        match?(%{elems: _}, v) &&
          err!(
            item,
            "nested-tuple",
            "nested tuples such as #{Macro.to_string(item)} are not in the kernel subset"
          )

        {s, v}
      end)

    # a tuple has no C of its own to put comma bindings in front of
    {stmts, elems} = in_order(lowered, env, :stmt)
    {stmts, %{t: {:tuple, Enum.map(elems, & &1.t)}, elems: elems}}
  end

  defp lower_cond(cond, env) do
    {s, c, _rel} = lower_test(cond, env)
    {s, c}
  end

  # a condition's statements and C, and what it says (Facts.holds/2)
  defp lower_test(cond, env) do
    {s, v} = lower_expr(cond, env)
    bool!(v, cond, "a condition")
    {s, v.c, v[:rel]}
  end

  defp clause_parts({:->, _, [[c], body]}), do: {c, body}

  # The one type of the values of `node` (an if, cond or case named `name`),
  # or of element `pos` of the tuples they are (counted from 1).
  defp branch_type!(vals, name, node, pos \\ nil) do
    # a u64 branch and i64 branches known to be >= 0 (a literal ...) give a u64
    u64? =
      Enum.any?(vals, &(&1.t == :u64)) and
        Enum.all?(vals, &(&1.t == :u64 or (&1.t == :i64 and Facts.nonneg?(&1))))

    if u64?, do: :u64, else: branch_type1!(vals, name, node, pos)
  end

  defp branch_type1!(vals, name, node, pos) do
    case Enum.uniq_by(vals, & &1.t) do
      [%{t: t}] ->
        t

      many ->
        ts = Enum.map(many, & &1.t)

        hint =
          if Enum.sort(ts) == [:f64, :i64],
            do: [
              hint:
                "convert the i64 branch to f64 with float/1, or the f64 branch to i64 with trunc/1 or round/1"
            ],
            else: []

        what =
          if pos,
            do: "element #{pos} of the tuples from this #{name} has different types",
            else: "the branches of this #{name} have different types"

        err!(node, "branch-types", "#{what}: #{Enum.map_join(ts, ", ", &fmt/1)}", hint)
    end
  end

  # The clauses of an `if` or `cond` value, the last one `true ->`. Each arm is
  # {cond_ast, body_ast, {stmts, c} | :else, body_stmts, body_val}.
  # A `case` without a catch-all ends in {:nomatch, stmts} instead, which
  # raises CaseClauseError.
  #
  # Arms that are tuples give a tuple: one branch per element
  # position, each with that position's type, all assigned in one if/else
  # chain (so every condition runs once), or a select per element when the
  # arms are pure. The value is a tuple of the element temporaries.
  defp lower_arms(clauses, name, node, env) do
    ref = make_ref()

    # each arm sees its condition and the negations of the conditions
    # before it; a later condition sees those negations too
    {lowered, _} =
      clauses
      |> Enum.with_index()
      |> Enum.map_reduce(env, fn
        {{:nomatch, s}, _k}, aenv ->
          {{{nil, nil, :nomatch, s, nil}, {aenv, aenv}}, aenv}

        {{c, body}, k}, aenv ->
          # the first arm's condition runs unconditionally; a later arm's
          # runs only when the arms before it did not take (it sits in their
          # else blocks), like the arm's own body
          {cond, rel} =
            cond do
              c == true -> {:else, nil}
              k == 0 -> test_parts(lower_test(c, aenv))
              true -> srec_arm(ref, k, fn -> test_parts(lower_test(c, aenv)) end)
            end

          benv = narrow(aenv, rel, true)
          {sb, v} = srec_arm(ref, k, fn -> lower_block(body, benv) end)
          {{{c, body, cond, sb, v}, {aenv, benv}}, narrow(aenv, rel, false)}
      end)

    {arms, envs} = Enum.unzip(lowered)
    relies = relies_on_condition(arms, envs, env)
    vals = for {_, _, _, _, v} <- arms, v, do: v

    if Enum.any?(vals, &Map.has_key?(&1, :elems)) do
      tuple_arms(arms, vals, name, node, env, {ref, relies})
    else
      arms = bits_arms(arms)
      vals = for({_, _, _, _, v} <- arms, v, do: v)
      t = branch_type!(vals, name, node)
      tmp = fresh(name, t)
      {lower_branch(arms, [t], [tmp], env, node, {ref, relies}), branch_val(tmp, t, vals)}
    end
  end

  defp test_parts({s, c, rel}), do: {{s, c}, rel}

  # The first arm (counted from 0) whose body, or condition, dropped a check
  # by the conditions it runs under, or nil. A select computes every arm and
  # condition whether taken or not, so such an arm keeps the chain
  # (ADR-0007). Asked only of arms a select could take: each narrowed one
  # is lowered again in the branch's own env, and its C compared.
  defp relies_on_condition(arms, envs, env) do
    if select?(arms) do
      Enum.zip(arms, envs)
      |> Enum.find_index(fn {{c, body, cond, sb, v}, {cenv, benv}} ->
        (benv != env and not same_c?(probe(fn -> lower_block(body, env) end), {sb, v})) or
          (cenv != env and match?({_, _}, cond) and
             not same_c?(probe(fn -> lower_cond(c, env) end), cond))
      end)
    end
  end

  # a lowering's {stmts, value or C} gives the same C as another's
  defp same_c?({:ok, {s, x}}, {s0, x0}),
    do: IO.iodata_to_binary(s) == IO.iodata_to_binary(s0) and c_of(x) == c_of(x0)

  defp same_c?(:error, _), do: false

  defp c_of(c) when is_binary(c), do: c
  defp c_of(v), do: parts(v)

  defp tuple_arms(arms, vals, name, node, env, branch) do
    sizes = Enum.map(vals, &length(Map.get(&1, :elems, [nil])))

    if not Enum.all?(vals, &Map.has_key?(&1, :elems)) or not match?([_], Enum.uniq(sizes)) do
      err!(
        node,
        "branch-tuple",
        "the arms of this #{name} give #{vals |> Enum.map(&fmt(&1.t)) |> Enum.uniq() |> Enum.join(" and ")}; every arm of a tuple-valued #{name} gives a tuple of the same size"
      )
    end

    # per position: the arms with that element as their value
    {arms, ts} =
      Enum.reduce(0..(hd(sizes) - 1), {arms, []}, fn i, {arms, ts} ->
        pos =
          arms
          |> Enum.map(fn {c, b, cd, sb, v} -> {c, b, cd, sb, v && Enum.at(v.elems, i)} end)
          |> bits_arms()

        t = branch_type!(for({_, _, _, _, v} <- pos, v, do: v), name, node, i + 1)

        arms =
          Enum.zip_with(arms, pos, fn
            {c, b, cd, sb, nil}, _ ->
              {c, b, cd, sb, nil}

            {c, b, cd, sb, v}, {_, _, _, _, e} ->
              {c, b, cd, sb, %{v | elems: List.replace_at(v.elems, i, e)}}
          end)

        {arms, ts ++ [t]}
      end)

    tmps = Enum.map(ts, &fresh(name, &1))

    elems =
      Enum.with_index(Enum.zip(tmps, ts), fn {tmp, t}, i ->
        branch_val(tmp, t, for({_, _, _, _, v} <- arms, v, do: Enum.at(v.elems, i)))
      end)

    {lower_branch(arms, ts, tmps, env, node, branch), %{t: {:tuple, ts}, elems: elems}}
  end

  # The value of an if, cond or case in temporary `tmp` of type `t`, its arms
  # giving `vals`. An array is any of the arms' arrays: owned when
  # every arm's is, its buffer may be any of theirs (merge_bufs/1), and it
  # keeps the facts all of them have. An input array is not copied: the
  # temporary holds the caller's view, re-bound after a resume like a
  # parameter (resume_block/3), and a write to it copies it first.
  defp branch_val(tmp, {:arr, _} = t, vals) do
    bufs = for v <- vals, do: v[:buf]
    {buf, st} = Copies.merge_bufs(copies(), bufs)
    copies_put(st)

    # a buffer every arm's array holds is carried into the value's (for
    # write-not-returned); one only some arms hold may be lost
    for b <- Enum.uniq(bufs),
        b != nil,
        Enum.all?(bufs, &Copies.carries?(copies(), &1, b)),
        do: carried(buf, b)

    # every arm `<<>>`: still a bitstring accumulator's start (bits_init/2)
    bits0 = if Enum.all?(vals, &(&1[:bits0] == true)), do: %{bits0: true}, else: %{}

    Map.merge(%{val(tmp, t, tmp) | owned: Enum.all?(vals, & &1.owned)}, %{
      buf: buf,
      fin: Enum.all?(vals, &(&1[:fin] == true))
    })
    |> Facts.join(vals)
    |> Map.merge(bits0)
  end

  # a number keeps the range facts every arm's has (Facts.join/2)
  defp branch_val(tmp, t, vals), do: Facts.join(val(tmp, t, tmp), vals)

  # the code that assigns each of `tmps` (of types `ts`) its element of the
  # value of the arm taken; `node` is the if, cond or case
  # `relies`: the first arm that relies on its condition (relies_on_condition/3)
  defp lower_branch(arms, ts, tmps, env, node, {ref, relies}) do
    sel = relies == nil and select?(arms)

    # a select's arms run inline in the assigned statement; a chain assigns
    # each arm's value to the temporaries inside that arm's block
    if sel, do: srec_drop_frame(ref), else: record_arm_assigns(arms, tmps, ref)

    code = if(sel, do: select(arms, ts, tmps, env), else: chain(arms, tmps))
    note_branch(node, arms, code, tmps, relies)
    code
  end

  defp record_arm_assigns(arms, tmps, ref) do
    arms
    |> Enum.with_index()
    |> Enum.each(fn
      {{_, _, _, _, nil}, _k} ->
        :ok

      {{_, _, _, _, v}, k} ->
        srec_arm(ref, k, fn -> Enum.zip_with(tmps, parts(v), &srec_assign/2) end)
    end)
  end

  # the C of each element of an arm's value
  defp parts(%{elems: elems}), do: Enum.map(elems, & &1.c)
  defp parts(%{c: c}), do: [c]

  # An `if` or `cond` value whose arms (and conditions after the first) are pure
  # arithmetic is compiled as a select: every arm is computed with overflow
  # flags instead of raising, and only an overflow replays the clauses with the
  # raising checks. A raise inside one arm would otherwise keep clang from
  # if-converting the branch; it then threads the branch into the loop that
  # computed the condition, which made `if prime?(i), do: count + 1, else:
  # count` 1.7x slower than C. The first condition always runs, so
  # it is evaluated once as written and may call kernels. A tuple value gets
  # one select per element over the same condition temporaries.
  # (A `case` with no catch-all ends in a :nomatch arm and is never a select.)
  defp select?([{_, _, {_, _}, _, _} | later] = arms) do
    case Enum.split(later, -1) do
      {later, [{_, _, :else, _, _}]} ->
        Enum.all?(arms, fn {_, body, _, sb, _} ->
          IO.iodata_length(sb) == 0 and speculate?(body)
        end) and
          Enum.all?(later, fn
            {c, _, {sc, _}, _, _} -> IO.iodata_length(sc) == 0 and speculate?(c)
            _ -> false
          end)

      _ ->
        false
    end
  end

  defp select?(_arms), do: false

  defp select([{_, _, {sc, c}, _, _} | later] = arms, ts, tmps, env) do
    later = Enum.drop(later, -1)

    flagged = fn flag ->
      fenv = Map.put(env, :ovf, flag)
      conds = for {ca, _, _, _, _} <- later, do: elem(lower_cond(ca, fenv), 1)
      {conds, for({_, body, _, _, _} <- arms, do: parts(elem(lower_block(body, fenv), 1)))}
    end

    plain_conds = for {_, _, {_, cc}, _, _} <- later, do: cc
    plain_bodies = for {_, _, _, _, v} <- arms, do: parts(v)

    if flagged.("_") == {plain_conds, plain_bodies} do
      # nothing can raise: clang if-converts the plain branches itself
      chain(arms, tmps)
    else
      ovf = fresh("ovf", :bool)
      {fconds, fbodies} = flagged.(ovf)
      [cv | cvs] = for _ <- [c | fconds], do: fresh("cond", :bool)
      # per arm, a temporary per element
      tvs = for _ <- arms, do: Enum.map(ts, &fresh("arm", &1))

      replay = fn body -> Enum.map_join(body, " ", &"(void)(#{&1});") end

      [
        sc,
        "#{cv} = #{c};\n#{ovf} = 0;\n",
        Enum.zip_with(cvs, fconds, &"#{&1} = #{&2};\n"),
        Enum.zip_with(List.flatten(tvs), List.flatten(fbodies), &"#{&1} = #{&2};\n"),
        Enum.with_index(tmps, fn tmp, i ->
          arm_tvs = Enum.map(tvs, &Enum.at(&1, i))

          [
            "#{tmp} = ",
            Enum.zip_with([cv | cvs], arm_tvs, &"#{&1} ? #{&2} : "),
            "#{List.last(arm_tvs)};\n"
          ]
        end),
        "if (DEFK_UNLIKELY(#{ovf})) {\n",
        Enum.zip_with(
          [cv | plain_conds],
          plain_bodies,
          &"if (#{&1}) { #{replay.(&2)} }\nelse "
        ),
        "{ #{replay.(List.last(plain_bodies))} }\n}\n"
      ]
    end
  end

  defp chain(arms, tmps) do
    assign = fn v -> Enum.zip_with(tmps, parts(v), &"#{&1} = #{&2};\n") end

    List.foldr(arms, [], fn
      {_, _, :else, sb, v}, _rest ->
        [sb, assign.(v)]

      {_, _, :nomatch, s, _}, _rest ->
        s

      {_, _, {sc, c}, sb, v}, rest ->
        [sc, "if (#{c}) {\n", sb, assign.(v), "} else {\n", rest, "}\n"]
    end)
  end

  defp checked(%{ovf: flag}) do
    srec_addr(flag)
    "_s(&#{flag}"
  end

  defp checked(_env), do: "(ctx"

  # a float operation in a case guard flags a non-finite result as a failed
  # guard (an Elixir error), not as an overflow
  defp checked_float(%{bad: flag}) do
    srec_addr(flag)
    "_s(&#{flag}"
  end

  defp checked_float(env), do: checked(env)

  # pure expressions that can only fail by i64 overflow or a non-finite float
  # result: safe to evaluate untaken, with the failure flagged. Only cheap
  # arithmetic is speculated: a division (div, rem and the float
  # `/`, tens of cycles each) is not, so an arm holding one is a branch that
  # skips it when untaken. Array reads and calls are not speculated either.
  defp speculate?({:__block__, _, [e]}), do: speculate?(e)
  defp speculate?(x) when is_number(x) or is_boolean(x), do: true
  # a tuple arm: each element
  defp speculate?({a, b}), do: speculate?(a) and speculate?(b)
  defp speculate?({:{}, _, items}) when is_list(items), do: Enum.all?(items, &speculate?/1)
  defp speculate?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true

  # a case guard flags its own failures (guard_expr), so it is safe untaken
  defp speculate?({:defk_guard, _, [_]}), do: true

  defp speculate?({op, _, args})
       when op in [
              :+,
              :-,
              :*,
              :==,
              :!=,
              :===,
              :!==,
              :<,
              :>,
              :<=,
              :>=,
              :and,
              :or,
              :&&,
              :||,
              :not,
              :!
            ],
       do: Enum.all?(args, &speculate?/1)

  # bitwise operators: only bsl/bsr can fail, and only by i64 overflow
  defp speculate?({op, _, args}) when op in @bitwise_names and is_list(args),
    do: bitwise_call?(op, args) and Enum.all?(args, &speculate?/1)

  defp speculate?({{:., _, [mod, f]}, _, args}) when f in @bitwise,
    do: bitwise_module?(mod) and bitwise_call?(f, args) and Enum.all?(args, &speculate?/1)

  defp speculate?(_), do: false

  # ------------------------------------------------------------- bitwise --
  # The Bitwise functions on i64, with Elixir's results: band/bor/bxor/bnot
  # are two's complement and stay in i64; bsl/bsr shift exactly (a negative
  # shift goes the other way, bsr fills with the sign) and raise
  # ArithmeticError when the exact result leaves i64 (defk_bsl_i64 in
  # priv/defk_runtime.h). In a select's arms bsl/bsr flag the overflow
  # instead (the _s forms), like + - *. `label` names the construct as
  # written, for errors: "&&&", "band/2" or "Bitwise.band/2".

  defp bitwise_module?({:__aliases__, _, [:Bitwise]}), do: true
  defp bitwise_module?(mod), do: mod == :erlang

  defp bitwise_call?(op, args),
    do: length(args) == Defk.Builtins.bitwise_arity(Defk.Builtins.bitwise_fun(op))

  defp lower_bitwise(f, label, args, node, env) do
    with :band <- f, {expr, mask} <- Defk.Masked.split(args) do
      lower_masked(expr, mask, label, env)
    else
      _ ->
        {stmts, vals} = lower_ops(args, env)
        Enum.zip_with(vals, args, &int!(&1, &2, label))
        {stmts, bitwise_val(f, vals, args, node, env)}
    end
  end

  # Masked arithmetic (Defk.Masked): the tree of + - * neg band bor bxor
  # bnot bsl under a mask 2^k - 1 is computed in uint64_t, which wraps
  # modulo 2^64 without an overflow check, and masked once; its leaves are
  # lowered as usual. The low k bits are those of Elixir's exact result, so
  # nothing can raise but the leaves (and a bsl by a negative count that is
  # not a literal). The 64-bit mask gives a u64; a narrower mask m
  # an i64 in 0..m; -1 stands for wrap64/1, the i64 bit pattern of the low
  # 64 bits.
  defp lower_masked(expr, mask, label, env) do
    {s, c} = wrapped(expr, {expr, label}, nil, env)

    v =
      cond do
        mask == -1 -> val("((int64_t)#{c})", :i64)
        mask == @max_u64 -> Facts.assert(val(c, :u64), lo: 0)
        true -> Facts.assert(val("((int64_t)(#{c} & UINT64_C(#{mask})))", :i64), lo: 0, hi: mask)
      end

    {s, v}
  end

  # {s, uint64_t C expression}; `top` is the masked expression and the
  # band's label, `parent` the operator taking `ast` (for errors): nil,
  # {:arith, op} or {:bit, label}
  defp wrapped(ast, top, parent, env) do
    case Defk.Masked.tree_node(ast) do
      nil ->
        {s, v} = lower_expr(ast, env)
        v.t in @ints || masked_operand!(v, ast, top, parent)
        {s, "((uint64_t)#{v.c})"}

      {:pos, a} ->
        wrapped(a, top, parent, env)

      {:neg, a} ->
        {s, c} = wrapped(a, top, {:arith, "-"}, env)
        {s, "(UINT64_C(0) - #{c})"}

      {:bnot, a} ->
        {s, c} = wrapped(a, top, {:bit, "bnot/1"}, env)
        {s, "(~#{c})"}

      {:bsl, a, n} ->
        {s, c} = wrapped(a, top, {:bit, "bsl/2"}, env)
        {s, if(n >= 64, do: "(UINT64_C(0) & #{c})", else: "(#{c} << #{n})")}

      # a count that is not a literal: 64 or more gives 0, a negative one
      # raises (defk_wbsl)
      {:bsl_var, a, n} ->
        {s, c} = wrapped(a, top, {:bit, "bsl/2"}, env)
        {[s, sn], [%{c: c}, vn]} = in_order([{s, val(c, :u64)}, lower_expr(n, env)], env, :comma)
        int!(vn, n, "bsl/2")

        shift =
          if vn.t == :u64,
            do: "(#{vn.c} >= 64 ? UINT64_C(0) : #{c} << #{vn.c})",
            else: "defk_wbsl#{checked(env)}, #{c}, #{vn.c})"

        {[s, sn], shift}

      {op, a, b} ->
        cop = %{add: "+", sub: "-", mul: "*", band: "&", bor: "|", bxor: "^"}[op]
        parent = if op in [:band, :bor, :bxor], do: {:bit, "#{op}/2"}, else: {:arith, cop}
        {sa, ca} = wrapped(a, top, parent, env)
        {sb, cb} = wrapped(b, top, parent, env)

        {[sa, sb], [%{c: ca}, %{c: cb}]} =
          in_order([{sa, val(ca, :u64)}, {sb, val(cb, :u64)}], env, :comma)

        {[sa, sb], "(#{ca} #{cop} #{cb})"}
    end
  end

  # the error the same expression gets without the mask: an f64 under
  # + - * makes the masked expression f64, which band rejects; a bool is
  # rejected by + - *; a bitwise operator rejects both
  @spec masked_operand!(term(), term(), term(), term()) :: no_return()
  defp masked_operand!(v, ast, {top, label}, parent) do
    case parent do
      nil -> int!(v, ast, label)
      {:bit, l} -> int!(v, ast, l)
      {:arith, _} when v.t == :f64 -> int!(v, top, label)
      {:arith, op} -> numeric!(v, ast, op)
    end
  end

  # bnot of a u64 is negative: no u64, and no i64 for every u64
  defp bitwise_val(:bnot, [%{t: :u64}], [x], node, _env) do
    err!(node, "operand-type", "bnot/1 takes an i64, and #{Macro.to_string(x)} is u64",
      why: "bnot of a u64 is negative, and an i64 does not hold it for every u64",
      hint: "bnot of a u64 is negative; to flip its 64 bits, write it inside a mask",
      rewrite: "band(#{Macro.to_string(node)}, 0xFFFFFFFFFFFFFFFF)"
    )
  end

  defp bitwise_val(:bnot, [a], _args, _node, _env),
    do:
      Facts.assert(val("(~#{a.c})", :i64),
        lo: Facts.bnot(Facts.hi(a)),
        hi: Facts.bnot(Facts.lo(a))
      )

  defp bitwise_val(f, [a, b], _args, node, _env) when f in [:band, :bor, :bxor] do
    cop = %{band: "&", bor: "|", bxor: "^"}[f]

    case int_pair!(a, b, node) do
      {:i64, a, b} -> Facts.put(val("(#{a.c} #{cop} #{b.c})", :i64), Facts.bit_facts(f, a, b))
      {:u64, a, b} -> val("(#{a.c} #{cop} #{b.c})", :u64)
    end
  end

  # a u64 shifted: exact, bsr is logical, bsl raises when a bit
  # leaves the 64; by a literal 0..63, bsr is one shift with a range
  defp bitwise_val(f, [%{t: :u64} = a, b], [_x, n], _node, env) when f in [:bsl, :bsr] do
    b = coerce!(b, :i64, n, "shift count")

    case int_literal(n) do
      k when f == :bsr and is_integer(k) and k in 0..63 ->
        Facts.assert(val("(#{a.c} >> #{k})", :u64),
          lo: 0,
          hi: Bitwise.bsr(Facts.hi(a) || @max_u64, k)
        )

      _ ->
        val("defk_#{f}_u64#{checked(env)}, #{a.c}, #{b.c})", :u64)
    end
  end

  # a shift of two literals that leaves i64 would always raise: rejected
  defp bitwise_val(f, [a, b], [x, n] = args, node, env) when f in [:bsl, :bsr] do
    b = coerce!(b, :i64, Enum.at(args, 1), "shift count")
    {x, n} = {int_literal(x), int_literal(n)}

    (is_integer(x) and is_integer(n) and Defk.ElixirMode.Ops.shift(f, x, n) == :overflow) &&
      err!(node, "shift-overflow", "#{Macro.to_string(node)} does not fit in i64",
        hint:
          "the kernel would raise ArithmeticError here every time. Write a value past 2^63 - 1 as a u64 literal (0x8000000000000000); a mask (1 <<< k) - 1 directly in band(x, mask) is computed at compile time, for k up to 64"
      )

    c =
      if f == :bsr and Facts.nonneg?(b),
        do: "defk_bsr_nn(#{a.c}, #{b.c})",
        else: "defk_#{f}_i64#{checked(env)}, #{a.c}, #{b.c})"

    Facts.put(val(c, :i64), if(f == :bsr, do: Facts.bsr_facts(a, b), else: Facts.none()))
  end

  # the value of an integer literal, also a negative one (-63 is -(63))
  defp int_literal(n) when is_integer(n), do: n
  defp int_literal({:-, _, [n]}) when is_integer(n), do: -n
  defp int_literal(_), do: nil

  # `at` is the operand's expression; `label` names what takes it
  defp int!(v, at, label) do
    v.t in @ints ||
      err!(
        at,
        "operand-type",
        "#{label} takes integers, and #{Macro.to_string(at)} is #{type_name(v)}",
        convert_hint(v.t, :i64, at) ++ operand_why(v.t, :integer)
      )
  end

  # ---------------------------------------------------------------- calls --

  defp lower_call(:alloc, [{e, _, ctx}, n] = args, m, env) when e in @elems and is_atom(ctx) do
    {s, v} = lower_expr(n, env)
    v = coerce!(v, :i64, n, "alloc/2 length")
    {sz, c} = alloc_zeroed(e, v, {:alloc, m, args}, env)
    arr = %{c: c, t: {:arr, e}, owned: true, var: nil, fin: true}
    {[s, sz], Facts.len_from(arr, v)}
  end

  # a kernel named alloc at another arity is an ordinary call
  defp lower_call(:alloc, args, m, env) when not is_map_key(env.sigs, {:alloc, length(args)}) do
    node = {:alloc, m, args}

    what =
      case args do
        [{e, _, ctx}, _] when is_atom(e) and is_atom(ctx) -> "#{e} is not an array element type"
        [n] -> "alloc(#{Macro.to_string(n)}) has no element type"
        _ -> "alloc/#{length(args)} takes an element type and a length"
      end

    rewrite = with [n] <- args, do: "alloc(f64, #{Macro.to_string(n)})"

    err!(node, "alloc-form", what,
      hint: "write alloc(type, length) with an element type: #{@elems_text}",
      rewrite: if(is_binary(rewrite), do: rewrite)
    )
  end

  # a raise is a statement: it has no value to give
  defp lower_call(:raise, args, m, _env), do: Defk.Raise.value!({:raise, m, args}, &reject!/4)

  defp lower_call(name, args, m, env) do
    node = {name, m, args}

    # a construct outside the subset (a map, |>, unless, ...) is reported
    # before its arguments are compiled
    with false <- Defk.Builtins.builtin?(name) or Map.has_key?(env.sigs, {name, length(args)}),
         {_, _, _} = r <- Defk.Errors.Rewrites.unsupported_local(node, &type_in(&1, env)) do
      unsupported!(node, r, env)
    end

    # an inlined kernel and a range copy read their arguments in statements
    how =
      if name in [:copy, :copy_back] or Map.has_key?(env.sigs, {name, length(args)}),
        do: :stmt,
        else: :comma

    {stmts, vals} = lower_ops(args, env, how)

    for {%{elems: _}, a} <- Enum.zip(vals, args) do
      err!(
        a,
        "tuple-argument",
        "passing the tuple #{Macro.to_string(a)} to #{name}/#{length(args)} is not in the kernel subset",
        rewrite: Macro.to_string({name, [], Enum.flat_map(args, &(tuple_items(&1) || [&1]))})
      )
    end

    # a builtin is an expression; an inlined kernel call also has statements
    case builtin(name, vals, node, env) do
      {s, v} -> {[stmts, s], v}
      v -> {stmts, v}
    end
  end

  # `node` is the call, for the argument expressions
  defp emit_builtin(:bit_size, [%{t: :bitstring} = a], _node, _),
    do: Facts.assert(val("(#{a.c}).nbits", :i64), lo: 0)

  defp emit_builtin(:length, [%{t: {:arr, _}} = a], _node, _) do
    # a view that is not a variable (e.g. a kernel call) is a new array each
    # time it is evaluated: only a binding's length is len(a) exactly
    Facts.len_value(val("(#{a.c}).len", :i64), a, a.var != nil)
  end

  # u64_le(bytes, i) and the other word loads (Defk.Builtins.loads/0): an
  # unaligned load of w bytes at byte offset i, bounds-checked unless
  # i + w <= length(bytes) is proven. u64 gives the i64 bit pattern.
  defp emit_builtin(f, [%{t: {:arr, :u8}} = a, %{t: :i64} = i], node, env) when f in @loads do
    w = Defk.Builtins.load_width(f)
    proven = Facts.check(a, i, w, env)
    note_bounds(node, w, proven, {a, i, env})

    c =
      case proven do
        {:proven, _} ->
          srec_proven(:load, a, i, proven)
          "defk_#{f}_at((#{a.c}).data + #{i.c})"

        {:unproven, _} ->
          "defk_#{f}(ctx, #{a.c}, #{i.c})"
      end

    v = val(c, :i64)
    if w < 8, do: Facts.assert(v, lo: 0, hi: Bitwise.bsl(1, 8 * w) - 1), else: v
  end

  # copy(out, at, src, from, n) and copy_back(out, at, off, n): `out` with a
  # range replaced, checked once for the whole range
  # (defk_rcopy_T and defk_rcopy_back_T in defk_runtime.h).
  defp emit_builtin(:copy, [%{t: {:arr, _}} = a, at, s, from, n], node, env),
    do: range_copy(:copy, a, s, [at, from, n], node, env)

  defp emit_builtin(:copy_back, [%{t: {:arr, _}} = a, at, off, n], node, env),
    do: range_copy(:copy_back, a, nil, [at, off, n], node, env)

  # mulhi, clz, ctz, popcount, rotl/2, rotr/2 (Defk.Builtins.bits/0): the
  # Defk.Bits functions on the u64 bit patterns; the helpers are in
  # defk_runtime.h (defk_rotl64, defk_rotr64 for the 64-bit rotates). The
  # counts are in 0..64.
  defp emit_builtin(f, [%{t: t} = a], _, _) when f in [:clz, :ctz, :popcount] and t in @ints,
    do: Facts.assert(val("defk_#{f}(#{a.c})", :i64), lo: 0, hi: 64)

  defp emit_builtin(:mulhi, [%{t: :i64} = a, %{t: :i64} = b], _, _),
    do: val("defk_mulhi(#{a.c}, #{b.c})", :i64)

  defp emit_builtin(f, [%{t: :i64} = a, %{t: :i64} = b], _, _) when f in [:rotl, :rotr],
    do: val("defk_#{f}64(#{a.c}, #{b.c})", :i64)

  # clz/2, ctz/2, rotl/3, rotr/3: x is a w-bit value, checked as
  # Defk.Bits checks it; an i64 x passes its sign. rotl/rotr give x's type.
  defp emit_builtin(f, [%{t: t} = x, w], _node, _) when f in [:clz, :ctz] and t in @ints do
    c = "defk_#{f}_#{if t == :i64, do: "i", else: "u"}(ctx, #{x.c}, #{w.c})"
    Facts.assert(val(c, :i64), lo: 0, hi: 64)
  end

  defp emit_builtin(f, [%{t: t} = x, n, w], _node, _) when f in [:rotl, :rotr] and t in @ints do
    c = val("defk_#{f}_#{if t == :i64, do: "i", else: "u"}(ctx, #{x.c}, #{n.c}, #{w.c})", :u64)
    if t == :i64, do: u64_to_i64(c), else: c
  end

  # crc32c(crc, x, w): one CRC32C step, checked as Defk.Bits
  # checks it; the instruction or the table is picked at run time in
  # defk_runtime.h. The result is a 32-bit value.
  defp emit_builtin(:crc32c, [%{t: tc} = c, %{t: tx} = x, w], _node, _)
       when tc in @ints and tx in @ints do
    sfx = Enum.map_join([tc, tx], &if(&1 == :i64, do: "i", else: "u"))

    Facts.assert(val("defk_crc32c_#{sfx}(ctx, #{c.c}, #{x.c}, #{w.c})", :i64),
      lo: 0,
      hi: 0xFFFFFFFF
    )
  end

  defp emit_builtin(:f64_bits, [x], node, _) do
    numeric!(x, arg(node, 0), "f64_bits/1")
    val("defk_f64_to_u64(#{to_f(x)})", :u64)
  end

  defp emit_builtin(f, [%{t: ta} = a, %{t: tb} = b], node, env)
       when f in [:div, :rem] and ta in @ints and tb in @ints do
    v = int_div(f, a, b, node, env)

    k = Facts.const(b)

    cond do
      f != :div or v.t != :i64 -> v
      is_integer(k) and k > 0 -> Facts.put(v, Facts.div_facts_of(a, k))
      # a case guard's zero divisor flags and computes on
      Map.has_key?(env, :bad) -> v
      true -> Facts.put(v, Facts.div_by_facts(a, b))
    end
  end

  defp emit_builtin(:float, [a], node, _),
    do:
      (
        numeric!(a, arg(node, 0), "float/1")
        val(to_f(a), :f64)
      )

  defp emit_builtin(f, [%{t: t} = a], _, _) when f in [:trunc, :round] and t in @ints, do: a

  defp emit_builtin(f, [%{t: :f64} = a], _, env) when f in [:trunc, :round],
    do: val("defk_#{f}#{checked(env)}, #{a.c})", :i64)

  defp emit_builtin(:abs, [%{t: :u64} = a], _, _), do: a

  defp emit_builtin(:abs, [%{t: :i64} = a], _, env),
    do: val("defk_abs_i64#{checked(env)}, #{a.c})", :i64)

  defp emit_builtin(:abs, [%{t: :f64} = a], _, _),
    do: Map.put(val("fabs(#{a.c})", :f64), :nonneg, true)

  defp emit_builtin(f, [%{t: ta} = a, %{t: tb} = b], node, _)
       when f in [:min, :max] and ta in @ints and tb in @ints do
    case int_pair!(a, b, node) do
      {:i64, a, b} ->
        Facts.put(val("defk_#{f}_i64(#{a.c}, #{b.c})", :i64), Facts.minmax_facts(f, a, b))

      {:u64, a, b} ->
        val("defk_#{f}_u64(#{a.c}, #{b.c})", :u64)
    end
  end

  # max(x, 0.0) is never below 0.0, and neither is the min of two such
  defp emit_builtin(f, [%{t: :f64} = a, %{t: :f64} = b], _, _) when f in [:min, :max] do
    nonneg = if f == :max, do: a[:nonneg] || b[:nonneg], else: a[:nonneg] && b[:nonneg]
    Map.put(val("defk_#{f}_f64(#{a.c}, #{b.c})", :f64), :nonneg, nonneg == true)
  end

  # sqrt of a value never below 0.0 cannot raise, and its result is finite
  # when the value is (a non-finite one was checked where it was made), so it
  # needs no check, also in a flagged strip
  defp emit_builtin(:sqrt, [%{t: :f64, nonneg: true} = a], _node, _),
    do: Map.put(val("__builtin_sqrt(#{a.c})", :f64), :nonneg, true)

  defp emit_builtin(f, [a], node, _) when f in @math1 do
    numeric!(a, arg(node, 0), "#{f}/1")

    c =
      if f in [:sqrt, :log, :log2, :log10, :exp],
        do: "defk_#{f}(ctx, #{to_f(a)})",
        else: "#{f}(#{to_f(a)})"

    val(c, :f64)
  end

  defp emit_builtin(:pow, [a, b], node, _) do
    numeric!(a, arg(node, 0), "pow/2")
    numeric!(b, arg(node, 1), "pow/2")
    val("defk_pow(ctx, #{to_f(a)}, #{to_f(b)})", :f64)
  end

  # length of a bitstring keeps its own rejection (the accumulator cannot be
  # measured mid-build)
  defp builtin(:length, [%{t: :bitstring}], node, _), do: bits_read!(node, arg(node, 0))

  defp builtin(name, vals, node, env) do
    case Defk.Builtins.typing(name, Enum.map(vals, & &1.t)) do
      {:ok, _result, coerce} ->
        emit_builtin(name, coerce_builtin(vals, coerce, node), node, env)

      _bespoke_or_no_row ->
        dispatch_call(name, vals, node, env)
    end
  end

  # The i64 coercions a row names, applied before emission with the row's
  # own argument label. An f64 coercion stays with the emitters (to_f/1
  # emits the same C it always has); the table still gates acceptance.
  defp coerce_builtin(vals, coerce, node) do
    Enum.reduce(coerce, vals, fn
      {i, :i64, label}, vals ->
        List.update_at(vals, i, &coerce!(&1, :i64, arg(node, i), label))

      {_i, :f64, _label}, vals ->
        vals
    end)
  end

  # a kernel-to-kernel call, or the rejection for a builtin given the wrong
  # arguments (the signature table said no row matches)
  defp dispatch_call(name, vals, node, env) do
    arity = length(vals)

    case Map.get(env.sigs, {name, arity}) do
      %{} = k ->
        inline(k, vals, node, env)

      nil ->
        cond do
          {name, arity} in ctx(:broken) -> throw(:defk_poison)
          Defk.Builtins.builtin?(name) -> builtin_arguments!(name, vals, node)
          true -> unknown_function!(name, vals, node, env)
        end
    end
  end

  defp arg({_, _, args}, i), do: Enum.at(args, i)

  @builtin_takes %{
    length: "an array",
    bit_size: "a bitstring",
    div: "two i64 values",
    rem: "two i64 values",
    float: "a number",
    trunc: "a number",
    round: "a number",
    abs: "a number",
    min: "two numbers of the same type",
    max: "two numbers of the same type",
    pow: "two numbers",
    sqrt: "a number",
    exp: "a number",
    log: "a number",
    log2: "a number",
    log10: "a number",
    sin: "a number",
    cos: "a number",
    band: "two integers",
    bor: "two integers",
    bxor: "two integers",
    bsl: "two integers",
    bsr: "two integers",
    bnot: "an integer",
    wrap64: "an integer",
    u64_le: "a [u8] array and an i64 byte offset",
    u64_be: "a [u8] array and an i64 byte offset",
    u32_le: "a [u8] array and an i64 byte offset",
    u32_be: "a [u8] array and an i64 byte offset",
    u16_le: "a [u8] array and an i64 byte offset",
    u16_be: "a [u8] array and an i64 byte offset",
    mulhi: "two i64 values",
    clz: "an integer",
    ctz: "an integer",
    popcount: "an integer",
    rotl: "an integer, an i64 count and an i64 width",
    rotr: "an integer, an i64 count and an i64 width",
    f64_bits: "a number",
    crc32c: "an integer crc, an integer word and an i64 width (8, 16, 32 or 64)",
    copy:
      "an array, an i64 index, a source array of the same element type, an i64 source index and an i64 length",
    copy_back: "an array, an i64 index, an i64 offset and an i64 length"
  }

  @spec builtin_arguments!(term(), term(), term()) :: no_return()
  defp builtin_arguments!(name, vals, {_, _, args} = node) do
    sig = Enum.map_join(vals, ", ", &fmt(&1.t))
    ts = Enum.map(vals, & &1.t)

    arity = takes_arity(name, vals)
    takes = "#{name}/#{arity} takes #{takes_what(name, arity) || @builtin_takes[name]}"

    err!(
      node,
      "builtin-arguments",
      "#{takes}, and is called here with (#{sig})",
      argument_fix(name, ts, args)
    )
  end

  # the arity a rejected builtin call is named with: the call's own where the
  # builtin takes two (clz/1 or clz/2, rotl/2 or rotl/3)
  defp takes_arity(f, vals) when f in [:clz, :ctz], do: if(match?([_, _], vals), do: 2, else: 1)
  defp takes_arity(f, vals) when f in [:rotl, :rotr], do: if(match?([_, _], vals), do: 2, else: 3)
  defp takes_arity(:copy, _vals), do: 5
  defp takes_arity(:copy_back, _vals), do: 4
  defp takes_arity(:crc32c, _vals), do: 3
  defp takes_arity(f, _vals) when f in [:div, :rem, :min, :max, :pow, :mulhi], do: 2
  defp takes_arity(:bnot, _vals), do: 1
  defp takes_arity(f, _vals) when f in @loads or f in @bitwise, do: 2
  defp takes_arity(_f, _vals), do: 1

  # what a builtin's other arity takes, where @builtin_takes names one
  defp takes_what(f, 2) when f in [:clz, :ctz], do: "an integer and an i64 width"
  defp takes_what(f, 2) when f in [:rotl, :rotr], do: "two i64 values"
  defp takes_what(_f, _arity), do: nil

  # A hint/rewrite pairing the mis-typed call off against the near variants.
  @spec argument_fix(term(), [atom()], [term()]) :: keyword()
  defp argument_fix(name, ts, args) do
    cond do
      name in [:div, :rem] and match?([_, _], ts) and Enum.all?(ts, &(&1 in [:i64, :f64])) ->
        conv =
          Enum.zip_with(args, ts, fn a, t -> if t == :f64, do: {:trunc, [], [a]}, else: a end)

        [
          hint: "convert the f64 arguments with trunc/1 or round/1, or use / for float division",
          rewrite: Macro.to_string({name, [], conv})
        ]

      name in [:min, :max] and Enum.sort(ts) == [:f64, :i64] ->
        conv =
          Enum.zip_with(args, ts, fn a, t -> if t == :i64, do: {:float, [], [a]}, else: a end)

        [
          hint: "convert the i64 argument with float/1",
          rewrite: Macro.to_string({name, [], conv})
        ]

      true ->
        []
    end
  end

  @spec unknown_function!(term(), term(), term(), term()) :: no_return()
  defp unknown_function!(name, vals, node, env) do
    arity = length(vals)
    others = for {{^name, a}, _} <- env.sigs, do: "#{name}/#{a}"

    what =
      case others do
        [] ->
          "undefined function #{name}/#{arity}"

        _ ->
          "undefined function #{name}/#{arity}; this module has the kernel #{Enum.join(others, " and ")}"
      end

    err!(node, "undefined-function", what)
  end

  # A call to another kernel is lowered as the callee's body, inlined into the
  # caller with the arguments bound to its parameters. Its loops nest in the
  # caller's loops, so their safepoints spill and resume with the caller's
  # frame, and a long loop in a callee (several calls deep) yields like one in
  # the caller. A separately compiled callee would need its own frame and a
  # resume path into the middle of the caller's loop body. The
  # arguments keep their range facts, so the callee may drop bounds checks a
  # standalone kernel needs. Code size grows with the number of call sites
  # along each call chain; recursion is rejected, so inlining terminates.
  defp inline(k, vals, {_, _, args} = node, env) do
    key = {k.name, k.arity}
    key in env.inlining && recursion!(key, node, env)
    note(:inline, node, :inlined, "#{k.name}/#{k.arity}")

    # bind each argument to a parameter once, as `p = arg` binds it
    {binds, vars} =
      Enum.zip_with([vals, k.params, args], fn [v, {p, t}, a] ->
        (v.t == :bitstring and t != :bitstring) && bits_argument!(a, k, p, t)
        v = coerce!(v, t, a, "argument #{p} of #{k.name}/#{k.arity}")

        if match?({:arr, _}, t) do
          {s, b} = array_binding(p, v, 1)
          {s, {p, b}}
        else
          c = fresh(p, t)

          srec_assign(c, v.c)
          {"#{c} = #{v.c};\n", {p, %{c: c, t: t, owned: false, var: c, facts: Facts.bound(v)}}}
        end
      end)
      |> Enum.unzip()

    # the bindings the caller still reads after the call stay live in the callee
    outer = MapSet.union(env.live, pairs(env, Copies.reads_outside(env.stmt, node)))

    # scope/1 takes the empty set at both call sites (dialyzer treats a
    # MapSet built by union as opaque and the literal as structural); the
    # caller's live sets are merged in afterwards. The parameters' facts may
    # name the caller's atoms, which stay in scope in the inlined body
    # (env.atoms, see put_var/3).
    atoms =
      for {_, %{t: :i64, c: c} = b} <- vars, into: env[:atoms] || %{}, do: {c, Facts.facts(b)}

    cenv =
      %{vars: Map.new(vars), atoms: atoms, sigs: env.sigs, inlining: [key | env.inlining]}
      |> Map.merge(scope(MapSet.new()))
      |> Map.merge(%{out: outer, nest: outer, live: outer})

    params = for {p, {:arr, _}} <- k.params, do: {p, cenv.vars[p].id}

    # the callee's rejections are reported in the callee
    {sb, rets} =
      in_kernel(k, fn ->
        {prev, st} = Copies.swap_writes(copies(), [])
        copies_put(st)

        try do
          {sb, v} = lower_block(k.body, cenv)
          {[], ret} = coerce_return(v, k)
          unreturned_writes!(k, params, Map.get(v, :elems, [v]))
          {sb, Enum.zip(ret, Map.get(v, :elems, [v]))}
        after
          {_, st2} = Copies.swap_writes(copies(), prev)
          copies_put(st2)
        end
      end)

    # temporaries, so the result is computed here and not where it is used; a
    # returned array keeps its buffer, which may be an argument's, and its
    # constant length bound (len_lo; len_lb names the callee's C variables)
    {ss, results} =
      Enum.map(rets, fn {{c, t}, v} ->
        tmp = fresh("#{k.name}_ret", t)
        # an array the callee returns unwritten is still the argument's
        r = %{val(tmp, t, tmp) | owned: not match?({:arr, _}, t) or v.owned}

        r =
          if match?({:arr, _}, t),
            do:
              r
              |> Map.merge(%{buf: v[:buf] || make_ref(), fin: v[:fin] || false})
              |> Facts.assert(len_lo: Facts.len_lo(v)),
            else: r

        srec_assign(tmp, c)
        {"#{tmp} = #{c};\n", r}
      end)
      |> Enum.unzip()

    result =
      case {k.ret, results} do
        {{:tuple, ts}, elems} -> %{t: {:tuple, ts}, elems: elems}
        {_, [r]} -> r
      end

    {[binds, sb, ss], result}
  end

  defp in_kernel(k, fun) do
    prev = {ctx(:fun), ctx(:where)}
    ctx_put(:fun, {k.name, k.arity})
    ctx_put(:where, k.head)

    try do
      fun.()
    after
      {f, c} = prev
      ctx_put(:fun, f)
      ctx_put(:where, c)
    end
  end

  # `node` calls `key`, which is being inlined already: env.inlining is the
  # chain of kernels being inlined, innermost first
  @spec recursion!(term(), term(), term()) :: no_return()
  defp recursion!({name, arity} = key, node, env) do
    cycle = Enum.take_while(env.inlining, &(&1 != key))
    through = Enum.map_join(Enum.reverse(cycle), " and ", fn {n, a} -> "#{n}/#{a}" end)
    via = if cycle == [], do: "", else: " through #{through}"
    what = "#{name}/#{arity} calls itself#{via}, and recursion is not in the kernel subset"

    err!(node, "recursion", what,
      hint:
        "write the recursion as a loop: for ..., reduce: for a fold, Enum.reduce_while/3 to stop early",
      key: {:recursion, MapSet.new([key | cycle])}
    )
  end

  # ------------------------------------------------------- alloc zeroing --
  # alloc/2 gives zeros, as in Elixir mode, but one memset of a large buffer
  # held the scheduler (85 MB: ~5 ms cold) before the kernel's first loop.
  # So an alloc is zeroed one of three ways:
  #   * not at all, when the next statement provably writes every element
  #     before anything reads it (unzeroed_allocs/1)
  #   * at once (defk_alloc_T), when its length is known to be at most
  #     @zero_at_once bytes, or the kernel has yield: false
  #   * otherwise in strips of DEFK_ZERO_STRIP bytes with a safepoint after
  #     each: a loop like any other, whose frame state is the array and the
  #     bytes zeroed so far (fresh frame variables, spilled at a yield)
  @zero_at_once 4096
  @elem_bytes %{f64: 8, i64: 8, u64: 8, u8: 1, i16: 2, i32: 4, f32: 4}

  defp alloc_zeroed(e, v, {:alloc, m, _} = node, env) do
    {{_, _}, yield?} = low(:report_kernel)
    hi = Facts.hi(v)

    cond do
      unzeroed = m[:defk_unzeroed] ->
        unzeroed_alloc(e, v, node, unzeroed, yield?, env)

      is_integer(hi) and hi * @elem_bytes[e] <= @zero_at_once ->
        note(:alloc, node, :zeroed, "zeroed at once (at most #{@zero_at_once} bytes)")
        {[], "defk_alloc_#{e}(ctx, #{v.c})"}

      not yield? ->
        note(:alloc, node, :zeroed, "zeroed at once (yield: false)")
        {[], "defk_alloc_#{e}(ctx, #{v.c})"}

      true ->
        note(
          :alloc,
          node,
          :strips,
          "zeroed in strips of DEFK_ZERO_STRIP bytes, a safepoint per strip"
        )

        a = fresh("alloc", {:arr, e})
        z = fresh("zeroed", {:c, "uint64_t"})
        bytes = "(uint64_t)#{a}.len * sizeof(*#{a}.data)"

        zero =
          in_loop(fn id ->
            [
              "#{a} = defk_alloc_raw_#{e}(ctx, #{v.c});\n#{z} = 0;\n",
              "defk_l#{id}:;\nwhile (#{z} < #{bytes}) {\n",
              "uint64_t defk_z0 = #{z};\n",
              "#{z} = defk_zero_strip(#{a}.data, #{bytes}, #{z});\n",
              safepoint("DEFK_ZERO_TICKS(#{z} - defk_z0)"),
              "}\n"
            ]
          end)

        {zero, a}
    end
  end

  # An alloc the next loop writes in full (unzeroed_allocs/1). The strided
  # form (extents []) needs nothing more: a negative length raises. The
  # nested form's extents may be negative with a positive product (two of
  # them): no trip writes then, so the buffer is zeroed when any extent is
  # negative, a test that is false for every array the loop writes.
  defp unzeroed_alloc(e, v, node, {at, []}, _yield?, _env) do
    note(
      :alloc,
      node,
      :unzeroed,
      "not zeroed: the loop on #{line_from(at, node)} writes every element first"
    )

    {[], "defk_alloc_raw_#{e}(ctx, #{v.c})"}
  end

  defp unzeroed_alloc(e, v, node, {at, extents}, yield?, env) do
    note(
      :alloc,
      node,
      :unzeroed,
      "not zeroed: the loops on #{line_from(at, node)} write every element first (zeroed only if an extent is negative)"
    )

    {ss, vs} = extents |> Enum.map(&lower_expr(&1, env)) |> Enum.unzip()
    negative = Enum.map_join(vs, " || ", &"(#{&1.c}) < 0")
    a = fresh("alloc", {:arr, e})
    bytes = "(uint64_t)#{a}.len * sizeof(*#{a}.data)"

    zero =
      if yield? do
        z = fresh("zeroed", {:c, "uint64_t"})

        in_loop(fn id ->
          [
            "#{z} = 0;\ndefk_l#{id}:;\nwhile (#{z} < #{bytes}) {\n",
            "uint64_t defk_z0 = #{z};\n",
            "#{z} = defk_zero_strip(#{a}.data, #{bytes}, #{z});\n",
            safepoint("DEFK_ZERO_TICKS(#{z} - defk_z0)"),
            "}\n"
          ]
        end)
      else
        "memset(#{a}.data, 0, (size_t)(#{bytes}));\n"
      end

    {[ss, "#{a} = defk_alloc_raw_#{e}(ctx, #{v.c});\nif (#{negative}) {\n", zero, "}\n"], a}
  end

  # ---------------------------------------------------------- range copies --
  # copy(out, at, src, from, n) and copy_back(out, at, off, n) give `out`
  # with a range replaced, as a kernel that writes and returns
  # its array parameter would: the buffer is written in place when it is the
  # kernel's own and no other binding of it is read after the call (what
  # inline/4 takes as live for a callee), and copied first otherwise. One
  # check covers the range. A copy of at most DEFK_COPY_STRIP bytes runs at
  # once and is charged to the budget like a loop over its bytes; a longer
  # one runs in strips with a safepoint after each, as alloc/2's zeroing does,
  # unless the kernel has yield: false or the length is known to be short.
  @copy_at_once 1024 * 1024

  defp range_copy(f, a, s, ints, node, env) do
    {:arr, e} = a.t
    {sv, [at, x, n]} = Enum.map_reduce(ints, [], &bind_tmp/2)
    {sd, d} = range_dest(a, node, env)
    dst = fresh("copy", a.t)

    {ss, src} =
      cond do
        s == nil -> {[], nil}
        s[:var] -> {[], s.c}
        true -> with {st, [c]} <- bind_tmp(s, []), do: {st, c}
      end

    {{_, _}, yield?} = low(:report_kernel)
    hi = Facts.hi(Enum.at(ints, 2))
    once? = not yield? or (is_integer(hi) and hi * @elem_bytes[e] <= @copy_at_once)
    k = fresh("copied", {:c, "int64_t"})
    args = if f == :copy, do: "#{at}, #{src}, #{x}, #{n}", else: "#{at}, #{x}, #{n}"
    call = "#{k} = defk_r#{f}_#{e}(ctx, #{dst}, #{args}, #{if once?, do: 1, else: 0});\n"
    ticks = "DEFK_TICKS(DEFK_ZERO_TICKS(#{k}))\n"

    run =
      if once?,
        do: [call, ticks],
        else: [
          call,
          "if (DEFK_LIKELY(#{k} >= 0)) {\n",
          ticks,
          "} else {\n",
          copy_strips(f, dst, at, src, x, n),
          "}\n"
        ]

    what = Macro.to_string(node)

    note(
      :bounds,
      node,
      :kept,
      "#{what}: one range check for the whole copy" <>
        if(once?,
          do: "",
          else: "; over DEFK_COPY_STRIP bytes it runs in strips, a safepoint after each"
        )
    )

    fin = (d[:fin] || false) and (s == nil or s[:fin] == true)
    r = %{val(dst, a.t, dst) | owned: true}

    {[sv, ss, sd, "#{dst} = #{d.c};\n", run],
     Facts.assert(Map.merge(r, %{buf: d[:buf] || make_ref(), fin: fin}), len_lo: Facts.len_lo(a))}
  end

  # a value in a fresh local of its own (an argument the strip loop reads
  # after a yield)
  defp bind_tmp(v, acc) do
    c = fresh("arg", v.t)
    srec_assign(c, v.c)
    {"#{c} = #{v.c};\n", acc ++ [c]}
  end

  # the array a range copy writes: `a`'s buffer, or a copy of it when another
  # binding may see that buffer after the call or it is not the kernel's own
  defp range_dest(a, {name, _, args} = node, env) do
    outer = MapSet.union(env.live, pairs(env, Copies.reads_outside(env.stmt, node)))

    if a.owned and not Copies.shared?(copies(), Map.put(a, :id, make_ref()), outer) do
      {[], a}
    else
      {s, b} = copied(Map.put(a, :var, nil), "#{name}")

      note(
        :copy,
        node,
        :copied,
        "the array is copied before #{name}/#{length(args)}: #{copy_why(a)}"
      )

      {s, b}
    end
  end

  # a long copy in strips of DEFK_COPY_STRIP bytes, a safepoint after each: a
  # loop whose frame state is its arguments and the bytes done
  defp copy_strips(f, dst, at, src, x, n) do
    done = fresh("done", {:c, "uint64_t"})
    bytes = "(uint64_t)#{n} * sizeof(*#{dst}.data)"
    d = "(uint8_t *)(#{dst}.data + #{at})"

    step =
      if f == :copy,
        do: "defk_move_strip(#{d}, (const uint8_t *)(#{src}.data + #{x}), #{bytes}, #{done})",
        else: "defk_back_strip(#{d}, (uint64_t)#{x} * sizeof(*#{dst}.data), #{bytes}, #{done})"

    in_loop(fn id ->
      [
        "#{done} = 0;\n",
        "defk_l#{id}:;\nwhile (#{done} < #{bytes}) {\n",
        "uint64_t defk_z0 = #{done};\n",
        "#{done} = #{step};\n",
        safepoint("DEFK_ZERO_TICKS(#{done} - defk_z0)"),
        "}\n"
      ]
    end)
  end

  # The statements `es` of a block, each `x = alloc(e, len)` marked (meta
  # :defk_unzeroed, the loop's line) when a later statement writes every
  # element of x before anything reads it. Only one form is accepted:
  #
  #     x = alloc(e, k * n)              # or alloc(e, n), k = 1
  #     ...                              # statements that do not mention x
  #     for i <- 0..(n - 1)//1 do        # or 0..(n - 1); length(x) - 1 for k = 1
  #       ...
  #       x[k * i + c] = v               # for each c in 0..k-1 exactly once
  #       ...
  #     end
  #
  # where the statements in between do not mention x and bind no variable of
  # n (so the range's n is the alloc's), the writes are statements of the
  # loop body itself (not in a branch), x is not otherwise mentioned in the
  # body (no read, no alias, no length/1), n does not mention x, and nothing in
  # the body binds i (so each write's i is the loop's). Then each trip i
  # writes k * i .. k * i + k - 1, and the trips 0..n-1 write all k * n
  # elements; nothing reads x until the loop is done. Every way out before
  # that is a raise, which frees the buffer, and a yield resumes where it
  # left off with x unread, so no unwritten element is ever seen. With
  # `0..(n - 1)` (step -1 when n < 1) a trip writes x[0] first, which raises
  # for n < 1 (k * n < k). Anything else is zeroed.
  defp unzeroed_allocs(es) do
    es
    |> Enum.with_index(1)
    |> Enum.map(fn {e, j} ->
      case {e, unzeroed_by(e, Enum.drop(es, j))} do
        {{:=, m, [x, {:alloc, am, args}]}, {_, _} = unzeroed} ->
          {:=, m, [x, {:alloc, [{:defk_unzeroed, unzeroed} | am], args}]}

        _ ->
          e
      end
    end)
  end

  # {line, extents} of the loop in `rest` (the statements after the alloc
  # `e`) that writes every element of e's array first, or nil; the extents
  # are those of a nested form (nested_all?/3), [] for the strided one
  defp unzeroed_by({:=, _, [{x, _, xc}, {:alloc, _, [{_, _, ec}, len]}]}, rest)
       when is_atom(x) and is_atom(xc) and is_atom(ec) do
    {between, from} = Enum.split_while(rest, &(not mentions?(&1, x)))
    len_vars = vars(len)

    with [loop | _] <- from,
         false <- Enum.any?(between, fn s -> Enum.any?(len_vars, &binds?(s, &1)) end) do
      writes_all(loop, x, len)
    else
      _ -> nil
    end
  end

  defp unzeroed_by(_e, _rest), do: nil

  # the line of `loop` if it writes all of x: the strided single loop above,
  # plain or `reduce:` (the loop may be the right side of a match whose left
  # side does not mention x, as `{h, t} = for ..., reduce: {h, t}`), or a
  # nest of range loops writing a row-major index (nested_all?/3)
  defp writes_all({:=, _, [lhs, {:for, _, _} = loop]}, x, len) do
    if mentions?(lhs, x), do: nil, else: writes_all(loop, x, len)
  end

  defp writes_all({:for, fm, args} = loop, x, len) do
    with {:ok, gens, [], init, pat, body} <- loop_parts(args),
         false <- mentions?(len, x) or mentions?(init, x) or mentions?(pat, x),
         {:ok, extents} <-
           if(strided_all?(gens, pat, body, x, len),
             do: {:ok, []},
             else: nested_all?(loop, x, len)
           ) do
      {meta_line(fm) || 0, extents}
    else
      _ -> nil
    end
  end

  defp writes_all(_loop, _x, _len), do: nil

  # {:ok, generators, filters, init, pattern, body statements} of a for's
  # arguments: a plain `do:` (init and pattern nil) or a `reduce:` with one
  # clause whose pattern is bound per trip. A generator binds a plain
  # variable; anything else among the qualifiers is a filter here.
  defp loop_parts(args) do
    # `reduce: init` is a keyword list of its own, before the do block's
    {quals, opts} = Enum.split_with(args, &(not Keyword.keyword?(&1)))
    opts = Enum.concat(opts)

    {gens, filters} =
      Enum.split_with(quals, &match?({:<-, _, [{v, _, c}, _]} when is_atom(v) and is_atom(c), &1))

    case {Enum.sort(Keyword.keys(opts)), opts[:do]} do
      {[:do], body} ->
        {:ok, gens, filters, nil, nil, block_stmts(body)}

      {[:do, :reduce], [{:->, _, [[pat], body]}]} ->
        {:ok, gens, filters, opts[:reduce], pat, block_stmts(body)}

      _ ->
        :error
    end
  end

  defp block_stmts({:__block__, _, ss}), do: ss
  defp block_stmts(s), do: [s]

  # one generator over 0..(n - 1)//1 whose body writes x[k * i + c] for every
  # c in 0..k-1 at its top level and mentions x nowhere else (for a reduce:
  # the clause pattern binds neither x nor i; the fold's value may be
  # anything, as the writes are statements of the clause body, which runs
  # every trip)
  defp strided_all?([{:<-, _, [{i, _, _}, range]}], pat, body, x, len) when i != x do
    {k, n} =
      case len do
        {:*, _, [k, n]} when is_integer(k) and k >= 1 -> {k, n}
        n -> {1, n}
      end

    cs = for s <- body, c = unzeroed_write(s, x, i, k), do: c

    zero_based_to(range, n, x, k) and Enum.sort(cs) == Enum.to_list(0..(k - 1)) and
      count_var(body, x) == k and not binds?(body, i) and not mentions?(pat, i)
  end

  defp strided_all?(_gens, _pat, _body, _x, _len), do: false

  # Nested range loops: at every level `for v <- 0..(n - 1)//1` (several
  # generators in one for are successive levels), the inner for a statement
  # of the outer body, and the innermost body writing
  # x[((v1 * n2 + v2) * n3 + v3) ...] once, as a statement of its own. The
  # alloc's length is the product of the extents, in any order. Every trip
  # writes one element, the trips write the elements 0..n1*...*nm-1 each
  # once (an extent of 0 makes both empty; a negative one makes the alloc
  # raise), nothing else in the nest mentions x, and no body binds a loop
  # variable or a variable of the length, so the extents are the alloc's.
  defp nested_all?(loop, x, len) do
    with {:ok, levels, body} <- nest_levels(loop, x, len, []),
         extents = Enum.map(levels, &elem(&1, 1)),
         true <- permutation?(product_factors(len), extents),
         [idx] <-
           for(
             {:=, _, [{{:., _, [Access, :get]}, _, [{^x, _, c}, idx]}, _]} <- body,
             is_atom(c),
             do: idx
           ),
         true <- row_major?(idx, levels) and count_var(loop, x) == 1 do
      {:ok, extents}
    else
      _ -> :error
    end
  end

  # {:ok, [{var, extent}] outermost first, innermost body statements}
  defp nest_levels({:for, _, args}, x, len, acc) do
    with {:ok, gens, [], nil, nil, body} <- loop_parts(args),
         {:ok, vars} <- level_vars(gens, x),
         levels = acc ++ vars,
         names = Enum.map(levels, &elem(&1, 0)),
         true <- Enum.uniq(names) == names,
         false <- Enum.any?(names ++ MapSet.to_list(vars(len)), &binds?(body, &1)) do
      case Enum.split_with(body, &match?({:for, _, _}, &1)) do
        {[inner], others} ->
          if mentions?(others, x), do: :error, else: nest_levels(inner, x, len, levels)

        {[], _} ->
          {:ok, levels, body}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp level_vars(gens, x) do
    vars =
      for {:<-, _, [{v, _, _}, {:..//, _, [0, {:-, _, [n, 1]}, 1]}]} <- gens,
          v != x and not mentions?(n, x),
          do: {v, n}

    if length(vars) == length(gens), do: {:ok, vars}, else: :error
  end

  # idx is the row-major index of the levels' variables with their extents
  defp row_major?({v, _, c}, [{v, _}]) when is_atom(c), do: true

  defp row_major?({:+, _, [{:*, _, [inner, n]}, {v, _, c}]}, levels) when is_atom(c) do
    case List.pop_at(levels, -1) do
      {{^v, extent}, outer} when outer != [] -> same_ast?(n, extent) and row_major?(inner, outer)
      _ -> false
    end
  end

  defp row_major?(_idx, _levels), do: false

  defp product_factors({:*, _, [a, b]}), do: product_factors(a) ++ product_factors(b)
  defp product_factors(t), do: [t]

  # the same terms, in any order
  defp permutation?(as, bs) when length(as) == length(bs) do
    Enum.reduce_while(bs, as, fn b, rest ->
      case Enum.find_index(rest, &same_ast?(&1, b)) do
        nil -> {:halt, :no}
        i -> {:cont, List.delete_at(rest, i)}
      end
    end) == []
  end

  defp permutation?(_as, _bs), do: false

  # `range` is 0..(n - 1)//1 or 0..(n - 1), or for k = 1 also with length(x) - 1
  defp zero_based_to({:..//, _, [0, stop, 1]}, n, x, k), do: stop_at(stop, n, x, k)
  defp zero_based_to({:.., _, [0, stop]}, n, x, k), do: stop_at(stop, n, x, k)
  defp zero_based_to(_range, _n, _x, _k), do: false

  defp stop_at({:-, _, [m, 1]}, n, x, k) do
    same_ast?(m, n) or (k == 1 and match?({:length, _, [{^x, _, c}]} when is_atom(c), m))
  end

  defp stop_at(_stop, _n, _x, _k), do: false

  # c when `s` is x[k * i + c] = v (x[i] = v for k = 1, x[k * i] for c = 0)
  defp unzeroed_write({:=, _, [{{:., _, [Access, :get]}, _, [{x, _, xc}, idx]}, _]}, x, i, k)
       when is_atom(xc) do
    case idx do
      {^i, _, c} when is_atom(c) and k == 1 -> 0
      {:*, _, [^k, {^i, _, c}]} when is_atom(c) -> 0
      {:+, _, [{:*, _, [^k, {^i, _, c}]}, d]} when is_atom(c) and is_integer(d) -> d
      _ -> nil
    end
  end

  defp unzeroed_write(_s, _x, _i, _k), do: nil

  defp same_ast?(a, b), do: strip_meta(a) == strip_meta(b)
  defp strip_meta(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _ -> [] end))

  defp mentions?(ast, x), do: count_var(ast, x) > 0

  defp vars(ast) do
    {_, vs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {v, _, c} = t, vs when is_atom(v) and is_atom(c) -> {t, MapSet.put(vs, v)}
        t, vs -> {t, vs}
      end)

    vs
  end

  defp count_var(ast, x) do
    {_, n} =
      Macro.prewalk(ast, 0, fn
        {^x, _, c} = v, n when is_atom(c) -> {v, n + 1}
        t, n -> {t, n}
      end)

    n
  end

  # whether anything in `ast` binds a variable named `i`: a match (other than
  # an array write), a generator, or a clause pattern (case, reduce arms)
  defp binds?(ast, i) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:=, _, [{{:., _, [Access, :get]}, _, _}, _]} = t, f -> {t, f}
        {:=, _, [lhs, _]} = t, f -> {t, f or mentions?(lhs, i)}
        {:<-, _, [pat, _]} = t, f -> {t, f or mentions?(pat, i)}
        {:->, _, [pats, _]} = t, f -> {t, f or mentions?(pats, i)}
        t, f -> {t, f}
      end)

    found
  end

  # ----------------------------------------------------------- bitstrings --
  # The bitstring accumulator (Defk.Bitstring): a value of type
  # :bitstring is a defk_bits {nbits, slot + 1} over a growable owned buffer
  # (priv/defk_runtime.h), kept in the frame across yields like any local.
  # `<<acc::bitstring, v::size(n), ...>>` evaluates acc and then every value
  # and size left to right, as Elixir does, and appends the segments in order;
  # each append checks 0 <= n <= 64 and 0 <= v < 2^n, or -2^(n-1) <= v <
  # 2^(n-1) for a signed segment (a limit: Elixir keeps the low n bits). A value is never changed by a
  # later append: the runtime appends in place only to a value that ends where its buffer ends, and
  # copies an older value first. The empty binary literal `<<>>` is a [u8]
  # marked bits0, and becomes the empty bitstring where it is bound to a name
  # the kernel appends to, returned or assigned as a bitstring, or given by a
  # branch whose other arms give one.

  defp lower_append(node, head, parts, env) do
    {sh, h} = lower_expr(head, env)
    h = if h[:bits0], do: empty_bits(), else: h
    h.t == :bitstring || bits_head!(node, head, h)
    r = fresh("bits", :bitstring)

    {ss, args} =
      Enum.map_reduce(parts, [], fn {v_ast, n_ast, signed}, acc ->
        {sv, v} = lower_expr(v_ast, env)
        # an unsigned segment takes a u64 as it is (2^63 and up included)
        t = if v.t == :u64 and not signed, do: :u64, else: :i64
        v = coerce!(v, t, v_ast, "a bitstring segment value")
        {sn, n} = lower_expr(n_ast, env)
        n = coerce!(n, :i64, n_ast, "a bitstring segment size")
        tv = fresh("seg", t)
        {sn, nc} = segment_size(sn, n, n_ast)
        {[sv, "#{tv} = #{v.c};\n", sn], [{tv, nc, signed, t} | acc]}
      end)

    puts =
      for {tv, nc, signed, t} <- Enum.reverse(args) do
        put =
          cond do
            signed -> "defk_bits_put_signed"
            t == :u64 -> "defk_bits_put_u64"
            true -> "defk_bits_put"
          end

        "#{r} = #{put}(ctx, #{r}, #{tv}, #{nc});\n"
      end

    {[sh, "#{r} = #{h.c};\n", ss, puts], val(r, :bitstring, r)}
  end

  # a literal size is used as it is; any other is evaluated in its place
  defp segment_size(_sn, n, n_ast) when is_integer(n_ast), do: {[], n.c}

  defp segment_size(sn, n, _n_ast) do
    tn = fresh("size", :i64)
    {[sn, "#{tn} = #{n.c};\n"], tn}
  end

  defp binary_literal(node, segs) do
    case Defk.BinaryLiteral.bytes(node) do
      # `<<>>` may be the empty bitstring
      {:ok, ""} when segs == [] ->
        {[], Map.put(static_u8(""), :bits0, true)}

      {:ok, b} ->
        {[], static_u8(b)}

      {:error, why, opts} ->
        err!(node, "binary-literal", Defk.BinaryLiteral.message(node, why), opts)
    end
  end

  defp empty_bits, do: val("((defk_bits){0, 0})", :bitstring)

  # the names the current kernel appends to (Defk.Bitstring.accumulator_names/1)
  defp bits_names,
    do: Map.get(ctx(:bits_names), ctx(:fun), MapSet.new())

  # the initial value `v` of accumulator pattern `p`
  defp bits_init({n, _, ctx}, %{bits0: true} = v) when is_atom(n) and is_atom(ctx),
    do: if(n in bits_names(), do: empty_bits(), else: v)

  defp bits_init(_p, v), do: v

  # the arms of a branch: `<<>>` beside a bitstring arm is the empty bitstring
  defp bits_arms(arms) do
    if Enum.any?(arms, &match?({_, _, _, _, %{t: :bitstring}}, &1)) do
      Enum.map(arms, fn
        {c, body, cond, sb, %{bits0: true}} -> {c, body, cond, sb, empty_bits()}
        arm -> arm
      end)
    else
      arms
    end
  end

  @spec bits_head!(term(), term(), term()) :: no_return()
  defp bits_head!(node, head, %{t: {:arr, :u8}}) do
    err!(
      head,
      "bitstring-use",
      "#{Macro.to_string(node)} appends to #{Macro.to_string(head)}, a [u8]: starting from an input bitstring is not supported yet",
      why: "a bitstring accumulator starts from <<>> and is only appended to",
      hint:
        "start from <<>> and append the bytes: for b <- #{Macro.to_string(head)}, reduce: <<>> do acc -> <<acc::bitstring, b>> end"
    )
  end

  defp bits_head!(_node, head, h) do
    err!(
      head,
      "type-mismatch",
      "#{Macro.to_string(head)} is appended to as a bitstring, and has type #{type_name(h)}"
    )
  end

  # `node` reads bitstring `bits`
  @spec bits_read!(term(), term()) :: no_return()
  defp bits_read!(node, bits) do
    hint =
      if match?({:length, _, [_]}, node),
        do: [rewrite: "bit_size(#{Macro.to_string(bits)})"],
        else: [hint: "keep what the kernel needs to read in variables or an array as it appends"]

    err!(
      node,
      "bitstring-use",
      "#{Macro.to_string(node)} reads the bitstring #{Macro.to_string(bits)}: reading a bitstring accumulator is not supported yet (bit_size/1 measures it)",
      hint
    )
  end

  @spec bits_argument!(term(), term(), atom(), term()) :: no_return()
  defp bits_argument!(a, k, p, t) do
    err!(
      a,
      "bitstring-use",
      "passing the bitstring #{Macro.to_string(a)} to #{k.name}/#{k.arity} as #{p} :: #{fmt(t)} is not supported: a bitstring is not read",
      hint:
        "declare the parameter #{p} :: bitstring to append to it in #{k.name}/#{k.arity}, and return it"
    )
  end

  # ---------------------------------------------------------------- loops --

  # `node` is the whole for
  defp parse_for(args, node, env) do
    {kws, quals} = Enum.split_with(args, &(is_list(&1) and Keyword.keyword?(&1)))
    opts = Enum.concat(kws)

    for k <- Keyword.keys(opts), k not in [:do, :reduce] do
      if k == :into,
        do:
          for_collect!(
            node,
            quals,
            opts[:do],
            opts[:into],
            env,
            "for ..., into: is not in the kernel subset"
          ),
        else: err!(node, "for-option", "for ..., #{k}: is not in the kernel subset")
    end

    case quals do
      [{:<-, _, _} | _] ->
        :ok

      [{:<<>>, _, [{:<-, _, [x, bin]}]} = gen | _] ->
        err!(
          gen,
          "generator-pattern",
          "the bitstring generator #{Macro.to_string(gen)} is not in the kernel subset",
          hint: "walk the bytes as a [u8] array",
          rewrite: "#{Macro.to_string(x)} <- #{Macro.to_string(bin)}"
        )

      _ ->
        err!(node, "for-form", "this for has no generator")
    end

    body =
      Keyword.get(opts, :do) ||
        err!(node, "for-form", "this for has no do block",
          hint: "write the loop body in a do block"
        )

    case Keyword.fetch(opts, :reduce) do
      {:ok, init} -> {quals, {:reduce, init}, body}
      :error -> {quals, nil, body}
    end
  end

  # Nest generators/filters; `inner.(env)` emits the innermost body.
  defp lower_quals([], env, inner), do: inner.(env)

  defp lower_quals([{:<-, _, [pat, src]} = gen | rest], env, inner) do
    name =
      case pat do
        {n, _, ctx} when is_atom(n) and is_atom(ctx) -> n
        _ -> generator_pattern!(gen)
      end

    case src do
      {:.., _, [a, b]} -> range_loop(name, a, b, :auto, rest, env, inner, src)
      {:..//, _, [a, b, s]} -> range_loop(name, a, b, s, rest, env, inner, src)
      _ -> array_loop(name, src, rest, env, inner)
    end
  end

  defp lower_quals([filter | rest], env, inner) do
    {sc, c, rel} = lower_test(filter, env)
    inner = srec_arm(make_ref(), 0, fn -> lower_quals(rest, narrow(env, rel, true), inner) end)
    [sc, "if (#{c}) {\n", inner, "}\n"]
  end

  # `range` is the range expression
  defp range_loop(name, a, b, step, rest, env, inner, range) do
    {[sa, sb], [va, vb]} = in_order([lower_expr(a, env), lower_expr(b, env)], env, :stmt)
    va = coerce!(va, :i64, a, "range start")
    vb = coerce!(vb, :i64, b, "range end")
    i = fresh(name, :i64)
    e = fresh("stop", :i64)
    setup = [sa, sb, "#{i} = #{va.c};\n#{e} = #{vb.c};\n"]

    {setup, done, incr, iv, strip} =
      case literal_int(step) do
        k when is_integer(k) and k > 0 ->
          # counting up from a to b: in the body a <= i <= b
          iv = Facts.between(val(i, :i64), va, vb, Facts.lo(va), Facts.hi(vb))

          strip = %{
            done_at: &"#{i} > #{&1}",
            remaining: "((uint64_t)#{e} - (uint64_t)#{i}) / #{k}",
            step: k
          }

          {[setup, range_limit(i, e, k, vb)], "#{i} > #{e}", "#{i} += #{k};\n", iv, strip}

        k when is_integer(k) and k < 0 ->
          # counting down from a to b: in the body b <= i <= a
          iv = Facts.between(val(i, :i64), vb, va, Facts.lo(vb), Facts.hi(va))

          strip = %{
            done_at: &"#{i} < #{&1}",
            remaining: "((uint64_t)#{i} - (uint64_t)#{e}) / #{-k}",
            step: k
          }

          {[setup, range_limit(i, e, k, vb)], "#{i} < #{e}", "#{i} -= #{-k};\n", iv, strip}

        0 ->
          err!(range, "range-step", "the range #{Macro.to_string(range)} has step 0",
            rewrite: Macro.to_string({:..//, [], [a, b, 1]})
          )

        nil ->
          st = fresh("step", :i64)

          step_setup =
            if step == :auto do
              # Elixir semantics: a..b counts down when a > b (use a..b//1 for "maybe empty")
              "#{st} = (#{i} <= #{e}) ? 1 : -1;\n"
            else
              {ss, vs} = lower_expr(step, env)
              vs = coerce!(vs, :i64, step, "range step")

              [
                ss,
                "#{st} = #{vs.c};\n",
                "if (#{st} == 0) defk_fail(ctx, DEFK_E_ARG, #{Defk.Messages.c_literal(:range_step_zero)});\n"
              ]
            end

          {[setup, step_setup, range_limit(i, e, st, vb)],
           "(#{st} > 0 ? #{i} > #{e} : #{i} < #{e})", "#{i} += #{st};\n", val(i, :i64), nil}
      end

    env = put_var(env, name, iv) |> nonempty(step, va, vb)

    in_loop(fn id ->
      {rows, {body, flat?}} =
        srec_rows(fn ->
          res = lower_quals_tracked(rest, env, inner)
          srec_assign(i, "#{i} + step")
          res
        end)

      strip = strip && Map.merge(strip, %{var: i, stop: e})
      loop_at(range)
      [setup, loop(id, done, strip, flat?, [body, incr], rows)]
    end)
  end

  # The body of a range with a literal step runs only when the range is not
  # empty: start <= stop counting up, start >= stop counting down. The
  # bounds are computed before the loop, never in a strip, so a checked
  # one narrows too.
  defp nonempty(env, step, va, vb) do
    case literal_int(step) do
      k when is_integer(k) and k > 0 -> narrow(env, Facts.relation(:<=, va, vb), true)
      k when is_integer(k) and k < 0 -> narrow(env, Facts.relation(:>=, va, vb), true)
      _ -> env
    end
  end

  # Stepping past the last element of a range that ends within one step of the
  # i64 limit would overflow i (C UB: in practice i wraps, the exit test never
  # passes, the loop hangs without a safepoint, and an index proven in range
  # from i is not). Such a range raises before the loop starts (a limit, even
  # when a reduce_while halt would end it earlier). The test, one compare,
  # is dropped when the facts on the end prove it far enough from the limit,
  # e.g. an end <= length(a) + d with d <= 0: arrays are shorter than 2^61
  # elements (DEFK_ALLOC_MAX_BYTES, and the largest binary).
  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF
  defp range_limit(i, e, k, vb) do
    near_limit =
      cond do
        is_integer(k) and k > 0 ->
          hi = Facts.hi_of(vb)
          if !(is_integer(hi) and hi <= @i64_max - k), do: "#{e} > INT64_C(#{@i64_max - k})"

        is_integer(k) ->
          lo = Facts.lo_of(vb)
          if !(is_integer(lo) and lo >= @i64_min - k), do: "#{e} < INT64_C(#{@i64_min - k})"

        true ->
          "(#{k} > 0 ? #{e} > INT64_MAX - #{k} : #{e} < INT64_MIN - #{k})"
      end

    if near_limit,
      do: "if (DEFK_UNLIKELY(#{near_limit})) defk_range_limit(ctx, #{i}, #{e}, #{k});\n",
      else: []
  end

  defp array_loop(name, src, rest, env, inner) do
    {s, a} = lower_expr(src, env)
    a.t == :bitstring && bits_read!({:<-, [], [{name, [], nil}, src]}, src)

    match?({:arr, _}, a.t) ||
      err!(
        src,
        "generator-source",
        "#{Macro.to_string(src)} is #{fmt(a.t)}, not a range or an array",
        if(a.t == :i64, do: [rewrite: "#{name} <- 0..(#{Macro.to_string(src)} - 1)//1"], else: [])
      )

    {:arr, e} = a.t

    # The generator walks the array as it is now. A variable written in the
    # loop that shares its buffer is copied before the loop, and the loop walks
    # the old buffer under a C local of its own; only an owned buffer can be
    # shared with a written variable (an input one was copied before the loop
    # statement, see hoist/3), so that local stays valid across a resume.
    # Iterating an input array while writing it copies it twice.
    {sw, env} = snapshot_writes(a, env)

    # reference the view by variable so it is re-bound after a resume
    {s, arr} =
      if a[:var] && sw == [] do
        {s, a.c}
      else
        tmp = fresh("arr", a.t)
        {[s, "#{tmp} = #{a.c};\n", sw], tmp}
      end

    k = fresh("k", :i64)
    x = fresh(name, wide(e))
    env = put_var(env, name, elem_val(x, e))

    # index is in range by construction: no bounds check
    in_loop(fn id ->
      read = widen("#{arr}.data[#{k}]", e)

      read =
        if e in [:f64, :f32] and not a[:fin], do: "defk_in_f64(ctx, #{read}, #{k})", else: read

      {rows, {body, flat?}} =
        srec_rows(fn ->
          srec_access(:index, arr, k, [])
          srec_assign(x, read)
          res = lower_quals_tracked(rest, env, inner)
          srec_assign(k, "#{k} + 1")
          res
        end)

      body = ["#{x} = #{read};\n", body, "#{k} += 1;\n"]

      strip = %{
        done_at: &"#{k} > #{&1}",
        remaining: "(uint64_t)(#{arr}.len - #{k} - 1)",
        step: 1,
        var: k,
        stop: "#{arr}.len - 1"
      }

      loop_at(src)
      [s, "#{k} = 0;\n", loop(id, "#{k} >= #{arr}.len", strip, flat?, body, rows)]
    end)
  end

  # Lower the rest of a loop and note whether that body is flat: no nested
  # loop, including one in an inlined kernel call, so one iteration costs a
  # bounded amount of work. flat :: false | :plain | :exits (a reduce_while
  # halt jumps out of it).
  defp lower_quals_tracked(rest, env, inner) do
    before = {low(:sp), low(:halts_emitted)}
    body = lower_quals(rest, env, inner)

    flat =
      case {before, {low(:sp), low(:halts_emitted)}} do
        {{sp, h}, {sp, h}} -> :plain
        {{sp, _}, {sp, _}} -> :exits
        _ -> false
      end

    {body, flat}
  end

  # The checked helpers a flagged strip turns into flags (DEFK_NF_ forms):
  # the float checks, which make a strip worth flagging, and the other checks
  # that may join them: i64/u64 overflow, element access, narrow
  # ------------------------------------------------------- strip record ---
  # What the lowering declares, as it emits, about the statements that may
  # end up inside a flat loop's strip: whole-variable assignments
  # with their right-hand side's C (so a float read, a float tree or a
  # scalar copy is recognisable from its row), addresses taken, raw element
  # accesses with their bounds proof's support (Defk.Facts.prove_in_bounds),
  # and float trees with their sticky leaves. Each row carries its position
  # (seq), the branch arms it sits under (path, outermost last) and whether
  # it sits in a conditional expression (cond). flag_strip/3 classifies from
  # these rows instead of re-parsing the C text it was handed. One
  # process-dictionary key: the defk_ prefix keeps with_acc_facts'
  # backtracking snapshot covering it; it now lives in the compiler context.

  defp srec_get, do: low(:strip)

  defp srec(row) do
    %{seq: seq, path: path, cond: cond?, rows: rows} = st = srec_get()
    row = Map.merge(row, %{seq: seq, path: path, cond: cond?})
    low_put(:strip, %{st | seq: seq + 1, rows: [row | rows]})
  end

  # the rows recorded while `fun` ran (oldest first), beside its result;
  # paths are relative to where `fun` started (the strip body's own arms)
  defp srec_rows(fun) do
    %{seq: first, path: entry} = srec_get()
    res = fun.()
    base = length(entry)

    rows =
      for r <- srec_get().rows, r.seq >= first do
        %{r | path: Enum.take(r.path, length(r.path) - base)}
      end

    {Enum.reverse(rows), res}
  end

  # run `fun` as arm `arm` of the branch `ref`: its rows run only when that
  # arm does
  defp srec_arm(ref, arm, fun) do
    st = srec_get()
    low_put(:strip, %{st | path: [{ref, arm} | st.path]})
    res = fun.()
    low_put(:strip, %{srec_get() | path: st.path})
    res
  end

  # drop branch frame `ref` from every row: a short-circuit right side that
  # turned out inline runs with its statement after all
  defp srec_drop_frame(ref) do
    st = srec_get()

    rows =
      Enum.map(st.rows, fn row ->
        %{row | path: Enum.reject(row.path, &match?({^ref, _}, &1))}
      end)

    low_put(:strip, %{st | rows: rows})
  end

  defp srec_assign(var, rhs) do
    srec(%{k: :assign, var: var, rhs: IO.iodata_to_binary([rhs])})
    :ok
  end

  defp srec_addr(var), do: srec(%{k: :addr, var: var})

  # a raw (proof-dropped) element access, read or write; kind :index for
  # (a).data[i], :load for a word load's (a).data + i
  defp srec_access(kind, arr, idx, support),
    do: srec(%{k: :access, access: kind, arr: arr, idx: idx, support: support})

  defp srec_proven(kind, a, i, {:proven, support}),
    do: srec_access(kind, a.c, i.c, support)

  defp srec_ftree(f, anchor, leaves),
    do: srec(%{k: :ftree, f: f, anchor: anchor, leaves: leaves})

  # write ranges and float-to-integer conversions.
  @nf_helpers ~w(fadd fsub fmul fdiv in_f64 sqrt log log2 log10 exp pow to_f32)
  @nf_joins ~w(add_i64 sub_i64 mul_i64 neg_i64 abs_i64 add_u64 sub_u64 mul_u64 trunc round
               get_in_f64 to_u8 to_i16 to_i32) ++
              for(t <- ~w(f64 i64 u8 u64 i16 i32 f32), op <- ~w(get put), do: "#{op}_#{t}")
  @nf_all @nf_helpers ++ @nf_joins
  @nf_call ~r/\bdefk_(?:#{Enum.join(@nf_helpers, "|")})\(ctx,/
  @nf_join_call ~r/\bdefk_(?:#{Enum.join(@nf_joins, "|")})\(ctx,/
  # a float_tree check's replay: no braces inside (its operands are pure)
  @nf_replay ~r/DEFK_FCHECK\([^{}]*\) \{[^{}]*\}/
  @nf_scalars ~w(int64_t double int uint64_t)
  # the end of a loop/5 form, for Defk.Report's remark mapping (note_loop/2)
  @loop_end "/* defk:end */\n"
  @strips "strips of DEFK_STRIP trips, one safepoint per strip"

  # A loop with a safepoint on every back-edge, except for a flat loop whose
  # trip count is known on entry:
  #   * short (< DEFK_STRIP trips left): the plain loop with no safepoint; its
  #     trips are charged to the budget afterwards and the enclosing loop's
  #     safepoint does the check, so at most DEFK_STRIP flat iterations per
  #     enclosing iteration go unchecked. A loop a reduce_while halt can leave
  #     (flat == :exits) charges them on entry instead, so the jump past the
  #     loop cannot skip the charge (it overcharges by under DEFK_STRIP).
  #   * long: strips of DEFK_STRIP iterations, one safepoint per strip
  # Neither inner loop has a safepoint, so clang can vectorise it. Forms that
  # never yield define DEFK_SHORT as 1 and the strip version is dead code.
  #   strip.remaining - trips left after the next one, as uint64
  #   strip.done_at   - the loop's exit test against a given last index
  # A flat loop with float checks whose other checks can all become flags
  # runs flagged (flagged_loop/5).
  # Each form is noted for the fast-path report (note_loop/2) and marked in
  # the C for clang's remarks (Defk.Report).
  defp loop(id, done, strip, :plain = flat, body, rows) when is_map(strip) do
    case flag_strip(id, body, strip.var, rows) do
      nil ->
        mark = note_loop(:strips, @strips)
        note_unflagged(body, strip.var, rows)
        [mark, strip_loop(id, done, strip, flat, body), @loop_end]

      flagged ->
        mark = note_loop(:strips, @strips <> "; flagged")

        checks =
          if flagged.joined,
            do: "float, overflow and bounds checks",
            else: "float checks"

        note(
          :nonfinite,
          low(:report_loop),
          :flagged,
          "#{checks} set a flag tested once per strip; a set flag replays the strip with raising checks"
        )

        [mark, flagged_loop(id, done, strip, body, flagged), @loop_end]
    end
  end

  defp loop(id, done, strip, flat, body, _rows) when is_map(strip) and flat == :exits do
    mark =
      note_loop(
        :strips,
        @strips <> "; a reduce_while halt can leave it, so its trips are charged on entry"
      )

    [mark, strip_loop(id, done, strip, flat, body), @loop_end]
  end

  defp loop(id, done, strip, flat?, body, _rows) do
    why =
      [
        strip == nil && "the range step is not a literal, so the trip count is not known on entry",
        flat? == false && "the body has a nested loop (its own or in an inlined call)"
      ]
      |> Enum.filter(& &1)
      |> Enum.join("; ")

    [
      note_loop(:per_iteration, "a safepoint every iteration: " <> why),
      "defk_l#{id}:;\nwhile (!(#{done})) {\n",
      resume_dispatch(),
      body,
      safepoint(),
      "}\n",
      @loop_end
    ]
  end

  defp strip_loop(id, done, strip, flat, body) do
    r = fresh("rem", {:c, "uint64_t"})
    se = fresh("strip_stop", :i64)
    %{var: i, stop: e, step: k} = strip

    # no overflow: taken only when the strip ends before the loop's last index
    strip_stop =
      "(int64_t)((uint64_t)#{i} + (uint64_t)(DEFK_STRIP - 1) * (uint64_t)INT64_C(#{k}))"

    [
      "#{r} = #{strip.remaining};\nif (DEFK_SHORT(#{r})) {\n",
      if(flat == :exits, do: "DEFK_TICKS(#{r} + 1)\n", else: []),
      "while (!(#{done})) {\n",
      body,
      "}\n",
      if(flat == :exits, do: [], else: "DEFK_TICKS(#{r} + 1)\n"),
      strip_frame(id, done, se, strip, e, strip_stop, [
        "while (!(#{strip.done_at.(se)})) {\n",
        body,
        "}\n"
      ])
    ]
  end

  # The long form of a flat loop: strips of DEFK_STRIP trips, `inner` running
  # one strip, one safepoint per strip. Shared by the plain and flagged forms.
  defp strip_frame(id, done, se, strip, e, strip_stop, inner) do
    [
      "} else {\n",
      "defk_l#{id}:;\nwhile (!(#{done})) {\n#{se} = #{strip.remaining} < DEFK_STRIP ? #{e} : #{strip_stop};\n",
      inner,
      safepoint("DEFK_STRIP"),
      "}\n}\n"
    ]
  end

  # strip_loop/5 for a flat loop whose checks can all become flags
  # (flag_strip/3): the short loop and each strip run the body with a flag
  # (DEFK_NF_ forms in the runtime) and test it once at their end, before the
  # safepoint, so the body has no branch or call for its checks and clang can
  # vectorise it. A set flag replays that strip, restored from the snapshot
  # taken at its start, with the raising forms: it raises at the first failing
  # operation, in Elixir's order. The replay is shared by both forms (`se` is
  # the strip's last index in both), so the body is emitted three times.
  defp flagged_loop(id, done, strip, body, %{decls: decls, snap: snap, restore: restore} = fl) do
    r = fresh("rem", {:c, "uint64_t"})
    se = fresh("strip_stop", :i64)
    %{var: i, stop: e, step: k} = strip

    strip_stop =
      "(int64_t)((uint64_t)#{i} + (uint64_t)(DEFK_STRIP - 1) * (uint64_t)INT64_C(#{k}))"

    flagged = fn cond ->
      [
        snap,
        "defk_nf = 0;\n",
        Enum.map(fl.helpers, &"#define defk_#{&1} DEFK_NF_#{&1}\n"),
        "#undef DEFK_FCHECK\n#define DEFK_FCHECK DEFK_NF_FCHECK\n",
        "while (!(#{cond})) {\n",
        fl.body,
        "}\n",
        Enum.map(fl.helpers, &"#undef defk_#{&1}\n"),
        "#undef DEFK_FCHECK\n#define DEFK_FCHECK(B) if (DEFK_UNLIKELY(B))\n",
        "if (DEFK_UNLIKELY(defk_nf#{fl.test})) goto defk_rp#{id};\n"
      ]
    end

    [
      "{\n",
      decls,
      "int defk_nf;\n",
      if(fl.joined, do: "defk_nf_sink defk_sink;\n", else: []),
      "#{r} = #{strip.remaining};\nif (DEFK_SHORT(#{r})) {\n",
      "#{se} = #{e};\n",
      flagged.(done),
      "DEFK_TICKS(#{r} + 1)\n",
      strip_frame(id, done, se, strip, e, strip_stop, flagged.(strip.done_at.(se))),
      "if (0) {\ndefk_rp#{id}:;\n/* defk:replay */\n",
      restore,
      "while (!(#{strip.done_at.(se)})) {\n",
      body,
      "}\n",
      "defk_nonfinite_lost(ctx);\n}\n}\n"
    ]
  end

  # Whether a flat loop body can run flagged, and if so how: the snapshot
  # (decls, snap, restore), the flagged body and the extra end-of-strip test
  # (sticky_trees/1). It can when:
  #   * it has a float check: a strip without one gains nothing;
  #   * the only use of ctx (every error goes through it) is in a check that
  #     becomes a flag: a float check, or one that joins it (@nf_joins: i64
  #     overflow, an element access). Any other error (a
  #     CaseClauseError, a division by zero) could be raised before an earlier
  #     flagged one;
  #   * with a joined check, every unchecked a.data[i] has an index made only
  #     of the loop counter and values not assigned in the strip
  #     (fixed_indices?/3), so a wrong value from a failed check, which the
  #     flagged run computes on with, never reaches an address;
  #   * every local it mentions is a scalar, so a snapshot of those restores
  #     the strip's start state (unchanged ones fold away), or an array (in
  #     the snapshot when it is assigned whole, as array accumulators are);
  #   * an array it writes is not otherwise mentioned (no read of it, so the
  #     replay recomputes the values it wrote) and no input array is written.
  defp flag_strip(id, body, var, rows),
    do: flag_strip_rows(id, IO.iodata_to_binary(body), var, rows)

  # the classifier behind flag_strip/4, on its own for tests: body text plus
  # the strip record in, the flagged form (or nil) out
  @doc false
  def __flag_strip_rows__(id, text, var, rows), do: flag_strip_rows(id, text, var, rows)

  # ----------------------------------------------- the record classifier ---
  # Decisions from the strip record, each mirroring its text analysis
  # exactly (bug-for-bug: the gate demanded byte-identical C), except where
  # a mirrored bug was fixed since (sr_reaches?/3). Token-presence
  # scans over the body text stay (@nf_call, ctx-in-rest, the [vp]_ variable
  # roster): they reconstruct no structure and fail safe. What moved to rows
  # is everything that used to re-derive structure from the text: writes,
  # element writes, index composition with proof support, float reads and
  # trees with their sticky leaves, scalar copies, and branch positions.

  defp sr_writes(rows, v), do: Enum.count(rows, &(&1.k in [:assign, :addr] and &1.var == v))

  defp sr_written?(rows, v), do: sr_writes(rows, v) > 0

  defp sr_array_writes(rows, a), do: Enum.count(rows, &(&1.k == :elem_write and &1.arr == a))

  # an i64 + - * of such values in an index computes the checked value: the
  # bounds proof bounds the result, so it cannot overflow
  @index_words ~w(INT64_C UINT64_C int64_t uint64_t len ctx defk_add_i64 defk_sub_i64 defk_mul_i64)

  # the words a strip-assigned value may be computed from and stay exact in
  # a flagged run: no checked helper (one that flags computes a wrapped value
  # after a failure), so only the arithmetic the compiler proved cannot fail
  @fixed_words ~w(INT64_C UINT64_C int64_t uint64_t len)

  # The proof that dropped an index's check may reason about atoms its text
  # does not name (a bound of the counter, an exact form of a binding):
  # its support has to be fixed too, or a value the run computed wrongly
  # could stand behind it (ADR-0007).
  defp sr_fixed_indices?(rows, var) do
    Enum.all?(rows, fn
      %{k: :access, access: :index, idx: idx, support: support} ->
        sr_fixed_index?(idx, rows, var) and
          Enum.all?(support, &(&1 == var or sr_fixed_var?(&1, rows, var, [])))

      %{k: :access} ->
        false

      _ ->
        true
    end)
  end

  # An index is fixed when every value in it is one the flagged run computes
  # exactly: the loop counter, a value not assigned in the strip, or one the
  # strip assigns once, unconditionally and at the top level, from fixed
  # values alone with no checked helper (sr_fixed_var?/4). A value read from
  # memory, a division, a conversion or a float fails the word test.
  defp sr_fixed_index?(idx, rows, var) do
    Regex.scan(~r/[A-Za-z_]\w*/, idx)
    |> List.flatten()
    |> Enum.all?(fn w ->
      w in @index_words or w == var or
        (Regex.match?(~r/^[vp]_\w+$/, w) and sr_fixed_var?(w, rows, var, []))
    end)
  end

  # `seen`: the values whose assignments are being followed (a cycle)
  defp sr_fixed_var?(w, rows, var, seen) do
    case Enum.filter(rows, &(&1.k in [:assign, :addr] and &1.var == w)) do
      [] ->
        true

      # one plain assignment from fixed words (a value assigned from itself,
      # or through a cycle, is not fixed)
      [%{k: :assign, rhs: rhs, path: [], cond: false}] ->
        w not in seen and
          Regex.scan(~r/[A-Za-z_]\w*/, rhs)
          |> List.flatten()
          |> Enum.all?(fn x ->
            x in @fixed_words or x == var or
              (Regex.match?(~r/^[vp]_\w+$/, x) and sr_fixed_var?(x, rows, var, [w | seen]))
          end)

      _ ->
        false
    end
  end

  defp sr_replayable?(text, rows, arrays) do
    counts = Enum.map(arrays, fn a -> {length(mentions(text, a)), sr_array_writes(rows, a)} end)
    Enum.all?(counts, fn {_, w} -> w == 0 end) or Enum.all?(counts, fn {m, w} -> m == w end)
  end

  defp sr_fread(rhs) do
    cond do
      String.starts_with?(rhs, "defk_in_f64(ctx, ") -> "defk_in_f64"
      String.starts_with?(rhs, "defk_get_in_f64(ctx, ") -> "defk_get_in_f64"
      true -> nil
    end
  end

  defp sr_ftree_f(rhs) do
    case Regex.run(~r/^\(\{ double (f_\d+) = /, rhs) do
      [_, f] -> f
      _ -> nil
    end
  end

  defp sr_sticky(rows) do
    leaves = Map.new(for %{k: :ftree, f: f, leaves: ls} <- rows, ls != nil, do: {f, ls})

    tops =
      for %{k: :assign, var: x, rhs: rhs, path: [], cond: false} <- rows,
          f = sr_ftree_f(rhs),
          do: {x, f}

    copies =
      for %{k: :assign, var: d, rhs: r, path: [], cond: false} <- rows,
          Regex.match?(~r/^v_\w+$/, r),
          do: [d, r]

    once? = fn v -> sr_writes(rows, v) == 1 end

    for {x, f} <- tops,
        ls = leaves[f],
        ls != nil,
        sticky_path?(x, ls, copies, once?, []),
        do: {x, f}
  end

  defp sr_seen_later(text, rows) do
    freads = for %{k: :assign, var: y, rhs: rhs} = r <- rows, h = sr_fread(rhs), do: {r, y, h}
    trees = for %{k: :assign, var: y, rhs: rhs} = r <- rows, f = sr_ftree_f(rhs), do: {r, y, f}

    text =
      Enum.reduce(freads, text, fn {r, y, h}, t ->
        if sr_reaches?(rows, y, r) do
          later = if h == "defk_in_f64", do: "defk_in_f64_later", else: "defk_get_f64"
          String.replace(t, "#{y} = #{h}(ctx, ", "#{y} = #{later}(ctx, ")
        else
          t
        end
      end)

    Enum.reduce(trees, text, fn {r, y, f}, t ->
      if sr_reaches?(rows, y, r),
        do: String.replace(t, "DEFK_FCHECK(DEFK_NONFIN(#{f}))", "if (0)"),
        else: t
    end)
  end

  # Whether `y`, assigned by row `from`, reaches a checked use later in the
  # strip. A tree whose own variable is one of its leaves (acc = acc + ...)
  # is not a later use of itself: the old text scan counted it (and the
  # first strip record mirrored that), which removed the check of an
  # accumulator updated under a branch (a filter's) with no end-of-strip
  # test behind it, so an inf never raised. The unconditional accumulator still drops its
  # check: it is sticky (sr_sticky/1), and the end-of-strip test covers it.
  defp sr_reaches?(rows, y, from) do
    uses =
      for %{k: :ftree, leaves: ls, seq: t} = u <- rows,
          ls != nil,
          y in ls,
          t > from.seq,
          do: u

    copies = for %{k: :assign, rhs: rhs, seq: t} = c <- rows, t > from.seq, rhs == y, do: c

    reached? = fn to ->
      sr_runs_after?(from, to) and sr_unchanged?(rows, y, from, to)
    end

    Enum.any?(uses, reached?) or
      Enum.any?(copies, fn c ->
        sr_runs_after?(from, c) and sr_unchanged?(rows, y, from, c) and
          sr_reaches?(rows, c.var, c)
      end)
  end

  defp sr_suffix?(inner, outer), do: inner == Enum.drop(outer, length(outer) - length(inner))

  defp sr_runs_after?(from, to) do
    to.seq > from.seq and length(to.path) <= length(from.path) and
      sr_suffix?(to.path, from.path) and to.cond == false
  end

  defp sr_unchanged?(rows, y, from, to) do
    writes =
      for %{k: k, var: v, seq: w} = r <- rows,
          k in [:assign, :addr],
          v == y,
          w > from.seq,
          w < to.seq,
          do: r

    case from.path do
      [{ref, arm} | _] ->
        Enum.all?(writes, fn w ->
          Enum.any?(w.path, fn {r2, a2} -> r2 == ref and a2 != arm end)
        end)

      [] ->
        writes == []
    end
  end

  defp flag_strip_rows(id, text, var, rows) do
    rest = unflagged_rest(text)
    joined = Regex.match?(@nf_join_call, text)
    types = Map.new(low(:decls))

    vars =
      Regex.scan(~r/\b[vp]_\w+/, text)
      |> List.flatten()
      |> Enum.uniq()

    {arrays, others} =
      Enum.split_with(vars, &String.starts_with?(types[&1] || "", "defk_arr_"))

    {params, locals} = Enum.split_with(others, &String.starts_with?(&1, "p_"))

    with true <- Regex.match?(@nf_call, text) or String.contains?(text, "DEFK_FCHECK("),
         false <- Regex.match?(~r/\bctx\b/, rest),
         true <- not joined or sr_fixed_indices?(rows, var),
         true <- Enum.all?(locals, &(types[&1] in @nf_scalars)),
         false <- Enum.any?(params, &(sr_written?(rows, &1) or sr_array_writes(rows, &1) > 0)),
         true <- sr_replayable?(text, rows, arrays) do
      saved = locals ++ Enum.filter(arrays, &sr_written?(rows, &1))
      named = Enum.with_index(saved, fn v, n -> {v, "defk_s#{id}_#{n}", types[v]} end)
      sticky = sr_sticky(rows)

      flagged =
        Enum.reduce(sticky, text, fn {_, f}, t ->
          String.replace(t, "DEFK_FCHECK(DEFK_NONFIN(#{f}))", "if (0)")
        end)
        |> sr_seen_later(rows)

      %{
        decls: Enum.map(named, fn {_, s2, t} -> "#{t} #{s2};\n" end),
        snap: Enum.map(named, fn {v, s2, _} -> "#{s2} = #{v};\n" end),
        restore: Enum.map(named, fn {v, s2, _} -> "#{v} = #{s2};\n" end),
        body: flagged,
        test: Enum.map(sticky, fn {x, _} -> " | DEFK_NONFIN(#{x})" end),
        joined: joined,
        helpers: Enum.filter(@nf_all, &String.contains?(flagged, "defk_#{&1}(ctx,"))
      }
    else
      _ -> nil
    end
  end

  # the body without the checks a flagged strip turns into flags: any ctx
  # left is a check that must raise where it fails
  defp unflagged_rest(text) do
    text
    |> String.replace(@nf_replay, "")
    |> String.replace(@nf_call, "")
    |> String.replace(@nf_join_call, "")
  end

  defp sticky_path?(v, leaves, copies, once?, seen) do
    once?.(v) and v not in seen and
      (v in leaves or
         case for [dst, ^v] <- copies, do: dst do
           [next] -> sticky_path?(next, leaves, copies, once?, [v | seen])
           _ -> false
         end)
  end

  defp mentions(text, a) do
    Regex.scan(~r/\b#{Regex.escape(a)}\b/, text, return: :index)
    |> Enum.map(fn [{at, _}] -> at end)
  end

  # Resuming re-enters loops only through their headers, so every loop keeps a
  # single entry (an irreducible CFG would cost LLVM most loop optimisations).
  # A safepoint is the last statement of its loop's body, so continuing after
  # it means re-testing that loop's condition. The kernel's top dispatch jumps
  # to the label in front of the outermost loop on the way to the safepoint;
  # the top of that loop's body dispatches to the next loop down, and so on.
  #
  # While resuming, defk_rs is the safepoint and the dispatch depth reached,
  # n * 256 + depth: each level matches only its own depth and
  # hands the next one on, so a missing case above leaves the depth behind
  # and nothing below matches. The last step jumps to the safepoint's arrival
  # label, defk_a<n>, in front of its own loop (arrival_blocks/3): only
  # arriving there clears the resume, so a jump to any other loop leaves it
  # pending, and the next yield or the return raises (defk_lost_resume).
  defp in_loop(fun) do
    id = low(:nloops) + 1
    low_put(:nloops, id)
    stack = low(:loops)
    low_put(:loops, [id | stack])
    res = fun.(id)
    low_put(:loops, stack)
    # the loop's extent in the C, for safepoint_saves/2 (removed there)
    ["/* defk:in #{id} */\n", res, "/* defk:out #{id} */\n"]
  end

  # Dispatch for the loops entered from here (the current loop body, or the
  # kernel top level when no loop is open).
  defp resume_dispatch do
    case resume_cases(low(:sps), Enum.reverse(low(:loops))) do
      [] -> []
      cases -> ["if (DEFK_RESUMING) switch (defk_rs) {\n", cases, "}\n"]
    end
  end

  # `here` is the path of loop ids (outermost first) whose body we are in
  defp resume_cases(sps, here) do
    depth = length(here)

    for {n, path} <- Enum.sort(sps), length(path) > depth, List.starts_with?(path, here) do
      if length(path) == depth + 1,
        do: "case #{rs(n, depth)}: goto defk_a#{n};\n",
        else:
          "case #{rs(n, depth)}: defk_rs = #{rs(n, depth + 1)}; goto defk_l#{Enum.at(path, depth)};\n"
    end
  end

  # defk_rs while resuming safepoint n at dispatch depth `depth`
  defp rs(n, depth) when depth < 256, do: n * 256 + depth

  # The arrival label of each safepoint, in front of its own loop's label, in
  # a block only a goto enters: the normal path never runs it, and the loop
  # itself does not change. A kernel that never yields keeps its dispatch
  # behind DEFK_RESUMING (0), so the labels stay, with nothing to clear.
  defp arrival_blocks(text, sps, yields?) do
    clear = if yields?, do: " defk_rs = F->resume = 0;", else: ""
    own = Enum.group_by(sps, fn {_, path} -> List.last(path) end, fn {n, _} -> n end)

    Regex.replace(~r/defk_l(\d+):;\n/, text, fn label, id ->
      case own[String.to_integer(id)] do
        nil ->
          label

        ns ->
          arrive = Enum.map_join(Enum.sort(ns), " ", &"defk_a#{&1}:")
          "if (0) { #{arrive};#{clear} }\n" <> label
      end
    end)
  end

  defp lower_reduce(quals, init_ast, clauses, env, node) do
    {pat, body} =
      case clauses do
        [{:->, _, [[pat], body]}] ->
          {pat, body}

        [_, _ | _] ->
          err!(
            node,
            "reduce-clauses",
            "this for ..., reduce: has #{length(clauses)} clauses; more than one is not in the kernel subset"
          )

        _ ->
          err!(node, "reduce-clauses", "this for ..., reduce: has no `acc -> body` clause")
      end

    # the outer names the loop reads while it runs: its generators and
    # filters (quals_reads/1), and its body where the accumulator does not
    # shadow them
    loop_reads =
      MapSet.union(
        Copies.quals_reads(quals),
        MapSet.difference(Copies.reads(body), Copies.reads(pat))
      )

    lenv = loop_env(env, node)
    entered = make_ref()

    try do
      u64_accs(fn u64s ->
        {si, accs} = reduce_accs(pat, init_ast, "the reduce: value", env, node, loop_reads, u64s)

        loops =
          with_acc_facts(accs, fn accs, fix ->
            inner = fn genv ->
              Process.put(entered, true)
              {sb, res} = lower_block(body, acc_env(accs, genv))
              [sb, assign_accs(accs, res, last_expr(body), "the reduce body", genv.live, fix)]
            end

            lower_quals(quals, lenv, inner)
          end)

        {[si, loops], acc_result(accs)}
      end)
    catch
      # the init or a generator was rejected (or reads a poisoned variable)
      # before the body ran: the body is still checked (recover_reduce/5)
      {:defk_reject, _} = rejection ->
        recover_reduce(entered, quals, pat, body, lenv)
        throw(rejection)

      :defk_poison ->
        recover_reduce(entered, quals, pat, body, lenv)
        throw(:defk_poison)
    after
      Process.delete(entered)
    end
  end

  # An accumulator whose initial value is a non-negative integer literal is
  # a u64 when a new value is: `reduce: 0` with a body that ends
  # in band(..., 0xFFFFFFFFFFFFFFFF). The fold is lowered with i64
  # accumulators; assign_accs throws for such an accumulator meeting a u64,
  # and the fold is lowered again from the saved compiler state with it as a
  # u64. Elixir mode settles the same types (Defk.ElixirMode). The saved
  # state is the whole ctx, like with_acc_facts/2's, so a retry of either
  # kind inside the other's attempt is undone with that attempt: each
  # restores what it saved, including the other's pending fact notes.
  defp u64_accs(fun, u64s \\ []) do
    snap = ctx()
    ref = make_ref()

    try do
      fun.({ref, u64s})
    catch
      {:defk_u64_acc, ^ref, name} ->
        ctx_swap(snap)
        u64_accs(fun, [name | u64s])
    end
  end

  # Enum.reduce_while(src, init, fn x, acc -> ... end) is the loop of
  # `for x <- src`, with the accumulator of `for ..., reduce: init`. Every tail
  # position of the fn body is a literal {:cont, acc} or {:halt, acc} (see
  # lower_tail), so the next accumulator is assigned where the tuple is
  # written, and a halt jumps to a label after this loop. That leaves only
  # this loop (and the loops nested in it), so a halt in a nested
  # reduce_while ends the inner fold only, as in Elixir. Jumping out of loops
  # keeps every loop's single entry, which resume relies on.
  # `for ..., reduce:` with {:cont, acc}/{:halt, acc} is not early exit in
  # Elixir (the tuple becomes the next accumulator), so it is not one here.
  # `node` is the whole call.
  defp lower_reduce_while(src, init_ast, x, acc_pat, body, env, m, node),
    do: u64_accs(&reduce_while_loop({src, init_ast, x, acc_pat, body}, env, m, node, &1))

  defp reduce_while_loop({src, init_ast, x, acc_pat, body}, env, m, node, u64s) do
    loop_reads =
      MapSet.union(
        Copies.quals_reads([{:<-, m, [x, src]}]),
        MapSet.difference(Copies.reads(body), Copies.reads([x, acc_pat]))
      )

    {si, accs} =
      reduce_accs(acc_pat, init_ast, "the initial accumulator", env, node, loop_reads, u64s)

    id = low(:nhalts) + 1
    low_put(:nhalts, id)
    label = "defk_halt#{id}"
    loop = {:for, m, [{:<-, m, [x, src]}, [do: body]]}
    lenv = loop_env(env, loop)

    loops =
      with_acc_facts(accs, fn accs, fix ->
        leaf = fn tag, v_ast, env ->
          {s, v} = lower_expr(v_ast, env)
          assign = assign_accs(accs, v, v_ast, "{:#{tag}, acc}", lenv.live, fix)

          if tag == :halt do
            low_update(:halted, &Map.put(&1, id, true))
            low_put(:halts_emitted, low(:halts_emitted) + 1)
          end

          [s, assign, if(tag == :halt, do: "goto #{label};\n", else: [])]
        end

        inner = fn genv -> lower_tail(body, acc_env(accs, genv), leaf) end
        lower_quals([{:<-, m, [x, src]}], lenv, inner)
      end)

    halt = if low_halted_pop(id), do: "#{label}:;\n", else: []
    {[si, loops, halt], acc_result(accs)}
  end

  # Accumulators [{name, cvar, acc}] from `acc` or `{a, b, ...}` and the
  # initial value, where acc is what the body sees: %{t: type}, and for an
  # array also its facts (owned, fin, len_lo, len_lb).
  #
  # An array accumulator is threaded through the loop in place:
  # its buffer is the loop's own, so the body writes it, and a helper returns
  # it, without a copy. The initial array is copied before the loop when it is
  # not owned (an input, a binary attribute), or when another binding of its
  # buffer is live: read after the loop statement, read in the loop
  # (`loop_reads`, the outer names its generators, filters and body read
  # while it runs; not the first range nor the initial value, evaluated
  # before the first iteration),
  # or an earlier accumulator. The new value at the end of each iteration is
  # copied on the same test (assign_accs/6), so no buffer but the
  # accumulator's own is seen across an iteration. `node` is the loop.
  # {ref, u64s} names the accumulators that are u64 (u64_accs/2).
  defp reduce_accs(pat, init_ast, what, env, node, loop_reads, {ref, u64s}) do
    {si, init} = lower_expr(init_ast, env)
    pats = if is_tuple(pat) and tuple_items(pat), do: tuple_items(pat), else: [pat]
    items = (match?(%{elems: _}, init) && tuple_items(init_ast)) || [init_ast]
    inits = u64_candidates(Map.get(init, :elems, [init]), items, ref)

    length(pats) == length(inits) ||
      err!(
        init_ast,
        "accumulator-shape",
        "the accumulator #{Macro.to_string(pat)} has #{length(pats)} element#{if match?([_], pats), do: "", else: "s"}, #{what} #{Macro.to_string(init_ast)} has #{length(inits)}"
      )

    live =
      MapSet.union(
        env.live,
        pairs(env, MapSet.union(loop_reads, Copies.reads_outside(env.stmt, node)))
      )

    {accs, _} =
      Enum.zip(pats, inits)
      |> Enum.map_reduce(MapSet.new(live, &elem(&1, 1)), fn {p, v}, seen ->
        v = bits_init(p, v)

        name =
          case p do
            {n, _, ctx} when is_atom(n) and is_atom(ctx) ->
              n

            _ ->
              err!(
                p,
                "accumulator-pattern",
                "the accumulator pattern #{Macro.to_string(p)} is not in the kernel subset"
              )
          end

        v = if name in u64s, do: as_u64(v), else: v
        c = fresh(name, v.t)

        case v.t do
          {:arr, _} ->
            {ic, seen} = loop_owned(v, seen)

            note_copy(
              ic,
              init_ast,
              "the initial value of #{name} is copied: the accumulator's buffer is the loop's alone"
            )

            acc =
              Facts.len_facts_of(
                %{
                  t: v.t,
                  owned: true,
                  fin: v[:fin] || false,
                  buf: carried(make_ref(), v[:buf])
                },
                v
              )

            {{{name, c, acc}, ic}, seen}

          t ->
            {{{name, c, Map.put(Map.take(v, [:u64_ref]), :t, t)}, v.c}, seen}
        end
      end)

    {[
       si,
       Enum.map(accs, fn {{_, c, _}, ic} -> assign_copy(c, ic) end)
     ], Enum.map(accs, &elem(&1, 0))}
  end

  # an i64 literal >= 0 may become a u64 accumulator (u64_accs/2): marked
  # with the fold's ref
  defp u64_candidates(inits, items, ref) when length(items) == length(inits) do
    Enum.zip_with(inits, items, fn v, item ->
      if is_integer(item) and item >= 0 and v.t == :i64, do: Map.put(v, :u64_ref, ref), else: v
    end)
  end

  defp u64_candidates(inits, _items, _ref), do: inits

  # Lower a loop with accumulators `accs` by `lower.(accs, fix)`. The body is
  # lowered assuming each array accumulator keeps the facts of its initial
  # value (fin, len_lo, len_lb); a new value without them is noted in `fix` by
  # assign_accs/6, and the loop is lowered again (from the same compiler
  # state) with those facts dropped: first the relative length facts, then,
  # if the new value still lacks one, the rest (drop_facts/2).
  defp with_acc_facts(accs, lower) do
    if Enum.any?(accs, fn {_, _, a} -> facts?(a) end) do
      fix = make_ref()
      snap = ctx()
      low_update(:acc_fix, &Map.put(&1, fix, MapSet.new()))
      res = lower.(accs, fix)
      weak = Map.fetch!(low(:acc_fix), fix)
      low_update(:acc_fix, &Map.delete(&1, fix))

      if Enum.empty?(weak) do
        res
      else
        ctx_swap(snap)
        accs |> Enum.map(&drop_facts(&1, weak)) |> with_acc_facts(lower)
      end
    else
      lower.(accs, nil)
    end
  end

  defp drop_facts({name, c, a} = acc, weak) do
    cond do
      c not in weak -> acc
      Facts.weakest?(a) -> {name, c, Facts.weaken(%{a | fin: false})}
      true -> {name, c, Facts.weaken(a)}
    end
  end

  # {C expression, seen}: array value `v` as an accumulator's, copied unless
  # it is owned and no binding whose buffer is in `seen` (the live ones and
  # earlier accumulators') may share its buffer
  defp loop_owned(v, seen) do
    {:arr, e} = v.t
    copy? = not v.owned or Enum.any?(seen, &Copies.same_buf?(copies(), v[:buf], &1))
    c = if copy?, do: "defk_copy_#{e}(ctx, #{v.c})", else: v.c
    {c, if(v[:buf], do: MapSet.put(seen, v.buf), else: seen)}
  end

  # a new value `r` of array accumulator `a` without a fact the body assumed
  defp lost_facts?(%{t: {:arr, e}} = a, r) do
    (e in [:f64, :f32] and a.fin and not r[:fin]) or not Facts.covers?(a, r)
  end

  # an array accumulator with facts a new value may not have
  defp facts?(%{t: {:arr, e}} = a), do: (e in [:f64, :f32] and a.fin) or Facts.carries?(a)
  defp facts?(_a), do: false

  defp acc_env(accs, env) do
    Enum.reduce(accs, env, fn {name, c, a}, e ->
      cond do
        String.starts_with?(Atom.to_string(name), "_") ->
          e

        # the accumulator's buffer is the loop's own: a binding of its own,
        # and a name the body may bind again (array-rebind-in-loop is about
        # the outer variable it shadows)
        match?({:arr, _}, a.t) ->
          buf = carried(make_ref(), a[:buf])
          b = Map.merge(a, %{c: c, id: make_ref(), buf: buf, depth: e.depth + 1})
          %{put_var(e, name, b) | guard: MapSet.delete(e.guard, name)}

        # an accumulator that may become a u64 is marked (u64_mix!/2)
        a[:u64_ref] ->
          put_var(e, name, Map.merge(val(c, a.t), %{u64_ref: a.u64_ref, acc: name}))

        true ->
          put_var(e, name, val(c, a.t))
      end
    end)
  end

  # Enum.find/3 (Defk.EnumForms): the element found and the default are one
  # type, as no conversion keeps Elixir's result (an i64 element found under
  # a float default would come back as a float)
  defp find_types!(t, t, _at), do: :ok
  defp find_types!(e, d, _at) when e in @ints and d in @ints, do: :ok

  defp find_types!(e, d, at) do
    err!(
      at,
      "type-mismatch",
      "Enum.find/3's default has type #{fmt(d)} and the elements have type #{fmt(e)}",
      hint: "give a default of the element type, #{fmt(e)}"
    )
  end

  # `at` is the expression that gives the new value; `live` the {id, buf}
  # live across iterations (and after the loop); `fix` collects array
  # accumulators whose new value lacks the facts assumed (with_acc_facts/2)
  defp assign_accs(accs, res, at, what, live, fix) do
    results = Map.get(res, :elems, [res])

    length(results) == length(accs) ||
      err!(
        at,
        "accumulator-shape",
        "#{what} gives #{length(results)} value#{if match?([_], results), do: "", else: "s"}, the accumulator has #{length(accs)}"
      )

    items = tuple_items(at) || List.duplicate(at, length(accs))

    outs =
      Enum.zip_with([accs, results, items], fn [{name, _c, a}, r, item] ->
        if a[:u64_ref] && a.t == :i64 && r.t == :u64, do: throw({:defk_u64_acc, a.u64_ref, name})
        name == Defk.EnumForms.find_default() && find_types!(r.t, a.t, item)
        coerce!(r, a.t, item, "the new value of #{name}")
      end)

    # a new array value another live binding (or an earlier accumulator) may
    # see, or that is not owned, is copied: the accumulator's buffer is the
    # loop's alone
    {outs, _} =
      Enum.zip(accs, outs)
      |> Enum.map_reduce(MapSet.new(live, &elem(&1, 1)), fn
        {{name, c, %{t: {:arr, _}} = a}, r}, seen ->
          lost_facts?(a, r) &&
            low_update(:acc_fix, &Map.update!(&1, fix, fn set -> MapSet.put(set, c) end))

          a[:buf] && not Copies.carries?(copies(), r[:buf], a.buf) &&
            copies_put(Copies.cut_carry(copies(), a.buf))

          {rc, seen} = loop_owned(r, seen)

          note_copy(
            rc,
            at,
            "the new value of #{name} is copied every iteration: the accumulator's buffer is the loop's alone"
          )

          {%{r | c: rc}, seen}

        {_, r}, seen ->
          {r, seen}
      end)

    case accs do
      [{_, c, _}] ->
        assign_copy(c, hd(outs).c)

      _ ->
        # compute all new values before assigning (they may read each other)
        tmps = Enum.map(accs, fn {name, _, a} -> fresh("#{name}_next", a.t) end)

        [
          Enum.zip_with(tmps, outs, fn t, o -> assign_copy(t, o.c) end),
          Enum.zip_with(accs, tmps, fn {_, c, _}, t ->
            srec_assign(c, t)
            "#{c} = #{t};\n"
          end)
        ]
    end
  end

  # the loop's value; an array accumulator's buffer is no other binding's
  defp acc_result([acc]), do: acc_value(acc)

  defp acc_result(accs),
    do: %{t: {:tuple, Enum.map(accs, &elem(&1, 2).t)}, elems: Enum.map(accs, &acc_value/1)}

  defp acc_value({_, c, %{t: {:arr, _}} = a}),
    do: Map.merge(a, %{c: c, var: c, buf: carried(make_ref(), a[:buf])})

  defp acc_value({_, c, a}), do: val(c, a.t, c)

  # The body of a reduce_while fn: statements, then a tail that is a literal
  # {:cont, acc} or {:halt, acc}, or an if/cond/case whose branches end in one.
  # `leaf.(tag, acc_ast, env)` emits a tail tuple.
  defp lower_tail(ast, env, leaf) do
    es = exprs(ast)
    {init, [last]} = Enum.split(es, -1)
    lives = Copies.live_after(es)
    {s, env} = stmt_list(init, lives, nested(env, ast))

    [
      s,
      in_ctx(last, fn ->
        {sh, env} = enter(last, List.last(lives), env)
        [sh, tail_expr(last, env, leaf)]
      end)
    ]
  end

  defp tail_expr({tag, v}, env, leaf) when tag in [:cont, :halt], do: leaf.(tag, v, env)
  defp tail_expr({:__block__, _, _} = b, env, leaf), do: lower_tail(b, env, leaf)

  defp tail_expr({:if, _, [c, kw]} = node, env, leaf) when is_list(kw) do
    else_ast =
      Keyword.get(kw, :else) ||
        err!(
          node,
          "reduce-while-tail",
          "this if ends an Enum.reduce_while/3 fn but has no else branch",
          hint: "add an else branch that returns {:cont, acc} or {:halt, acc}"
        )

    note_branch_stmt(node, "it ends an Enum.reduce_while/3 fn, each arm continuing or halting")
    branch_chain([{c, Keyword.fetch!(kw, :do)}, {true, else_ast}], env, &lower_tail(&1, &2, leaf))
  end

  defp tail_expr({:cond, _, [[do: clauses]]} = node, env, leaf) when is_list(clauses) do
    arms = Enum.map(clauses, &clause_parts/1)
    match?({true, _}, List.last(arms)) || cond_without_true!(node)
    note_branch_stmt(node, "it ends an Enum.reduce_while/3 fn, each arm continuing or halting")
    branch_chain(arms, env, &lower_tail(&1, &2, leaf))
  end

  defp tail_expr({:case, _, [subject, [do: clauses]]} = node, env, leaf) do
    note_branch_stmt(node, "it ends an Enum.reduce_while/3 fn, each arm continuing or halting")
    {ss, arms, cenv} = case_arms(subject, clauses, node, env)
    [ss, branch_chain(arms, cenv, &lower_tail(&1, &2, leaf))]
  end

  defp tail_expr({:raise, m, args}, _env, _leaf) when is_list(args),
    do: Defk.Raise.value!({:raise, m, args}, &reject!/4)

  defp tail_expr(other, _env, _leaf) do
    err!(
      other,
      "reduce-while-tail",
      "an Enum.reduce_while/3 fn returns #{Macro.to_string(other)}, not {:cont, acc} or {:halt, acc}",
      rewrite: "{:cont, #{Macro.to_string(other)}}"
    )
  end

  # An if/else chain over [{cond_ast | true, body_ast} | {:nomatch, stmts}],
  # each body lowered by `lower_body.(body_ast, env)`, in the env its
  # condition and the negations of the conditions before it narrow.
  defp branch_chain(arms, env, lower_body) do
    arms
    |> Enum.map_reduce(env, fn
      {:nomatch, s}, aenv ->
        {{:nomatch, s}, aenv}

      {true, body}, aenv ->
        {{true, lower_body.(body, aenv)}, aenv}

      {c, body}, aenv ->
        {sc, cc, rel} = lower_test(c, aenv)
        {{{sc, cc}, lower_body.(body, narrow(aenv, rel, true))}, narrow(aenv, rel, false)}
    end)
    |> elem(0)
    |> List.foldr([], fn
      {:nomatch, s}, _ -> s
      {true, sb}, _ -> sb
      {{sc, c}, sb}, rest -> [sc, "if (#{c}) {\n", sb, "} else {\n", rest, "}\n"]
    end)
  end

  # ----------------------------------------------------------------- case --
  # `case` on an i64 or bool. Patterns: integer literals (bool: true/false),
  # `^pinned`, `_`, or a variable that binds the subject; each with an
  # optional guard. Lowered to [{cond_ast | true, body_ast}] for lower_arms
  # (a value; pure-arithmetic arms become a select) or branch_chain (a
  # statement or a reduce_while tail). The clauses test in order, like an
  # if/else chain; clang turns literal tests into a switch where that pays.
  # Like Elixir, a value no clause matches raises CaseClauseError, so a
  # catch-all is not required. Clauses after one that always matches are
  # unreachable and dropped. Returns {stmts, arms, env with the subject bound}.
  # `node` is the case
  defp case_arms(subject, clauses, node, env) do
    (is_list(clauses) and Enum.all?(clauses, &match?({:->, _, [_, _]}, &1))) || case_form!(node)
    {ss, sv} = lower_expr(subject, env)

    sv.t in [:i64, :bool] ||
      err!(
        subject,
        "case-subject",
        "case on #{Macro.to_string(subject)}, #{if sv[:elems], do: "a tuple", else: "an #{fmt(sv.t)} value"}, is not in the kernel subset"
      )

    c = fresh("case", sv.t)
    # a name no Elixir variable can have, bound to the subject evaluated once
    name = :"defk case #{c}"

    env =
      put_var(env, name, %{c: c, t: sv.t, owned: false, var: c, facts: Facts.bound(sv)})

    subj = {name, [], nil}

    {arms, exhaustive?} =
      Enum.reduce_while(clauses, {[], MapSet.new()}, fn clause, {arms, seen} ->
        {pat, guard, body, cm} = case_clause_head(clause)
        {test, rename} = case_pattern(pat, sv.t, subj, cm)

        guard =
          guard &&
            {:defk_guard, cm,
             [
               guard
               |> guard_safe!()
               |> rename.()
               |> in_types!(env, unrename(pat, name))
               |> Defk.GuardIn.lower()
             ]}

        body = rename.(body)

        seen =
          if guard == nil and match?({:lit, _, _}, test),
            do: MapSet.put(seen, elem(test, 1)),
            else: seen

        always? =
          guard == nil and (test == :any or MapSet.equal?(seen, MapSet.new([true, false])))

        cond_ast = case_test_cond(test, guard, seen, cm)

        arms = [{cond_ast, body} | arms]
        if always?, do: {:halt, {arms, true}}, else: {:cont, {arms, seen}}
      end)

    nomatch = no_clause(node, sv.t, c)
    # exhaustive? is the set of literals seen unless a clause always matches
    arms = Enum.reverse(arms) ++ if(exhaustive? == true, do: [], else: [{:nomatch, nomatch}])
    {[ss, "#{c} = #{sv.c};\n"], arms, env}
  end

  # The C statement for a case no clause matches: CaseClauseError, or the
  # FunctionClauseError of the multi-clause kernel the case stands for
  # (Defk.Clauses), with its module and function as one static string,
  # "Elixir.Mod\0name", and the length of the module part.
  defp no_clause({:case, m, _}, t, c) do
    case m[:defk_clauses] do
      {name, arity} ->
        mod = Atom.to_string(ctx(:module))
        str = Defk.Raise.c_string(mod <> <<0>> <> Atom.to_string(name))
        "defk_no_fun_clause(ctx, #{str}, #{byte_size(mod)}, #{arity});\n"

      nil ->
        "defk_no_clause(ctx, #{if t == :bool, do: 1, else: 0}, #{c});\n"
    end
  end

  # A case clause as {pattern, guard, body, meta}; a clause with several
  # patterns is rejected (the compiler only commits to the subject once).
  defp case_clause_head(clause) do
    case clause do
      {:->, cm, [[{:when, _, [pat, guard]}], body]} ->
        {pat, guard, body, cm}

      {:->, cm, [[pat], body]} ->
        {pat, nil, body, cm}

      {:->, _, [pats, _]} = cl ->
        err!(
          cl,
          "case-pattern",
          "a case clause with #{length(pats)} patterns is not in the kernel subset"
        )
    end
  end

  # The `if` condition of a clause: `true` when the clause always matches,
  # the eval of its test, the guard, or the test and the guard together.
  defp case_test_cond(test, guard, seen, m) do
    cond do
      guard == nil and (test == :any or MapSet.equal?(seen, MapSet.new([true, false]))) -> true
      test == :any -> guard
      guard == nil -> elem(test, 2)
      true -> {:and, m, [elem(test, 2), guard]}
    end
  end

  # {test, rename}: test is :any or {:lit | :pin, value, cond_ast}; rename
  # renames a bound variable to the subject in the guard and the body
  defp case_pattern(pat, t, subj, m) do
    same = & &1
    lit_cond = fn v -> {:===, m, [subj, v]} end

    case {pat, t} do
      {n, :i64} when is_integer(n) ->
        {{:lit, n, lit_cond.(n)}, same}

      {{:-, _, [n]}, :i64} when is_integer(n) ->
        {{:lit, -n, lit_cond.(-n)}, same}

      {b, :bool} when is_boolean(b) ->
        {{:lit, b, lit_cond.(b)}, same}

      {{:^, _, [{v, _, ctx} = var]}, _} when is_atom(v) and is_atom(ctx) ->
        {{:pin, v, {:===, m, [subj, var]}}, same}

      {{v, _, ctx}, _} when is_atom(v) and is_atom(ctx) ->
        if String.starts_with?(Atom.to_string(v), "_"),
          do: {:any, same},
          else: {:any, &rename_var(&1, v, subj)}

      {{:@, _, _} = p, _} ->
        match?({:ok, b} when is_binary(b), Defk.Attributes.of(p)) || attribute!(p)

        err!(
          p,
          "case-pattern",
          "the case pattern #{Macro.to_string(p)}, a binary, is not in the kernel subset"
        )

      {p, _} when is_integer(p) or is_boolean(p) ->
        err!(
          p,
          "case-pattern-type",
          "the pattern #{inspect(p)} never matches a #{fmt(t)} subject"
        )

      {p, _} ->
        err!(
          p,
          "case-pattern",
          "the case pattern #{Macro.to_string(p)} is not in the kernel subset"
        )
    end
  end

  # every occurrence of variable `name` in `ast` (a consistent renaming, so
  # rebinding and shadowing inside keep their meaning)
  defp rename_var(ast, name, {to, _, _}) do
    Macro.prewalk(ast, fn
      {^name, meta, ctx} when is_atom(ctx) -> {to, meta, nil}
      other -> other
    end)
  end

  # Elixir allows only guard-safe expressions in guards: no kernel calls,
  # indexing or `&&`. An error in a guard fails its clause: a zero
  # divisor in div, rem or `/`, and a float result that is inf or NaN. The
  # guard is computed with flagged operations: `bad` is set by those errors,
  # and the guard is then false, as a whole (an error in the left of an `or`
  # fails the guard too, but an operand a short-circuit skips never runs).
  # A result outside i64 is not an Elixir error (Elixir has no i64 limit):
  # `ovf` is set, and the guard is replayed with the raising checks, which
  # raise as the unguarded operation does. The guard error wins:
  # Elixir fails such a guard whatever the exact value, so `bad` decides
  # before `ovf`, in either order. An overflowed value is not Elixir's value,
  # so it decides nothing (guard_poison/4): an error whose operands were
  # computed from it is not flagged, and an and/or whose left side it decides
  # raises (`stop`, set only while no error came first) unless the operand is
  # an `and` whose false fails the guard anyway (guard_false_pos/1), whose
  # right side then runs: its error fails the guard. A guard with no
  # operation that can fail lowers as written, with no flags.
  # A case guard as a C condition. Lowered once with placeholder flags: when
  # no flag appears nothing can fail and that is the guard. Otherwise the
  # flags are real locals, reset on every evaluation. Inside a speculated
  # select (env.ovf) an overflow sets the select's own flag, which replays the
  # clauses with a guard that raises; elsewhere it replays this guard.
  @guard_bad "defk guard bad"
  @guard_ovf "defk guard ovf"
  @guard_stop "defk guard stop"

  defp guard_expr(guard, env) do
    guard = guard_false_pos(guard)
    gv = Map.merge(env, %{ovf: @guard_ovf, bad: @guard_bad, stop: @guard_stop})
    {s, v} = lower_expr(guard, gv)
    0 = IO.iodata_length(s)
    bad? = String.contains?(v.c, "&" <> @guard_bad)
    ovf? = String.contains?(v.c, "&" <> @guard_ovf)
    outer = Map.get(env, :ovf)
    {c, bad, ovf, stop} = guard_flags(v.c, ovf?, outer)

    cond do
      not (bad? or ovf?) ->
        {[], v}

      outer != nil and bad == false ->
        {[], val(c, :bool)}

      # the select replays with a raising guard when its flag is set, so
      # only an error matters here
      outer != nil ->
        g = fresh("guard", :bool)
        {[], val("(#{bad} = 0, #{g} = (#{c}), !#{bad} && #{g})", :bool)}

      true ->
        {[], val(guard_decide(guard, env, c, bad, ovf? && ovf, stop), :bool)}
    end
  end

  # The guard's C with its placeholder flags made locals (`bad`, `stop`) or
  # the outer select's flag (`ovf`), each false when it cannot be set
  defp guard_flags(c, ovf?, outer) do
    stop? = String.contains?(c, @guard_stop)
    bad = (String.contains?(c, "&" <> @guard_bad) or stop?) && fresh("gbad", :bool)
    ovf = if ovf? and outer == nil, do: fresh("govf", :bool), else: outer
    stop = stop? && fresh("gstop", :bool)

    c =
      c
      |> String.replace(@guard_bad, bad || "")
      |> String.replace(@guard_ovf, ovf || "")
      |> String.replace(@guard_stop, stop || "")

    {c, bad, ovf, stop}
  end

  # The guard `c` with its flags (each a local, or false when it cannot be
  # set) decided: an error (not after a `stop`) fails it, else an overflow
  # replays it with the raising checks, else its value.
  defp guard_decide(guard, env, c, bad, ovf, stop) do
    g = fresh("guard", :bool)
    resets = [bad, ovf, stop] |> Enum.filter(& &1) |> Enum.map_join(", ", &"#{&1} = 0")
    failed = if stop, do: "#{bad} && !#{stop}", else: bad

    ok =
      if ovf do
        {_, plain} = lower_expr(guard, env)
        "DEFK_UNLIKELY(#{ovf}) ? ((void)(#{plain.c}), 0) : #{g}"
      else
        g
      end

    ok = if bad, do: "#{failed} ? 0 : (#{ok})", else: ok
    "(#{resets}, #{g} = (#{c}), #{ok})"
  end

  # `va cop vb`. In a case guard (env.bad) whose left side may overflow, an
  # overflowed left side does not decide which side runs (guard_expr): an
  # `and` whose false fails the guard runs its right side (an error there
  # fails the guard whatever the left side's exact value); any other sets
  # `stop` unless an error came first, and the guard raises the overflow.
  defp guard_short_circuit(va, vb, cop, m, env) do
    ovf = Map.has_key?(env, :bad) && env.ovf

    if ovf && String.contains?(va.c, "&" <> ovf) do
      l = fresh("gl", :bool)
      saved = fresh("gsave", :bool)
      poisoned = fresh("gpoison", :bool)

      left =
        "(#{saved} = #{ovf}, #{ovf} = 0, #{l} = #{va.c}, #{poisoned} = #{ovf}, #{ovf} |= #{saved}, "

      if cop == "&&" and m[:defk_false_pos] do
        left <> "(#{l} || #{poisoned}) && #{vb.c})"
      else
        left <> "#{poisoned} ? ((#{env.bad} || (#{env.stop} = 1)), 0) : (#{l} #{cop} #{vb.c}))"
      end
    else
      "(#{va.c} #{cop} #{vb.c})"
    end
  end

  # The `and` nodes of a guard whose false fails the guard: the root and,
  # through them, the operands of an `and` there. Their meta carries
  # :defk_false_pos, read by the and/or lowering under an overflow.
  defp guard_false_pos({:and, m, [a, b]}),
    do: {:and, [{:defk_false_pos, true} | m], [guard_false_pos(a), guard_false_pos(b)]}

  defp guard_false_pos(other), do: other

  # In a case guard (env.bad), the C of an operation `call` on the operands
  # `vs` whose result depends on whether any of the `watched` (a suffix of
  # `vs`) was computed with an overflow: a divisor's zero, a float result's
  # finiteness. When one was, the operation is skipped (its result is
  # poisoned, the overflow already flagged): an overflowed value is not
  # Elixir's, so its error is not Elixir's either. The overflow flag is saved,
  # cleared around the watched operands and restored, the operands evaluated
  # in order into temporaries. Elsewhere, or with no overflow possible in the
  # watched operands, the operation as written.
  defp guard_poison(vs, watched, env, call) do
    {pre, post} = Enum.split(vs, length(vs) - watched)
    ovf = Map.has_key?(env, :bad) && env.ovf

    if ovf && Enum.any?(post, &String.contains?(&1.c, "&" <> ovf)) do
      tmps = Enum.map(vs, &fresh("gop", &1.t))
      {tpre, tpost} = Enum.split(tmps, length(pre))
      saved = fresh("gsave", :bool)
      poisoned = fresh("gpoison", :bool)
      assign = fn ts, xs -> Enum.zip_with(ts, xs, &"#{&1} = #{&2.c}, ") end

      [
        "(",
        assign.(tpre, pre),
        "#{saved} = #{ovf}, #{ovf} = 0, ",
        assign.(tpost, post),
        "#{poisoned} = #{ovf}, #{ovf} |= #{saved}, ",
        "#{poisoned} ? 0 : #{call.(tmps)})"
      ]
      |> IO.iodata_to_binary()
    else
      call.(Enum.map(vs, & &1.c))
    end
  end

  @guard_ops [
    :+,
    :-,
    :*,
    :/,
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :and,
    :or,
    :not,
    :div,
    :rem,
    :abs,
    :trunc,
    :round,
    :min,
    :max
  ]

  defp guard_safe!(guard) do
    case guard do
      x when is_number(x) or is_boolean(x) ->
        :ok

      {v, _, ctx} when is_atom(v) and is_atom(ctx) ->
        :ok

      {op, _, args} when op in @guard_ops and is_list(args) ->
        Enum.each(args, &guard_safe!/1)

      {:@, _, _} = a ->
        match?({:ok, b} when is_binary(b), Defk.Attributes.of(a)) || attribute!(a)
        err!(a, "case-guard", "#{Macro.to_string(a)}, a binary, is not allowed in a case guard")

      {:in, _, _} = node ->
        case Defk.GuardIn.check(node) do
          :ok -> Enum.each(Defk.GuardIn.operands(node), &guard_safe!/1)
          {:error, at, what, opts} -> err!(at, "case-guard", what, opts)
        end

      other ->
        err!(other, "case-guard", "#{Macro.to_string(other)} is not allowed in a case guard")
    end

    guard
  end

  # The operands of an `in` in a guard are integers (a bool list takes a bool
  # on the left), as in Elixir, where `1.0 in 1..3` is false; the guard's
  # comparisons would say true for a float.
  defp in_types!(guard, env, show) do
    Macro.prewalk(guard, fn
      {:in, _, [lhs, _]} = node ->
        kind = Defk.GuardIn.kind(node)
        [lhs_t | bound_ts] = for e <- Defk.GuardIn.operands(node), do: guard_type(e, env)
        in_lhs_type!(node, kind, lhs, lhs_t, show)

        for {e, t} <- Enum.zip(tl(Defk.GuardIn.operands(node)), bound_ts),
            t != :i64,
            do: in_type_err!(node, e, t, "as a bound of", show)

        node

      other ->
        other
    end)

    guard
  end

  defp in_lhs_type!(node, kind, lhs, t, show) do
    cond do
      kind == :range and t == :i64 -> :ok
      kind == :int_list and t == :i64 -> :ok
      kind == :bool_list and t == :bool -> :ok
      kind != :range and t in [:i64, :bool] -> in_never!(node, lhs, t, show)
      true -> in_type_err!(node, lhs, t, "on the left of", show)
    end
  end

  @spec in_never!(term(), term(), term(), term()) :: no_return()
  defp in_never!(node, lhs, t, show) do
    err!(
      node,
      "case-guard",
      "#{show.(node)} never matches: #{show.(lhs)} is #{fmt(t)}, the list holds #{if t == :bool, do: "integers", else: "booleans"}",
      hint: "match a value of the subject's type"
    )
  end

  @spec in_type_err!(term(), term(), term(), term(), term()) :: no_return()
  defp in_type_err!(node, e, t, where, show) do
    err!(
      node,
      "case-guard",
      "#{show.(e)} is #{fmt(t)}, an integer#{if Defk.GuardIn.kind(node) != :range, do: " or bool"} is needed #{where} #{show.(node)}"
    )
  end

  # prints an AST with the case subject under the pattern variable's name
  defp unrename({v, _, ctx}, name) when is_atom(v) and is_atom(ctx),
    do: &Macro.to_string(rename_var(&1, name, {v, [], nil}))

  defp unrename(_pat, _name), do: &Macro.to_string/1

  defp guard_type(e, env), do: e |> lower_expr(env) |> elem(1) |> Map.fetch!(:t)

  # `weight` back-edges are charged to the budget at once
  defp safepoint(weight \\ "1") do
    n = low(:sp) + 1
    low_put(:sp, n)
    low_put(:sps, [{n, Enum.reverse(low(:loops))} | low(:sps)])
    "DEFK_SP(#{n}, #{weight})\n"
  end

  # ---------------------------------------------------------- range facts --
  # The lattice lives in Defk.Facts: what a value is known to
  # satisfy, the derivations, and the proofs (in_bounds?, in_i64?) that drop
  # checks. This file creates facts and asks those questions; it holds no
  # fact algebra of its own.

  # A comparison's relation (Facts.relation/3), from i64 operands computed
  # without a check: a flagged strip computes on past a failed check, so a
  # condition on a checked value could narrow by a wrong one (ADR-0007).
  # Outside every loop no strip runs, and a failed check raises (a case
  # guard's flags and computes on), so there a checked operand is exact too:
  # a raising guard `length(m) == n * dim` narrows by its checked product.
  # The operands are judged before in_order/3 may move one into a local.
  defp relation(op, [{_, va}, {_, vb}], env) do
    exact? =
      (low(:loops) == [] and not Map.has_key?(env, :bad)) or
        (check_free?(va) and check_free?(vb))

    if va.t == :i64 and vb.t == :i64 and exact?, do: Facts.relation(op, va, vb)
  end

  # every check calls a runtime helper (defk_*), and every raise goes
  # through ctx
  defp check_free?(%{c: c}), do: not (c =~ "ctx" or c =~ "defk_")

  # `env` where relation `rel` is `true?` (Facts.holds/2): each fact on its
  # newest atom, in that atom's binding (env.atoms and the i64 binding for a
  # C variable, the array binding for a length), so a read of the binding
  # and the prover both see it. The env is lexical: the facts end with the
  # branch, filter or loop body they were made for.
  defp narrow(env, rel, true?) do
    rel
    |> Facts.holds(true?)
    |> Enum.reduce(env, fn d, env ->
      {x, kind, b} = Facts.narrowing(d)
      narrow_atom(env, x, kind, b)
    end)
  end

  # a product's fact goes on the binding of its newer factor
  defp narrow_atom(env, {:mul, y, _} = x, kind, b), do: narrow_on(env, y, x, kind, b)
  defp narrow_atom(env, x, kind, b), do: narrow_on(env, x, x, kind, b)

  defp narrow_on(env, {:var, c}, x, kind, b) do
    atoms = env[:atoms] || %{}
    f = Facts.facts(Facts.narrow(%{facts: atoms[c] || Facts.none()}, x, kind, b))

    Map.merge(env, %{atoms: Map.put(atoms, c, f), vars: narrow_vars(env.vars, c, x, kind, b)})
  end

  defp narrow_on(env, {:len, c}, x, kind, b),
    do: %{env | vars: narrow_vars(env.vars, c, x, kind, b)}

  defp narrow_vars(vars, c, x, kind, b) do
    Map.new(vars, fn
      {n, %{c: ^c} = v} -> {n, Facts.narrow(v, x, kind, b)}
      kv -> kv
    end)
  end

  # A raising guard: the statements after `if c` see the condition of the
  # arm that does not raise, as the one that does never reaches them.
  defp guarded(env, rel, do_ast, else_ast) do
    case {raises?(do_ast), raises?(else_ast)} do
      {true, false} -> narrow(env, rel, false)
      {false, true} -> narrow(env, rel, true)
      _ -> env
    end
  end

  # every path through the block raises: one of its statements is a raise,
  # or an if whose arms both raise
  defp raises?({:__block__, _, es}), do: Enum.any?(es, &raises?/1)
  defp raises?({:raise, _, args}) when is_list(args), do: true

  defp raises?({:if, _, [_, kw]}) when is_list(kw),
    do: raises?(Keyword.get(kw, :do)) and raises?(Keyword.get(kw, :else))

  defp raises?(_), do: false

  # ------------------------------------------------------- element types --
  # A narrow element (u8, i16, i32, f32) widens when read: an integer to an
  # i64 that carries its type's range as facts, an f32 to the f64 of the same
  # value. A write takes the wide type and must fit: the store checks the
  # range (defk_to_*), unless the value's facts prove it fits, as for
  # max(min(v, 32_767), -32_768) into [i16].

  @int_range %{u8: {0, 255}, i16: {-32_768, 32_767}, i32: {-2_147_483_648, 2_147_483_647}}

  defp wide(e) when e in [:f64, :f32], do: :f64
  defp wide(:u64), do: :u64
  defp wide(_e), do: :i64

  defp widen(c, :f32), do: "((double)#{c})"
  defp widen(c, e) when is_map_key(@int_range, e), do: "((int64_t)#{c})"
  defp widen(c, _e), do: c

  defp elem_val(c, e) when is_map_key(@int_range, e) do
    {lo, hi} = @int_range[e]
    Facts.assert(val(c, :i64), lo: lo, hi: hi)
  end

  defp elem_val(c, e), do: val(c, wide(e))

  # the C value stored into [e], from v of type wide(e)
  defp narrowed(v, :f32), do: "defk_to_f32(ctx, #{v.c})"

  defp narrowed(v, e) when is_map_key(@int_range, e) do
    {lo, hi} = @int_range[e]

    if is_integer(Facts.lo(v)) and is_integer(Facts.hi(v)) and Facts.lo(v) >= lo and
         Facts.hi(v) <= hi,
       do: "((#{ctype_elem(e)})#{v.c})",
       else: "defk_to_#{e}(ctx, #{v.c})"
  end

  defp narrowed(v, _e), do: v.c

  # The C value stored into an integer [e] from an integer v: a
  # value that doesn't fit raises ArgumentError, as a [u8] write of 300
  # does. A u64 above 2^63 - 1 saturates before a narrow check, which then
  # fails.
  defp int_stored(%{t: :u64} = v, :u64), do: v.c

  defp int_stored(%{t: :i64} = v, :u64),
    do: if(Facts.nonneg?(v), do: v.c, else: "defk_to_u64(ctx, #{v.c})")

  defp int_stored(%{t: :u64} = v, :i64) do
    if is_integer(Facts.hi(v)) and Facts.hi(v) <= @max_i64,
      do: "((int64_t)#{v.c})",
      else: "defk_to_i64_elem(ctx, #{v.c})"
  end

  defp int_stored(%{t: :u64} = v, e), do: narrowed(%{v | c: "defk_u64_sat(#{v.c})", t: :i64}, e)
  defp int_stored(v, e), do: narrowed(v, e)

  defp ctype_elem(:u8), do: "uint8_t"
  defp ctype_elem(e), do: "#{String.replace(to_string(e), "i", "int")}_t"

  defp literal_int(n) when is_integer(n), do: n
  defp literal_int({:-, _, [n]}) when is_integer(n), do: -n
  defp literal_int(_), do: nil

  # ------------------------------------------------------------ emitting ---

  defp emit_entry(k) do
    f = "frame_#{k.cid}"
    arrays = for {{p, {:arr, _}}, i} <- Enum.with_index(k.params), do: {p, i}
    scalars = for {{p, t}, i} <- Enum.with_index(k.params), t in @scalars, do: {p, t, i}

    params = Enum.map(scalars, fn {p, _, _} -> "p_#{sanitize(p)}" end)
    yields? = yields?(k)
    {stmts, saves} = safepoint_saves(k, params)
    # the frame holds what some safepoint spills
    framed = if yields?, do: Enum.uniq(Enum.flat_map(saves, &elem(&1, 1))), else: []

    [
      "/* ---- #{k.name}/#{k.arity}#{if yields?, do: " (yielding)", else: ""} ---- */\n",
      "typedef struct {\n  defk_ctx ctx;\n  int resume;\n  int64_t budget;\n  int copy[#{max(k.arity, 1)}];\n",
      frame_fields(k, framed),
      "} #{f};\n\n",
      # noinline: keep the kernel body out of the setjmp frame below
      "static __attribute__((noinline)) int run_#{k.cid}(ErlNifEnv *env, #{f} *F, const ERL_NIF_TERM *argv, ERL_NIF_TERM *result) {\n",
      "defk_ctx *ctx = &F->ctx;\n",
      run_preamble(yields?),
      zero_params(k),
      decl_locals(k),
      bind_params(k, arrays),
      resume_block(yields?, k, saves),
      decode_params(scalars),
      sp_macro(yields?, k, saves),
      stmts,
      "*result = #{emit_result(k)};\nreturn DEFK_DONE;\n",
      @undef_macros,
      if(yields?, do: Enum.map(saves, fn {n, _} -> "#undef DEFK_SAVE#{n}\n" end), else: []),
      "}\n\n",
      guard_fn(k, f),
      step_fn(yields?, k, f),
      nif_fn(yields?, k, f)
    ]
  end

  defp frame_fields(k, framed) do
    framed = MapSet.new(framed)

    Enum.map(k.params, fn {p, t} -> "  #{ctype(t)} p_#{sanitize(p)};\n" end) ++
      for {c, ct} <- k.decls, c in framed, do: "  #{ct} #{c};\n"
  end

  # {the kernel's statements, [{n, locals}]}: what safepoint n spills, the
  # locals live where it resumes, at the header of its own loop. A local
  # bound in the body of loop L (fresh/2 notes the innermost open loop) is
  # written before it is read in every iteration of L: it is dead wherever
  # control is not inside an iteration of L, which is at L's own header and
  # anywhere outside L. Only a safepoint in a loop nested in L spills it;
  # the others leave it out, when every mention of it in the C is between
  # L's in_loop/1 markers (a local mentioned outside is spilled everywhere,
  # as before). A dead local in a spill list is not wrong, but it is read
  # at the safepoint, so the C compiler keeps its value alive into it: a
  # temporary of an inner loop becomes a value that loop carries out to
  # the enclosing loop's safepoint. With Keccak's 25 lanes that spilled
  # half the state on every round. The markers are removed.
  defp safepoint_saves(k, params) do
    text = IO.iodata_to_binary(k.stmts)
    marks = Regex.scan(~r{/\* defk:(in|out) (\d+) \*/\n}, text, return: :index)

    extent =
      Enum.reduce(marks, %{}, fn [{at, len}, {ks, kl}, {is, il}], acc ->
        id = String.to_integer(binary_part(text, is, il))

        case binary_part(text, ks, kl) do
          "in" -> Map.put(acc, id, {at + len, nil})
          "out" -> Map.update!(acc, id, fn {from, nil} -> {from, at} end)
        end
      end)

    mentions =
      Regex.scan(~r/\bv_\w+/, text, return: :index)
      |> Enum.group_by(fn [{at, len}] -> binary_part(text, at, len) end, fn [{at, _}] -> at end)

    inside? = fn c ->
      case extent[k.decl_loop[c]] do
        {from, to} -> Enum.all?(Map.get(mentions, c, []), &(&1 >= from and &1 < to))
        nil -> false
      end
    end

    local = for {c, _} <- k.decls, inside?.(c), into: %{}, do: {c, k.decl_loop[c]}

    saves =
      for {n, path} <- Enum.sort(k.sps) do
        open = MapSet.new(Enum.drop(path, -1))
        {n, params ++ for({c, _} <- k.decls, not dead_at?(local, c, open), do: c)}
      end

    text = String.replace(text, ~r{/\* defk:(in|out) \d+ \*/\n}, "")
    {arrival_blocks(text, k.sps, yields?(k)), saves}
  end

  # a local of a loop whose iterations do not enclose the safepoint
  defp dead_at?(local, c, open), do: Map.has_key?(local, c) and local[c] not in open

  defp run_preamble(yields?) do
    if yields?,
      do:
        "int defk_rs = F->resume;\nint64_t defk_ticks = 0;\nint64_t defk_budget = defk_rs ? F->budget : DEFK_BUDGET0;\ndefk_clock defk_clk;\ndefk_clock_init(&defk_clk, ctx);\n",
      else: ""
  end

  defp zero_params(k),
    do: Enum.map(k.params, fn {p, t} -> "#{ctype(t)} p_#{sanitize(p)} = {0};\n" end)

  defp bind_params(k, arrays) do
    # a misaligned input is copied at once unless the kernel yields: then
    # the prologue's strip loops (bind_strips/1) fill the buffer
    once = if yields?(k), do: 0, else: 1

    Enum.map(arrays, fn {p, i} ->
      {:arr, e} = Keyword.fetch!(k.params, p)
      sp = "p_#{sanitize(p)}"

      # bind through temporaries: if the view's address escaped, clang would
      # reload data/len on every iteration (the yield call might change them)
      "{ void *d; int64_t l; defk_bind(env, ctx, argv[#{i}], sizeof(*#{sp}.data), &d, &l, &F->copy[#{i}], #{i + 1}, \"#{p}\", \"#{e}\", #{once}); #{sp}.data = d; #{sp}.len = l; }\n"
    end)
  end

  # Each safepoint restores what it spilled. An array local may hold an input
  # array's view (an array from a branch, an unwritten array a callee
  # returns, a loop's walk over an input), and the binary may have
  # moved in a GC since the yield: a local whose data was an input's at the
  # yield (the input as the safepoint saved it, F->p_x) takes that input's
  # new data, bound above. A view of no input (an owned buffer, a binary
  # literal) never moves. Inputs, owned buffers and literals are distinct
  # memory while the kernel runs, so a non-empty view is one of them; an
  # empty one is never read.
  defp resume_block(yields?, k, saves) do
    if yields? do
      [
        "if (defk_rs) {\nswitch (defk_rs) {\n",
        Enum.map(saves, fn {n, saved} ->
          rebinds = Enum.map(input_aliases(k, saved), &rebind_view/1)
          ["case #{n}:\n", Enum.map(saved, &"#{&1} = F->#{&1};\n"), rebinds, "break;\n"]
        end),
        "}\ndefk_rs *= 256;\nswitch (defk_rs) {\n",
        resume_cases(k.sps, []),
        "}\n}\n"
      ]
    else
      ""
    end
  end

  defp decode_params(scalars) do
    Enum.map(scalars, fn {p, t, i} ->
      "p_#{sanitize(p)} = defk_get_#{t}_arg(env, ctx, argv[#{i}], #{i + 1}, \"#{p}\");\n"
    end)
  end

  # local `c` that was a view of one of inputs `ps` at the yield takes its
  # new data (else-if: a new address may equal another input's old one)
  defp rebind_view({c, ps}) do
    Enum.map_join(ps, "else ", fn p ->
      "if (F->#{p}.len > 0 && #{c}.data == F->#{p}.data) #{c}.data = #{p}.data;\n"
    end)
  end

  # [{local, input parameters}] for the array locals among `saved` and the
  # array parameters of their type, which they may be a view of at a yield
  defp input_aliases(k, saved) do
    types = Map.new(k.decls)

    inputs =
      for {p, {:arr, _} = t} <- k.params, do: {"p_#{sanitize(p)}", ctype(t)}

    for c <- saved,
        t = types[c],
        ps = for({p, ^t} <- inputs, do: p),
        ps != [],
        do: {c, ps}
  end

  defp sp_macro(yields?, k, saves) do
    if yields? do
      Enum.map_join(saves, fn {n, saved} ->
        inputs = k |> input_aliases(saved) |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
        "#define DEFK_SAVE#{n} #{Enum.map(saved ++ inputs, &"F->#{&1} = #{&1}; ")}\n"
      end) <>
        "#define DEFK_SP(N, W) if (DEFK_UNLIKELY((defk_ticks += (W)) >= defk_budget)) { defk_ticks = 0; if (!(defk_budget = defk_tick(env, &defk_clk, defk_budget))) { if (DEFK_UNLIKELY(F->resume)) { defk_lost_resume(ctx, F->resume, N); return DEFK_ERR; } DEFK_SAVE##N F->resume = N; F->budget = defk_clk.budget; return DEFK_YIELD; } }\n" <>
        "#define DEFK_SHORT(R) DEFK_LIKELY((R) < DEFK_STRIP)\n#define DEFK_TICKS(W) defk_ticks += (W);\n#define DEFK_RESUMING DEFK_UNLIKELY(defk_rs)\n"
    else
      @no_yield_macros
    end
  end

  # the kernel's result term; each element is {c, type, term}
  defp emit_result(k) do
    views = Map.get(k, :ret_views, Enum.map(k.ret_vals, fn _ -> false end))

    terms =
      Enum.zip_with(k.ret_vals, views, fn {c, t}, view? ->
        {c, t, if(view?, do: view_term(c, t, k), else: to_term(c, t))}
      end)

    case terms do
      [{_, _, term}] ->
        term

      many ->
        if Enum.count(many, &match?({_, {:arr, _}, _}, &1)) < 2,
          do: plain_tuple(many),
          else: shared_tuple(many)
    end
  end

  # An array the kernel may not own: the caller's own binary when
  # it is an input array of the same type, the same data and length (so an
  # unwritten input is returned as it came, no copy); else an owned buffer
  # handed over, or a binary literal's bytes in a new binary
  # (defk_make_arr_view).
  defp view_term(c, {:arr, _} = t, k) do
    inputs =
      for {{p, ^t}, i} <- Enum.with_index(k.params) do
        sp = "p_#{sanitize(p)}"
        "(#{c}).data == #{sp}.data && (#{c}).len == #{sp}.len ? argv[#{i}] : "
      end

    "(#{inputs}defk_make_arr_view(env, ctx, (#{c}).data, (size_t)(#{c}).len * sizeof(*(#{c}).data)))"
  end

  defp plain_tuple(many),
    do:
      "enif_make_tuple(env, #{length(many)}#{Enum.map(many, fn {_, _, term} -> ", " <> term end)})"

  defp shared_tuple(many) do
    # two elements may be one buffer (`{a, b}` after `b = a`): its binary
    # is handed over once and both elements are that term
    {decls, _} =
      many
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {{c, t, term}, i}, arrays ->
        r = "defk_r#{i}"

        if match?({:arr, _}, t) do
          term =
            Enum.reduce(arrays, term, fn {pc, pr}, rest ->
              "(#{c}).data == (#{pc}).data && (#{c}).len == (#{pc}).len ? #{pr} : #{rest}"
            end)

          {"ERL_NIF_TERM #{r} = #{term}; ", [{c, r} | arrays]}
        else
          {"ERL_NIF_TERM #{r} = #{term}; ", arrays}
        end
      end)

    terms = Enum.map_join(0..(length(many) - 1), &", defk_r#{&1}")
    "({ #{decls}enif_make_tuple(env, #{length(many)}#{terms}); })"
  end

  # setjmp lives in a separate frame so it does not pessimise the kernel body.
  # defk_cur_ctx marks the call as running on this thread for the fault
  # handler: set before the body, cleared on every way out.
  defp guard_fn(k, f) do
    "static __attribute__((noinline)) int guard_#{k.cid}(ErlNifEnv *env, #{f} *F, const ERL_NIF_TERM *argv, ERL_NIF_TERM *result) {\n" <>
      "defk_ctx **defk_slot = &defk_cur_ctx; /* one thread-local lookup per call */\n" <>
      "if (sigsetjmp(F->ctx.jb, 0)) { *defk_slot = NULL; return DEFK_ERR; }\n" <>
      "*defk_slot = &F->ctx;\nint r = run_#{k.cid}(env, F, argv, result);\n*defk_slot = NULL;\nreturn r;\n}\n\n"
  end

  defp step_fn(yields?, k, f) do
    if yields? do
      [
        "static ERL_NIF_TERM step_#{k.cid}(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {\n",
        "#{f} *F;\nERL_NIF_TERM res;\n",
        "ERL_NIF_TERM exc;\nF = defk_frame_of(env, argv[0], sizeof *F, &exc);\nif (DEFK_UNLIKELY(!F)) return exc;\n",
        "int r = guard_#{k.cid}(env, F, argv + 1, &res);\n",
        "if (DEFK_UNLIKELY(r == DEFK_DONE && F->resume)) { defk_lost_resume(&F->ctx, F->resume, 0); r = DEFK_ERR; }\n",
        "if (r == DEFK_YIELD) {\natomic_fetch_add(&defk_stat_yields, 1);\n",
        "return enif_schedule_nif(env, \"#{k.name}\", 0, step_#{k.cid}, argc, argv);\n}\n",
        "defk_finish(&F->ctx);\n",
        "return r == DEFK_ERR ? defk_raise(env, &F->ctx) : res;\n}\n\n"
      ]
    else
      ""
    end
  end

  defp nif_fn(yields?, k, f) do
    [
      "static ERL_NIF_TERM nif_#{k.cid}(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {\n",
      "#{f} local;\nERL_NIF_TERM res;\n",
      "local.ctx.err = 0;\nlocal.ctx.owned = NULL;\nlocal.ctx.nowned = local.ctx.cap = 0;\nlocal.ctx.owned_bytes = 0;\nlocal.ctx.finished = local.ctx.is_resource = 0;\n",
      "local.resume = 0;\nmemset(local.copy, 0, sizeof local.copy);\n",
      # the run-queue hint, when the NIF takes one, is the last argument
      "defk_slice_init(env, &local.ctx, argc > #{k.arity} ? &argv[#{k.arity}] : NULL);\n",
      "int r = guard_#{k.cid}(env, &local, argv, &res);\n",
      promote(yields?, k),
      "defk_finish(&local.ctx);\n",
      "return r == DEFK_ERR ? defk_raise(env, &local.ctx) : res;\n}\n\n"
    ]
  end

  defp promote(yields?, k) do
    if yields? do
      [
        "if (r == DEFK_YIELD) {\n",
        "ERL_NIF_TERM args2[#{k.arity + 1}];\n",
        "defk_promote(env, &local, sizeof local, &args2[0]);\n",
        "memcpy(args2 + 1, argv, sizeof(ERL_NIF_TERM) * #{k.arity});\n",
        "atomic_fetch_add(&defk_stat_yields, 1);\n",
        "return enif_schedule_nif(env, \"#{k.name}\", 0, step_#{k.cid}, #{k.arity + 1}, args2);\n}\n"
      ]
    else
      ""
    end
  end

  # a yielding kernel's NIF takes the run-queue hint as an extra last
  # argument (defk_slice_init) unless the module opted out
  defp yields?(k), do: k.yield and k.sp_count > 0

  defp emit_init(module, kernels, nif_name, fault_hooks?, adaptive?) do
    funcs =
      Enum.map(kernels, fn k ->
        if adaptive? and yields?(k),
          do:
            "  {\"#{Defk.ElixirMode.native_name(k.name)}\", #{k.arity + 1}, nif_#{k.cid}, 0},\n",
          else: "  {\"#{nif_name.(k.name)}\", #{k.arity}, nif_#{k.cid}, 0},\n"
      end)

    [
      "static ErlNifFunc defk_funcs[] = {\n",
      funcs,
      "  {\"__defk_stats__\", 0, defk_stats_nif, 0},\n",
      "  {\"__defk_force_yields__\", 1, defk_force_yields_nif, 0},\n",
      if(fault_hooks?,
        do:
          "  {\"__defk_corrupt_tags__\", 1, defk_corrupt_tags_nif, 0},\n" <>
            "  {\"__defk_inject_fault__\", 1, defk_inject_fault_nif, 0},\n",
        else: ""
      ),
      "};\n\n",
      "ERL_NIF_INIT(#{Atom.to_string(module)}, defk_funcs, defk_load, NULL, defk_upgrade, defk_unload)\n"
    ]
  end

  defp decl_locals(k), do: Enum.map(k.decls, fn {c, ct} -> "#{ct} #{c} = {0};\n" end)

  defp to_term(c, :i64), do: "enif_make_int64(env, #{c})"
  defp to_term(c, :u64), do: "enif_make_uint64(env, #{c})"
  defp to_term(c, :f64), do: "defk_make_f64(ctx, env, #{c})"
  defp to_term(c, :bool), do: "defk_make_bool(env, #{c})"
  defp to_term(c, {:arr, _}), do: "defk_make_arr(env, ctx, (#{c}).data)"
  defp to_term(c, :bitstring), do: "defk_make_bits(env, ctx, #{c})"

  # -------------------------------------------------------------- helpers --

  defp val(c, t, var \\ nil), do: %{c: c, t: t, owned: false, var: var}

  defp fresh(base, t) do
    n = low(:n) + 1
    low_put(:n, n)
    c = "v_#{sanitize(base)}_#{n}"
    low_put(:decls, [{c, ctype(t)} | low(:decls)])
    # the innermost loop open where it is bound (safepoint_saves/2)
    loop = List.first(low(:loops))
    low_put(:decl_loop, Map.put(low(:decl_loop), c, loop))
    c
  end

  defp ctype(:i64), do: "int64_t"
  defp ctype(:u64), do: "uint64_t"
  defp ctype(:f64), do: "double"
  defp ctype(:bool), do: "int"
  defp ctype({:arr, e}), do: "defk_arr_#{e}"
  defp ctype(:bitstring), do: "defk_bits"
  defp ctype({:c, ct}), do: ct

  defp to_f(%{t: t, c: c}) when t in @ints, do: "((double)#{c})"
  defp to_f(%{c: c}), do: c

  defp numeric?(v), do: v.t in [:i64, :u64, :f64]
  # `at` is the operand's expression; `op` names what takes it
  defp numeric!(v, at, op) do
    numeric?(v) ||
      err!(
        at,
        "operand-type",
        "#{op} takes numbers, and #{Macro.to_string(at)} is #{type_name(v)}",
        convert_hint(v.t, :i64, at) ++ operand_why(v.t, :number)
      )
  end

  defp bool!(v, at, op) do
    takes = if is_binary(op), do: "#{op} must be a boolean", else: "#{op} takes booleans"

    v.t == :bool ||
      err!(
        at,
        "operand-type",
        "#{takes}, and #{Macro.to_string(at)} is #{type_name(v)}",
        convert_hint(v.t, :bool, at) ++ operand_why(v.t, :bool)
      )
  end

  # The why of an operand-type error, for an operand of type `t` where the
  # operator takes `takes`; other operands keep the registry's general why.
  defp operand_why(:bool, takes) when takes in [:number, :integer],
    do: [why: "booleans are not numbers in Elixir, and defk keeps that"]

  defp operand_why(:f64, :integer),
    do: [why: "defk never converts a float to an integer implicitly"]

  defp operand_why(t, :bool) when t in [:i64, :u64, :f64],
    do: [why: "a number is not a boolean in Elixir (0 is not false), and defk keeps that"]

  defp operand_why(_t, _takes), do: []

  defp type_name(%{elems: _, t: t}), do: "a tuple #{fmt(t)}"
  defp type_name(%{t: t}), do: fmt(t)

  # ------------------------------------------------------ more rejections --

  # a read-only [u8] view over a static C array; its length is a known fact.
  # The bytes are one `static const uint8_t` array per module, named by a hash
  # of the contents, however often a use site is inlined.
  defp static_u8(b) do
    name = "defk_lit_" <> Base.encode16(binary_part(:crypto.hash(:sha256, b), 0, 8), case: :lower)
    ctx_update(:statics, &Map.put(&1, name, b))
    view = "((defk_arr_u8){(uint8_t *)#{name}, #{byte_size(b)}})"
    Facts.assert(Map.merge(val(view, {:arr, :u8}), %{buf: make_ref()}), len_lo: byte_size(b))
  end

  # The declarations of the static arrays `body` uses (a speculative lowering
  # may have registered others), in name order, ahead of every function.
  defp emit_statics(body) do
    for {name, b} <- Enum.sort(ctx(:statics)), String.contains?(body, name) do
      "static const uint8_t #{name}[] =\n#{c_bytes(b)};\n\n"
    end
  end

  # The bytes of `b` as a C string literal of octal escapes, 64 bytes a line.
  defp c_bytes(""), do: ~s("")

  defp c_bytes(b) do
    b
    |> :binary.bin_to_list()
    |> Enum.chunk_every(64)
    |> Enum.map_join("\n", fn bytes ->
      ~s(") <>
        Enum.map_join(bytes, &("\\" <> String.pad_leading(Integer.to_string(&1, 8), 3, "0"))) <>
        ~s(")
    end)
  end

  # A module attribute whose value is not in the kernel subset: undefined
  # where the kernel is defined, an integer outside i64 and u64, or a value that is
  # not a number, a boolean or a binary.
  @spec attribute!(term()) :: no_return()
  defp attribute!({:@, _, [{name, _, _}]} = node) do
    case Defk.Attributes.of(node) do
      :undefined ->
        err!(
          node,
          "undefined-attribute",
          "@#{name} is not defined where this kernel is defined"
        )

      {:ok, n} when is_integer(n) ->
        err!(node, "integer-literal", "@#{name} is #{n}, which does not fit in i64 or u64",
          hint: "use a value that fits, or a float attribute and compute in f64"
        )

      {:ok, v} ->
        err!(
          node,
          "attribute-value",
          "@#{name} is #{Defk.Attributes.describe(v)}, which is not in the kernel subset",
          attribute_fix(name, v)
        )
    end
  end

  # a list of bytes packs into a binary attribute, read as a [u8]
  defp attribute_fix(name, v) when is_list(v) and v != [] do
    if Enum.all?(v, &(is_integer(&1) and &1 in 0..255)) do
      bin = inspect(:erlang.list_to_binary(v), binaries: :as_binaries, limit: :infinity)

      [
        hint:
          "pack it into a binary attribute and index it as a [u8], or pass it as an array parameter",
        rewrite: "@#{name} #{bin}"
      ]
    else
      [hint: "pass it as an array parameter ([i64] or [f64])"]
    end
  end

  defp attribute_fix(_name, _v), do: []

  @spec not_an_array!(term(), term(), term()) :: no_return()
  defp not_an_array!(node, arr, %{t: :bitstring}), do: bits_read!(node, arr)

  defp not_an_array!(node, arr, a) do
    err!(
      node,
      "not-an-array",
      "#{Macro.to_string(node)} indexes #{Macro.to_string(arr)}, which is #{type_name(a)}, not an array"
    )
  end

  @spec cond_without_true!(term()) :: no_return()
  defp cond_without_true!(node) do
    err!(
      node,
      "cond-without-true",
      "this cond is used as a value but has no `true ->` clause at the end"
    )
  end

  @spec case_form!(term()) :: no_return()
  defp case_form!(node) do
    err!(node, "case-form", "this case has no do block of `pattern -> body` clauses")
  end

  # `fun` (e.g. "Enum.all?/2") called without a literal one-clause fn; `params`
  # name the fn's parameters for the rewrite of a capture
  @spec fn_argument!(term(), term(), term()) :: no_return()
  defp fn_argument!({_, _, args}, fun, params) do
    f = List.last(args)
    vars = Enum.map(params, &{&1, [], nil})

    rewrite =
      case f do
        {:&, _, [{:/, _, [{name, _, ctx}, n]}]}
        when is_atom(name) and is_atom(ctx) and n == length(params) ->
          [rewrite: Macro.to_string({:fn, [], [{:->, [], [vars, {name, [], vars}]}]})]

        {:&, _, [body]} ->
          body =
            Macro.prewalk(body, fn
              {:&, _, [i]} when is_integer(i) and i <= length(params) -> Enum.at(vars, i - 1)
              other -> other
            end)

          [rewrite: Macro.to_string({:fn, [], [{:->, [], [vars, body]}]})]

        _ ->
          []
      end

    err!(
      f,
      "fn-argument",
      "#{fun} with #{Macro.to_string(f)} is not in the kernel subset",
      rewrite
    )
  end

  # a for that would collect values (`into` is its into:, or nil): `what` says how
  @spec for_collect!(term(), term(), term(), term(), term(), term()) :: no_return()
  defp for_collect!(node, quals, body, into, env, what) do
    if into == nil, do: recover_for(node, quals, body, env)

    rewrite =
      case quals do
        [{:<-, _, [x, src]}] when body != nil ->
          Defk.Errors.Rewrites.collect_rewrites(src, x, body, into, returned_type(node, env))

        _ ->
          nil
      end

    err!(node, "for-collect", what, checked_rewrite([rewrite: rewrite], env))
  end

  # Recovery inside a rejected for: its generators, filters and body are
  # lowered as if the for ran for effect, so their own rejections are recorded
  # in the same compile. Nothing about the for's value is checked (the body's
  # last expression is lowered as a statement, and a rejected statement poisons
  # what it binds), and an abandoned statement stays silent, so a rejection
  # that only follows from this one is not reported. Not done for
  # `into:`, whose body is the element of another collection (`<<y::float-64>>`),
  # not a statement, so what it rejects would be an artefact of the rejection.
  defp recover_for(_node, _quals, nil, _env), do: :ok

  defp recover_for(node, quals, body, env) do
    entered = make_ref()

    try do
      lower_quals(quals, loop_env(env, node), fn env ->
        Process.put(entered, true)
        elem(lower_stmts(body, env), 0)
      end)
    catch
      {:defk_reject, d} -> record(d)
      :defk_poison -> :ok
    end

    # a generator or filter that was rejected (or reads a poisoned variable)
    # never reached the body: lower it anyway (recover_body/3)
    unless Process.delete(entered), do: recover_body(quals, body, loop_env(env, node))

    :ok
  end

  # Recovery inside a `for ..., reduce:` whose init or a generator was
  # rejected (or reads a poisoned variable) before the body ran, so the body
  # was never lowered: it is lowered for effect with the accumulator
  # poisoned (its init gave it no value), so its own rejections are recorded
  # in the same compile. A body that did run has reported its own already.
  defp recover_reduce(entered, quals, pat, body, lenv) do
    unless Process.get(entered),
      do: recover_body(quals, body, poison({:=, [], [pat, nil]}, lenv))

    :ok
  end

  # Recovery inside a rejected pipe: the nested call it stands for is lowered
  # as an expression, so the rejections of the calls in it are recorded in
  # the same compile (the first one along the way, as in any expression).
  # Unpiping is exact, so none of them follows from the pipe's rejection.
  # Enum.reduce/3 and Enum.find/3 in it take the forms the compiler knows
  # (Defk.EnumForms), as they do outside a pipe.
  defp recover_pipe(node, env) do
    try do
      node |> Defk.Errors.Rewrites.unpipe() |> Defk.EnumForms.desugar() |> lower_expr(env)
    catch
      {:defk_reject, d} -> record(d)
      :defk_poison -> :ok
    end

    :ok
  end

  # a loop body lowered for effect, with the generators' variables bound to
  # what is certain (a range's i64), else poisoned; its rejections are
  # recorded, and an abandoned statement stays silent
  defp recover_body(quals, body, env) do
    poisoned =
      Enum.reduce(quals, env, fn
        # a range generator's variable is an i64 whatever its bounds
        {:<-, _, [{n, _, ctx}, {op, _, _}]}, env
        when is_atom(n) and is_atom(ctx) and op in [:.., :..//] ->
          put_var(env, n, val(fresh(n, :i64), :i64))

        {:<-, _, [pat, _]}, env ->
          poison({:=, [], [pat, nil]}, env)

        _filter, env ->
          env
      end)

    try do
      lower_stmts(body, poisoned)
    catch
      {:defk_reject, d} -> record(d)
      :defk_poison -> :ok
    end

    :ok
  end

  # The body's type function for a for's rewrite: the element type of the
  # declared return type when the for is the kernel's value and the body's
  # type fits it (the rewrite is still compiled), else the body's own type.
  defp returned_type(node, env) do
    elem =
      case env[:ret] do
        {:arr, e} -> if node in Map.get(env, :ret_fors, []), do: e
        _ -> nil
      end

    fn probe ->
      t = type_in(probe, env)
      if elem != nil and fits_elem?(t, elem), do: elem, else: t
    end
  end

  defp fits_elem?(t, elem) when t in [:i64, :u64], do: elem in [:i64, :u64, :u8, :i16, :i32]
  defp fits_elem?(:f64, elem), do: elem in [:f64, :f32]
  defp fits_elem?(t, t), do: true
  defp fits_elem?(_, _), do: false

  @spec generator_pattern!(term()) :: no_return()
  defp generator_pattern!({:<-, _, [pat, src]} = gen) do
    {opts, what} =
      case {pat, src} do
        {{x, i}, {{:., _, [{:__aliases__, _, [:Enum]}, :with_index]}, _, [arr]}} ->
          a = Macro.to_string(arr)

          {[
             hint:
               "walk the index and read #{Macro.to_string(x)} = #{a}[#{Macro.to_string(i)}] in the body",
             rewrite: "#{Macro.to_string(i)} <- 0..(length(#{a}) - 1)//1"
           ], "the generator #{Macro.to_string(gen)} is not in the kernel subset"}

        _ ->
          {[], "the generator pattern #{Macro.to_string(pat)} is not in the kernel subset"}
      end

    err!(gen, "generator-pattern", what, opts)
  end

  defp last_expr({:__block__, _, [_ | _] = es}), do: List.last(es)
  defp last_expr(e), do: e

  defp cop(:===), do: "=="
  defp cop(:!==), do: "!="
  defp cop(op), do: Atom.to_string(op)

  # The C text comparing `va` OP `vb` by Elixir's semantics, or a rejection.
  defp compare_c(op, va, vb, node) do
    if numeric?(va) and numeric?(vb) do
      compare_numeric_c(op, va, vb, node)
    else
      if va.t == :bool and vb.t == :bool and op in [:==, :!=, :===, :!==] do
        "(#{va.c} #{cop(op)} #{vb.c})"
      else
        err!(
          node,
          "operand-type",
          "#{Macro.to_string(node)} compares #{fmt(va.t)} with #{fmt(vb.t)}",
          why:
            "defk compares numbers by value and booleans only for equality; " <>
              "Elixir's term order between other values is not in the subset",
          hint: "compare two numbers or two booleans"
        )
      end
    end
  end

  # Numeric compare with exact-value semantics: i64 against f64 orders by
  # value (cmp(a, b) OP 0, and cmp(f, i) = -cmp(i, f)), and === tells -0.0
  # from 0.0 the way Erlang's =:= does.
  defp compare_numeric_c(op, va, vb, node) do
    cond do
      # an integer is never === a float; an i64 and a u64 are both integers
      op in [:===, :!==] and (va.t == :f64 or vb.t == :f64) and va.t != vb.t ->
        if op == :===, do: "0", else: "1"

      op in [:===, :!==] and va.t == :f64 and vb.t == :f64 ->
        if op == :===,
          do: "defk_feq_exact(#{va.c}, #{vb.c})",
          else: "(!defk_feq_exact(#{va.c}, #{vb.c}))"

      va.t == vb.t ->
        "(#{va.c} #{cop(op)} #{vb.c})"

      # i64 or u64 against f64, u64 against i64: exact values, as Erlang
      # compares them (cmp(a, b) OP 0, and cmp(b, a) = -cmp(a, b))
      cmp = mixed_cmp(va.t, vb.t) ->
        "(defk_cmp_#{cmp}(#{va.c}, #{vb.c}) #{cop(op)} 0)"

      cmp = mixed_cmp(vb.t, va.t) ->
        "(0 #{cop(op)} defk_cmp_#{cmp}(#{vb.c}, #{va.c}))"

      true ->
        err!(
          node,
          "operand-type",
          "#{Macro.to_string(node)} compares #{fmt(va.t)} with #{fmt(vb.t)}",
          why:
            "defk compares numbers by value and booleans only for equality; " <>
              "Elixir's term order between other values is not in the subset",
          hint: "compare two numbers or two booleans"
        )
    end
  end

  defp mixed_cmp(:i64, :f64), do: "i64_f64"
  defp mixed_cmp(:u64, t) when t in [:i64, :f64], do: "u64_#{t}"
  defp mixed_cmp(_, _), do: nil

  defp fmt({:arr, e}), do: "[#{e}]"
  defp fmt({:tuple, ts}), do: "{#{Enum.map_join(ts, ", ", &fmt/1)}}"
  defp fmt(t), do: Atom.to_string(t)

  defp sanitize(name), do: name |> to_string() |> String.replace(~r/[^A-Za-z0-9_]/, "_")

  # --------------------------------------------------------------- report --
  # The fast-path report (Defk.Report): a handful of lowering sites
  # note what they decided for the hot path with note/4, as {kernel, line,
  # {topic, verdict, text}}, and report/0 returns the notes of the last
  # compile/4 in this process. A note is never read back by the lowering, so
  # the report cannot change a kernel. `kernel` is the kernel called from
  # Elixir; a note inside an inlined call keeps the callee's line. The notes
  # live under lowering keys (lowering_key?/1), so a lowering that is undone
  # and redone (with_acc_facts/2, u64_accs/2) drops its notes with the rest
  # of its state; a note made twice (a select lowers its arms twice) is kept
  # once.

  @doc false
  # The notes of the last compile/4, each kernel's in line order.
  # the fast-path report: one of compile/4's results, never read back by
  # the lowering (a note cannot change a kernel)
  defp report do
    notes = ctx(:report) |> Enum.reverse() |> Enum.uniq()
    order = notes |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    groups = Enum.group_by(notes, &elem(&1, 0))
    Enum.flat_map(order, fn k -> Enum.sort_by(groups[k], &(elem(&1, 1) || 0)) end)
  end

  defp note(topic, at, verdict, text) do
    {kernel, _yield?} = low(:report_kernel)
    n = {kernel, note_line(at), {topic, verdict, text}}
    ctx_update(:report, &[n | &1])
    note_per_iteration(topic, at)
  end

  # An alloc/2 or a copy runs inside a loop: every owned buffer lives until
  # the kernel returns, so the loop keeps one per iteration, bounded only by
  # max_owned_bytes. A copy hoisted before a loop is lowered outside it
  # (the open loops are those around the loop statement), so it is not noted.
  defp note_per_iteration(topic, at) when topic in [:alloc, :copy] do
    if low(:loops) != [] do
      text =
        case topic do
          :alloc ->
            "alloc/2 is inside a loop: each iteration keeps a buffer until the kernel returns (max_owned_bytes bounds the total). Allocate before the loop and clear each pass."

          :copy ->
            "this copy is inside a loop: each iteration keeps a buffer until the kernel returns (max_owned_bytes bounds the total)"
        end

      note(
        :owned,
        at,
        :per_iteration,
        text
      )
    end

    :ok
  end

  defp note_per_iteration(_topic, _at), do: :ok

  defp note_line(line) when is_integer(line), do: line
  defp note_line({file, line} = at) when is_binary(file) and is_integer(line), do: at
  defp note_line({_, m, _}) when is_list(m), do: meta_line(m) || ctx_line()
  defp note_line(_), do: ctx_line()

  # the line of the statement being lowered (in_ctx/2)
  defp ctx_line do
    case ctx(:where) do
      {_, m, _} when is_list(m) -> meta_line(m)
      _ -> nil
    end
  end

  # A kernel generated by a `quote location: :keep` macro carries the
  # macro's source location (`keep: {file, line}`): its notes go there, not
  # on the macro call line. A line in another file than the module's is
  # {file, line} (Defk.Report.line/0).
  defp meta_line(m) do
    case Keyword.get(m, :keep) do
      {file, line} when is_binary(file) and is_integer(line) and line > 0 ->
        if file == ctx(:file), do: line, else: {file, line}

      _ ->
        Keyword.get(m, :line)
    end
  end

  # "line N" for a line `at` (meta_line/1) named in the text of a note on
  # `node`, with its file when that is not the note's own: a reader looks
  # for the line in the file the note is listed under.
  defp line_from(at, node) do
    {file, line} = in_file(at)
    {note_file, _} = in_file(note_line(node))

    if file == note_file,
      do: "line #{line}",
      else: "line #{line} of #{Path.relative_to_cwd(file)}"
  end

  defp in_file({file, line}), do: {file, line}
  defp in_file(line), do: {ctx(:file), line}

  # a[i], or the word load u64_le(bytes, i), of width w: its bounds check
  # dropped, or kept with the facts that would drop it. `proof` is the
  # access's own (Facts.check/4), which names the half that fails, so what
  # is named is what the proof would accept. A failing half names the fact
  # it would follow from when that is small (Facts.residual/5): a value `a`
  # indexed by `i`, in `env`.
  defp note_bounds(node, w, proof, {a, i, env}) do
    {text, arr, idx} =
      case node do
        {{:., _, [Access, :get]}, _, [arr, idx]} -> {src_text(node), arr, idx}
        {_, _, [arr, idx]} -> {Macro.to_string(node), arr, idx}
      end

    case proof do
      {:proven, _} ->
        note(:bounds, node, :dropped, text)

      {:unproven, half} ->
        {arr, idx} = {src_text(arr), src_text(idx)}

        named = fn h, what ->
          case Facts.residual(a, i, w, h, env) |> hint_text(env) do
            nil -> what
            fact -> "#{what} (it would follow from #{fact})"
          end
        end

        low = fn -> named.(:low, "0 <= #{idx}") end

        high = fn ->
          named.(
            :high,
            if(w == 1, do: "#{idx} < length(#{arr})", else: "#{idx} + #{w} <= length(#{arr})")
          )
        end

        missing =
          case half do
            :low -> low.()
            :high -> high.()
            :both -> "#{low.()} and #{high.()}"
          end

        note(:bounds, node, :kept, "#{text}: bounds check kept; nothing proves #{missing}")
    end
  end

  # A residual D (the fact D <= 0) in source names: an atom by the binding
  # in scope whose C variable it is, a length as length(name); nil when an
  # atom has no such binding (a temporary, or a shadowed name).
  defp hint_text(nil, _env), do: nil

  defp hint_text(d, env) do
    names = Map.new(d.t, fn {m, _} -> {m, atom_name(m, env)} end)

    cond do
      Enum.any?(names, fn {_, n} -> n == nil end) ->
        nil

      map_size(d.t) == 1 ->
        case Facts.narrowing(d) do
          {x, :lo, b} -> "#{names[x]} >= #{b}"
          {x, :hi, b} -> "#{names[x]} <= #{b}"
        end

      true ->
        {pos, neg} =
          d.t |> Enum.sort_by(fn {m, _} -> names[m] end) |> Enum.split_with(&(elem(&1, 1) > 0))

        sum = fn ts ->
          Enum.map_join(ts, " + ", fn
            {m, c} when abs(c) == 1 -> names[m]
            {m, c} -> "#{abs(c)} * #{names[m]}"
          end)
        end

        case {pos, neg} do
          {[], _} -> "#{sum.(neg)} >= #{d.k}"
          {_, []} -> "#{sum.(pos)} <= #{-d.k}"
          _ -> "#{sum.(pos)} <= #{sum.(neg)}#{offset(-d.k)}"
        end
    end
  end

  defp atom_name({:mul, x, y}, env) do
    {nx, ny} = {atom_name(x, env), atom_name(y, env)}
    if nx && ny, do: "#{ny} * #{nx}"
  end

  defp atom_name({kind, c}, env) do
    Enum.find_value(env.vars, fn
      {n, %{c: ^c}} -> if kind == :len, do: "length(#{n})", else: "#{n}"
      _ -> nil
    end)
  end

  defp offset(0), do: ""
  defp offset(k) when k > 0, do: " + #{k}"
  defp offset(k), do: " - #{-k}"

  # Macro.to_string/1 (which runs the formatter), short-cut for the usual
  # a[i +- k]
  defp src_text({n, _, ctx}) when is_atom(n) and is_atom(ctx), do: Atom.to_string(n)
  defp src_text(n) when is_integer(n) and n >= 0, do: Integer.to_string(n)

  defp src_text({{:., _, [Access, :get]}, _, [arr, idx]}),
    do: "#{src_text(arr)}[#{src_text(idx)}]"

  defp src_text({op, _, [a, {n, _, ctx} = b]})
       when op in [:+, :-] and is_atom(n) and is_atom(ctx),
       do: "#{src_text(a)} #{op} #{src_text(b)}"

  defp src_text({op, _, [a, b]}) when op in [:+, :-] and is_integer(b) and b >= 0,
    do: "#{src_text(a)} #{op} #{b}"

  defp src_text(ast), do: Macro.to_string(ast)

  # an if/cond/case value: lower_branch/6's choice, and why not a select
  defp note_branch(node, arms, code, tmps, relies) do
    name = elem(node, 0)

    cond do
      not select?(arms) ->
        note(:branch, node, :branch, "#{name}: a branch; not a select: #{why_not_select(arms)}")

      relies != nil ->
        note(
          :branch,
          node,
          :branch,
          "#{name}: a branch; not a select: arm #{relies + 1} relies on its condition to drop a check"
        )

      # select/4 found nothing that can raise and gave the plain chain
      code == chain(arms, tmps) ->
        note(
          :branch,
          node,
          :branch,
          "#{name}: a plain branch, no arm can raise; clang may if-convert it"
        )

      true ->
        note(
          :branch,
          node,
          :select,
          "#{name}: a select; every arm is computed with overflow flags, an overflow replays the arm taken"
        )
    end
  end

  # select?/1's conditions in its order, as a reason; a rule it gains that
  # these do not name is reported as the heuristic's
  defp why_not_select([{_, _, :else, _, _}]), do: "it has one arm"

  defp why_not_select(arms) do
    {[_ | later], [last]} = Enum.split(arms, -1)
    arm = fn i -> if i == length(arms) - 1, do: "the last arm", else: "arm #{i + 1}" end

    stmts = Enum.find_index(arms, fn {_, _, _, sb, _} -> sb && IO.iodata_length(sb) > 0 end)
    impure = Enum.find_index(arms, fn {_, body, _, _, _} -> not speculate?(body) end)

    later_cond =
      Enum.find_index(later, fn
        {c, _, {sc, _}, _, _} -> IO.iodata_length(sc) > 0 or not speculate?(c)
        _ -> false
      end)

    cond do
      match?({_, _, :nomatch, _, _}, last) ->
        "a case with no catch-all clause raises CaseClauseError when none matches"

      stmts ->
        "#{arm.(stmts)} has statements before its value (a binding, a loop, an inlined call)"

      impure ->
        "#{arm.(impure)} may raise or call a kernel, so it cannot be computed when not taken"

      later_cond ->
        "condition #{later_cond + 2} may raise or has statements"

      true ->
        "the select heuristic declined it"
    end
  end

  # an if/cond/case that is a statement or a reduce_while tail
  defp note_branch_stmt(node, what),
    do: note(:branch, node, :branch, "#{elem(node, 0)}: a branch; #{what}")

  # the loop that loop/5 lowers next (range_loop/8, array_loop/5)
  defp loop_at(node), do: low_put(:report_loop, note_line(node))

  # loop/5's choice of safepoints: the C marker that maps clang's remarks to
  # this loop (Defk.Report), and the note
  defp note_loop(verdict, why) do
    {{name, arity}, yield?} = low(:report_kernel)
    line = low(:report_loop)

    if yield? do
      note(:loop, line, verdict, why)
    else
      note(:loop, line, :none, "no safepoints: #{name}/#{arity} has yield: false")
    end

    "/* defk:loop #{Defk.Report.loop_key({name, arity}, line)} */\n"
  end

  # a flat loop that is not flagged: why its float checks stay
  defp note_unflagged(body, var, rows) do
    text = IO.iodata_to_binary(body)

    if Regex.match?(@nf_call, text) do
      why =
        cond do
          Regex.match?(~r/\bctx\b/, unflagged_rest(text)) ->
            "the body can also raise otherwise (a division, a no-match, a check that cannot set a flag)"

          not sr_fixed_indices?(rows, var) ->
            "an unchecked element access uses an index assigned in the loop body from a value a flagged strip could compute wrongly after a failed check"

          true ->
            "the body's state cannot be restored from a snapshot to replay a strip"
        end

      note(
        :nonfinite,
        low(:report_loop),
        :checked,
        "float checks raise where they fail: #{why}"
      )
    end
  end

  defp copy_why(%{owned: true}), do: "another binding still sees its buffer"
  defp copy_why(_a), do: "its buffer is not the kernel's own (an input, or another variable's)"

  # an array copied for value semantics; `c` is the C of the value used
  defp note_copy(c, at, what) do
    if String.starts_with?(c, "defk_copy_"), do: note(:copy, at, :copied, what)
  end
end
