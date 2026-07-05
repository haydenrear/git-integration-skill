#!/usr/bin/env bash
# new-change.sh <TICKET> [base-branch]
# Create a ticketed parent worktree for a cross-repo change. The worktree
# contains constituent files as PLAIN files (no constituent .git inside it), so
# you edit across repos freely and commit once to the parent feature branch.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

TICKET="${1:-}"; BASE="${2:-}"
[ -n "$TICKET" ] || die "usage: new-change.sh <TICKET> [base-branch]"

ROOT="$(repo_root)"; cd "$ROOT"
assert_parent_clean "$ROOT"

BRANCH="feature/$TICKET"
WT="$(dirname "$ROOT")/$(basename "$ROOT")-$TICKET"
[ -e "$WT" ] && die "worktree path already exists: $WT"

: "${BASE:=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)}"

step "Creating worktree for $TICKET"
git -C "$ROOT" worktree add -q -b "$BRANCH" "$WT" "$BASE"
info "worktree:  $WT"
info "branch:    $BRANCH  (base: $BASE)"

# Sanity: no constituent .git leaked into the worktree.
if find "$WT/constituents" -maxdepth 2 -name .git 2>/dev/null | grep -q .; then
  info "WARNING: found a .git inside the worktree's constituents — unexpected"
fi

cat >&2 <<EOF

Edit across constituents in:
  $WT
Then commit to the parent feature branch and bring it back:
  git -C "$WT" add -A && git -C "$WT" commit -m "$TICKET: <what changed>"
  git -C "$ROOT" merge --no-ff "$BRANCH"
  git -C "$ROOT" worktree remove "$WT"
Finally fan it out to the constituents:
  $SCRIPT_DIR/propagate.sh "$TICKET"
EOF
