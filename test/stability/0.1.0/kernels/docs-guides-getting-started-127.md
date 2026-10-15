<!-- docs/guides/getting-started.md line 127 of v0.1.0. A frozen file is never edited. -->

```elixir
defmodule Filter do
  use Defk

  defk positives(xs :: [i64]) :: {[i64], i64} do
    out = alloc(i64, length(xs))

    n =
      for x <- xs, reduce: 0 do
        n ->
          if x > 0 do
            out[n] = x
            n + 1
          else
            n
          end
      end

    {out, n}
  end
end
```

```elixir
iex> xs = for x <- [3, -1, 4, -1, 5], into: <<>>, do: <<x::signed-64-native>>

iex> {out, n} = Filter.positives(xs)

iex> n
3

iex> for <<x::signed-64-native <- binary_part(out, 0, n * 8)>>, do: x
[3, 4, 5]
```
