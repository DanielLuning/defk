<!-- lib/defk/errors.ex line 672 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-string -->
```elixir
defk f(x :: i64) :: i64 do
  s = "ab" <> "cd"
  length(s) + x
end
```
