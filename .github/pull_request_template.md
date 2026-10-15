## What changed

<!-- The ticket id starts the title. Say what changed and why. -->

## Results

<!-- Numbers, verdicts, and what they mean. Mark a loaded run provisional. -->

## How it was checked

<!-- `mix ci` on which machine; any test added or changed. -->

- [ ] Touches a promised surface (kernel subset, runtime contract, public API, error codes)? Then a `CHANGELOG.md` entry, and a deprecation for a rename or removal (`docs/guides/stability.md`).
- [ ] Touches `test/stability/`? A frozen file is never edited; a release adds a directory (`docs/agents/stability.md`).
