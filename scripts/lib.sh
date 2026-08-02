#!/usr/bin/env bash
# Shared helpers for git-integration-repo scripts. Source this:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*" >&2; }

# ----------------------------------------------------------------- the contract
#
# Prose goes to stderr (everything above). THE CONTRACT GOES TO STDOUT, and
# stdout carries nothing else.
#
# That split is the whole point. An agent handed a ticket has to create a
# worktree, and today it must read CLAUDE.md, INTEGRATION.md,
# references/skill-homes.md, references/worktrees.md and git-issue-workflow's
# provision.md before it can do so safely. The observed failure mode is that it
# does not: it gives up and writes its own script, which knows none of the rules
# those pages exist to state. The fix is not more documentation, it is an output
# an agent can act on without any — so the successful run answers exactly the
# questions it has next, one per line, keyword first, value runnable:
#
#   WORKTREE   where to edit
#   BRANCH     what was branched, from what
#   LAUNCH     the command that starts an agent bound to this worktree's home
#   IF-EXIT-8  the command that clears the first-launch drift gate
#   CLOSE      the command that tears it down through the gate
#   PROPAGATE  (integration repos only) the fan-out
#
# and the failing run answers the only two it has then:
#
#   FAILED     one line, what went wrong
#   FIX        one runnable command
#
# The KEYS are the interface, not this file. git-issue-skill#4 asks whether this
# primitive should move to `git-issue` or into `skill-manager` itself; a caller
# that reads these keys keeps working across that move, and a caller that parses
# the prose does not. So: never add a key without adding it to `references/worktrees.md`,
# and never make a key's value anything but a path or a command that runs.
contract() { printf '%-10s %s\n' "$1" "$2"; }

# The failure half. Both lines, always: a FAILED with no FIX is the banner this
# replaces, and a FIX with no FAILED is a command with no reason to run it.
contract_fail() {
  local fix="$1"; shift
  contract FAILED "$*"
  contract FIX    "$fix"
}

# die(), plus the contract, plus a chosen exit code. The prose still goes to
# stderr — it is where the reasoning lives, and the reasoning is why these
# scripts refuse at all — but a caller that reads only stdout gets the two lines
# it can act on.
die_fix() {
  local code="$1" fix="$2"; shift 2
  contract_fail "$fix" "$*"
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

# Two questions that look like one. Conflating them is how new-change.sh came
# to build a worktree of the wrong repository, silently and with exit 0:
#
#   repo_root()      Which INTEGRATION repo am I operating on? propagate.sh,
#                    refresh.sh, verify.sh, add-constituent.sh and
#                    finalize-constituents.sh are meaningless outside one, so
#                    walking up to the nearest integration.toml is right for
#                    them.
#
#   checkout_root()  Which repo does `git worktree add` act on HERE? The
#                    nearest enclosing git toplevel. A constituent has its own
#                    real .git, so from inside constituents/deploy-helm the
#                    answer is deploy-helm — not the parent that merely tracks
#                    its files. repo_root() answers the parent there, and a
#                    worktree built on that answer branches a different
#                    repository entirely.
#
# Anything that creates or removes a worktree wants checkout_root().

# Repo root = nearest ancestor with integration.toml. Falls back to git toplevel.
repo_root() {
  local d="${1:-$PWD}"
  d="$(cd "$d" && pwd)"
  while [ "$d" != "/" ]; do
    [ -f "$d/integration.toml" ] && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  git rev-parse --show-toplevel 2>/dev/null || die "not inside an integration repo (no integration.toml found)"
}

# The git repo a worktree command here would act on: nearest enclosing
# toplevel, physical path.
checkout_root() {
  local d="${1:-$PWD}" top
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repository: $(cd "$d" && pwd -P)"
  (cd "$top" && pwd -P)
}

# The MAIN working tree of the repository $1 is a checkout of. For an ordinary
# checkout that is the checkout itself; for a LINKED worktree it is the repo the
# worktree was created from — the "project" a ticket worktree hangs off.
#
# `git worktree list` names the main working tree first, always, and that answer
# does not depend on where the caller is standing. Deriving it from the checkout
# rather than from $PWD is the point: see project_home below.
main_checkout_root() {
  local d="${1:-$PWD}" first
  first="$(git -C "$d" worktree list --porcelain 2>/dev/null \
    | awk 'NR==1 && $1=="worktree"{ $1=""; sub(/^ /,""); print }')" || first=""
  [ -n "$first" ] || return 1
  (cd "$first" 2>/dev/null && pwd -P) || return 1
}

# True when $1 is a linked worktree rather than its repository's main working
# tree. Non-zero (false) when $1 is not in a git repo at all.
is_linked_worktree() {
  local root main
  root="$(cd "${1:-$PWD}" && pwd -P)"
  main="$(main_checkout_root "$root")" || return 1
  [ "$main" != "$root" ]
}

# THE project home for the repository $1 belongs to: <main working tree>/.skill-manager.
#
# One definition, and both halves of the worktree lifecycle read it:
# bootstrap-home.sh clones a worktree home FROM it, close-change.sh reconciles
# that home back INTO it. That is issue #50. The two used to answer the question
# separately — bootstrap from `${SKILL_MANAGER_HOME:-$HOME/.skill-manager}`,
# close-out from `<checkout_root>/.skill-manager` — and from a bare shell those
# are different homes. Measured: bootstrap cloned the operator's 845 MB global
# home into the worktree and close-out then blocked on 17 units before any work
# existed, printing a remedy that would have synced those 17 GLOBAL units into
# the project home.
#
# It is derived from the CHECKOUT, never from an environment variable, because
# "the operator exported the right thing" is not a construction — the launch
# shims export it and a bare shell does not, and a bare shell is how these
# scripts are run by hand.
project_home() {
  local main; main="$(main_checkout_root "${1:-$PWD}")" || return 1
  printf '%s/.skill-manager\n' "$main"
}

# The HIGHEST ancestor of $1 holding integration.toml; empty when there is
# none. Highest, not nearest: integration repos nest — meta-orchestrator is a
# constituent of this repo and an integration repo in its own right — and it is
# the OUTERMOST working tree that must stay unpolluted.
outermost_integration_root() {
  local d out=""
  d="$(cd "${1:-$PWD}" && pwd -P)"
  while [ "$d" != "/" ]; do
    [ -f "$d/integration.toml" ] && out="$d"
    d="$(dirname "$d")"
  done
  printf '%s\n' "$out"
}

# What kind of checkout $1 is: integration | constituent | standalone.
# "constituent" here means only "a git repo living inside an integration repo's
# working tree" — it does not consult integration.toml's [[constituent]] list,
# because a repo that is not listed yet has exactly the same worktree hazard.
checkout_kind() {
  local root; root="$(cd "$1" && pwd -P)"
  if [ -f "$root/integration.toml" ]; then printf 'integration\n'; return 0; fi
  if [ -n "$(outermost_integration_root "$root")" ]; then printf 'constituent\n'; return 0; fi
  printf 'standalone\n'
}

# Where $1's ticket worktrees live: BESIDE the outermost enclosing integration
# repo, never inside one.
#
# For a top-level repo this is the same directory as before (the repo's own
# parent), so the ordinary case is unchanged. For a repo that sits INSIDE an
# integration repo — an ordinary constituent, or a nested integration repo like
# meta-orchestrator — the old rule dropped the worktree into the parent's
# constituents/, where the parent reports it as untracked and no rule ignores
# it. Worse than untracked: a worktree's `.git` is a FILE, so a parent
# `git add -A` stages the whole directory as a gitlink (mode 160000) — exactly
# the submodule INTEGRATION.md rule 1 forbids.
#
# It cannot be fixed from the parent's .gitignore either: any glob wide enough
# to catch `constituents/meta-orchestrator-CO2` also catches real constituents
# named `deploy-helm` or `hyper-experiments`. So the worktree goes where the
# parent cannot see it at all.
worktree_parent_dir() {
  local root outer
  root="$(cd "$1" && pwd -P)"
  outer="$(outermost_integration_root "$root")"
  dirname "${outer:-$root}"
}

# The conventional worktree path for a ticket. new-change.sh creates it and
# close-change.sh resolves it; one implementation so the two cannot disagree
# about where a worktree is.
ticket_worktree_path() {
  local root="$1" ticket="$2"
  root="$(cd "$root" && pwd -P)"
  printf '%s/%s-%s\n' "$(worktree_parent_dir "$root")" "$(basename "$root")" "$ticket"
}

# Refuse a worktree path that lands inside an integration repo's working tree.
# worktree_parent_dir already avoids it; this is the assertion that turns any
# future mistake — or a hand-passed path — into a loud failure instead of a
# gitlink in someone else's index.
assert_worktree_outside_integration() {
  local wt="$1" parent enclosing
  parent="$(dirname "$wt")"
  [ -d "$parent" ] || die "worktree parent directory does not exist: $parent"
  enclosing="$(outermost_integration_root "$parent")"
  if [ -n "$enclosing" ]; then
    die "refusing to create a worktree at
    $wt
  because that path is inside the integration repository
    $enclosing
  which would report it as untracked and, on \`git add -A\`, stage the whole
  worktree as a gitlink (INTEGRATION.md rule 1). Choose a path outside it."
  fi
}

# Pick any Python 3 interpreter. _manifest.py is dependency-free (no tomllib),
# so the system python3 is fine; fall back to python / python3.x if needed.
_pick_py() {
  local c
  for c in python3 python python3.14 python3.13 python3.12 python3.11; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
  done
  die "no python interpreter found (need python3 or python)"
}
PY="${INTEGRATION_PY:-$(_pick_py)}"

manifest() { "$PY" "$SCRIPT_DIR/_manifest.py" "$@"; }

# Default branch of a constituent as its own git sees origin's HEAD, with the
# manifest value as the fallback.
constituent_default_branch() {
  local dir="$1" fallback="${2:-main}" b
  b="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')" || true
  [ -n "$b" ] && { printf '%s\n' "$b"; return 0; }
  printf '%s\n' "$fallback"
}

# Assert a working tree is clean. Names the repo: the caller is not always the
# integration parent, and "parent working tree is not clean" printed against a
# constituent's files is how you misread which repo a script picked.
assert_parent_clean() {
  local root="$1"
  if [ -n "$(git -C "$root" status --porcelain)" ]; then
    git -C "$root" status --short >&2
    die_fix 1 "git -C $root status --short" "working tree is not clean: $root (commit or revert the files listed above)"
  fi
}
