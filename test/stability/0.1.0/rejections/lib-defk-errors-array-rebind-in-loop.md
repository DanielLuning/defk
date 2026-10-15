<!-- lib/defk/errors.ex line 862 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: array-rebind-in-loop -->
```elixir
defk f(n :: i64) :: [i64] do
  a = alloc(i64, n)

  for i <- 0..(n - 1)//1 do
    a = alloc(i64, n)
    a[i] = i
  end

  a
end
```
