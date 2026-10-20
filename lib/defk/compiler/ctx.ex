defmodule Defk.Compiler.Ctx do
  # The compiler's one process-dictionary key: everything one
  # module's compile accumulates lives in this struct under :defk_ctx, so a
  # snapshot or a restore is one get or put of one value. The compile-wide
  # fields travel into every rejection (err!/4); `lowering` is replaced
  # wholesale per kernel and holds what one kernel's lowering changes.
  @moduledoc false

  defstruct file: nil,
            module: nil,
            lines: nil,
            fun: nil,
            where: nil,
            diags: [],
            broken: MapSet.new(),
            statics: %{},
            report: [],
            hints: false,
            bits_names: %{},
            lowering: nil

  defmodule Lowering do
    # what one kernel's lowering changes, replaced wholesale per kernel:
    # fresh-name and loop counters, declarations, safepoints, halt labels
    # ({id => true}, once {:defk_halted, id} keys), the fast-path report's
    # current kernel and loop, the strip record (Defk.Strip), the accumulator-carry
    # fix sets (per with_acc_facts retry ref, once {:defk_acc_facts, ref}),
    # the operand bindings of the expression being lowered (lower_ops), the
    # case guard being lowered (guard_expr): its flags as C locals once
    # used, nil outside a guard, and how often each local is mentioned in
    # each loop's C, by loop id (in_loop/1), from which the kernel's locals
    # table is built as the lowering ends (loop_locals/2)
    @moduledoc false

    defstruct n: 0,
              decls: [],
              decl_loop: %{},
              sp: 0,
              sps: [],
              loops: [],
              nloops: 0,
              nhalts: 0,
              halts_emitted: 0,
              halted: %{},
              report_kernel: nil,
              report_loop: nil,
              acc_fix: %{},
              copies: %Defk.Copies{},
              strip: %Defk.Strip{},
              operand_binds: [],
              guard: nil,
              loop_mentions: %{}
  end

  def new(file, module, lines), do: %__MODULE__{file: file, module: module, lines: lines}

  # Defk.ElixirMode refreshes :file for the rejections its own translation
  # raises after compile/4 returned (the compile's ctx stays in the process)
  def set(key, value) do
    ctx = Process.get(:defk_ctx) || %__MODULE__{}
    Process.put(:defk_ctx, Map.put(ctx, key, value))
  end
end
