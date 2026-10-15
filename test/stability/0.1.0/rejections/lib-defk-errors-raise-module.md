<!-- lib/defk/errors.ex line 850 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: raise-module -->
```elixir
defk f(n :: i64) :: i64 do
  if n < 1, do: raise(KeyError, "no such key")
  n
end
```
