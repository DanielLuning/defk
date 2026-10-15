<!-- lib/defk/errors.ex line 793 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: bitstring-segment -->
```elixir
defk f(x :: i64) :: bitstring do
  acc = <<>>
  <<acc::bitstring, x::little-16>>
end
```
