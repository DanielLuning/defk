<!-- lib/defk/errors.ex line 781 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: binary-literal -->
```elixir
defk f(i :: i64) :: i64 do
  t = <<1, 2, 300>>
  t[i]
end
```
