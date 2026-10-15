<!-- lib/defk/errors.ex line 310 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: integer-literal -->
```elixir
defk f(x :: i64) :: i64 do
  x + 18_446_744_073_709_551_616
end
```
