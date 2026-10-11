# defk cold test 3: Shannon entropy per window, from the built HexDocs only

Ticket defk-djy.9, run 2026-10-11 by a fresh Sonnet session with no prior
context. Unlike the first two cold tests (count-min.md, leb128-topk.md, which
read README.md and docs/language.md in the repo), the session could read only
the built HexDocs (`mix docs` output: the HTML, the Markdown copies listed by
llms.txt, or the epub), never the repo's source; defk was a path dependency
of a new Mix project. Tasks: install defk, write and test a kernel, measure
it, read compile errors and follow their links, answer scope questions from
the scope page, and decide defk or Elixir for two jobs. The log below is the
session's own; each confusing point ends with its resolution (added after the
run, not part of the session).

Job: Shannon entropy (bits/byte) of each consecutive 4096-byte window of a large binary, returned as packed f64s; last partial window ignored.

Sources read, in order: llms.txt (TOC) -> readme.md (partly; the middle was truncated by my own output limit, I read the head, the Language list and the Roadmap) -> getting-started.md -> testing.md -> measuring.md -> cheatsheet.md -> scope.md -> deploying.md -> language.md sections 6 (Arrays), 4 (Float arithmetic, Builtins), 7 (`for`, early exit, array accumulators), 11 (Compile errors) -> compile-errors.md (head, unknown-function, for-collect, unsupported-call) -> performance.md (TOC, 2.1, 3.3, 5.x, 1.5, 4.8) -> Defk.Bench.md, Defk.Errors.md. Not read: runtime-contract.md, Defk.md, Defk.Test.md, Defk.ElixirMode.md, Defk.Report.md, Defk.Bits.md, most of language.md and performance.md.

Files next to this log: attempt1.ex.txt (did not compile), attempt2.ex.txt (compiles), entropy_test.exs.txt, entropy_yield_test.exs.txt, bench_entropy.exs.txt (first-pass and optimised Elixir + timing), bench_report.exs.txt (Defk.Bench.report), probes_p.exs.txt (extra deliberate error probes). Project: app/.

## Task 1: Install (done)

- Lookup: "how to add the dependency" -> getting-started.md "Add defk to a project" (also readme.md). Clear: `{:defk, path: "../defk"}` in deps, then `mix deps.get`. I used the absolute path I was given. Elixir 1.20.2/OTP 29, cc present.
- `mix deps.get` then `mix compile`: first compile ~1.9 s total (defk 20 files + app), no errors, no warnings. 1 attempt.
- Unclear/wrong in install:
  - getting-started.md links to `cheatsheet.cheatmd` (and Defk.md the same), but DOCS has `cheatsheet.md`/`.html`; link is dead in my copy.
  - Links like `../scope.md`, `../language.md#3-types`, `docs/guides/getting-started.md` (readme) point at source-tree layout, not at the flat DOCS layout. Resolvable only by guessing the basename.
  - readme.md says "Needs Elixir >= 1.20" and a C compiler; getting-started says the same. Fine. Nothing says which `mix` env/`only:` to use for the dep (non-test is implied).
  - The `stream_data` line (`only: :test`) I copied; it was fine.
  - No mention that the first `mix test` also compiles defk in the test env (extra ~3 s). Minor.

## Task 2: Kernel (done)

### Attempt 1 (natural first draft; attempt1.ex.txt) - did not compile
Written as I would in Elixir: `byte_size`, `for ... do` collecting a list, a `%{}` counter map via `Map.update`, `|> Map.values() |> Enum.reduce`, `:math.log2`. I had skimmed the Cheatsheet/readme before writing, so I knew about `len`, `alloc`, `for ... reduce:`, yet still wrote it this way (honest "natural" draft).

### Attempt 2 (attempt2.ex.txt) - compiled first time
Rewritten from the docs: `len(data)`, `alloc(f64, n)` for the output, one `alloc(i64, 256)` histogram reused per window and re-zeroed with a loop (because language.md "Allocating" says an `alloc` in a loop is not freed until the kernel returns), `//1` ranges, `for c <- counts, c > 0, reduce: 0.0`, and `log(p) / log(2.0)` because there is no `log2`. The language.md `histogram` example in "Writing" was almost exactly the core of the job; that page was the one that unlocked it. Whole task from reading to a compiling kernel: 2 attempts, ~25 min of reading time, no help beyond docs and compiler.

Note: `log(p)/log(2.0)` differs from `:math.log2/1` by ~9e-16 on real data (max abs diff measured). Docs promise bit-exactness with Elixir, but only for the same expression; nothing says "there is no log2, divide by log(2) and expect last-ulp differences from :math.log2".

### Testing (as the testing guide recommends)
- entropy_test.exs.txt: unit tests (constant window = 0.0, uniform window ~ 8.0, partial window ignored, empty binary), `assert_agrees/3` on edge inputs (empty, 4095 bytes, random 3 windows + 5) and a StreamData property over binaries up to 9000 bytes (30 runs), plus entropy_yield_test.exs.txt with `__defk_force_yields__(true)` and the `__defk_stats__().yields` check. All 8 pass (`mix test`, 0.5 s). First time, no failures.
- Caveat for the property: the guide suggests lengths around 2048 and non-multiples; for my window of 4096 the interesting lengths are 4095/4096/4097/8192; I picked them myself.
- `Defk.Report.print(App.Entropy)` worked; margin notes showed every bounds check removed (`data[w * 4096 + i]: no bounds check`, `counts[b]: no bounds check`) and a safepoint per outer iteration. Understandable and useful.

### Measuring (measuring.md workflow)
- Baselines in bench_entropy.exs.txt: first pass (`bin_to_list |> Enum.frequencies`, 9.0 MB/s, 4 MB in 465 ms) and an optimised version (`:counters`, 8 bytes per binary-pattern step as per performance.md 2.2/2.3, result appended to a binary as per 2.1, window counters reset as they are read): 64 MB in 485 ms = 138 MB/s.
- Kernel on the same 64 MB (half random, half repeating): 29.8 ms = 2251 MB/s => 16x over the optimised Elixir, ~250x over first pass.
- `Defk.Bench.report/1` (32 MB random, `baseline: :optimized`): elixir 273 ms, defk 18.6 ms, 14.71x, correct true, verdict `good`. I had to make `check:` tolerant (1e-9), since my Elixir used `:math.log2`; Defk.Bench's doc says it is "Unstable" and points back to Measuring.
- Both sides in 1 process vs 1 call; performance.md 1.5 says to also compare split over all schedulers. I did not (would likely drop the ratio); noted.
- I took the Elixir baseline further than a casual reader would; the docs' "try BIFs first" lookup (`:binary`, `:crypto`, ...) found no BIF for a byte histogram, performance.md has no byte-histogram/entropy entry. "Looked for: Elixir-side histogram technique -> found 2.12 (dense counters, `:atomics`) only by searching `counters`."

## Task 3: Compile errors (verbatim)

### Error 1 (attempt 1): unknown-function
```
error: byte_size/1 is not in the kernel subset
  │
7 │    n = div(byte_size(data), @window)
  │            ^^^^^^^^^^^^^^^
  │
  └─ lib/entropy.ex:7:13: App.Entropy.entropy/1

why: the length of a kernel array is len/1
hint: use len/1:

    len(data)
(defk unknown-function: /path/to/defk/docs/compile-errors.md#unknown-function)
```
Rating: HELPED (exact rewrite). Small oddity: heading says "is not in the kernel subset", which the docs define as "stays out by design", yet the code is `unknown-function`, kind "a mistake to fix". The two phrases collide with the "not in the kernel subset" vs "not supported yet" rule in getting-started.md.
Footer: points at an absolute local path `/path/to/defk/docs/compile-errors.md#unknown-function`, which is inside the library's source tree (forbidden for me to open, and I did not). Could not open it "within DOCS". The equivalent in DOCS is compile-errors.md `### unknown-function`: exists, lists the builtins and shows rejected/rewrite, but its example is about calling an undefined kernel `double(x)`, not about `byte_size`; the `byte_size`->`len` mapping appears only in language.md Builtins ("`length/1`, `byte_size/1` and `tuple_size/1` are unknown-function with the hint to use `len/1`") and cheatsheet "Common rewrites".

### Error 2 (attempt 1): for-collect
```
error: a for without reduce: used as a value is not in the kernel subset
  │
9 │    for w <- 0..(n - 1) do
  │    ^^^^^^^^^^^^^^^^^^^^^^
  │
  └─ lib/entropy.ex:9:5: App.Entropy.entropy/1

why: a for without reduce: builds a list in Elixir (into: another collection), and a kernel has no lists
hint: allocate the output array and write it in the loop
(defk for-collect: /path/to/defk/docs/compile-errors.md#for-collect)
```
Rating: PARTLY (right direction; the hint has no rewrite, unlike error 1; I needed the docs page for the `out = alloc(f64, len(a)); out[i] = ...` shape). Footer: same absolute-path problem. DOCS equivalent compile-errors.md `### for-collect`: yes, explains it fully with a working rewrite (alloc + write + return out). Also `mix run -e 'Defk.Errors.explain!("for-collect")'` printed the entry offline and worked as documented.
Not reported: the body of that `for` had a `%{}` map, `Map.update`, `|>`, `Enum.reduce`, `:math.log2`. Language.md says errors "caused by an earlier one" are suppressed; the compiler stopped at 2 errors, so I would have had to recompile again to meet map/pipe/log2 errors (one more round trip). That is consistent with the docs, just worth knowing.

### Probes (extra, deliberate, in probes_p.exs.txt, via Code.compile_string, so no source frame shown)
- P1 `:math.log2(p)` -> `unsupported-call`; why: "a kernel's math builtins are sqrt, exp, log, sin, cos and pow"; hint: "compute it from those, or in Elixir". Rating PARTLY (no `log(x)/log(2.0)` rewrite and no mention that it is not bit-equal to log2). DOCS entry compile-errors.md#unsupported-call exists but its example is `Enum.map`; does not mention :math.log2 anywhere (grep log2 in all DOCS: no hits).
- P2 `d |> len()` -> `pipe`; hint gives `len(d)`. HELPED.
- P3 `xs :: list(f64)` -> `unknown-type`; hint lists the types. PARTLY: does not say "a list of floats is passed as a packed [f64] binary".
- P4 `%{}` -> `unsupported-map`; "pass the values as separate arguments, or pack them into an array". PARTLY: for per-key counters the useful hint is a dense `alloc(i64, n)` indexed by key; not given.
- P5 `:: String.t()` -> `unknown-type`; same type list. PARTLY (does not say "return [u8]").
- P6 `String.valid?(d)` -> `unsupported-call`; hint "compute it in Elixir before or after the call". HELPED (consistent with scope.md).
- P7 `if flag, do: out, else: d` -> `array-in-branch` ("not supported yet"); hint rewrites to `out[0], else: d[0]`, which changes the kernel's meaning (returns a number, not an array). PARTLY/misleading for my case; the hint is generic. Scope page names the ticket defk-gqk.
All probe footers also pointed at the local absolute path. DOCS has all those headings in compile-errors.md.

Totals: 2 real compile errors (1 helped, 1 partly) + 7 probe errors (2 helped, 5 partly). Compile attempts: 2 (second compiled clean).

Note on footer vs docs: language.md section 11 and Defk.Errors say the footer is a GitHub URL (`https://github.com/.../docs/compile-errors.md#code`) or a path relative to cwd "when it lies below it". With a path dep outside the project the footer is an absolute path into the library checkout. A newcomer who only has HexDocs has no way to open it; Defk.Errors.md explains the logic, but a hex-docs-only reader would not know to look at compile-errors.html in the same site. Also the language.md example footer says GitHub URL, which differs from what I saw.

## Task 4: Scope page answers

(a) Per-key map of counters across calls: NO. Two reasons.
- Maps: "Won't be: by design. **Lists, maps, atoms and other BEAM terms** (`unsupported-list`, `unsupported-map`, `unsupported-atom`). A kernel works on numbers, booleans, tuples of them and packed arrays, and never touches the BEAM heap while it computes". "Won't be."
- Across calls: "Under exploration, with no promise either way: kernel-owned state that lives between calls and is changed in place (defk-sve). Today state travels as values, binaries in and new binaries out." So persistent state is "not yet" in the weakest sense (explore, no promise, defk-sve). Workaround from docs: pass a packed counter array `[i64]` in and return the updated array (language.md array accumulators `tally`, `update_many` examples), for dense integer keys.

(b) Take a list of floats directly: NO. "Won't be": same bullet ("Lists ... `unsupported-list`: Lists are not in the kernel subset; a kernel takes packed arrays"). Scope "Elixir is the right choice when the data arrives as a list ... packing it costs more than Elixir's whole loop". Pass a packed `[f64]` binary built with `for x <- xs, into: <<>>, do: <<x::float-64-native>>`.

(c) Return a string: "Won't be" as a string value: "**Strings as values** (`unsupported-string`). A kernel sees bytes, not text: a string literal is a read-only `[u8]`, and there are no UTF-8 or grapheme operations and no building a string at run time. Do text work in Elixir before or after the call." But a `[u8]` result reaches Elixir as a binary (cheatsheet: "`[u8]`: binary of packed native-endian elements") which is a string if the bytes are valid; the page does not say that plainly. So: a text-looking binary can be returned as `[u8]`; "a string" as a type/operation will not be.

## Task 5: Elixir or defk?

(a) WebSocket text frames, a few hundred bytes, valid UTF-8: ELIXIR.
- scope.md: "Elixir is the right choice when ... each call does little work, such as ... small inputs: the call costs more than the work" and "the BEAM already has a native answer: `:binary.match/2`, `:crypto`, `String.valid?/1`, `:erlang.crc32/1`".
- performance.md 3.3: "`String.valid?(bin)  # fine for a WebSocket frame (what Bandit uses)`", and `:unicode.characters_to_binary/1` for big inputs; "a scalar kernel cannot beat the BIF by much". 5.4: "`utf8_valid`: at 1 KB the kernel's fixed cost ... loses, 0.56-0.68x at 64 KB." And scope: no UTF-8 operations in kernels.

(b) Moving mean and stddev over 1 million sensor readings: DEFK, conditionally.
- readme.md "Where defk looks like it helps": "rolling sensor statistics"; scope "loops over numbers ... rolling statistics"; performance.md 1.5: "`rolling_stats`: one call ~34x (65 vs 1.9 ms)"; 2.1: the optimised Elixir binary-accumulator version is ~53-68 ms for 1M samples; 4.8: one call needs no chunking.
- Conditions: the 1M readings should already be packed (a binary/`:persistent_term`), else "packing a list often costs more than the kernel" (5.3; "data that arrives as lists (defk ~3x slower)"). Provisional numbers ("measured under load", defk-sgw.4). Also it must be measured against the optimised Elixir, which my reading of measuring.md says to do first. If it is called once on a list, use Elixir.
- Note on ambiguity: "moving mean and stddev" is rolling_stats; a single mean/stddev over 1M floats is a plain reduction; the docs examples cover the rolling case only.

## Task 6: Deploy (done, from docs; also tried `mix release`)

From deploying.md:
- Build machine needs a C compiler (`cc` or `CC`; Debian `build-essential`/`gcc libc6-dev`, Alpine `build-base`, macOS `xcode-select --install`); runtime machine needs none (libs link only libc). Build and run on same CPU arch and libc (arm64/glibc will not load on x86_64 or Alpine/musl). Cross-compiling and relups untried. `_build/<env>/defk/` is cached by source hash, so a CI cache of `_build` helps.
- BIG caveat (warning box at top): "`mix release` does not copy the kernels' native libraries, so a release moved to another machine or path fails to start" (`on_load_function_failed`, `cannot open shared object file`); ticket defk-n8f. Workaround: copy `_build/<env>/defk` to the same absolute path in the runtime image (multi-stage Debian example `examples/release_debian` - link left the docs to GitHub, not followed). "A workaround, not a contract: the release is not relocatable."
- No Elixir fallback in prod: if the library does not load, the module does not load; `config :defk, mode: :elixir` is refused outside dev/test. `Mod.__defk_lib__/0` shows the loaded path.
- I verified: `mix release` built; copying the release to /tmp ran and called the kernel (still reading the .so from my project's `_build`), and with `_build/dev/defk` moved away the copied release failed to load the module - matching the docs. (I ran `mix release` in dev env; the docs say `_build/<env>`.)
- Elsewhere in scope.md: "Kernel .so files shipped inside mix release (defk-n8f)" is under "Not yet: planned".
- Also: the deploying.md text "the release is not relocatable" vs getting-started's "The machine that only runs your code needs no compiler" - both true but the second reads as if deploy is easy; you only find the caveat in deploying.md.

## Confusing points

1. Footer link of every compile error is a local absolute path into the library checkout (when defk is a path dep), not openable from HexDocs, and it differs from the GitHub URL shown in language.md section 11 and the sample in getting-started.md. Where: any compile error; Defk.Errors.md; language.md "11. Compile errors". Would help: always print the plain code plus `Defk.Errors.explain!("<code>")` in the message, or say in getting-started that the footer may be a file path and that the same entry is compile-errors.md#<code> on this site.

    Resolution: fixed: the footer is now the URL in any project that depends on defk and a path only inside the defk repository (`lib/defk/errors.ex`, `Defk.Errors.docs/2`; moduledoc, docs/language.md section 11 and the getting-started sample updated, which also say the same entry is on this site's Compile errors page).

2. Dead intra-doc links: `cheatsheet.cheatmd` (getting-started "Your first kernel", "Next"; Defk.md), `docs/guides/getting-started.md`/`docs/language.md` (readme.md), `../README.md#...` (performance.md), `../scope.md` style paths. Many links go to GitHub for things I needed (examples/_template.exs, fast-path-report.md, examples/release_debian/README.md, examples/README.md "Measuring correctly"). Where: getting-started.md, readme.md, measuring.md, performance.md. Would help: links valid within the published docs; inline the template and the release Dockerfile.

    Resolution: fixed: `mix docs` now rewrites the links in ex_doc's Markdown copies (doc/*.md, which ex_doc writes as the source has them, while the HTML is rewritten) to the flat page names, and fails on any relative link in doc/*.md or doc/*.html that leads nowhere (`mix.exs`, `docs` alias); test/docs_checks_test.exs checks that every relative link in an extra names a page of the built docs. The measuring template and the release Dockerfile steps are now inline (points 9, 12). Links to repo-only files (examples, the fast-path report) stay GitHub URLs.

3. There is no `log2`, and `:math.log2` is rejected with a hint that does not give the `log(x) / log(2.0)` rewrite; results then differ from `:math.log2` by about 1 ulp, which the "bit for bit Elixir" promise does not cover. Where: compile error unsupported-call (and its entry); language.md Builtins (lists log, says other :math is rejected). Would help: a "math functions you may expect" row in the Cheatsheet/Builtins table listing log2, log10, tan, floor, ceil... as missing with rewrites.

    Resolution: fixed in the docs and the message: `:math.log2/1` and `:math.log10/1` now get the rewrite `log(x) / log(2.0)` with the last-bit caveat (`lib/defk/errors.ex`), and docs/language.md Builtins, the cheatsheet and getting-started say so; a bit-exact builtin is ticket defk-ngj. (Note: builtin added in defk-ngj: `log2/1`, `log10/1` and `:math.log2/1`, `:math.log10/1` now compile and match `:math` bit for bit; the rewrite above is gone.)

4. First error "not in the kernel subset" for `byte_size` contradicts the doc's definition ("not in the kernel subset" = stays out by design) while the code is a "mistake to fix". Where: getting-started "Reading a compile error"; compile-errors.md `unknown-function`. Would help: distinct wording ("unknown function") for names that have a builtin spelling.

    Resolution: fixed: `byte_size/1`, `length/1`, `tuple_size/1` and `elem/2` now say "is not a kernel builtin" (`lib/defk/errors.ex`); getting-started and language.md section 11 say that wordings other than "not in the kernel subset" and "not supported yet" are mistakes with a fix in the hint.

5. Compile errors stop at the first group: map/pipe/log2 inside the `for` that failed were reported only after I rewrote the loop. Language.md says dependents are suppressed, but a newcomer expects all errors in one run. Where: language.md 11. Would help: say "fix and recompile; later errors may appear".

    Resolution: documented (getting-started "Reading a compile error", language.md section 11: the compiler does not look inside a rejected construct; expect a few rounds); reporting them in one run is ticket defk-uw9.

6. Hints for type/data-shape errors are generic: `unknown-type` for `list(f64)` / `String.t()`, `unsupported-map`, and `array-in-branch` (whose rewrite changes meaning) do not say what to do with a list, a string result or per-key counters. Where: those compile-error entries; scope.md. Would help: hints "pass packed [f64]", "return [u8]", "use alloc(i64, n) indexed by key", plus a small "how to port a counter-map job" recipe.

    Resolution: fixed where small: `unknown-type` hints for `list(...)` (pass a packed array) and `String.t()` (`[u8]`), `unsupported-map` hint for counters (an array indexed by the key), and `array-in-branch` no longer guesses the `a[0]`/`b[0]` rewrite (it changed meaning when the array is the result); its hint says what to do instead (`lib/defk/compiler.ex`, `lib/defk/errors.ex`, docs/compile-errors.md regenerated, tests in compile_errors_test.exs). Rows for these in language.md "Unsupported, write this instead" and the cheatsheet. A rewrite for `for-collect` is ticket defk-djy.13.

7. Allocation inside loops is not freed until the kernel returns ("alloc inside a loop allocates on every iteration"), which is easy to miss and decisive for per-window scratch buffers (a 1 GB input would have allocated 512 MB). Found only deep in language.md "Allocating". Where: language.md 6. Would help: a note in getting-started "Things that trip people up" and in the compile/runtime of `alloc` in loop (a warning in the fast-path report).

    Resolution: fixed: getting-started "Things that trip people up" has the alloc-in-a-loop note with a checked example (scratch array before the loop, cleared each pass); a fast-path report note is ticket defk-djy.15.

8. No byte-histogram/counting guidance on the Elixir side: building a fair optimised Elixir baseline (the measuring.md requirement) meant guessing `:counters` and 8-bytes-per-step patterns; performance.md 2.12 "dense counters" only turned up by searching. Where: measuring.md "1. Make the Elixir version fast first"; performance.md section 2. Would help: an index by job type ("counting bytes", "histograms") pointing to the entry.

    Resolution: measuring.md now points at performance.md section 2 ("2.12 Dense counters") for counting jobs; there is no measured byte-histogram entry in the repo, so a catalog example with optimised Elixir baselines and a performance.md entry is ticket defk-9p6.28.

9. The docs say `Defk.Bench.report/1` is the thing "the project's examples use" but also "Unstable... To measure your own kernel follow Measuring; any benchmarking tool works." and the measuring script template shows `Mix.install` + `path: "../defk"` plus a note elsewhere to remove it inside a project. Unclear which to use in my own app; the `check:` option needs exact equality semantics I had to relax. Where: measuring.md "4. A measuring script"; Defk.Bench.md. Would help: a copy-paste project-ready version (no Mix.install) and what `check` should compare.

    Resolution: fixed in docs/guides/measuring.md section 4: any tool works; `Defk.Bench` is unstable in its API, not its numbers; how to run the script inside a Mix project (no `Mix.install`, `mix run bench/x.exs` in `:dev`); what `check:` compares and when to use a tolerance.

10. The recommendation "also compare over all schedulers" (measuring.md section 3; performance.md 1.5) is not turned into a concrete recipe; I reported 1 process vs 1 call (16x), which the docs themselves say overstates. Where: measuring.md 3. Would help: a short Task.async_stream chunking snippet and the sizes to use.

    Resolution: fixed: measuring.md "Comparing over all schedulers", a checked script (both sides split into one chunk per scheduler with `binary_part/3`, started at once, agreeing exactly), linking performance.md section 4.

11. Testing guide has no guidance on picking agreement inputs for my kernel's own structure (window size 4096 boundaries) and the example property uses `list_of(float())`, not binary generators; I had to infer `binary/1`. Where: testing.md "Choosing inputs". Would help: a `[u8]` property example.

    Resolution: fixed: testing.md "Choosing inputs" adds the kernel's own boundaries (k - 1, k, k + 1, 2k) and a `[u8]` agreement test with `binary/1` and boundary lengths, run by the docs runner.

12. Deploy: getting-started says "The machine that only runs your code needs no compiler" prominently while the release not being relocatable is only in deploying.md (and a warning box). Release instructions are a workaround requiring the same absolute path; the real recipe is in an off-docs GitHub README. Where: getting-started "What you need"; deploying.md "Releases". Would help: put the Dockerfile inline and a one-line warning in getting-started.

    Resolution: fixed: getting-started "What you need" says a `mix release` does not carry the kernels yet and links Deploying; deploying.md "Releases" has the workaround steps, a sketch multi-stage Dockerfile and the `__defk_lib__/0` check inline (the release fix itself is defk-n8f, commented).

13. Scope page "Not yet" mixes "planned" with "under exploration, no promise" (defk-sve state between calls), so Task 4(a)'s answer needs a careful read; "a string" is "won't be" yet a `[u8]` result is a binary that can hold text, and this is not said. Where: scope.md "Under exploration", "Strings as values". Would help: one explicit line "to return text, return [u8]; to keep state, pass it in and out as binaries".

    Resolution: fixed in docs/scope.md: "Under exploration: no promise either way" is its own section (state between calls, with the pass-in/pass-out workaround), and "Strings as values" says a kernel returns text as a `[u8]` binary.

14. Case 5(b): "moving mean and stddev" has an obvious defk example but the docs have no inline kernel for it (only the number, linking to examples/rolling_stats.exs on GitHub), so the decision rests on external numbers marked provisional. Where: readme.md "Examples", performance.md 2.1/1.5. Would help: inline the kernel or at least its signature and input packing.

    Resolution: fixed in docs/scope.md: the "defk can help" list now says its numbers are mostly provisional (loaded machine, defk-sgw.4) and to measure your own job (README already said so). No inline rolling-stats kernel added.

15. readme.md is mostly a repo-internal readme (file table pointing at `lib/...`, roadmap with ticket ids, `bw show`) and is the first page listed; it is ~29 KB, so I mis-skimmed the middle. Where: readme.md. Would help: make Getting started the landing page, move the file table/roadmap out of the user docs.

    Resolution: ticket defk-djy.14 (ready-for-human): the options for the HexDocs main page, with a recommendation; the main page is unchanged here.
