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
      ...>     n = min(length(a), length(b))
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
  `defk/2`). A module may mix kernels with ordinary `def`s. Four options:

    * `elixir_mode: true` compiles Elixir mode into the module in any
      environment, so `__defk_elixir__/2` exists outside `:test` (in a
      `Mix.install` script, for instance). The kernels' own functions still
      run natively. Default `false`. See `Defk.ElixirMode`.
    * `report: :full` adds the C compiler's vectorisation of each loop to the
      [fast-path report](`Defk.Report`), at the cost of a second C compile.
      What it adds is unstable.
    * `adaptive_slice: false` turns off the short first slice on a crowded
      run queue. By default a yielding kernel's function reads
      `:erlang.statistics(:total_run_queue_lengths)` (about 9 ns) and, when
      processes are waiting, yields every 50 µs instead of every 250 µs for
      the call's first millisecond, so short calls fanned out with
      `Task.async_stream/3` spread over the schedulers. Turn it off only for
      a module whose kernels are called many times a microsecond's work at a
      time, where the 9 ns shows. The option is unstable: the heuristic is
      new and may be retuned or replaced. See the
      [runtime contract](runtime-contract.md#1-preemption-a-long-kernel-yields).
    * `max_owned_bytes: n` is the most one kernel call may hold in arrays it
      allocates or copies (every one lives until the kernel returns, so an
      `alloc` or a copy in a loop body keeps one per iteration). An
      allocation past it raises `ArgumentError` "out of memory" instead of
      letting the operating system kill the node. A positive integer, or an
      expression giving one; default half of physical memory, read when the
      library loads. Elixir mode enforces the same budget, with the same
      message, on the bytes the call's `alloc/2` calls ask for; it does not
      count copies or bitstring buffers, which it garbage-collects. See
      [the owned-buffer budget](language.md#the-owned-buffer-budget).

  Any other option raises `ArgumentError`. Module attributes whose names
  start with `@defk_` are reserved for defk: don't define your own.

  A module may set its own `@on_load`. defk chains it: the kernels' library
  loads first, then your hook runs (so it may call the module's kernels —
  locally only, `kernel(x)` not `__MODULE__.kernel(x)`, since the module is
  not loaded while its own `on_load` runs), and the module loads only if both
  return `:ok`.

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
    * `DEFK_SANITIZE` builds the kernels with sanitizers, to check the
      generated C for memory errors and undefined behaviour (never for
      production or benchmarks: `Defk.Bench.report/1` refuses to run in this
      mode). It is a comma-separated list of `address` (AddressSanitizer),
      `undefined` (UndefinedBehaviorSanitizer, stopping at the first report)
      and `trap` (UBSan with no runtime: a report is a `SIGTRAP`, with no
      message); each adds `-g -fno-omit-frame-pointer`. The mode is part of
      the library's cache key and its file name
      (`<Module>-<key>-san-<modes>.so`), so a normal build never reuses a
      sanitized library or the reverse. A module of a Mix app compiles in this
      mode only with a build path of its own (`MIX_BUILD_PATH`), so the
      normal `_build/<env>` never gets a sanitized library. Under `address`,
      the bytes of slack ERTS allocates past an `alloc/2` result are poisoned,
      so a one-byte overrun is reported on a stock emulator too. An `address`
      library needs the ASan runtime in the VM (OTP's `asan` emulator, or
      `-env DYLD_INSERT_LIBRARIES` / `LD_PRELOAD` with `+Mea min`); an
      `undefined` one loads its runtime itself.
    * The C source and the library are written to
      `_build/<env>/defk/<Module>-<key>.{c,so}`; a module of a Mix app also
      gets a copy of the library in its app's `ebin/`, which it loads from
      wherever the app is (so it ships in a `mix release`). These paths are
      unstable.

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
  | `__defk_stats__/0` | unstable | the library's runtime counters: `%{frames_live:, promotions:, yields:, crc32c:, max_owned_bytes:}`. They count the currently loaded library only: a reload that builds a new library starts them at zero, and a call still running in the old library is counted there |

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
  # the generated message defines the runtime header includes (Defk.Messages)
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @messages_h Path.expand("../priv/defk_messages.h", __DIR__)

  @doc false
  # The options `use Defk` accepts, each with its tier: `:public` ones are
  # promised (the stability guide, "The public API"), `:unstable` ones may
  # change in any release ("What it does not cover"). The one list:
  # __using__/1 rejects any other key, `mix defk.stability.freeze` writes the
  # public ones into a release's API snapshot, and the docs checks hold the
  # guide to the unstable ones.
  def __options__,
    do: [
      elixir_mode: :public,
      report: :public,
      adaptive_slice: :unstable,
      max_owned_bytes: :public
    ]

  defmacro __using__(opts) do
    opts = Defk.Deprecations.rename_options(opts, __CALLER__)
    elixir_mode = Keyword.get(opts, :elixir_mode, false)
    report = Keyword.get(opts, :report)
    adaptive = Keyword.get(opts, :adaptive_slice, true)

    # an expression (`4 * 1024 ** 3`, `@limit`): evaluated in the module,
    # checked in __before_compile__/1 (max_owned_bytes!/1)
    max_owned_bytes = Keyword.get(opts, :max_owned_bytes)

    if Keyword.keys(opts) -- Keyword.keys(__options__()) != [] or
         not is_boolean(elixir_mode) or not is_boolean(adaptive) or report not in [nil, :full] do
      raise ArgumentError,
            "use Defk accepts only `elixir_mode: true | false`, `report: :full`, `adaptive_slice: true | false` and `max_owned_bytes: n`, got: #{Macro.to_string(opts)}"
    end

    quote do
      @defk_elixir_mode unquote(elixir_mode)
      @defk_adaptive_slice unquote(adaptive)
      @defk_max_owned_bytes unquote(max_owned_bytes)
      @defk_report unquote(report)
      import Defk, only: [defk: 1, defk: 2, defk: 3]
      Module.register_attribute(__MODULE__, :defk_kernels, accumulate: true)
      require Defk.Deprecations
      @defk_mode Defk.Deprecations.compile_env(:mode, :native)
      @external_resource unquote(@runtime_h)
      @external_resource unquote(@messages_h)
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
  compile error [`unknown-option`](compile-errors.md#unknown-option).

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

  # Module aliases are lexical, so they are expanded here, at the `defk` call
  # site, where the caller's `alias` lines are in scope (`__before_compile__`
  # runs later, with another scope). The expansion stays an `__aliases__`
  # node, so the compiler's `{:__aliases__, _, [:Defk, :Bits]}` patterns match
  # `Bits.clz(x)` under `alias Defk.Bits` and an aliased unsupported module is
  # reported under its real name. `Macro.expand/2` keeps compile tracers firing.
  defp expand_aliases(ast, caller) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [first | _]} = node when is_atom(first) ->
        case Macro.expand(node, caller) do
          mod when is_atom(mod) ->
            if match?("Elixir." <> _, Atom.to_string(mod)),
              do: {:__aliases__, meta, mod |> Module.split() |> Enum.map(&String.to_atom/1)},
              else: node

          _ ->
            node
        end

      node ->
        node
    end)
  end

  defp kernel(head, opts, body, caller) do
    head = expand_aliases(head, caller)
    body = if body == :head, do: body, else: expand_aliases(body, caller)

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
                    |> Map.merge(Defk.take_fn_attrs(__MODULE__))
    end
  end

  # An `@impl` or `@doc` written before a `defk` is meant for the kernel's
  # function. Left on the module, the `@impl` would go to the first function
  # defk generates (`__defk_load__/0`) and the `@doc` to the next `def`
  # written after the kernel. Take them off the module here and put them
  # before the kernel's `def` (attrs_before/2). The `@doc` keeps its line
  # (`{line, text}`). Metadata such as `@doc since: ...` is not an attribute
  # this can take: it still goes to the next `def`.
  @doc false
  def take_fn_attrs(module) do
    Map.new([:impl, :doc], fn attr ->
      value = Module.get_attribute(module, attr)
      Module.delete_attribute(module, attr)
      {attr, value}
    end)
  end

  # The `@impl` and `@doc` of each kernel, by {name, arity}: a multi-clause
  # kernel takes them from its head, the first entry that has them
  defp fn_attrs(raw_kernels) do
    Enum.reduce(raw_kernels, %{}, fn k, acc ->
      case for({attr, v} <- Map.take(k, [:impl, :doc]), v != nil, into: %{}, do: {attr, v}) do
        none when map_size(none) == 0 -> acc
        attrs -> Map.update(acc, Defk.Clauses.key(k.head), attrs, &Map.merge(attrs, &1))
      end
    end)
  end

  # `@doc` and `@impl` ahead of the public `def` of a kernel that had them
  # before its `defk`; the generated helpers and renamed NIFs never get them
  defp attrs_before(stubs, attrs) do
    Enum.map(stubs, fn
      {:__block__, meta, exprs} -> {:__block__, meta, Enum.flat_map(exprs, &put_attrs(&1, attrs))}
      expr -> put_attrs(expr, attrs) |> then(&{:__block__, [], &1})
    end)
  end

  defp put_attrs({:def, _, [{name, _, args}, _]} = expr, attrs) when is_list(args) do
    case Map.fetch(attrs, {name, length(args)}) do
      {:ok, a} -> doc_attr(a[:doc]) ++ impl_attr(a[:impl]) ++ [expr]
      :error -> [expr]
    end
  end

  defp put_attrs(expr, _attrs), do: [expr]

  defp doc_attr(nil), do: []

  defp doc_attr(doc),
    do: [quote(do: Module.put_attribute(__MODULE__, :doc, unquote(Macro.escape(doc))))]

  defp impl_attr(nil), do: []
  defp impl_attr(impl), do: [quote(do: @impl(unquote(Macro.escape(impl))))]

  @doc false
  defmacro __before_compile__(env) do
    raw_kernels = env.module |> Module.get_attribute(:defk_kernels) |> Enum.reverse()
    attrs = fn_attrs(raw_kernels)

    # a deprecated builtin is renamed here, once, so both backends lower
    # the new one and each call site warns once
    kernels =
      raw_kernels
      |> Defk.Deprecations.rename_builtins(env.file)
      |> Enum.map(&(&1 |> Defk.Attributes.inline() |> Defk.EnumForms.desugar()))
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
    adaptive? = Module.get_attribute(env.module, :defk_adaptive_slice)

    {c_src, all_sigs, report} =
      Defk.Compiler.compile(env.module, kernels, env.file,
        nif_name: nif_name,
        fault_hooks: fault_hooks?,
        adaptive_slice: adaptive?,
        max_owned_bytes: max_owned_bytes!(env.module)
      )

    # a yielding kernel's NIF takes the run-queue hint: it is
    # renamed, and the kernel's function passes the hint
    all_sigs = Enum.map(all_sigs, &Map.update!(&1, :yields, fn y -> adaptive? and y end))

    if dump = System.get_env("DEFK_DUMP_C"), do: dump_c!(dump, env.module, c_src)

    {report, lib_defs} = library(env, c_src, report)

    # a helper (a kernel taking a bitstring) is only inlined: no function
    sigs = Enum.reject(all_sigs, &Defk.Bitstring.helper?/1)

    stubs = sigs |> kernel_defs(elixir?, mode, bits) |> attrs_before(attrs)

    elixir_mode =
      if elixir?, do: Defk.ElixirMode.definitions(kernels, all_sigs, env.file), else: []

    # The generated functions are `@doc false` (ADR-0006): the Defk moduledoc
    # ("Generated functions") describes them, with their stability.
    corrupt_tags = corrupt_tags_def(fault_hooks?)

    load_def = load_def(Defk.take_on_load(env.module))

    quote do
      @on_load :__defk_load__
      unquote(load_def)
      unquote(lib_defs)
      @doc false
      def __defk_c_source__, do: unquote(c_src)

      unquote(recompile_def())

      @doc false
      def __defk_report__, do: unquote(Macro.escape(report))
      @doc false
      def __defk_stats__, do: :erlang.nif_error(:defk_not_loaded)
      @doc false
      def __defk_kernels__, do: unquote(Macro.escape(Enum.map(sigs, &Map.delete(&1, :yields))))
      @doc false
      def __defk_force_yields__(_on), do: :erlang.nif_error(:defk_not_loaded)
      unquote(corrupt_tags)
      unquote_splicing(stubs)
      unquote_splicing(elixir_mode)
    end
  end

  # Mix's compile.elixir asks every module __mix_recompile__? on every
  # compile: the build inputs read from the environment (the C compiler, the
  # include dir, the sanitizer mode) are baked in, so a change recompiles the
  # module. Raw values, so set-versus-unset counts; harmless outside Mix.
  # DEFK_NO_CC is one of them: a module compiled without its library
  # compiles again, with it, as soon as the variable is unset.
  @build_env ["CC", "ERTS_INCLUDE_DIR", "DEFK_SANITIZE", "DEFK_NO_CC"]

  defp recompile_def do
    baked = for var <- @build_env, do: {var, System.get_env(var)}

    quote do
      @doc false
      def __mix_recompile__? do
        Enum.any?(unquote(baked), fn {var, value} -> System.get_env(var) != value end)
      end
    end
  end

  # The module's own `@on_load`: a module may have only one, so take
  # the user's off here (defk sets its own) and chain it after the kernels load.
  @doc false
  def take_on_load(module) do
    hook = Module.get_attribute(module, :on_load)
    Module.delete_attribute(module, :on_load)

    case hook do
      nil -> nil
      [h | _] -> hook_name(h)
      h -> hook_name(h)
    end
  end

  defp hook_name({name, 0}), do: name
  defp hook_name(name) when is_atom(name), do: name

  # __defk_load__/0 is the module's on_load: load the kernels, then the
  # module's own hook; only :ok from both lets the module load.
  defp load_def(nil) do
    quote do
      @doc false
      def __defk_load__, do: __defk_load_nif__()
    end
  end

  defp load_def(user_hook) do
    quote do
      @doc false
      def __defk_load__ do
        case __defk_load_nif__() do
          :ok -> unquote(user_hook)()
          other -> other
        end
      end
    end
  end

  # The module's library (Defk.Build.library/3) and the report that may read
  # it: `{report, lib_defs}`.
  defp library(env, c_src, report) do
    case Defk.Build.library(env.module, c_src, env.file) do
      {:ok, lib} ->
        # the fast-path report: defk's own notes, and clang's vectorisation
        # under `report: :full` (an extra compiler pass, Defk.Report.full/3)
        report =
          if Module.get_attribute(env.module, :defk_report) == :full,
            do: Defk.Report.full(report, c_src, lib),
            else: report

        {report, lib_defs(Defk.Build.placement!(env.module, lib, env.file))}

      :no_cc ->
        {report, lib_defs(:none)}
    end
  end

  # __defk_load_nif__/0 and __defk_lib__/0 (Defk.Build.placement!/3). A Mix app's
  # module loads its library from beside its beams, wherever the app is at
  # load time (a release, a moved _build); anything else from the
  # absolute build path. Only :code and :filename at load time: the on_load
  # function may run before other applications' modules are loaded.
  # DEFK_NO_CC with no cached library: the module loads without its NIFs, so
  # a dump can load test files and examples; a kernel call raises
  # (:erlang.nif_error from its stub).
  defp lib_defs(:none) do
    quote do
      @doc false
      def __defk_load_nif__, do: :ok
      @doc false
      def __defk_lib__, do: nil
    end
  end

  defp lib_defs({:path, base}) do
    quote do
      @doc false
      def __defk_load_nif__, do: :erlang.load_nif(unquote(String.to_charlist(base)), 0)
      @doc false
      def __defk_lib__, do: unquote(base <> ".so")
    end
  end

  defp lib_defs({:app, app, name, fallback}) do
    rel = String.to_charlist(Path.join("ebin", Path.rootname(name)))
    fallback = String.to_charlist(Path.rootname(fallback))

    quote do
      # Mix recompiles the module when the library is gone. A module whose
      # library is missing cannot load, so __mix_recompile__?/0 never runs.
      @external_resource unquote(List.to_string(fallback) <> ".so")

      defp __defk_lib_base__ do
        case :code.lib_dir(unquote(app)) do
          dir when is_list(dir) -> :filename.join(dir, unquote(rel))
          _ -> unquote(fallback)
        end
      end

      @doc false
      def __defk_load_nif__, do: :erlang.load_nif(__defk_lib_base__(), 0)
      @doc false
      def __defk_lib__, do: :unicode.characters_to_binary(__defk_lib_base__() ++ ~c".so")
    end
  end

  # Each kernel's function: the NIF itself (a stub it replaces), or an Elixir
  # function calling the renamed NIF (Elixir mode, a bitstring result, the
  # run-queue hint)
  defp kernel_defs(sigs, true, mode, _bits), do: native_stubs(sigs) ++ dispatch_defs(sigs, mode)

  defp kernel_defs(sigs, false, _mode, bits) do
    {wrapped, plain} = Enum.split_with(sigs, &(&1.name in bits or &1.yields))
    render_stubs(plain) ++ native_stubs(wrapped) ++ wrappers(wrapped)
  end

  # DEFK_DUMP_C=<dir>: every module compiled while it is set writes its
  # generated C to <dir>/<Module>.c — the byte-identical gate for compiler
  # refactors (dev/dump_c.exs). A pure side channel: the build
  # and the module are unchanged.
  defp dump_c!(dir, module, c_src) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{inspect(module)}.c"), c_src)
  end

  # `use Defk, max_owned_bytes: n`: a positive integer of bytes that fits in
  # a uint64 (DEFK_MAX_OWNED), or nil (the runtime's default)
  defp max_owned_bytes!(module) do
    case Module.get_attribute(module, :defk_max_owned_bytes) do
      n when is_nil(n) or (is_integer(n) and n > 0 and n <= 0xFFFFFFFFFFFFFFFF) ->
        n

      other ->
        raise ArgumentError,
              "use Defk, max_owned_bytes: expects a positive integer number of bytes (at most 2^64 - 1), the most a kernel call may hold in arrays it allocates or copies, got: #{inspect(other)}"
    end
  end

  # `__defk_corrupt_tags__/1` deliberately breaks the frame-tag check and
  # `__defk_inject_fault__/1` makes a kernel fault on purpose, so they are
  # generated only when the user's module compiles under MIX_ENV=test
  # (scripts without Mix never get them).
  defp fault_hooks? do
    Defk.Build.mix_project?() and Mix.env() == :test
  end

  defp corrupt_tags_def(false), do: nil

  defp corrupt_tags_def(true) do
    quote do
      @doc false
      def __defk_corrupt_tags__(_on), do: :erlang.nif_error(:defk_not_loaded)
      @doc false
      def __defk_inject_fault__(_kind), do: :erlang.nif_error(:defk_not_loaded)
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

  # The NIF of a kernel that gets an Elixir function (Elixir mode, a
  # bitstring result, the run-queue hint) is renamed: a bare native stub for
  # it, which the NIF replaces. With the hint it takes one more argument.
  defp native_stubs(sigs) do
    for %{name: name, params: params} = sig <- sigs do
      args = for {p, _} <- params, do: Macro.var(:"_#{p}", nil)
      args = if sig.yields, do: args ++ [Macro.var(:_waiting, nil)], else: args

      quote do
        @doc false
        def unquote(Defk.ElixirMode.native_name(name))(unquote_splicing(args)),
          do: :erlang.nif_error(:defk_not_loaded)
      end
    end
  end

  # The call of a renamed NIF; a yielding kernel passes how many processes
  # wait in the run queues, and a crowded queue gets short first slices
  # (defk_slice_init in priv/defk_runtime.h).
  defp nif_call(%{name: name, yields: yields}, vs) do
    native = Defk.ElixirMode.native_name(name)

    if yields,
      do:
        quote(
          do: unquote(native)(unquote_splicing(vs), :erlang.statistics(:total_run_queue_lengths))
        ),
      else: quote(do: unquote(native)(unquote_splicing(vs)))
  end

  # A kernel's function that calls its renamed NIF; a bitstring result is
  # made from the NIF's {bytes, bit_length} (Defk.Bitstring.decode/2).
  defp wrappers(sigs) do
    for %{name: name, params: params, ret: ret} = sig <- sigs do
      specs = for {_, t} <- params, do: spec(t, :in)
      vs = Defk.Args.vars(params)
      body = Defk.Bitstring.decode(ret, nif_call(sig, vs))

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(vs)), do: unquote(body)
      end
    end
  end

  defp dispatch_defs(sigs, mode) do
    for %{name: name, params: params, ret: ret} = sig <- sigs do
      specs = for {_, t} <- params, do: spec(t, :in)
      vs = Defk.Args.vars(params)

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(vs)) do
          case Process.get(unquote(Defk.ElixirMode.process_mode_key()), unquote(mode)) do
            :elixir ->
              __defk_elixir__(unquote(name), [unquote_splicing(vs)])

            _ ->
              unquote(Defk.Bitstring.decode(ret, nif_call(sig, vs)))
          end
        end
      end
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
