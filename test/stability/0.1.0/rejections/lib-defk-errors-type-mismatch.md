<!-- lib/defk/errors.ex line 322 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: type-mismatch -->
```elixir
defk f(a :: [f64], i :: f64) :: f64 do
  a[i]
end
```
