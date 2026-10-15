<!-- docs/guides/getting-started.md line 246 of v0.1.0. A frozen file is never edited. -->

```elixir
defmodule Windows do
  use Defk

  # the largest byte count in each 4-byte window
  defk max_count(data :: [u8]) :: [i64] do
    n = div(length(data), 4)
    out = alloc(i64, n)
    counts = alloc(i64, 256)

    for w <- 0..(n - 1)//1 do
      for b <- 0..255//1 do
        counts[b] = 0
      end

      for i <- 0..3//1 do
        b = data[w * 4 + i]
        counts[b] = counts[b] + 1
      end

      out[w] = for c <- counts, reduce: 0 do
        m -> max(m, c)
      end
    end

    out
  end
end
```

```elixir
iex> Windows.max_count("aabcdddd")
<<2::signed-64-native, 4::signed-64-native>>
```
