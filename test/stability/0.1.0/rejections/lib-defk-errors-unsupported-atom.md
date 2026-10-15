<!-- lib/defk/errors.ex line 684 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-atom -->
```elixir
defk f(x :: i64) :: i64 do
  s = if x > 0, do: :pos, else: :neg
  x
end
```
