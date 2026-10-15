<!-- lib/defk/errors.ex line 522 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: for-form -->
```elixir
defk f(x :: i64) :: i64 do
  for x > 0, reduce: 0 do
    acc -> acc + 1
  end
end
```
