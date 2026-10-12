defmodule Defk.Compiler.Ctx do
  # The compiler's one process-dictionary key (defk-euu): everything one
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
            lowering: nil

  def new(file, module, lines), do: %__MODULE__{file: file, module: module, lines: lines}

  # Defk.ElixirMode refreshes :file for the rejections its own translation
  # raises after compile/4 returned (the compile's ctx stays in the process)
  def set(key, value) do
    ctx = Process.get(:defk_ctx) || %__MODULE__{}
    Process.put(:defk_ctx, Map.put(ctx, key, value))
  end
end
