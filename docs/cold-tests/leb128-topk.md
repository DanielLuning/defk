# defk cold test 2: LEB128 varint batch decode + streaming top-k

Job: kernel 1 decodes a binary of packed unsigned LEB128 varints into values, raising on a truncated final varint; kernel 2 returns the k largest of a [f64] in descending order using a small fixed-size sorted buffer, stopping early on empty input or k == 0. Compare both to plain Elixir.

Sources read (only): README.md, docs/language.md (sections 1-10 read in full via sed; section 11 error catalogue NOT consulted because every compiler message was self-explanatory). Note: my Read tool was intercepted by a hook that returns only an outline, so I used `cat`/`sed` on those two files.

Setup: README gives no instructions for using defk as a dependency (only "mix run demo.exs" inside the repo). docs/language.md section 10 mentions a Mix.install script and Mix projects. I made a Mix project at this directory with `{:defk, path: ...}`. `mix deps.get` / `mix compile` worked first try. Missing: `test/test_helper.exs` is a plain Mix thing, not defk. (Lookup: setup -> README: NOT found; language.md sec 2/10: partly.)

## Attempt 1 (natural Elixir, pattern-matching recursion + lists)  [saved: attempt1_metrics.ex.txt]
Wrote multi-clause recursive decode over `binary` patterns returning a list, and a top-k using Enum.reduce/Enum.sort on lists, `[]` literals.

Compiler output (verbatim):

```
error: binary is not a kernel type
  |
5 |  defk decode(bin :: binary) :: list do
  |                     ^^^^^^
  |
  └─ lib/metrics.ex:5:22: Metrics.decode/1

why: a kernel works on native numbers and packed arrays, and these are the types it has
hint: the kernel type for binary is [u8]
(defk unknown-type: docs/language.md#unknown-type)
```
Rating: HELPED (hint names the exact replacement). Note `:: list` return type was not reported (likely suppressed after the first type error; only the binary one shown).

```
error: decode/4 has clauses but no head
  |
9 |  defk decode(<<>>, 0, 0, acc), do: Enum.reverse(acc)
  |       ^^^^^^^^^^^^^^^^^^^^^^^
  |
  └─ lib/metrics.ex:9:8: Metrics.decode/4

why: a clause has patterns, not types; the head gives the kernel its parameter and return types, and Elixir reads the head first too
hint: a multi-clause kernel starts with a bodiless head that types its parameters and result, such as `defk decode(x1 :: i64, val :: i64, shift :: i64, acc :: i64) :: i64`, written before the clauses
(defk clause-head: docs/language.md#clause-head)
```
Rating: HELPED (the hint writes the head for me). Slightly misleading: it is moot, since binary patterns / lists are not allowed anyway, but it could not know that.

```
error: lists such as [] are not in the kernel subset
   |
21 |      []
   |      ^^
   |
   └─ lib/metrics.ex:21:7: Metrics.top_k/2

why: a list is a linked BEAM term; a kernel works on packed arrays
hint: pass the values as an array, a binary such as `for x <- list, into: <<>>, do: <<x::float-native-64>>`
(defk unsupported-list: docs/language.md#unsupported-list)
```
Rating: HELPED for the concept (packed arrays), PARTLY for what to do about a *result* (hint is about inputs; nothing says "return a packed [f64] and a count, you cannot slice"). I went to the docs for the real design.

Doc lookups after attempt 1: sections 3 (Types, tuple returns, how Elixir builds/reads arrays), 6 (alloc, writing, Returning), 7 (for/reduce, reduce_while, array accumulators, raise). All answers found in language.md. Key design consequences I derived from the docs: the output size is unknown, so allocate `len(bin)` u64 slots (a varint is >= 1 byte) and return `{array, count}`; the caller slices with binary_part. No slice/truncate builtin exists (not stated anywhere explicitly; I inferred it from the builtin table).

## Attempt 2 (array-based, array carried as reduce accumulator)  [attempt2_metrics.ex.txt]
decode: `for b <- bin, reduce: {out, 0, 0, 0}` with `if b < 128 do out[n] = val; {out, n+1, 0, 0} else {out, n, val, shift+7} end`. top_k: alloc(f64, max(min(k,len),0)), Enum.reduce_while with {buf, cnt} accumulator, insertion by counting elements >= x then shifting with a descending `for j <- last..(p+1)//-1`, `{:halt, ..}` when m == 0.

```
error: this if gives an array ([u64]) as element 1 of its tuples; arrays from if branches are not supported yet
   |
12 |          if b < 128 do
   |          ^^^^^^^^^^^^^
   |
   └─ lib/metrics.ex:12:11: Metrics.decode/1

why: an if/cond/case may give numbers, booleans or tuples of them, not arrays yet
hint: do the array work inside each branch
(defk array-in-branch: docs/language.md#array-in-branch)
```
Rating: HELPED. I had remembered from the docs ("a[i] = v ... does carry over") that I do not need to thread the array; the hint "do the array work inside each branch" confirms it. Only the decode kernel was flagged; top_k (same pattern but arrays in a reduce_while accumulator with if/else tails) was accepted.

Change: removed `out` from the accumulator, keep it as a plain variable written in place inside the `if`.

## Attempt 3: compiled with no errors and no warnings. [attempt3_metrics.ex.txt]
First test run: 3 of 4 passed; failure was a RUNTIME error (not compile time) on varint 2**63:

```
** (ArithmeticError) i64 overflow in bsl(1, 63)
  Metrics.__defk_native_decode__(<<128, 128, ..., 1, 5, ...>>)
```
Rating: HELPED (clearly names the cause: i64 arithmetic). Doc search: "u64" section (lines ~401-456) and "Masked arithmetic" intro in README; the u64 rule "an accumulator ... becomes a u64 ... or when it meets a u64; band(x, 0xFFFFFFFFFFFFFFFF) gives a u64, where i64 and u64 mix freely" led to the fix: `val = band(val + bsl(band(b, 0x7F), shift), 0xFFFFFFFFFFFFFFFF)`. Found in language.md, but I had to connect two separate paragraphs (u64 section + the count-min example's prose about masks).

## Attempt 4: all 4 tests pass.

## Final code: lib/metrics.ex
```elixir
defmodule Metrics do
  use Defk

  defk decode(bin :: [u8]) :: {[u64], i64} do
    out = alloc(u64, len(bin))

    {n, _val, shift} =
      for b <- bin, reduce: {0, 0, 0} do
        {n, val, shift} ->
          val = band(val + bsl(band(b, 0x7F), shift), 0xFFFFFFFFFFFFFFFF)

          if b < 128 do
            out[n] = val
            {n + 1, 0, 0}
          else
            {n, val, shift + 7}
          end
      end

    if shift != 0, do: raise(ArgumentError, "truncated varint")
    {out, n}
  end

  defk top_k(samples :: [f64], k :: i64) :: {[f64], i64} do
    m = max(min(k, len(samples)), 0)
    buf = alloc(f64, m)

    Enum.reduce_while(samples, {buf, 0}, fn x, {buf, cnt} ->
      if m == 0 do
        {:halt, {buf, cnt}}
      else
        p =
          for i <- 0..(cnt - 1)//1, reduce: 0 do
            acc -> if buf[i] >= x, do: acc + 1, else: acc
          end

        if p < m do
          last = min(cnt, m - 1)

          for j <- last..(p + 1)//-1 do
            buf[j] = buf[j - 1]
          end

          buf[p] = x
          {:cont, {buf, min(cnt + 1, m)}}
        else
          {:cont, {buf, cnt}}
        end
      end
    end)
  end
end
```

## Tests: test/metrics_test.exs
Compares against plain Elixir reference decoder (binary-pattern recursion, raises on truncation) and `Enum.sort(:desc) |> Enum.take(k)`; includes fixed cases (empty, 0, 127/128/300/16384, 2**63, k=0, k=-1, k > n, duplicates, truncated varints) and 200 random cases each; also compares native vs `Metrics.__defk_elixir__/2` (Elixir mode, available in :test).

Result of `mix test`: `4 tests, 0 failures` (after attempt 4).

Extra probe: 11 continuation bytes then a final 1 (an over-long varint, >64 bits) does not raise in either native or Elixir mode; high bits are silently dropped by the mask and one value (0) is returned. Native and Elixir mode agree. A real decoder would likely want to raise on >10 bytes; I did not add this, and docs do not warn that masking silently discards bits.

## Honest summary of what was confusing
- Biggest gap: how to set up a project. README never says how to depend on defk or how a user project looks; I guessed `{:defk, path: ...}` and `use Defk`. It worked, but a newcomer is left guessing (README only shows `mix run demo.exs` inside the repo).
- Natural Elixir (recursion over binary patterns, lists) is rejected wholesale; the three errors were individually clear, but the clause-head error was a red herring for a design that cannot work (binary patterns and lists are unsupported anyway). Each error alone did tell me how to get unstuck for its own line; the global redesign (array in + {array, count} out, binary_part in the caller, since there is no slicing or dynamic-length result) had to come from the docs; nothing in an error message says "variable-length results are returned as an over-allocated array plus a count".
- The array-in-branch hint was the right one; the docs section on "does carry over" writes explains why.
- Surprise at runtime, not compile time: i64 overflow in bsl for varints near 2**63. The u64/masking fix is documented but spread over several places; a varint/LEB128 recipe would help. The default `reduce: {0,...}` literal does not become u64 on its own from `bsl` results.
- Overlong varints silently truncate under the mask (see probe above).
- Tooling nit unrelated to defk: my file Read tool returned only an outline, so I used cat/sed.

## Follow-up (after the run, not part of the session)

Each gap above, fixed or ticketed (defk-dig):

- clause-head hiding the unsupported binary patterns, and suggesting
  `x1 :: i64` for a binary-pattern parameter: ticketed, defk-x4o.
- unsupported-list's hint covered inputs only: it now also says how to build
  a result of unknown length (`<<acc::bitstring, x::64>>`), and
  docs/language.md "Unsupported, write this instead" has a row for
  `[x | acc]` + `Enum.reverse(acc)` (bitstring accumulator, or `alloc` the
  largest size and return `{out, count}`).
- Checking that recipe on this job found a bug: a `u64` value in a bitstring
  segment was converted to `i64`, so `<<acc::bitstring, v::64>>` raised
  "9223372036854775808 does not fit in i64" natively for v >= 2^63 while
  Elixir mode returned the bytes. Fixed: an unsigned segment takes a `u64`
  as it is (test/bitstring_test.exs, with an agreement property).
- Masking silently drops high bits (an over-long varint): docs/language.md
  "Masked arithmetic" now says so, with the varint case.
- README did not say how to depend on defk: it now does (path dependency or
  `Mix.install`, then `use Defk`).
- The u64 rule spread over several paragraphs: the new masked-arithmetic note
  gives the varint case; no separate recipe added.
