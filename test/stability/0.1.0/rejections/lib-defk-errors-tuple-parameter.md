<!-- lib/defk/errors.ex line 95 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: tuple-parameter -->
```elixir
defk f(p :: {i64, i64}) :: i64 do
  {a, b} = p
  a + b
end
```
