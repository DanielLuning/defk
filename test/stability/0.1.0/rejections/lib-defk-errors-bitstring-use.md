<!-- lib/defk/errors.ex line 807 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: bitstring-use -->
```elixir
defk f(n :: i64) :: i64 do
  acc = <<>>
  acc = <<acc::bitstring, n::8>>
  length(acc)
end
```
