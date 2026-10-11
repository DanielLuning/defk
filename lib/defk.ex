defmodule Defk do
  @moduledoc """
  Write a kernel in a typed subset of Elixir and call it like any other
  function: `defk` compiles it to native code when its module compiles.

  A **kernel** is Elixir over numbers and binaries. It gives the result
  Elixir would, or raises where its types can't hold that result, or doesn't
  compile; it never gives a different answer. While it runs it keeps the
  BEAM's promises: a long kernel yields to its scheduler, an error is an
  ordinary exception in the calling process, and a process that dies frees
  its kernel's memory ([the runtime contract](runtime-contract.md)).

  Elixir stays the default. defk is for the jobs where Elixir today pushes
  you towards a hand-written NIF; when an Elixir version is as good or as
  fast, use it. The [scope page](scope.md) says when defk helps, when Elixir
  or a wrapper NIF is the better choice, and what is not supported yet.

      iex> defmodule MyApp.Stats do
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
      iex> a = <<1.0::float-native, 2.0::float-native>>
      iex> b = <<3.0::float-native, 4.0::float-native>>
      iex> MyApp.Stats.dot(a, b)
      11.0
      iex> MyApp.Stats.dot(a, :not_an_array)
      ** (ArgumentError) argument 2 (b) must be a binary of packed f64

  [Getting started](getting-started.md) walks through a first kernel. The
  [language reference](language.md) is the full description of the kernel
  subset, and the [cheatsheet](cheatsheet.cheatmd) the short one.

  ## `use Defk`

  `use Defk` imports the `defk/3` macro (and its shorter forms `defk/1` and
  `defk/2`). A module may mix kernels with ordinary `def`s. Two options:

    * `elixir_mode: true` compiles Elixir mode into the module in any
      environment, so `__defk_elixir__/2` exists outside `:test` (in a
      `Mix.install` script, for instance). The kernels' own functions still
      run natively. Default `false`. See `Defk.ElixirMode`.
    * `report: :full` adds the C compiler's vectorisation of each loop to the
      [fast-path report](`Defk.Report`), at the cost of a second C compile.
      What it adds is unstable.

  Any other option raises `ArgumentError`. Module attributes whose names
  start with `@defk_` are reserved for defk: don't define your own.

  ## Types

  | Type | In a kernel | Passed from Elixir as | Returned as |
  |---|---|---|---|
  | `i64` | signed 64-bit integer | an integer in -2^63..2^63-1 | an integer |
  | `u64` | unsigned 64-bit integer | an integer in 0..2^64-1 | an integer |
  | `f64` | double | a float, or an integer that fits in `i64` | a finite float |
  | `bool` | `true` or `false` | `true` or `false` | `true` or `false` |
  | `[f64]`, `[f32]`, `[i64]`, `[i32]`, `[i16]`, `[u8]`, `[u64]` | array of that element type | a binary of native-endian elements | a binary |
  | `{t1, t2, ...}` | taken apart at once | not allowed | a tuple |
  | `bitstring` | a bitstring accumulator | not allowed | a bitstring |

  An argument of the wrong type raises `ArgumentError`. Details, the
  restrictions on tuples and bitstrings, and how to build and read arrays
  from Elixir: [Types](language.md#3-types).

  ## Configuration

    * `config :defk, mode: :native | :elixir` is the default call path,
      read when a kernel module compiles. `:elixir` (every kernel call runs in
      Elixir mode) is allowed only in `:dev` and `:test`; the default is
      `:native`.
    * `CC` names the C compiler (default `cc`), and `ERTS_INCLUDE_DIR` builds
      against another ERTS's headers, as in elixir_make.
    * The C source and the library are written to
      `_build/<env>/defk/<Module>-<key>.{c,so}`. This path is unstable.

  How a module compiles, and the errors when the C compiler is missing:
  [Compile-time behaviour](language.md#compile-time-behaviour) and
  [Deploying](deploying.md).

  ## Generated functions

  For each kernel, `use Defk` defines a public function with the kernel's
  name and arity and an `@spec` derived from its types: your API. It also
  defines these functions in the module. They are `@doc false` there, so they
  don't appear in your module's docs; this is their description.

  | Function | Stability | Returns |
  |---|---|---|
  | `__defk_elixir__/2` | public | `Mod.__defk_elixir__(:name, args)` runs one call of kernel `name` in Elixir mode. Only where Elixir mode is compiled: in `:test`, with `config :defk, mode: :elixir`, or with `use Defk, elixir_mode: true` |
  | `__defk_force_yields__/1` | public (testing) | `true` makes the module's kernels yield at every clock read, so a test runs every resume path; `false` turns it off. It is module-wide: it affects every process calling the module's kernels, not only the caller |
  | `__defk_elixir_source__/0` | unstable | the generated Elixir mode code (same condition as `__defk_elixir__/2`) |
  | `__defk_c_source__/0` | unstable | the generated C source of the module's kernels |
  | `__defk_report__/0` | unstable | the fast-path report as data, `[{kernel, line, fact}]`; read it with `Defk.Report.print/1` |
  | `__defk_lib__/0` | unstable | the path of the compiled NIF library (`.so`) |
  | `__defk_kernels__/0` | unstable | each kernel's signature: `%{name:, arity:, params: [{name, type}], ret:}` |
  | `__defk_stats__/0` | unstable | the library's runtime counters: `%{frames_live:, promotions:, yields:}` |

  **Public** functions keep their meaning; a change would come with a
  deprecation. **Unstable** ones are for debugging and tools, and their
  output may change in any version. Any other `__defk_*__` function in a
  kernel module (the loader, the native entry points, test-only fault
  hooks) is internal: don't call it.

      iex> defmodule MyApp.Count do
      ...>   use Defk, elixir_mode: true
      ...>
      ...>   defk count_below(bytes :: [u8], limit :: i64) :: i64 do
      ...>     for b <- bytes, reduce: 0 do
      ...>       n -> if b < limit, do: n + 1, else: n
      ...>     end
      ...>   end
      ...> end
      iex> MyApp.Count.count_below("hello", 105)
      2
      iex> MyApp.Count.__defk_elixir__(:count_below, ["hello", 105])
      2
      iex> MyApp.Count.__defk_kernels__()
      [%{name: :count_below, arity: 2, params: [bytes: {:arr, :u8}, limit: :i64], ret: :i64}]
      iex> MyApp.Count.__defk_stats__().frames_live
      0

  The [language reference](language.md#what-use-defk-generates) lists the
  same functions with the language's view of them, and
  [Testing kernels](testing.md) shows how to use them in tests.

  ## Guides

    * [Getting started](getting-started.md): a first kernel, calling it,
      reading a compile error
    * [Testing kernels](testing.md): Elixir mode, `Defk.Test.assert_agrees/3`,
      forced yields
    * [Measuring](measuring.md): measuring a kernel against the best Elixir
      version, and explaining the number with `Defk.Report`
    * [The runtime contract](runtime-contract.md): what a kernel promises the
      BEAM while it runs
    * [Deploying](deploying.md): build machines, releases, scripts
    * [Scope](scope.md): what defk is, isn't yet, and won't be
  """

  # compile-time attribute: the defk app is not loaded when this module is
  # compiled, so Application.app_dir/2 (which reads :code.priv_dir) cannot
  # answer yet; a source-relative path is the only honest option.
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @runtime_h Path.expand("../priv/defk_runtime.h", __DIR__)

  defmacro __using__(opts) do
    elixir_mode = Keyword.get(opts, :elixir_mode, false)
    report = Keyword.get(opts, :report)

    if Keyword.keys(opts) -- [:elixir_mode, :report] != [] or not is_boolean(elixir_mode) or
         report not in [nil, :full] do
      raise ArgumentError,
            "use Defk accepts only `elixir_mode: true | false` and `report: :full`, got: #{Macro.to_string(opts)}"
    end

    quote do
      @defk_elixir_mode unquote(elixir_mode)
      @defk_report unquote(report)
      import Defk, only: [defk: 1, defk: 2, defk: 3]
      Module.register_attribute(__MODULE__, :defk_kernels, accumulate: true)
      @defk_mode Application.compile_env(:defk, :mode, :native)
      @external_resource unquote(@runtime_h)
      @before_compile Defk
    end
  end

  @doc """
  The head of a multi-clause kernel: its name, typed parameters and return
  type, with no body. The clauses follow it as `defk/2` calls, which give
  patterns, an optional guard and a body, as an Elixir multi-clause function
  does.

      iex> defmodule MyApp.Classify do
      ...>   use Defk
      ...>
      ...>   defk classify(x :: i64, strict :: bool) :: i64
      ...>   defk classify(0, _), do: 0
      ...>   defk classify(x, true) when x in 1..9, do: 1
      ...>   defk classify(x, _strict) when x > 0, do: 2
      ...>   defk classify(_, false), do: -1
      ...> end
      iex> MyApp.Classify.classify(5, true)
      1
      iex> MyApp.Classify.classify(-3, false)
      -1

  When no clause matches, the kernel raises `FunctionClauseError`, as a
  `def` with the same clauses would.

  To give a multi-clause kernel an option, write it after the head's return
  type: `defk classify(x :: i64, strict :: bool) :: i64, yield: false`. The
  rules for heads, patterns and guards:
  [Multi-clause kernels](language.md#multi-clause-kernels).
  """
  defmacro defk(head), do: kernel(head, [], :head, __CALLER__)

  @doc """
  Defines a kernel: a function in the kernel subset, compiled to native code
  with its module.

  The head is `name(param :: type, ...) :: return_type` (see the types in
  the `Defk` module docs), and the body a `do ... end` block or `, do: expr`
  whose last expression is the result:

      defk name(param :: type, ...) :: return_type do
        ...
      end

      defk name(param :: type, ...) :: return_type, do: expr

  `opts`, written after the return type, holds the one kernel option,
  `yield: false`. It compiles the kernel, and the kernels it calls, without
  safepoints, so it never yields: use it only for a kernel that always
  finishes in well under a millisecond, since a long kernel without
  safepoints blocks its scheduler for its whole run. Any other option is the
  compile error [`unknown-option`](language.md#unknown-option).

      iex> defmodule MyApp.Small do
      ...>   use Defk
      ...>
      ...>   defk add(a :: i64, b :: i64) :: i64, yield: false, do: a + b
      ...>
      ...>   defk sum(a :: [i64]) :: i64 do
      ...>     for x <- a, reduce: 0 do
      ...>       acc -> acc + x
      ...>     end
      ...>   end
      ...> end
      iex> MyApp.Small.add(1, 2)
      3
      iex> MyApp.Small.add(2 ** 62, 2 ** 62)
      ** (ArithmeticError) i64 overflow in 4611686018427387904 + 4611686018427387904
      iex> MyApp.Small.sum(<<1::signed-64-native, 2::signed-64-native>>)
      3

  The same macro, given patterns instead of types and no options, defines a
  clause of a multi-clause kernel (see `defk/1`).

  What a kernel body may contain, what it means, and every compile error:
  the [language reference](language.md#2-defining-a-kernel).
  """
  defmacro defk(head, opts \\ [], body) do
    if Keyword.has_key?(body, :do),
      do: kernel(head, opts ++ Keyword.delete(body, :do), Keyword.get(body, :do), __CALLER__),
      else: kernel(head, opts ++ body, :head, __CALLER__)
  end

  defp kernel(head, opts, body, caller) do
    kernel =
      if body == :head,
        do: %{head: head, opts: opts, body: nil, line: caller.line, head?: true},
        else: %{head: head, opts: opts, body: body, line: caller.line}

    # the module attributes the body reads, valued here as a def's would be
    quote do
      @defk_kernels Map.put(
                      unquote(Macro.escape(kernel)),
                      :attrs,
                      unquote(Defk.Attributes.capture(kernel.body))
                    )
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    kernels =
      env.module
      |> Module.get_attribute(:defk_kernels)
      |> Enum.reverse()
      |> Enum.map(&Defk.Attributes.inline/1)
      |> Defk.Clauses.merge()

    # Elixir mode: compiled in :test, wherever it is the configured mode, and
    # in any module that opts in with `use Defk, elixir_mode: true`
    {mode, elixir?} =
      Defk.ElixirMode.setup!(
        Module.get_attribute(env.module, :defk_mode),
        Module.get_attribute(env.module, :defk_elixir_mode),
        env
      )

    # a kernel returning a bitstring gets an Elixir wrapper (Defk.Bitstring),
    # so its NIF has another name, as with Elixir mode
    bits =
      for k <- kernels,
          Defk.Bitstring.returns_bits?(k.head),
          into: MapSet.new(),
          do: Defk.Bitstring.name(k.head)

    nif_name = fn name ->
      if elixir? or name in bits, do: Defk.ElixirMode.native_name(name), else: name
    end

    fault_hooks? = fault_hooks?()

    {c_src, all_sigs} =
      Defk.Compiler.compile(env.module, kernels, env.file,
        nif_name: nif_name,
        fault_hooks: fault_hooks?
      )

    lib = Defk.Build.build!(env.module, c_src, env.file)

    # the fast-path report: defk's own notes, and clang's vectorisation under
    # `report: :full` (an extra compiler pass, Defk.Report.full/3)
    report =
      if Module.get_attribute(env.module, :defk_report) == :full,
        do: Defk.Report.full(Defk.Compiler.report(), c_src, lib),
        else: Defk.Compiler.report()

    # a helper (a kernel taking a bitstring) is only inlined: no function
    sigs = Enum.reject(all_sigs, &Defk.Bitstring.helper?/1)

    {wrapped, plain} = Enum.split_with(sigs, &(&1.name in bits))

    stubs =
      if elixir?,
        do: native_stubs(sigs, nif_name) ++ dispatch_defs(sigs, mode, nif_name),
        else:
          render_stubs(plain) ++ native_stubs(wrapped, nif_name) ++ wrappers(wrapped, nif_name)

    elixir_mode =
      if elixir?, do: Defk.ElixirMode.definitions(kernels, all_sigs, env.file), else: []

    # The generated functions are `@doc false` (ADR-0006): the Defk moduledoc
    # ("Generated functions") describes them, with their stability.
    corrupt_tags = corrupt_tags_def(fault_hooks?)

    quote do
      @on_load :__defk_load__
      @doc false
      def __defk_load__, do: :erlang.load_nif(unquote(String.to_charlist(lib)), 0)
      @doc false
      def __defk_c_source__, do: unquote(c_src)
      @doc false
      def __defk_report__, do: unquote(Macro.escape(report))
      @doc false
      def __defk_lib__, do: unquote(lib <> ".so")
      @doc false
      def __defk_stats__, do: :erlang.nif_error(:defk_not_loaded)
      @doc false
      def __defk_kernels__, do: unquote(Macro.escape(sigs))
      @doc false
      def __defk_force_yields__(_on), do: :erlang.nif_error(:defk_not_loaded)
      unquote(corrupt_tags)
      unquote_splicing(stubs)
      unquote_splicing(elixir_mode)
    end
  end

  # `__defk_corrupt_tags__/1` deliberately breaks the frame-tag check, so it
  # is generated only when the user's module compiles under MIX_ENV=test
  # (scripts without Mix never get it).
  defp fault_hooks? do
    Code.ensure_loaded?(Mix.Project) and Mix.Project.get() != nil and Mix.env() == :test
  end

  defp corrupt_tags_def(false), do: nil

  defp corrupt_tags_def(true) do
    quote do
      @doc false
      def __defk_corrupt_tags__(_on), do: :erlang.nif_error(:defk_not_loaded)
    end
  end

  # A kernel's spec and stub, whose call raises unless the NIF is loaded.
  defp render_stubs(sigs) do
    for %{name: name, params: params, ret: ret} <- sigs do
      args = for {p, _} <- params, do: Macro.var(:"_#{p}", nil)
      specs = for {_, t} <- params, do: spec(t, :in)

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(args)), do: :erlang.nif_error(:defk_not_loaded)
      end
    end
  end

  # Elixir mode: the NIF keeps its own name, so each kernel gets a bare native
  # stub plus a kernel-name def that dispatches on the process mode.
  defp native_stubs(sigs, nif_name) do
    for %{name: name, params: params} <- sigs do
      args = for {p, _} <- params, do: Macro.var(:"_#{p}", nil)

      quote do
        @doc false
        def unquote(nif_name.(name))(unquote_splicing(args)),
          do: :erlang.nif_error(:defk_not_loaded)
      end
    end
  end

  # A kernel that returns a bitstring: its NIF gives {bytes, bit_length},
  # which this def makes the bitstring (Defk.Bitstring.decode/2).
  defp wrappers(sigs, nif_name) do
    for %{name: name, params: params, ret: ret} <- sigs do
      specs = for {_, t} <- params, do: spec(t, :in)
      vs = arg_vars(params)
      call = quote do: unquote(nif_name.(name))(unquote_splicing(vs))

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(vs)), do: unquote(Defk.Bitstring.decode(ret, call))
      end
    end
  end

  defp dispatch_defs(sigs, mode, nif_name) do
    for %{name: name, params: params, ret: ret} <- sigs do
      specs = for {_, t} <- params, do: spec(t, :in)
      vs = arg_vars(params)

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(vs)) do
          case Process.get(unquote(Defk.ElixirMode.process_mode_key()), unquote(mode)) do
            :elixir ->
              __defk_elixir__(unquote(name), [unquote_splicing(vs)])

            _ ->
              unquote(
                Defk.Bitstring.decode(
                  ret,
                  quote(do: unquote(nif_name.(name))(unquote_splicing(vs)))
                )
              )
          end
        end
      end
    end
  end

  @doc false
  # The variables a generated function passes its arguments on in: the
  # parameter names, with a leading underscore dropped (`_scale` is used
  # there, which Elixir warns about), numbered when that name is taken.
  def arg_vars(params) do
    names = MapSet.new(params, &elem(&1, 0))

    for {{p, _}, i} <- Enum.with_index(params) do
      trimmed = String.trim_leading(Atom.to_string(p), "_")

      name =
        cond do
          trimmed == "" -> :"arg#{i}"
          trimmed == Atom.to_string(p) -> p
          String.to_atom(trimmed) in names -> :"#{trimmed}#{i}"
          true -> String.to_atom(trimmed)
        end

      {name, [generated: true], nil}
    end
  end

  defp spec(:i64, _), do: quote(do: integer())
  defp spec(:u64, _), do: quote(do: non_neg_integer())
  defp spec(:f64, :in), do: quote(do: number())
  defp spec(:f64, :out), do: quote(do: float())
  defp spec(:bool, _), do: quote(do: boolean())
  defp spec({:arr, _}, _), do: quote(do: binary())
  defp spec(:bitstring, _), do: quote(do: bitstring())
  defp spec({:tuple, ts}, dir), do: {:{}, [], Enum.map(ts, &spec(&1, dir))}
end
