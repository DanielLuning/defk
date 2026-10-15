<!-- docs/guides/getting-started.md line 169 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-call -->
```elixir
defmodule Stats do
  use Defk

  defk sum(xs :: [f64]) :: f64 do
    Enum.sum(xs)
  end
end
```
