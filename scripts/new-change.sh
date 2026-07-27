#!/usr/bin/env bash
# new-change.sh <TICKET> [base-branch] [--no-home]
# Create a ticketed parent worktree for a cross-repo change. The worktree
# contains constituent files as PLAIN files (no constituent .git inside it), so
# you edit across repos freely and commit once to the parent feature branch.
#
# The worktree also gets its OWN Skill Manager home (bootstrap-home.sh), before
# this script returns and therefore before any agent can run in it. That is on
# purpose: an agent that has to remember to export SKILL_MANAGER_HOME will
# sometimes not, and the failure is invisible — it just edits the operator's
# global home instead. Pass --no-home (or INTEGRATION_SKIP_HOME=1) only when
# you know the worktree will never host an agent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

TICKET=""; BASE=""; SKIP_HOME="${INTEGRATION_SKIP_HOME:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-home) SKIP_HOME=1; shift ;;
    -h|--help) die "usage: new-change.sh <TICKET> [base-branch] [--no-home]" ;;
    -*)        die "unknown option: $1" ;;
    *)         if [ -z "$TICKET" ]; then TICKET="$1"; elif [ -z "$BASE" ]; then BASE="$1";
               else die "unexpected argument: $1"; fi; shift ;;
  esac
done
[ -n "$TICKET" ] || die "usage: new-change.sh <TICKET> [base-branch] [--no-home]"

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

# The worktree's own Skill Manager home. One implementation, shared with a
# repo root's scripts/agent-home.sh — see bootstrap-home.sh for why the clone
# has to happen before anything else touches a home.
if [ "$SKIP_HOME" = 1 ]; then
  info "home:      skipped (--no-home) — agents launched here will use the global home"
else
  step "Giving the worktree its own Skill Manager home"
  if ! "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT"; then
    cat >&2 <<EOF

The worktree exists at $WT but has NO home of its own, so an agent started in
it would read and write the operator's global home. Fix the cause above and
re-run:
  $SCRIPT_DIR/bootstrap-home.sh --root "$WT"
or, if this worktree will never host an agent, re-create it with --no-home.
EOF
    exit 3
  fi
fi

cat >&2 <<EOF

Edit across constituents in:
  $WT
Launch an agent bound to this worktree's own home:
  $WT/.skill-manager/bin/launch/claude
Then commit to the parent feature branch and bring it back:
  git -C "$WT" add -A && git -C "$WT" commit -m "$TICKET: <what changed>"
  git -C "$ROOT" merge --no-ff "$BRANCH"
  git -C "$ROOT" worktree remove "$WT"     # takes the worktree's home with it
Finally fan it out to the constituents:
  $SCRIPT_DIR/propagate.sh "$TICKET"

Teardown note: the home lives inside the worktree, so removing the worktree
removes the home. Push any skill edit made in it back to that skill's own repo
FIRST (see references/skill-homes.md — push-back is not propagate.sh), because
"git worktree remove" deletes an unpushed skill change without a trace.
EOF
