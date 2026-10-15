<!-- lib/defk/errors.ex line 836 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: raise-message -->
```elixir
defk f(n :: i64) :: i64 do
  if n < 1, do: raise(ArgumentError, "bad length #{n}")
  n
end
```
