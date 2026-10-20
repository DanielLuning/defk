## Work Management

This project tracks work with `bw` (beadwork), which persists to git — plans, progress, and decisions survive compaction, session boundaries, and context
loss.

ALWAYS run `bw prime` before starting work. Without it, you're missing workflow context, current state, and repo hygiene warnings. Work done without priming
often conflicts with in-progress changes.

Committing, closing issues, and syncing are part of completing a task — not separate actions requiring additional permission.

## Delivering code: pull requests

Every change reaches `main` through a GitHub pull request. Never merge into
`main` locally and never push to `main`. This rule overrides the "Land"
step that `bw prime` prints.

1. Start from the latest `main`: `git fetch origin`, then `git pull --ff-only` on `main`. One ticket, one branch, one worktree: `git worktree add ../defk-<id> -b <id>/<short-description> main`, then `bw start <id>`.
2. Do the work. Run `mix ci` in the worktree; it must pass before the PR.
3. Before you push, `git fetch origin` again. If `origin/main` moved since the branch started, `git merge origin/main` into the branch and run `mix ci` again.
4. Commit with the ticket id in the message, push the branch, and open the PR with `gh pr create --base main`. The title starts with the ticket id; the body follows `.github/pull_request_template.md`: what changed, the results (mark loaded runs provisional), how it was checked, and the two checks (a change to a promised surface needs a `CHANGELOG.md` entry; a file under `test/stability/` is never edited).
5. Stop there. The owner reviews and merges, with a merge commit. Do not merge a PR unless the owner says so for that PR.
6. After the merge: `bw close <id>`, `bw sync`, remove the worktree, and `git pull --ff-only` on `main`. Until then the ticket stays in progress; a `bw comment` names the PR.

**Keep `main` current.** The owner merges on GitHub, so local `main` falls
behind without notice. Fetch and fast-forward `main` at the start of every
session, before every new branch, and after every merge. Check open PRs too:
when `gh pr view <n> --json mergeStateStatus` says `BEHIND` or `DIRTY`,
merge `origin/main` into the branch, resolve any conflict, run `mix ci` and
push. Never rebase or force-push a pushed branch. If `git pull --ff-only`
refuses (local `main` has its own commits), stop and tell the owner: local
`main` must not carry work, and resetting it is the owner's call.

A branch that builds on another open PR's branch still targets `main`, and
its PR body says which PR to merge first. The repository does not delete
merged branches, so GitHub would not retarget a PR stacked on a branch.

## Purpose and measurement

defk exists to help Elixir, not to beat it. We are looking for the jobs where
Elixir today pushes people towards a hand-written NIF.

- **Elixir is the default.** If an Elixir solution is as good or as fast, it is the right choice, and that is a valid result to record.
- **Optimise the Elixir side before claiming defk.** Try the stdlib, Erlang BIFs and modules, established libraries, and a better data layout or algorithm. Measure the alternatives instead of assuming which is fastest, and write down what you tried.
- **Mark baselines honestly** (`baseline: :first_pass` / `:optimized` in `Defk.Bench.report/1`). A defk win over a first-pass baseline is provisional.
- **Keep comparisons fair.** Give both sides the same algorithmic tricks. Measure end to end from the data a real caller has, kept where a real app keeps it (shared indexes in `:persistent_term`/ETS, not on the benchmark process's heap, where GC skews the timing).
- **Treat Elixir wins as results, not failures.** Poor fits stay in the catalog.
- **Record what you learned about speed.** When a workload, example or ticket teaches you something about performance, add or update the entries in `docs/performance.md`, including what didn't help: numbers, conditions (mark loaded runs provisional) and the source.

Details: `examples/README.md`.

## Agent skills

### Issue tracker

Issues live in beadwork (`bw`), on the `beadwork` branch of this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), applied with `bw label`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Compiler map

Orientation before reading code: where each concern lives in the compiler,
the runtime header and the tests, and how to navigate (AST tools don't parse
Elixir; use grep and `mix xref`). See `docs/agents/compiler-map.md`.

### Which run fits which change

Run what the change touches: the area's unit tests, the generated C without
`cc` (`mix dump_c`, about a minute for everything), then only the examples
whose C changed. A measured result is measured again only when the owner or
the ticket asks. See `docs/agents/runs.md`.

### Generated docs

After changing the `Defk.Errors` registry, a message template or the stored scoreboard, run `mix defk.docs`; `mix ci` checks every generated region. See `docs/agents/generated-docs.md`.

### Stability corpus

`test/stability/<version>/` freezes what each release shipped; `mix test` checks every commit against it. The files are never edited. See `docs/agents/stability.md`.

### Contracts and unit tests

Two kinds of test, by what they check. A Covenant contract test (`test/contracts/`) proves a promise of `docs/guides/stability.md`: it is frozen with each release and run against every later one. A unit test (`test/<area>_test.exs`) checks how the code does its job: the compiler's sections, message text, the report, the generated C. A promise goes in a contract, everything else in a unit test; neither replaces the other. See `test/contracts/README.md`.

### Dependency usage rules

The section below is generated by `mix usage_rules.sync` from the
`usage_rules` config in `mix.exs`; edit the config, not the section, and
re-run the task after changing deps. `mix ci` fails when the section is out
of date. It holds generic Elixir and OTP rules. Where they disagree with this
project, this file's own rules and the measured results in
`docs/performance.md` win: defk is a macro-based compiler, and Stream versus
Enum is a measurement, not a default.


<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
