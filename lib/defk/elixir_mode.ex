defmodule Defk.ElixirMode do
  @moduledoc """
  Elixir mode: each kernel body compiled to plain Elixir instead of native
  code, for tests and debugging only (never a fallback, never a baseline).

  Its results define what the same code gives in Elixir, with the kernel
  subset's limits applied, so a kernel and its Elixir mode can agree exactly:

    * every integer operation is range-checked to i64 (`ArithmeticError`)
    * `a[i]` out of range raises `Enum.OutOfBoundsError`, as the kernel does
    * an array write whose value doesn't fit the element type raises
      `ArgumentError` (a `[u8]` write of 300, as the kernel does)
    * an `[f64]` element read whose bits are inf or NaN raises
      `ArgumentError` (reason `:non_finite_input`, defk-q1c)
    * wrong-typed arguments raise `ArgumentError`, as the kernel does
    * `alloc/2` over 2^48 bytes raises `ArgumentError` ("length too large"),
      and from 2^47 bytes ("out of memory"), as the kernel does
    * a range whose last element is within one step of the i64 limit raises
      `ArithmeticError` before its loop starts, as the kernel does
    * float operations that would give inf or NaN raise `ArithmeticError`
      at the operation, which plain Elixir already does

  Arrays are binaries and writes rebind them (value semantics, defk-i2e): an
  array written inside a loop or branch is threaded out as an accumulator.
  Yielding and timing don't exist in Elixir mode. `dbg/1` and `IO.inspect/1,2`
  work inside a kernel body (a kernel compiled to native code ignores them).

  ## Entry points

    * `Mod.__defk_elixir__(name, args)` runs kernel `name` in Elixir mode.
      Generated in the `:test` environment, and wherever Elixir mode is the
      configured mode.
    * `config :defk, mode: :elixir` (allowed in `:dev` and `:test` only; the
      default is `:native`) makes every kernel call run in Elixir mode.
    * `with_mode/2` switches the calling process between `:native` and
      `:elixir` for modules compiled with Elixir mode.
  """

  alias Defk.ElixirMode.Ops, warn: false

  @pdict :defk_mode
  @math1 Defk.Builtins.math1()
  @bitwise Defk.Builtins.bitwise()
  @bitwise_names Defk.Builtins.bitwise() ++ Defk.Builtins.bitwise_ops()
  @loads Defk.Builtins.loads()
  @bits Defk.Builtins.bits()

  @doc """
  Runs `fun` with this process's kernel calls in `mode` (`:native` or
  `:elixir`), for modules compiled with Elixir mode. Other modules always
  run natively.
  """
  def with_mode(mode, fun) when mode in [:native, :elixir] and is_function(fun, 0) do
    prev = Process.put(@pdict, mode)

    try do
      fun.()
    after
      if prev, do: Process.put(@pdict, prev), else: Process.delete(@pdict)
    end
  end

  # ---------------------------------------------------- compile-time hooks --

  @doc false
  # {default mode, whether Elixir mode is compiled} for a module
  def setup!(configured, env) do
    mix_env = mix_env()

    case configured do
      :native ->
        {:native, mix_env == :test}

      :elixir when mix_env in [:dev, :test] ->
        {:elixir, true}

      :elixir ->
        raise CompileError,
          file: env.file,
          line: 0,
          description:
            "defk: `config :defk, mode: :elixir` is allowed only in the :dev and :test environments, not #{inspect(mix_env)}"

      other ->
        raise CompileError,
          file: env.file,
          line: 0,
          description: "defk: unknown mode #{inspect(other)}; use :native or :elixir"
    end
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get(), do: Mix.env()
  end

  @doc false
  # The name a kernel's NIF gets when Elixir mode is compiled: the public
  # function then picks native or Elixir mode per call.
  def native_name(name), do: :"__defk_native_#{name}__"

  @doc false
  def process_mode_key, do: @pdict

  @doc false
  # Quoted definitions: `__defk_elixir__/2` and one private function per kernel.
  def definitions(raw_kernels, sigs, file) do
    Process.put(:defk_file, file)
    by_key = Map.new(sigs, &{{&1.name, &1.arity}, &1})
    kernels = Enum.zip_with(raw_kernels, sigs, fn raw, sig -> kernel(raw.body, sig, by_key) end)

    entries =
      for sig <- sigs do
        vs = for {p, _} <- sig.params, do: var(p)

        quote generated: true do
          def __defk_elixir__(unquote(sig.name), [unquote_splicing(vs)] = args) do
            [unquote_splicing(vs)] =
              Defk.ElixirMode.Ops.args!(args, unquote(Macro.escape(sig.params)))

            unquote(fun_name(sig.name))(unquote_splicing(vs))
          end
        end
      end

    doc =
      quote do
        @doc "Elixir mode: runs kernel `name` with `args` as plain Elixir (see `Defk.ElixirMode`)."
      end

    source =
      quote do
        @doc "Generated Elixir mode source."
        def __defk_elixir_source__,
          do: unquote(Enum.map_join(kernels, "\n\n", &Macro.to_string/1))
      end

    [source, doc | entries] ++ kernels
  end

  @doc false
  def fun_name(name), do: :"__defk_elixir_#{name}__"

  # --------------------------------------------------------------- kernels --

  defp kernel(body, sig, sigs) do
    Process.put(:defk_em_n, 0)
    Process.put(:defk_em_writes, [])
    vars = Map.new(sig.params, fn {p, t} -> {p, %{t: t, id: fresh_id()}} end)
    env = %{vars: vars, sigs: sigs}
    {stmts, last, t} = block_parts(body, env)
    alias_ops = quote(do: alias(Defk.ElixirMode.Ops, warn: false))
    params = for {p, _} <- sig.params, do: var(p)

    quote generated: true do
      defp unquote(fun_name(sig.name))(unquote_splicing(params)) do
        unquote(block([alias_ops | stmts] ++ [coerce(last, t, sig.ret)]))
      end
    end
  end

  # ---------------------------------------------------------------- blocks --

  defp exprs({:__block__, _, es}), do: es
  defp exprs(e), do: [e]

  # A block whose last expression is its value, as one expression.
  defp value_block(ast, env) do
    {stmts, last, t} = block_parts(ast, env)
    {block(stmts ++ [last]), t}
  end

  # {statements, value expression, type}
  defp block_parts(ast, env) do
    {init, [last]} = Enum.split(exprs(ast), -1)
    {stmts, env} = stmts(init, env)

    case last do
      {:=, _, [lhs, rhs]} ->
        {q, t} = expr(rhs, env)
        {bq, _env} = bind(lhs, q, t, env)
        {stmts, bq, t}

      _ ->
        {q, t} = expr(last, env)
        {stmts, q, t}
    end
  end

  defp stmts(asts, env) do
    {qs, env} = Enum.map_reduce(asts, env, &stmt/2)
    {qs, env}
  end

  defp block([q]), do: q
  defp block(qs), do: {:__block__, [generated: true], qs}

  # ------------------------------------------------------------ statements --

  defp stmt({:=, m, [{{:., _, [Access, :get]}, _, [arr, idx]}, rhs]}, env),
    do: {write(arr, idx, rhs, env, m), env}

  defp stmt({:=, _, [lhs, rhs]}, env) do
    {q, t} = expr(rhs, env)
    bind(lhs, q, t, env)
  end

  defp stmt({:if, m, [c, kw]}, env) when is_list(kw), do: {if_form(c, kw, :stmt, env, m), env}

  defp stmt({:case, m, [subject, [do: clauses]]}, env),
    do: {case_form(subject, clauses, :stmt, env, m), env}

  defp stmt({:for, m, args} = e, env) do
    case parse_for(args) do
      {quals, nil, body} -> {elem(for_form(quals, nil, body, env, m), 0), env}
      _ -> {elem(expr(e, env), 0), env}
    end
  end

  defp stmt(e, env), do: {elem(expr(e, env), 0), env}

  defp bind({name, _, ctx}, q, t, env) when is_atom(name) and is_atom(ctx) do
    if underscore?(name),
      do: {{:=, [generated: true], [{:_, [], nil}, q]}, env},
      else: {{:=, [generated: true], [var(name), q]}, put_var(env, name, t)}
  end

  defp bind(pat, q, {:tuple, ts}, env) do
    {pvars, env} =
      Enum.zip(tuple_items(pat), ts)
      |> Enum.map_reduce(env, fn {{name, _, _}, t}, env ->
        if underscore?(name), do: {var(name), env}, else: {var(name), put_var(env, name, t)}
      end)

    {{:=, [generated: true], [tuple(pvars), q]}, env}
  end

  # out[i] = v: `out` gets a new binary
  defp write(arr, idx, rhs, env, m) do
    {qa, {:arr, e}} = expr(arr, env)
    {pre, [qi, qv], [_, tv]} = operands([idx, rhs], env)
    put = call(:"put_#{e}", [qa, qi, coerce(qv, tv, if(e == :f64, do: :f64, else: :i64))], m)

    case arr do
      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        record_write(name, env.vars[name].id)
        with_pre(pre, {:=, [generated: true], [var(name), put]})

      _ ->
        with_pre(pre, {:=, [generated: true], [{:_, [], nil}, put]})
    end
  end

  # ----------------------------------------------------------- expressions --
  # expr(ast, env) :: {quoted, type}

  defp expr(n, _env) when is_integer(n), do: {n, :i64}
  defp expr(f, _env) when is_float(f), do: {f, :f64}
  defp expr(b, _env) when is_boolean(b), do: {b, :bool}

  defp expr({name, _, ctx}, env) when is_atom(name) and is_atom(ctx) do
    v = Map.fetch!(env.vars, name)
    {v[:q] || var(name), v.t}
  end

  # a binary module attribute (Defk.Attributes.inline/1): the binary itself
  defp expr({:@, _, [{name, _, ctx}]} = node, _env) when is_atom(name) and is_atom(ctx) do
    {:ok, b} = Defk.Attributes.of(node)
    {b, {:arr, :u8}}
  end

  # a binary literal: the binary itself
  defp expr(b, _env) when is_binary(b), do: {b, {:arr, :u8}}

  defp expr({:<<>>, _, _} = node, _env) do
    {:ok, b} = Defk.BinaryLiteral.bytes(node)
    {b, {:arr, :u8}}
  end

  defp expr({:__block__, _, _} = b, env), do: value_block(b, env)

  defp expr({a, b}, env), do: tuple_expr([a, b], env)
  defp expr({:{}, _, items}, env), do: tuple_expr(items, env)

  defp expr({{:., _, [Access, :get]}, m, [arr, idx]}, env) do
    {pre, [qa, qi], [{:arr, e}, _]} = operands([arr, idx], env)
    {with_pre(pre, call(:"get_#{e}", [qa, qi], m)), elem_type(e)}
  end

  defp expr({:if, m, [c, kw]}, env) when is_list(kw), do: if_form(c, kw, :value, env, m)
  defp expr({:cond, m, [[do: clauses]]}, env), do: cond_form(clauses, env, m)

  defp expr({:case, m, [subject, [do: clauses]]}, env),
    do: case_form(subject, clauses, :value, env, m)

  defp expr(
         {{:., _, [{:__aliases__, _, [:Enum]}, :reduce_while]}, m,
          [src, init, {:fn, _, [{:->, _, [[x, acc], body]}]}]},
         env
       ),
       do: reduce_while(src, init, x, acc, body, env, m)

  defp expr(
         {{:., _, [{:__aliases__, _, [:Enum]}, f]} = dot, m,
          [src, {:fn, fm, [{:->, am, [[x], pred]}]}]},
         env
       )
       when f in [:all?, :any?] do
    {_, writes} =
      trial(fn ->
        {_, _, xt} = gen_source(src, env)
        expr(pred, bind_gen(x, xt, env))
      end)

    if threaded(writes, env) == [] do
      # no array written: Enum.all?/any? as written
      {pre, srcq, xt} = gen_source(src, env)
      fenv = bind_gen(x, xt, env)
      {pq, _} = expr(pred, fenv)
      {with_pre(pre, {dot, gm(m), [srcq, {:fn, fm, [{:->, am, [[gen_pat(x)], pq]}]}]}), :bool}
    else
      # the kernel's meaning: a reduce_while with a bool accumulator
      {init, kw} = Defk.Builtins.bool_reduce(f)

      reduce_while(src, init, x, {:_, m, nil}, {:if, m, [pred, kw]}, env, m)
    end
  end

  defp expr({:for, m, args}, env) do
    {quals, {:reduce, init}, clauses} = parse_for(args)
    [{:->, _, [[pat], body]}] = clauses
    for_form(quals, {init, pat}, body, env, m)
  end

  defp expr({op, m, [a, b]}, env) when op in [:+, :-, :*, :/] do
    {pre, [qa, qb], [ta, tb]} = operands([a, b], env)

    {q, t} =
      case {op, ta, tb} do
        {:/, _, _} -> {{:/, gm(m), [qa, qb]}, :f64}
        {:+, :i64, :i64} -> {call(:add, [qa, qb], m), :i64}
        {:-, :i64, :i64} -> {call(:sub, [qa, qb], m), :i64}
        {:*, :i64, :i64} -> {call(:mul, [qa, qb], m), :i64}
        _ -> {{op, gm(m), [qa, qb]}, :f64}
      end

    {with_pre(pre, q), t}
  end

  defp expr({op, m, [a, b]}, env) when op in [:==, :!=, :===, :!==, :<, :>, :<=, :>=] do
    {pre, [qa, qb], _} = operands([a, b], env)
    {with_pre(pre, {op, gm(m), [qa, qb]}), :bool}
  end

  defp expr({op, m, [a, b]}, env) when op in [:and, :or, :&&, :||] do
    {_, writes} = trial(fn -> expr(b, env) end)
    conj? = op in [:and, :&&]

    if threaded(writes, env) == [] do
      {pre, [qa, qb], _} = operands([a, b], env)
      {with_pre(pre, {if(conj?, do: :and, else: :or), gm(m), [qa, qb]}), :bool}
    else
      # the right side writes an array: an `if`, so the write is threaded out
      kw = if conj?, do: [do: b, else: false], else: [do: true, else: b]
      if_form(a, kw, :value, env, m)
    end
  end

  defp expr({op, m, [a]}, env) when op in [:not, :!] do
    {q, _} = expr(a, env)
    {{:not, gm(m), [q]}, :bool}
  end

  defp expr({:-, m, [a]}, env) do
    case expr(a, env) do
      {q, :i64} -> {call(:neg, [q], m), :i64}
      {q, t} -> {{:-, gm(m), [q]}, t}
    end
  end

  defp expr({:+, _, [a]}, env), do: expr(a, env)

  # dbg and IO.inspect are Elixir's own here (native code ignores them)
  defp expr({:dbg, m, [x | rest]}, env) do
    {q, t} = expr(x, env)
    {{:dbg, m, [q | rest]}, t}
  end

  defp expr({{:., _, [{:__aliases__, _, [:IO]}, :inspect]} = dot, m, [x | rest]}, env) do
    {q, t} = expr(x, env)
    {{dot, m, [q | rest]}, t}
  end

  # wrap64(expr): the same tree, exact, then Defk.Bits.wrap64/1, which a
  # kernel author can call from Elixir for the same value
  defp expr({:wrap64, m, [x]}, env) do
    {q, _} = wrapped(x, env)
    {remote(Defk.Bits, :wrap64, [q], m), :i64}
  end

  defp expr({{:., _, [:math, fun]}, m, args}, env), do: fun_call(fun, args, m, env)

  # band(a, b), a &&& b, Bitwise.band(a, b) and :erlang.band(a, b) (the
  # compiler accepted only i64 operands): qualified Bitwise calls, so the
  # generated code needs no import, and Ops for the shifts' i64 limit
  defp expr({op, m, args}, env) when op in @bitwise_names and is_list(args) do
    f = Defk.Builtins.bitwise_fun(op)

    if length(args) == Defk.Builtins.bitwise_arity(f),
      do: bitwise(f, args, m, env),
      else: fun_call(op, args, m, env)
  end

  defp expr({{:., _, [_mod, f]}, m, args}, env) when f in @bitwise, do: bitwise(f, args, m, env)

  defp expr({name, m, args}, env) when is_atom(name) and is_list(args),
    do: fun_call(name, args, m, env)

  defp bitwise(f, args, m, env) do
    with :band <- f, {expr, mask} <- Defk.Masked.split(args) do
      masked(expr, mask, m, env)
    else
      _ ->
        {pre, qs, _} = operands(args, env)
        q = if f in [:bsl, :bsr], do: call(f, qs, m), else: remote(Bitwise, f, qs, m)
        {with_pre(pre, q), :i64}
    end
  end

  # Masked arithmetic (Defk.Masked): the tree under the mask is Elixir's own
  # + - * on bignums, unchecked, and the mask is Bitwise.band of the exact
  # result. Leaves are checked as usual.
  defp masked(expr, mask, m, env) do
    {q, _} = wrapped(expr, env)
    {remote(Bitwise, :band, [q, mask], m), :i64}
  end

  defp wrapped(ast, env) do
    case Defk.Masked.tree_node(ast) do
      nil ->
        expr(ast, env)

      {:pos, a} ->
        wrapped(a, env)

      {:neg, a} ->
        {q, _} = wrapped(a, env)
        {{:-, gm(elem(ast, 1)), [q]}, :i64}

      {:bsl, a, n} ->
        {q, _} = wrapped(a, env)
        {call(:wbsl, [q, n], elem(ast, 1)), :i64}

      {op, a, b} ->
        {pre, [qa, qb], _} = operands([a, b], env, &wrapped/2)
        eop = %{add: :+, sub: :-, mul: :*}[op]
        {with_pre(pre, {eop, gm(elem(ast, 1)), [qa, qb]}), :i64}
    end
  end

  defp tuple_expr(items, env) do
    {pre, qs, ts} = operands(items, env)
    {with_pre(pre, tuple(qs)), {:tuple, ts}}
  end

  # ----------------------------------------------------------------- calls --

  defp fun_call(:alloc, [{e, _, _}, n], m, env) do
    {q, _} = expr(n, env)
    {call(:alloc, [q, esize(e)], m), {:arr, e}}
  end

  defp fun_call(name, args, m, env) do
    {pre, qs, ts} = operands(args, env)
    {q, t} = builtin(name, qs, ts, m) || kernel_call(name, qs, ts, m, env)
    {with_pre(pre, q), t}
  end

  defp builtin(:len, [a], [{:arr, e}], m), do: {call(:"len_#{e}", [a], m), :i64}
  defp builtin(f, [a, i], [{:arr, :u8}, :i64], m) when f in @loads, do: {call(f, [a, i], m), :i64}

  defp builtin(f, [a, b], [:i64, :i64], m) when f in [:mulhi, :rotl64, :rotr64],
    do: {remote(Defk.Bits, f, [a, b], m), :i64}

  defp builtin(f, [a], [:i64], m) when f in @bits,
    do: {remote(Defk.Bits, f, [a], m), :i64}

  defp builtin(f, [a, b], [:i64, :i64], m) when f in [:div, :rem], do: {call(f, [a, b], m), :i64}
  defp builtin(:float, [a], [:i64], m), do: {{{:., gm(m), [:erlang, :float]}, gm(m), [a]}, :f64}
  defp builtin(:float, [a], [:f64], _m), do: {a, :f64}
  defp builtin(f, [a], [:i64], _m) when f in [:trunc, :round], do: {a, :i64}
  defp builtin(f, [a], [:f64], m) when f in [:trunc, :round], do: {call(f, [a], m), :i64}
  defp builtin(:abs, [a], [:i64], m), do: {call(:abs, [a], m), :i64}
  defp builtin(:abs, [a], [:f64], m), do: {remote(Kernel, :abs, [a], m), :f64}

  defp builtin(f, [a, b], [t, t], m) when f in [:min, :max] and t in [:i64, :f64],
    do: {remote(Kernel, f, [a, b], m), t}

  defp builtin(f, [a], [_], m) when f in @math1, do: {remote(:math, f, [a], m), :f64}
  defp builtin(:pow, [a, b], [_, _], m), do: {remote(:math, :pow, [a, b], m), :f64}
  defp builtin(_, _, _, _), do: nil

  # a call to another kernel: arguments coerced to its parameter types, as
  # when the kernel inlines it; the callee coerces its own return value
  defp kernel_call(name, qs, ts, m, env) do
    k = Map.fetch!(env.sigs, {name, length(qs)})
    args = Enum.zip_with([qs, ts, k.params], fn [q, t, {_, pt}] -> coerce(q, t, pt) end)
    {{fun_name(name), gm(m), args}, k.ret}
  end

  # Evaluate operands left to right. If one of them writes an array that the
  # surrounding code can see, every operand is bound to a temporary first, so
  # later operands see the write (Erlang can't use a variable bound inside a
  # sibling argument).
  defp operands(asts, env, lower \\ &expr/2) do
    results = Enum.map(asts, fn a -> scoped(fn -> lower.(a, env) end) end)

    if Enum.any?(results, fn {_, writes} -> threaded(writes, env) != [] end) do
      {pre, qs} =
        Enum.map(results, fn {{q, _}, _} ->
          t = temp("arg")
          {{:=, [generated: true], [t, q]}, t}
        end)
        |> Enum.unzip()

      {pre, qs, Enum.map(results, fn {{_, t}, _} -> t end)}
    else
      {[], Enum.map(results, fn {{q, _}, _} -> q end), Enum.map(results, fn {{_, t}, _} -> t end)}
    end
  end

  defp with_pre([], q), do: q
  defp with_pre(pre, q), do: block(pre ++ [q])

  # ------------------------------------------------------------- branches --
  # An if/cond/case is a chain of arms [{:when, cond, parts} | {:else, parts}
  # | {:raise, q}], parts = {stmts, value | nil, type}. Arrays written in it
  # (w) are threaded out: every arm ends in {value, w...} (or w...), and the
  # chain is bound to that pattern.

  defp if_form(c, kw, mode, env, m) do
    {arms, writes} =
      scoped(fn ->
        {cq, _} = expr(c, env)
        a = parts(Keyword.fetch!(kw, :do), env, mode)
        b = if Keyword.has_key?(kw, :else), do: parts(kw[:else], env, mode), else: {[], nil, nil}
        [{:when, cq, a}, {:else, b}]
      end)

    finish(arms, threaded(writes, env), mode, m)
  end

  defp cond_form(clauses, env, m) do
    {arms, writes} =
      scoped(fn ->
        for {:->, _, [[c], body]} <- clauses do
          if c == true do
            {:else, parts(body, env, :value)}
          else
            {cq, _} = expr(c, env)
            {:when, cq, parts(body, env, :value)}
          end
        end
      end)

    finish(arms, threaded(writes, env), :value, m)
  end

  # Like the kernel: the subject is evaluated once, clauses are tested in
  # order (an error in a guard raises, a limit), and no match raises
  # CaseClauseError. A pattern variable is bound in its clause body.
  defp case_form(subject, clauses, mode, env, m) do
    {{bind_subject, arms}, writes} =
      scoped(fn ->
        {sq, st} = expr(subject, env)
        s = temp("case")
        {{:=, [generated: true], [s, sq]}, case_arms(clauses, s, st, mode, env)}
      end)

    finish(arms, threaded(writes, env), mode, m, [bind_subject])
  end

  defp case_arms(clauses, s, st, mode, env) do
    Enum.reduce_while(clauses, {[], MapSet.new()}, fn {:->, _, [[head], body]}, {arms, seen} ->
      {pat, guard} = case_clause_head(head)
      {test, benv, prefix} = case_pattern(pat, s, st, env)
      gq = guard && elem(expr(guard, guard_env(pat, s, st, env)), 0)

      seen =
        if guard == nil and match?({:lit, _, _}, test),
          do: MapSet.put(seen, elem(test, 1)),
          else: seen

      {stmts, last, t} = parts(body, benv, mode)
      parts = {prefix ++ stmts, last, t}
      {arm, always?} = case_arm(test, guard, gq, parts, seen)

      if always?, do: {:halt, {:done, [arm | arms]}}, else: {:cont, {[arm | arms], seen}}
    end)
    |> case do
      {:done, arms} ->
        Enum.reverse(arms)

      {arms, _} ->
        Enum.reverse([{:raise, quote(do: raise(CaseClauseError, term: unquote(s)))} | arms])
    end
  end

  defp case_clause_head({:when, _, [pat, guard]}), do: {pat, guard}
  defp case_clause_head(pat), do: {pat, nil}

  # The completed arm and whether it always matches; the last is what decides
  # whether the reducer stops early with an exhaustive set.
  defp case_arm(test, guard, gq, parts, seen) do
    always? = guard == nil and (test == :any or MapSet.equal?(seen, MapSet.new([true, false])))

    cond do
      always? -> {{:else, parts}, true}
      test == :any -> {{:when, gq, parts}, false}
      guard == nil -> {{:when, elem(test, 2), parts}, false}
      true -> {{:when, {:and, [generated: true], [elem(test, 2), gq]}, parts}, false}
    end
  end

  defp case_pattern(pat, s, st, env) do
    lit = fn v -> {:lit, v, {:===, [generated: true], [s, v]}} end

    case pat do
      n when is_integer(n) or is_boolean(n) ->
        {lit.(n), env, []}

      {:-, _, [n]} when is_integer(n) ->
        {lit.(-n), env, []}

      {:^, _, [v]} ->
        {q, _} = expr(v, env)
        {{:pin, nil, {:===, [generated: true], [s, q]}}, env, []}

      {name, _, ctx} when is_atom(name) and is_atom(ctx) ->
        if underscore?(name),
          do: {:any, env, []},
          else: {:any, put_var(env, name, st), [{:=, [generated: true], [var(name), s]}]}
    end
  end

  # in a guard the pattern variable is the subject itself
  defp guard_env({name, _, ctx}, s, st, env) when is_atom(name) and is_atom(ctx),
    do: %{env | vars: Map.put(env.vars, name, %{t: st, id: fresh_id(), q: s})}

  defp guard_env(_pat, _s, _st, env), do: env

  defp parts(body, env, :value), do: block_parts(body, env)
  defp parts(body, env, :stmt), do: {elem(stmts(exprs(body), env), 0), nil, nil}
  defp parts(body, env, {:tail, leaf}), do: {[], tail(body, env, leaf), :tail}

  # Render a chain: as written when no array is written in it, else as nested
  # ifs (a binding in an `if` condition is visible in its arms; one in a later
  # `cond` condition is not), every arm ending in the threaded arrays.
  # A tail chain (mode {:tail, _}) threads nothing: its leaves carry the arrays.
  defp finish(arms, w, mode, m, pre \\ []) do
    t =
      Enum.find_value(arms, fn
        {:when, _, {_, _, t}} -> t
        {:else, {_, _, t}} -> t
        _ -> nil
      end)

    nested? = w != []
    tail? = match?({:tail, _}, mode)
    w = if tail?, do: [], else: w
    value? = mode == :value
    res = temp("res")

    out = fn
      {stmts, last, _} when value? and w == [] ->
        block(stmts ++ [last])

      {stmts, last, _} when value? ->
        block(stmts ++ [{:=, [generated: true], [res, last]}, tuple([res | vars(w)])])

      {stmts, last, _} when tail? ->
        block(stmts ++ [last])

      {[], _, _} when w == [] ->
        nil

      {stmts, _, _} when w == [] ->
        block(stmts)

      {stmts, _, _} ->
        block(stmts ++ [wtuple(w)])
    end

    rendered =
      case arms do
        [{:else, a}] ->
          out.(a)

        [{:when, c, a}, {:else, b}] ->
          if not value? and not tail? and w == [] and elem(b, 0) == [],
            do: {:if, gm(m), [c, [do: out.(a)]]},
            else: {:if, gm(m), [c, [do: out.(a), else: out.(b)]]}

        _ when nested? ->
          nested_arms(arms, out, m)

        _ ->
          cond_arms(arms, out, m)
      end

    q =
      cond do
        w == [] -> block(pre ++ [rendered])
        value? -> block(pre ++ [{:=, [generated: true], [tuple([res | vars(w)]), rendered]}, res])
        true -> block(pre ++ [{:=, [generated: true], [wtuple(w), rendered]}])
      end

    {q, t}
  end

  # Nested mode: each when-arm wraps the rest, the first else/raise ends the chain.
  defp nested_arms(arms, out, m) do
    List.foldr(arms, nil, fn
      {:when, c, a}, rest -> {:if, gm(m), [c, [do: out.(a), else: rest]]}
      {:else, a}, _ -> out.(a)
      {:raise, q}, _ -> q
    end)
  end

  # Flat mode: a cond of when/else/raise clauses, each arm rendered by `out`.
  defp cond_arms(arms, out, m) do
    clauses =
      for arm <- arms do
        case arm do
          {:when, c, a} -> {:->, gm(m), [[c], out.(a)]}
          {:else, a} -> {:->, gm(m), [[true], out.(a)]}
          {:raise, q} -> {:->, gm(m), [[true], q]}
        end
      end

    {:cond, gm(m), [[do: clauses]]}
  end

  # ----------------------------------------------------------------- loops --

  defp parse_for(args) do
    {kws, quals} = Enum.split_with(args, &(is_list(&1) and Keyword.keyword?(&1)))
    opts = Enum.concat(kws)

    case Keyword.fetch(opts, :reduce) do
      {:ok, init} -> {quals, {:reduce, init}, Keyword.fetch!(opts, :do)}
      :error -> {quals, nil, Keyword.fetch!(opts, :do)}
    end
  end

  # {pre, enumerable, element type}
  defp gen_source({:.., _, [a, b]}, env) do
    {pre, [qa, qb], _} = operands([a, b], env)
    {pre, call(:range, [qa, qb], []), :i64}
  end

  defp gen_source({:..//, m, [a, b, s]}, env) do
    {pre, qs, _} = operands([a, b, s], env)
    {pre, call(:range, qs, m), :i64}
  end

  defp gen_source(src, env) do
    {q, {:arr, e}} = expr(src, env)
    {[], call(:"elems_#{e}", [q], []), elem_type(e)}
  end

  defp bind_gen(x, t, env) do
    name = var_name(x)
    if underscore?(name), do: env, else: put_var(env, name, t)
  end

  defp gen_pat(x), do: var(var_name(x))

  # `for` with or without `reduce: {init, pattern}`. When no array is written
  # in it, it is Elixir's `for` as written. Otherwise each generator is its
  # own loop whose accumulator carries the arrays too, so a nested
  # generator or filter sees the arrays as written so far.
  defp for_form(quals, reduce, body, env, m) do
    {{init, levels, body_parts, acc}, writes} =
      scoped(fn ->
        case reduce do
          nil ->
            {levels, benv} = quals(quals, env)
            {nil, levels, parts(body, benv, :stmt), nil}

          {init_ast, pat} ->
            # the init is evaluated before the generators, as in the kernel
            {iq, it} = expr(init_ast, env)
            {levels, benv} = quals(quals, env)
            acc = acc_parts(pat, it)
            {{iq, it}, levels, block_parts(body, put_accs(benv, acc)), acc}
        end
      end)

    w = threaded(writes, env)

    if w == [],
      do: for_direct(init, levels, body_parts, acc, m),
      else: for_threaded(init, levels, body_parts, acc, w, m)
  end

  defp quals(quals, env) do
    Enum.map_reduce(quals, env, fn
      {:<-, _, [x, src]}, env ->
        {pre, q, t} = gen_source(src, env)
        {{:gen, gen_pat(x), with_pre(pre, q)}, bind_gen(x, t, env)}

      filter, env ->
        {q, _} = expr(filter, env)
        {{:filter, q}, env}
    end)
  end

  # [{name, type}] of an accumulator pattern and its init type
  defp acc_parts(pat, {:tuple, ts}),
    do: Enum.zip_with(tuple_items(pat), ts, fn p, t -> {var_name(p), t} end)

  defp acc_parts(pat, t), do: [{var_name(pat), t}]

  defp put_accs(env, acc) do
    Enum.reduce(acc, env, fn {name, t}, e ->
      if underscore?(name), do: e, else: put_var(e, name, t)
    end)
  end

  defp acc_type([{_, t}]), do: t
  defp acc_type(acc), do: {:tuple, Enum.map(acc, &elem(&1, 1))}
  defp acc_pat([{name, _}]), do: var(name)
  defp acc_pat(acc), do: tuple(Enum.map(acc, fn {name, _} -> var(name) end))

  defp qual_q({:gen, x, src}), do: {:<-, [generated: true], [x, src]}
  defp qual_q({:filter, q}), do: q

  # a for whose value is discarded: its body is statements only, and Elixir
  # already ignores the loop's value. A trailing nil pads an empty body; on a
  # non-empty one it would leave a final statement unreturned and warn.
  defp for_direct(nil, levels, {stmts, nil, nil}, nil, m) do
    body = if stmts == [], do: [nil], else: stmts
    {{:for, gm(m), Enum.map(levels, &qual_q/1) ++ [[do: block(body)]]}, nil}
  end

  defp for_direct({iq, it}, levels, {stmts, last, bt}, acc, m) do
    at = acc_type(acc)
    clause = {:->, [generated: true], [[acc_pat(acc)], block(stmts ++ [coerce(last, bt, at)])]}

    {{:for, gm(m), Enum.map(levels, &qual_q/1) ++ [[reduce: coerce(iq, it, at), do: [clause]]]},
     at}
  end

  defp for_threaded(init, levels, {stmts, last, bt}, acc, w, m) do
    acc = acc || []
    ts = Enum.map(acc, fn _ -> temp("acc") end)
    state = tuple_or_one(ts ++ vars(w))

    inner =
      case acc do
        [] ->
          block(stmts ++ [state])

        _ ->
          rs = Enum.map(acc, fn _ -> temp("next") end)
          next = coerce(last, bt, acc_type(acc))
          bind_user = {:=, [generated: true], [acc_pat(acc), tuple_or_one(ts)]}

          block(
            [bind_user | stmts] ++
              [{:=, [generated: true], [tuple_or_one(rs), next]}, tuple_or_one(rs ++ vars(w))]
          )
      end

    loops =
      List.foldr(levels, inner, fn
        {:gen, x, src}, body ->
          s = temp("src")
          clause = {:->, [generated: true], [[state], body]}

          block([
            {:=, [generated: true], [s, src]},
            {:for, gm(m), [{:<-, [generated: true], [x, s]}, [reduce: state, do: [clause]]]}
          ])

        {:filter, q}, body ->
          {:if, [generated: true], [q, [do: body, else: state]]}
      end)

    case init do
      nil ->
        {{:=, [generated: true], [wtuple(w), loops]}, nil}

      {iq, it} ->
        at = acc_type(acc)
        start = {:=, [generated: true], [tuple_or_one(ts), coerce(iq, it, at)]}
        {block([start, {:=, [generated: true], [state, loops]}, tuple_or_one(ts)]), at}
    end
  end

  # Enum.reduce_while: written as Elixir's, with the threaded arrays added to
  # its accumulator. Every tail is a literal {:cont, acc} or {:halt, acc}
  # (through if/cond/case), coerced to the accumulator's types.
  defp reduce_while(src, init_ast, x, acc_pat_ast, body, env, m) do
    {{iq, it, src_pre, srcq, fq, acc}, writes} =
      scoped(fn ->
        {{iq, it}, iw} = scoped(fn -> expr(init_ast, env) end)
        {src_pre, srcq, xt} = gen_source(src, env)
        acc = acc_parts(acc_pat_ast, it)
        fenv = bind_gen(x, xt, env)
        fenv = put_accs(fenv, acc)

        leaf = fn tag, v_ast, lenv ->
          {vq, vt} = expr(v_ast, lenv)
          {:"$defk_leaf", [tag: tag], [coerce(vq, vt, acc_type(acc))]}
        end

        fq = tail(body, fenv, leaf)
        # an init that writes an array is evaluated first
        {iq, src_pre} = if threaded(iw, env) != [], do: hoist(iq, src_pre), else: {iq, src_pre}
        {iq, it, src_pre, srcq, fq, acc}
      end)

    w = threaded(writes, env)
    at = acc_type(acc)

    fq =
      Macro.prewalk(fq, fn
        {:"$defk_leaf", [tag: tag], [vq]} when w == [] ->
          {tag, vq}

        {:"$defk_leaf", [tag: tag], [vq]} ->
          r = temp("acc")
          block([{:=, [generated: true], [r, vq]}, {tag, tuple([r | vars(w)])}])

        other ->
          other
      end)

    pat = if w == [], do: acc_pat(acc), else: tuple([acc_pat(acc) | vars(w)])
    init = if w == [], do: coerce(iq, it, at), else: tuple([coerce(iq, it, at) | vars(w)])
    fun = {:fn, [generated: true], [{:->, [generated: true], [[gen_pat(x), pat], fq]}]}

    call =
      {{:., gm(m), [{:__aliases__, [alias: false], [:Enum]}, :reduce_while]}, gm(m),
       [srcq, init, fun]}

    if w == [] do
      {with_pre(src_pre, call), at}
    else
      res = temp("res")
      {block(src_pre ++ [{:=, [generated: true], [tuple([res | vars(w)]), call]}, res]), at}
    end
  end

  defp hoist(q, pre) do
    t = temp("init")
    {t, [{:=, [generated: true], [t, q]} | pre]}
  end

  # the body of a reduce_while fn: statements, then a tail
  defp tail(ast, env, leaf) do
    {init, [last]} = Enum.split(exprs(ast), -1)
    {stmts, env} = stmts(init, env)
    block(stmts ++ [tail_expr(last, env, leaf)])
  end

  defp tail_expr({tag, v}, env, leaf) when tag in [:cont, :halt], do: leaf.(tag, v, env)
  defp tail_expr({:__block__, _, _} = b, env, leaf), do: tail(b, env, leaf)

  defp tail_expr({:if, m, [c, kw]}, env, leaf) do
    {{_, arms}, writes} =
      scoped(fn ->
        {cq, _} = expr(c, env)

        {cq,
         [
           {:when, cq, parts(kw[:do], env, {:tail, leaf})},
           {:else, parts(kw[:else], env, {:tail, leaf})}
         ]}
      end)

    tail_finish(arms, writes, env, m)
  end

  defp tail_expr({:cond, m, [[do: clauses]]}, env, leaf) do
    {arms, writes} =
      scoped(fn ->
        for {:->, _, [[c], body]} <- clauses do
          if c == true,
            do: {:else, parts(body, env, {:tail, leaf})},
            else: {:when, elem(expr(c, env), 0), parts(body, env, {:tail, leaf})}
        end
      end)

    tail_finish(arms, writes, env, m)
  end

  defp tail_expr({:case, m, [subject, [do: clauses]]}, env, leaf) do
    {{sq, s, arms}, writes} =
      scoped(fn ->
        {sq, st} = expr(subject, env)
        s = temp("case")
        {sq, s, case_arms(clauses, s, st, {:tail, leaf}, env)}
      end)

    block([{:=, [generated: true], [s, sq]}, tail_finish(arms, writes, env, m)])
  end

  # A tail chain carries the arrays in its leaves; it is rendered as nested
  # ifs when it writes one, so a write in a later condition is visible in the
  # later arms.
  defp tail_finish(arms, writes, env, m) do
    {q, _} = finish(arms, threaded(writes, env), {:tail, nil}, m)
    q
  end

  # --------------------------------------------------------- write tracking --
  # Each binding has an id. A write records {name, id}; the arrays a
  # construct must thread out are those written inside it whose binding is
  # the one visible where the construct starts.

  defp fresh_id do
    n = Process.get(:defk_em_n) + 1
    Process.put(:defk_em_n, n)
    n
  end

  defp put_var(env, name, t), do: %{env | vars: Map.put(env.vars, name, %{t: t, id: fresh_id()})}

  defp record_write(name, id),
    do: Process.put(:defk_em_writes, [{name, id} | Process.get(:defk_em_writes)])

  defp scoped(fun) do
    outer = Process.get(:defk_em_writes)
    Process.put(:defk_em_writes, [])
    res = fun.()
    inner = Process.get(:defk_em_writes)
    Process.put(:defk_em_writes, inner ++ outer)
    {res, inner}
  end

  # like scoped/1, but the writes are forgotten (a look ahead)
  defp trial(fun) do
    outer = Process.get(:defk_em_writes)
    {res, inner} = scoped(fun)
    Process.put(:defk_em_writes, outer)
    {res, inner}
  end

  defp threaded(writes, env) do
    writes
    |> Enum.reverse()
    |> Enum.filter(fn {name, id} -> match?(%{^name => %{id: ^id}}, env.vars) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
  end

  # --------------------------------------------------------------- helpers --

  # i64 -> f64 where the kernel converts (returns, arguments, accumulators, stores)
  defp coerce(q, t, t), do: q

  defp coerce(q, :i64, :f64),
    do: {{:., [generated: true], [:erlang, :float]}, [generated: true], [q]}

  defp coerce(q, {:tuple, ts}, {:tuple, rts}) do
    tmps = Enum.map(ts, fn _ -> temp("el") end)
    out = Enum.zip_with([tmps, ts, rts], fn [v, t, rt] -> coerce(v, t, rt) end)
    block([{:=, [generated: true], [tuple(tmps), q]}, tuple(out)])
  end

  defp coerce(q, _t, _rt), do: q

  defp call(fun, args, m),
    do: {{:., gm(m), [{:__aliases__, [alias: false], [:Ops]}, fun]}, gm(m), args}

  defp remote(mod, fun, args, m), do: {{:., gm(m), [mod, fun]}, gm(m), args}

  defp gm(m), do: [generated: true] ++ Keyword.take(m || [], [:line])

  defp var(name), do: {name, [generated: true], nil}
  defp vars(names), do: Enum.map(names, &var/1)

  defp temp(base) do
    n = fresh_id()
    {:"defk_#{base}#{n}", [generated: true], __MODULE__}
  end

  defp var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name

  defp underscore?(name), do: String.starts_with?(Atom.to_string(name), "_")

  defp tuple([a, b]), do: {a, b}
  defp tuple(items), do: {:{}, [generated: true], items}

  defp tuple_or_one([one]), do: one
  defp tuple_or_one(items), do: tuple(items)

  defp wtuple(w), do: tuple_or_one(vars(w))

  defp tuple_items({a, b}), do: [a, b]
  defp tuple_items({:{}, _, items}), do: items

  defp elem_type(:u8), do: :i64
  defp elem_type(e), do: e

  defp esize(:u8), do: 1
  defp esize(_), do: 8
end
