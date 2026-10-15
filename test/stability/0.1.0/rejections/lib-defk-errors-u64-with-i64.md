<!-- lib/defk/errors.ex line 342 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: u64-with-i64 -->
```elixir
defk f(h :: u64, x :: i64) :: u64 do
  h * 31 + x
end
```
