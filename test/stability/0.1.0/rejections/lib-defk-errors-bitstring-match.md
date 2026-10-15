<!-- lib/defk/errors.ex line 299 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: bitstring-match -->
```elixir
defk f(arr :: [u8]) :: i64 do
  <<a, b, _::16, _rest::binary>> = arr
  a + b
end
```
