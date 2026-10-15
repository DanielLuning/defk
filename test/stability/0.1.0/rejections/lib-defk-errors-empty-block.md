<!-- lib/defk/errors.ex line 192 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: empty-block -->
```elixir
defk f(x :: i64) :: i64 do
  y =
    if x > 0 do
    else
      1
    end

  y
end
```
