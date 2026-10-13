# out_of_scope_word_count: count word frequencies in a document
#
# Strings in, a map out. defk kernels work on numbers and packed arrays and
# cannot build BEAM terms such as maps or strings, so this cannot be a kernel
# at all. Elixir's String.split + Enum.frequencies is the right tool.
# Expected verdict: out_of_scope
#
#   elixir examples/out_of_scope_word_count.exs

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

# What happens if you try: the compiler rejects it with a clear error.
attempt = """
defmodule WordCount.Kernels do
  use Defk

  defk count(text :: [u8]) :: [i64] do
    words = String.split(text)
    Enum.frequencies(words)
  end
end
"""

try do
  Code.compile_string(attempt, "word_count_kernel.ex")
  raise "unexpected: the kernel compiled (this example expects a compile error)"
rescue
  e in CompileError -> IO.puts("defk compiler says: " <> Exception.message(e))
end

vocab = ~w(the beam schedules lightweight processes fairly across every core it has)
text = Enum.map_join(1..200_000, " ", fn i -> Enum.at(vocab, rem(i * 7919, length(vocab))) end)

Defk.Bench.report(
  name: "out_of_scope_word_count",
  expected: :out_of_scope,
  elixir: fn -> text |> String.split() |> Enum.frequencies() end,
  reason: "maps and strings are BEAM terms; kernels only work on numbers and packed arrays"
)
