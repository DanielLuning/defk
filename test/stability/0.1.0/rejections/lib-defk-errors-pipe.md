<!-- lib/defk/errors.ex line 487 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: pipe -->
```elixir
defk f(x :: f64) :: f64 do
  x |> abs() |> sqrt()
end
```
