#!/bin/sh
# The frozen stability files never change: ci/frozen.sh <base-ref> fails
# when the commits since <base-ref> modify, rename or delete a file under
# test/stability/<version>/ (a release adds a directory; a frozen file is
# never edited), or drop a code from test/stability/codes.txt (the ledger
# only grows; a line may gain a `retired <version>` mark). The rules:
# docs/agents/stability.md. Run on every pull request by
# .github/workflows/ci.yml, and by hand as `ci/frozen.sh origin/main`.
set -eu

base=${1:?usage: ci/frozen.sh <base-ref>}
ledger=test/stability/codes.txt

# the diff's starting point: where the branch left the base, when the
# history is there (a shallow checkout of a pull request's merge commit has
# the base's tip only, and the merge commit contains it, so its tip serves)
from=$(git merge-base "$base" HEAD 2>/dev/null || echo "$base")
status=0

# every change under test/stability/ other than an added file; the ledger
# is checked by its codes below
changed=$(git diff --name-status "$from" HEAD -- test/stability/ |
  grep -v -E "^A[[:space:]]" | grep -v -E "[[:space:]]${ledger}\$" || true)

if [ -n "$changed" ]; then
  echo "frozen stability files changed since $base (a frozen file is never edited; a release adds a directory):" >&2
  echo "$changed" >&2
  status=1
fi

# the codes of the ledger at a revision (the first word of each code line)
codes() {
  git show "$1:$ledger" 2>/dev/null | grep -v -E '^#|^[[:space:]]*$' | awk '{print $1}' | sort
}

before=$(mktemp)
after=$(mktemp)
codes "$from" > "$before"
codes HEAD > "$after"
lost=$(comm -23 "$before" "$after")
rm -f "$before" "$after"

if [ -n "$lost" ]; then
  echo "codes dropped from $ledger since $base (the ledger only grows):" >&2
  echo "$lost" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "frozen stability files unchanged since $base"
fi

exit "$status"
