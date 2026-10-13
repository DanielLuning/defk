# Issue tracker: beadwork (`bw`)

Issues and PRDs for this repo live in beadwork. It stores them in git on the
`beadwork` branch; IDs look like `defk-XYZ` (children of an epic: `defk-XYZ.N`).
Run `bw prime` first for the current state. `bw <command> --help` has the details.

## Zero-bug policy

Open `[BUG]` tickets come before new feature work (maintainer, 2026-10-13):
when picking from `bw ready`, take actionable bugs first, and don't start a
feature ticket while one is open. Bugs that are blocked, or labelled
`ready-for-human` (e.g. a quiet-machine re-measure), don't hold feature work
up — call them out instead.

## Conventions

- An issue is `bw create "<title>" -t task|bug -p P0-P4 -d "<description>"`.
  The description is self-contained: the problem, the context, and "Done when ...".
- A PRD or feature is an epic: `bw create "<title>" -t epic -d "<the PRD>"`.
  Its implementation issues are children (`--parent <epic-id>`), in order
  through dependencies: `bw dep add <blocker> blocks <blocked>`.
- Triage state is a label: `bw label <id> +<label>` / `-<label>` (strings in
  `triage-labels.md`).
- Conversation and decisions are comments: `bw comment <id> "..."`.
- Status is beadwork's own: `bw start` (in progress), `bw close`, `bw defer`.

## When a skill says "publish to the issue tracker"

Create the issue (or the epic and its children) with `bw create`, wire the
dependencies, and report the new IDs.

## When a skill says "fetch the relevant ticket"

`bw show <id>` (add `--json` for raw data). To find tickets: `bw ready`
(unblocked work), `bw list --all`, `bw list --label <label>`, `bw list --grep <text>`.

## Landing work

Follow `AGENTS.md`: one ticket per worktree on branch `<id>/<short-description>`,
commit messages reference the ID, then `bw close <id>` and `bw sync`.
