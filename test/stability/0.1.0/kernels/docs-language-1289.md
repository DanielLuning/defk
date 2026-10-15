<!-- docs/language.md line 1289 of v0.1.0. A frozen file is never edited. -->

```elixir
defk unpack(lits :: [u8], seqs :: [i64], size :: i64) :: [u8] do
  out = alloc(u8, size)

  {out, _, _} =
    for s <- 0..(div(length(seqs), 3) - 1)//1, reduce: {out, 0, 0} do
      {out, ip, op} ->
        ln = seqs[3 * s]
        out = copy(out, op, lits, ip, ln)
        out = copy_back(out, op + ln, seqs[3 * s + 1], seqs[3 * s + 2])
        {out, ip + ln, op + ln + seqs[3 * s + 2]}
    end

  out
end
```

```elixir
iex> seqs = for x <- [2, 0, 0, 1, 1, 4], into: <<>>, do: <<x::signed-64-native>>

iex> M.unpack("abc", seqs, 7)
"abccccc"
```
