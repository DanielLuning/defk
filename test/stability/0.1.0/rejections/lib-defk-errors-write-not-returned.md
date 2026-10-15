<!-- lib/defk/errors.ex line 876 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: write-not-returned -->
```elixir
defk fill(out :: [i64], v :: i64) :: i64 do
  out[0] = v
  v
end

defk f(n :: i64) :: [i64] do
  out = alloc(i64, n)
  _ = fill(out, 7)
  out
end
```
