# Cold test: an agent with only the usage rules

Source: defk-djy.18, 2026-10-15.

## Setup

- A scratch Mix project (`mix new consumer`) with defk as a path dependency
  and `usage_rules`, configured as the Getting started guide recommends:
  `usage_rules: [{:defk, sub_rules: []}, {:defk, sub_rules: :all, main: false, link: :markdown}]`.
- `mix usage_rules.sync --yes` wrote 173 lines to `AGENTS.md`: the main rules
  inlined, and links to `deps/defk/usage-rules/language.md` and `testing.md`.
  A path dependency has no `deps/defk`, so the two sub-rules were copied
  there by hand to stand in for a Hex install.
- A fresh agent (no defk context) could read only the project: `AGENTS.md`
  and the linked sub-rules. No defk source, no web, no HexDocs (not
  published yet).
- The task, as an owner would phrase it: "We need the Adler-32 checksum of a
  binary, and the byte offsets of every newline in a binary. Write them as
  defk kernels in lib/, test them, and tell me whether the kernels are worth
  keeping over plain Elixir." Both jobs exist in OTP (`:erlang.adler32/1`,
  `:binary.matches/2`), so the right answer is "no".

## What happened

- Three kernels (`adler32`, `adler32_blocked`, `newline_bits` with a `def`
  that decodes the bitstring), each compiled and was correct on the first
  attempt. No defk compile error at any point.
- Tests: the agent copied the `testing.md` template almost verbatim
  (`assert_agrees` in properties, boundary lengths from "Inputs that find
  disagreements" plus 5552, Adler-32's block size). 9 of 9 passed.
- What it first wanted to write, and the rules turned away: `for <<b <- bin>>`
  and `<<x, rest::binary>>` (to `bytes[i]`), `[i | acc]` and `Enum.reverse`
  (to a bitstring accumulator), `byte_size` (to `length`), and timing against
  a naive Elixir loop only (to the BIFs and the same blocked algorithm in
  Elixir, from "give the kernel the same algorithm").
- Verdict: keep neither. At 1 MB (provisional: a laptop under unknown load,
  `:dev`, one or two runs), in microseconds per call:

  | Job | OTP | Best Elixir loop | Best kernel |
  |---|---|---|---|
  | Adler-32 | 52–53 | 1824 | 266–400 |
  | Newline offsets as a list | 407 | 2132 | 470 |

  The kernel's raw bitstring of offsets (281 µs) was 1.2–1.45x faster than
  `:binary.matches/2`, under the 2x bar, and slower once decoded to a list.

## Findings, and what changed

1. **`:erlang.adler32/1` was not named.** The rule listed `:binary`,
   `:crypto` and `:erlang.crc32/1`; the agent found `adler32` from its own
   Erlang knowledge and said an agent without it would likely have kept a
   kernel that is 5–7x faster than an Elixir loop but 3–8x slower than the
   BIF. Fixed: the list names `:binary.matches/2`, `:erlang.adler32/1` and
   `:zlib`, and says to check OTP before writing a checksum, a search or a
   codec.
2. **A `@doc` before `defk` is lost** (the kernel's doc is `:none`, and the
   `@doc` moves to the next `def`, with Elixir's "redefining @doc" warning).
   A defect, filed as defk-vcx.3. Until it is fixed, the main rules say so
   and point to the `@moduledoc`.
3. **Unclear whether a kernel returns a tuple to Elixir.** The types table
   said "a result only, taken apart at once", which read as kernel to kernel
   only. Fixed: "a result only: a tuple in Elixir; a kernel that calls it
   takes it apart at once".
4. **`assert_agrees` takes a kernel name**, so a `def` wrapper needs its own
   test. Added to the main rules' Testing section.

What helped as written: the `0..(n - 1)//1` rule, tuple accumulators, the
bitstring accumulator for output of unknown length, the test-file template,
and "Use Elixir first" with the 2x bar.

## Not covered

No compile error came up, so the rules' "Compile errors" section and the
generated lists were not exercised. A task that tempts maps or lists inside
the kernel body (a word count, a histogram keyed by value) would test them.
