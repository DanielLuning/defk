---
modules: [Defk.Errors]
---

## Purpose

The compile error codes are one of the four surfaces of the stability promise
(`docs/guides/stability.md`, "The compile error codes"). A rejection names
its code; the registry (`Defk.Errors.entries/0`) holds every code, active and
retired; `test/stability/codes.txt` lists every code a release shipped; and
`test/stability/<version>/rejections/` holds every rejected example a release
shipped. This component promises that a code keeps its name and its
construct, is never reused, and stays in the catalogue when it is retired.

Not promised, and so not obligations here: the text of a compile error (its
sentence, why, hint and rewrite), which code comes first when a kernel has
several, and the keys of a registry entry other than `code` and `kind`.

### defk.error_codes.I1 — An active code rejects its own example, with that code alone
- **scope:** `Defk.Errors.entries/0`, every active code but those the build environment raises (`no-c-compiler`)
- **must:** the code has an example and a rewrite; compiling the example in a module that uses `Defk` fails with a compile error whose only code is this one, and compiling the rewrite succeeds and defines a kernel
- **why:** the catalogue shows each code's example and rewrite; a code whose example no longer triggers it, or whose rewrite no longer compiles, documents a rejection the compiler does not make
- **kind:** functional
- **status:** active

### defk.error_codes.I2 — A released code stays in the registry
- **scope:** `test/stability/codes.txt`, `Defk.Errors.entries/0`
- **must:** every code the ledger lists is a code of `Defk.Errors.entries/0`, active or retired, and the ledger lists each code once
- **why:** a code keeps its name within a major version; removing one breaks every tool and page that names it
- **kind:** persisted-format
- **record:** retire-never-remove
- **status:** active

### defk.error_codes.I3 — A code is never reused
- **scope:** `Defk.Errors.entries/0`, the codes the compiler's source names
- **must:** the registry lists each code once, with kind `:error`, `:subset`, `:planned` or `:retired`; the compiler names every active code and no retired one; the ledger's `retired <version>` marks and the registry's retired codes agree in both directions
- **why:** a code names one construct for as long as the major version lasts; raising a retired code again would give an old name a new meaning
- **kind:** functional
- **record:** retire-never-remove
- **status:** active

### defk.error_codes.I4 — A retired code stays in the catalogue
- **scope:** `Defk.Errors.entries/0`, `Defk.Errors.explain!/1`, every retired code
- **must:** a retired code stays in `entries/0` with the version that retired it (`x.y.z`) and no example; `explain!/1` prints it as retired, with that version
- **why:** a reader who meets an old code (in a log, a ticket, an old answer) still finds what it meant and why it went
- **kind:** functional
- **record:** retire-never-remove
- **status:** active

### defk.error_codes.I5 — A frozen rejection keeps its code
- **scope:** every file under `test/stability/<version>/rejections/`
- **must:** compiling the file's example either fails with the recorded code among its codes, or succeeds because the construct became valid: then the recorded code is retired in the registry, or the file is listed under `newly_supported` in `test/stability/exceptions.exs` with words the `CHANGELOG.md` contains
- **why:** a construct rejected with a code is rejected with the same code in every later release of the major version; a construct that became valid is an addition, recorded where a reader looks for it
- **kind:** functional
- **record:** frozen-rejections-are-data
- **status:** active

### defk.error_codes.I6 — explain!/1 refuses an unknown code
- **scope:** `Defk.Errors.explain!/1`
- **must:** raise `ArgumentError` for a code the registry does not hold, and print the entry, headed by its code, for one it holds
- **why:** the footer of every compile error names `explain!/1`; a typo must fail loudly, not print nothing
- **kind:** functional
- **status:** active
