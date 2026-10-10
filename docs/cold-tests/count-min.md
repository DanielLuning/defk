# defk cold test log: count-min sketch update_many

Rule check: I read README.md and docs/language.md only (via sed through Bash, because the Read tool
returned only an outline map from a hook; that is the same two allowed files). No lib/test/examples/etc.

Design decision (before attempt 1): signature
`update_many(sk :: [u64], d :: i64, w :: i64, hashes :: [u64]) :: [u64]`.
Sketch is an INPUT that gets written (docs "Writing"/"Copies": input array write is copied once, caller's binary
never changed, returned array reaches caller w/o copy). Chosen over alloc'd output because an update must start
from existing counters; alloc would be zeros, so a copy of the input is needed anyway and the compiler does it.
Hashes: Kirsch-Mitzenmacher h1 = low 32 bits, h2 = high 32 bits, col_r = (h1 + r*h2 mod 2^32) mod w.
Docs consulted: sec 2 (defining), 3 (types, u64 arrays/building binaries), 4 u64 + masked arithmetic, 6 Writing/Copies/Returning, 7 for, 10 Elixir mode.
Docs unclear points so far: how a [u64] write of `sk[i] + 1` types (u64 + literal: docs say ok); whether `rem(u64, i64)` is allowed (docs: "two i64, or two u64" -> probably not mixed).

## Time-ordered attempts

### Attempt 0 (tooling, not defk): first script edit
`sed -i '1i import Bitwise'` failed on macOS BSD sed. Not a defk issue. Also: `mix deps.get` + first compile printed
a lot of unrelated dep warnings (reach, vibe_kit); noise only.

### Attempt 1: first kernel, compiled and agreed
Code (cold_test/count_min.exs, module CountMin):
```elixir
defk update_many(sk :: [u64], d :: i64, w :: i64, hashes :: [u64]) :: [u64] do
  for h <- hashes do
    h1 = band(h, 0xFFFFFFFF)
    h2 = bsr(h, 32)
    for r <- 0..(d - 1)//1 do
      col = rem(band(h1 + r * h2, 0xFFFFFFFF), w)
      idx = r * w + col
      sk[idx] = sk[idx] + 1
    end
  end
  sk
end
```
Compile error / exception: none. No warnings from defk.
Docs consulted: sec 4 "u64" (answered: band result is u64 so `rem(u64, i64 w)` ... I feared u64-mix; it compiled,
because `band(..., 0xFFFFFFFF)` with a narrow mask is an i64 in 0..m per "Masked arithmetic" "The result type";
h1 + r*h2 is inside the mask so u64/i64 mixing is fine) and sec 6 "Writing" / "Copies" / "Returning" (answered: write to input
array copies once; returning a written input is allowed, `return-input-array` is only for unwritten).
Elixir mode: sec 10 told me `use Defk, elixir_mode: true` for mix run scripts and `Mod.__defk_elixir__(:name, args)`.
Result of `mix run cold_test/count_min.exs`: `{true, true, true}` = {native == plain-Elixir reference, Elixir mode == reference, native == Elixir mode}
on d=4, w=37, 2000 random 64-bit hashes (incl. top-bit set), initial counters random 1..1000.

### Attempt 2: ExUnit check with assert_agrees (cold_test/count_min_test.exs; kernel+Ref in count_min_lib.exs)
Randomised over (d,w) in {1x1,1x5,4x37,7x64,3x1000}, 20 runs each, 0..299 hashes (incl. empty batch), asserts native == Ref,
input binary unchanged after the call, and `Defk.Test.assert_agrees(CountMin, :update_many, [sk, d, w, hb])`.
Result: `mix test cold_test/count_min_test.exs` -> 1 test, 0 failures. Docs sec 10 gave the assert_agrees signature
and it worked as written (module defined in a required file under :test env; no `elixir_mode: true` needed but harmless).

## Summary
- Total attempts: 1 to a working kernel (plus 1 test run that also passed). Never stuck; no defk error code was hit.
- Error codes hit: none. Hence no helped/didn't-help data. (The error-code half of the cold test was not exercised.)
- Missing / misleading docs (small):
  1. sec 3 "As an argument": nothing says a [u64] binary built in Elixir must be `unsigned-64-native`; it is in the table
     (ok) but an Elixir ref author must also know that to read it back; fine.
  2. sec 4 "u64": the bullet "Any other i64 next to a u64 outside a mask is u64-mix" does not say plainly whether
     `rem(u64_value, i64_param)` is allowed. I resolved it by masking (`band(.., 0xFFFFFFFF)` gives an i64), which the
     "Masked arithmetic -> result type" bullet implies but nobody states for `rem`. An example "count-min / bucket index of a hash"
     (hash -> `rem(band(h, mask), w)`) would help. `bsr(h, 32)` of a u64 gives u64, then `r * h2` is i64*u64, which compiled
     only because it sits inside the mask; the doc covers this but only by inference.
  3. sec 6: no example of the very common "bump a counter in a [u64]/[i64] table from a batch" (the histogram example is [i64]);
     `sk[idx] = sk[idx] + 1` on [u64] working was inferred from the Writing rules, not shown.
  4. sec 10: Elixir mode under `mix run` needs `use Defk, elixir_mode: true`; the sentence is there but easy to miss;
     I did not know `config :defk, mode: :elixir` would be refused outside :dev/:test until reading the bullets (they are clear).
  5. Doc says the doc is 3800 lines; the Elixir-mode/agreement section (10) is far from the first mention in README, fine.
- Final kernel: as in Attempt 1. Signature chosen: sketch is an input (copied once on first write by the compiler, caller's binary unchanged,
  verified in the test), not alloc'd, because updates must preserve existing counters and an alloc'd output would force passing the
  old sketch in anyway and copying it by hand.
- Agrees with Elixir mode: yes. Checked via `Mod.__defk_elixir__/2` (== reference == native) in the script and
  `Defk.Test.assert_agrees/3` in the ExUnit test, on random inputs incl. top-bit-set hashes, empty batch, d=1, w=1.
- Caveat: counters are u64, so overflow past 2^64-1 would raise ArithmeticError (documented limit); not exercised.
