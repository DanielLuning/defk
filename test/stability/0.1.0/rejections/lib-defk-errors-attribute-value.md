<!-- lib/defk/errors.ex line 770 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: attribute-value -->
```elixir
@table [1, 2, 4, 8]

defk f(i :: i64) :: i64 do
  i + @table
end
```
