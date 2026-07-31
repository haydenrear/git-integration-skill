#!/usr/bin/env bash
# new-change.sh <TICKET> [base-branch] [--integration] [--no-home]
#
# Create a ticketed worktree, with its own Skill Manager home, for the repo you
# are standing in.
#
# Which repo that is
# ------------------
# The nearest enclosing git toplevel — and the script SAYS which one before it
# does anything. It used to resolve the nearest ancestor holding
# integration.toml instead (repo_root), which is right for propagate/refresh/
# verify and wrong here: a constituent has its own real .git, so run from
# constituents/deploy-helm that answer was the integration PARENT, and the
# script branched and worktree'd a different repository than the one the
# operator was standing in — with exit 0 and no warning. Three shapes now, all
# supported, all announced:
#
#   integration   the checkout holds integration.toml. Constituent files are
#                 plain files in the worktree; propagate.sh fans the change out
#                 afterwards. (Includes a NESTED integration repo such as
#                 meta-orchestrator, which is an integration repo in its own
#                 right and correct to branch here.)
#   constituent   a git repo living inside an integration repo's tree. Branch
#                 the constituent itself. Nothing to fan out; the integration
#                 parent refreshes its snapshot after the change merges.
#   standalone    an ordinary repo, outside any integration repo.
#
# Supporting all three rather than refusing two of them is deliberate. The
# script's value is that the per-worktree home is not optional; sending an
# operator to `git worktree add` + `bootstrap-home.sh` by hand makes the home
# step something to remember again, which is the exact failure the home exists
# to prevent. What must never happen is a SILENT wrong target, and that is
# fixed by resolving correctly and printing the answer, not by refusing.
#
# Pass --integration to target the enclosing integration repo instead of the
# constituent you happen to be standing in.
#
# Where the worktree goes
# -----------------------
# Beside the OUTERMOST enclosing integration repo — see worktree_parent_dir in
# lib.sh. Unchanged for a top-level repo; for anything inside an integration
# repo it is the difference between a clean parent and a parent whose
# `git add -A` stages the worktree as a gitlink.
#
# The home
# --------
# The worktree gets its OWN Skill Manager home (bootstrap-home.sh) before this
# script returns, and therefore before any agent can run in it. That is on
# purpose: an agent that has to remember to export SKILL_MANAGER_HOME will
# sometimes not, and the failure is invisible — it just edits the operator's
# global home instead. Pass --no-home (or INTEGRATION_SKIP_HOME=1) only when
# you know the worktree will never host an agent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: new-change.sh <TICKET> [base-branch] [--integration] [--no-home]

  TICKET          Ticket id. The branch is feature/<TICKET>; the worktree is
                  <repo>-<TICKET>, placed beside the outermost enclosing
                  integration repo.
  base-branch     Branch to start from. Default: the checkout's current branch.
  --integration   Target the enclosing INTEGRATION repo rather than the
                  constituent you are standing in.
  --no-home       Skip the per-worktree Skill Manager home. Agents launched in
                  the worktree then use the operator's global home.
  -h, --help      This message.
EOF
}

TICKET=""; BASE=""; SKIP_HOME="${INTEGRATION_SKIP_HOME:-0}"; WANT_INTEGRATION=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-home)     SKIP_HOME=1; shift ;;
    --integration) WANT_INTEGRATION=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            usage; die "unknown option: $1" ;;
    *)             if [ -z "$TICKET" ]; then TICKET="$1"; elif [ -z "$BASE" ]; then BASE="$1";
                   else die "unexpected argument: $1"; fi; shift ;;
  esac
done
[ -n "$TICKET" ] || { usage; die "a ticket id is required"; }

# ------------------------------------------------------- which repo, out loud

FROM="$PWD"
ROOT="$(checkout_root)"
KIND="$(checkout_kind "$ROOT")"
INTEGRATION="$(outermost_integration_root "$ROOT")"

if [ "$WANT_INTEGRATION" = 1 ]; then
  [ -n "$INTEGRATION" ] || die "--integration: no integration.toml in any ancestor of $ROOT"
  ROOT="$(repo_root)"                 # the NEAREST one: from inside a nested
  KIND="$(checkout_kind "$ROOT")"     # integration repo that is the right target
fi

step "Repository for $TICKET"
info "from:      $FROM"
info "repo:      $ROOT"
info "kind:      $KIND"
case "$KIND" in
  constituent)
    # The announcement is the point: this is the case that used to be answered
    # wrongly, silently, with exit 0.
    info "note:      a constituent of $INTEGRATION — branching the CONSTITUENT."
    info "           Pass --integration (or cd there) to branch $INTEGRATION."
    ;;
  integration)
    if [ -n "$INTEGRATION" ] && [ "$INTEGRATION" != "$ROOT" ]; then
      info "note:      a NESTED integration repo inside $INTEGRATION."
      info "           Branching it is correct; its worktree is kept OUTSIDE"
      info "           $INTEGRATION so that tree stays clean."
    fi
    ;;
esac

cd "$ROOT"
assert_parent_clean "$ROOT"

BRANCH="feature/$TICKET"
WT="$(ticket_worktree_path "$ROOT" "$TICKET")"
assert_worktree_outside_integration "$WT"
[ -e "$WT" ] && die "worktree path already exists: $WT"

: "${BASE:=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)}"

step "Creating worktree for $TICKET"
git -C "$ROOT" worktree add -q -b "$BRANCH" "$WT" "$BASE"
info "worktree:  $WT"
info "branch:    $BRANCH  (base: $BASE)"

# Sanity: no constituent .git leaked into an integration worktree. Only an
# integration repo has constituents, so only it can have this problem.
if [ "$KIND" = integration ] && [ -d "$WT/constituents" ]; then
  if command find "$WT/constituents" -maxdepth 2 -name .git 2>/dev/null | command grep -q .; then
    info "WARNING: found a .git inside the worktree's constituents — unexpected"
  fi
fi

# The worktree's own Skill Manager home. One implementation, shared with a
# repo root's scripts/agent-home.sh — see bootstrap-home.sh for why the clone
# has to happen before anything else touches a home.
if [ "$SKIP_HOME" = 1 ]; then
  info "home:      skipped (--no-home) — agents launched here will use the global home"
else
  step "Giving the worktree its own Skill Manager home"
  if ! "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT"; then
    # ROLL THE WORKTREE BACK. Leaving it was the wrong half of a two-step
    # operation: the worktree and the branch survived, `new-change.sh <TICKET>`
    # then refused with "worktree path already exists", and the recovery
    # (close-change.sh) was named nowhere. The most common cause is a project
    # with no home yet — 17 of this repo's 24 constituents — so the state an
    # operator lands in matters more than the rarity of the failure.
    #
    # Removal is safe precisely here and nowhere else: this worktree was created
    # seconds ago by this script, nothing has been edited in it, and the home
    # bootstrap FAILED so there is no home in it to lose. That is the one case
    # close-change.sh's gate would also wave through, so this is not a bypass of
    # it.
    rolled_back=0
    if git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null; then
      git -C "$ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
      rolled_back=1
    fi
    cat >&2 <<EOF

No home could be created for this worktree, so an agent started in it would
read and write the operator's GLOBAL home. The cause is printed above, and the
remedy that clears it is in that message — it is usually that this repo has no
project home yet, which one command fixes:

  $SCRIPT_DIR/bootstrap-home.sh --root "$ROOT"
  $0 $TICKET${BASE:+ $BASE}
EOF
    if [ "$rolled_back" = 1 ]; then
      cat >&2 <<EOF

The worktree and branch $BRANCH were removed, so re-running the line above
works as if this attempt had not happened.
EOF
    else
      cat >&2 <<EOF

The worktree at $WT could NOT be rolled back automatically. Remove it before
re-running, through the gate rather than by hand:
  $SCRIPT_DIR/close-change.sh "$TICKET"
EOF
    fi
    cat >&2 <<EOF

Or, if this worktree will never host an agent, create it with --no-home.
EOF
    exit 3
  fi
fi

# ----------------------------------------------------------------- next steps

cat >&2 <<EOF

Edit in:
  $WT
Launch an agent bound to this worktree's own home:
  $WT/.skill-manager/bin/launch/claude
Then commit and bring it back:
  git -C "$WT" add -A && git -C "$WT" commit -m "$TICKET: <what changed>"
  git -C "$ROOT" merge --no-ff "$BRANCH"
Close the worktree through the gate (NOT a bare "git worktree remove"):
  $SCRIPT_DIR/close-change.sh "$TICKET"
EOF

if [ "$KIND" = integration ]; then
  cat >&2 <<EOF
Finally fan it out to the constituents:
  $SCRIPT_DIR/propagate.sh "$TICKET"
EOF
else
  cat >&2 <<EOF

This is a $KIND worktree, so propagate.sh does NOT apply — there are no
constituents beneath it to fan out to. Once the change has merged here, refresh
the integration parent's snapshot of this repo from the parent's own main tree.
EOF
fi

cat >&2 <<EOF

Teardown note: the home lives inside the worktree, so removing the worktree
removes the home, and because the home is gitignored that loss appears in no
diff. close-change.sh runs "skill-manager home close-out" first and refuses
while the home still holds unit work, naming each blocker and its remedy; pass
--force to discard deliberately. See references/skill-homes.md. Reconciling
into the project home is NOT the same as pushing a skill edit back to that
skill's own repo — that is the separate push-back flow, and it is not
propagate.sh.
EOF
