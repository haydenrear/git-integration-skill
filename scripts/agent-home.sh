#!/usr/bin/env bash
# agent-home.sh — give THIS checkout its own Skill Manager home.
#
#   scripts/agent-home.sh                          # bootstrap (idempotent)
#   eval "$(scripts/agent-home.sh --print-env)"     # bind the current shell
#   scripts/agent-home.sh --help                    # every option
#
# Copy this ONE file into a repo's `scripts/` directory at onboarding. Run it
# once per checkout, before starting an agent there. It creates
# <repo>/.skill-manager (a clone of the home above it), <repo>/.claude,
# <repo>/.codex and <repo>/.gemini, all gitignored, and leaves launcher shims at
# <repo>/.skill-manager/bin/launch. An agent launched through those shims reads
# and writes THIS checkout's home; the home it was cloned from is only ever
# read, and only to clone from.
#
# Worktrees do not need it: `wt new` / new-change.sh bootstraps every worktree
# they create.
#
# THIS FILE IS A LOCATOR, NOT AN IMPLEMENTATION
# ---------------------------------------------
# The sequence — clone first, point SKILL_MANAGER_HOME at the clone, only then
# run anything that writes a home — lives in exactly one place, this skill's
# scripts/bootstrap-home.sh. A copy of that ordering would be a copy of the one
# rule whose violation writes into the operator's global home, so this script
# finds the canonical file and execs it. That is also why it is the only file
# the onboarding steps tell you to copy: everything else is reached through it.
#
# Which copy of bootstrap-home.sh it looks for, in order:
#
#   0. $INTEGRATION_BOOTSTRAP_HOME            an explicit pin always wins
#   1. <this file's repo>/scripts/bootstrap-home.sh
#                                             the copy shipped beside this one.
#                                             In the documented arrangement — one
#                                             copy in the target repo's scripts/ —
#                                             this and rung 2 are the same path.
#   2. <repo>/scripts/bootstrap-home.sh       the target repo ships the skill
#                                             itself (true in git-integration-repo's
#                                             own checkout, and in any repo that
#                                             vendored the whole scripts/ dir)
#   3. <repo>/constituents/git-integration-repo/scripts/bootstrap-home.sh
#                                             an integration repo tracking the
#                                             skill as a constituent — the copy
#                                             that is reviewed alongside the repo
#   4. $SKILL_MANAGER_HOME/skills/git-integration-repo/scripts/bootstrap-home.sh
#   5. $HOME/.skill-manager/skills/git-integration-repo/scripts/bootstrap-home.sh
#
# where <repo> is the CHECKOUT BEING BOOTSTRAPPED (see below), not this file's.
#
# Rungs 4 and 5 are the installed skill, read and never written. The last is the
# operator's GLOBAL home and is deliberately last: on a fresh machine it is the
# only copy that exists, and reading an implementation from it is not the
# failure this whole mechanism exists to prevent — writing a home into it is,
# and bootstrap-home.sh refuses that on its own.
#
# EXISTING IS NOT THE SAME AS BEING ABLE TO DO THE JOB
# ----------------------------------------------------
# A candidate is not accepted because the file is there. Measured, on one
# machine, from one fixture, with one command:
#
#   the checkout's copy   (941ec20, 71 KB)  18 of 18 skills projected into
#                                           .claude, .codex and .gemini
#   ~/.skill-manager's    (c5abdab, 33 KB)  EMPTY agent homes
#
# The stale copy predates the projection work entirely. It did not crash, warn
# or exit non-zero — it answered, and looked exactly like success, which is this
# epic's recurring failure and the reason `bootstrap-home.sh` probes the CLI's
# help TEXT rather than its exit status. So every candidate is asked the same
# question before it is run: does `--help` name `--allow-unprojected`, the flag
# that arrived with projection support? A candidate that cannot answer is
# SKIPPED — not run, not warned about and used anyway — and if no candidate can,
# this script REFUSES and prints every candidate with its verdict.
#
# Refusing is deliberate. The alternative measured itself: a home whose agent
# directories were empty, produced silently, discovered only when an agent
# started there could see none of its skills. A refusal that names
# `skill-manager sync` costs the operator one command; the guess cost a whole
# eval before anyone noticed. What this must never do is reach back into a path
# inside this checkout when the installed copy is stale: that would work in
# git-integration-repo and break for every consumer, which is the direction the
# per-checkout-home design points away from.
#
# WHICH COPY RAN IS ALWAYS ANNOUNCED
# -----------------------------------
# The chosen path goes to stderr on every run. It used to be announced only when
# the chosen copy lived under $HOME/.skill-manager AND the active home was
# something else — which is backwards. From a bare shell SKILL_MANAGER_HOME is
# unset, so the active home IS the global home, the condition is false, and the
# single case most likely to resolve the wrong copy was the one case that said
# nothing at all. "The bootstrap ran" and "the bootstrap you reviewed ran" are
# different facts, so the fact is stated unconditionally.
#
# $INTEGRATION_BOOTSTRAP_HOME is to this skill's SCRIPTS what $SKILL_MANAGER_CLI
# is to the CLI: the one way to say "use exactly this build, not whatever a home
# happens to carry". Nothing else pins them — an installed unit's scripts come
# from whichever home resolved it, and that home can be arbitrarily stale
# (measured skew on one machine: checkout 941ec20, ~/.skill-manager c5abdab,
# project home 24fe6e8). The probe above turns that skew from a silent wrong
# answer into a refusal; the pin is how an operator overrides it.
#
# There is no rung that resolves a skill-manager CLI, or this file, by a path
# relative to its own location beyond the repo root above it; see selftest.sh's
# "No script resolves a skill-manager by a path relative to itself".
#
# WHICH CHECKOUT GETS THE HOME IS THE CALLER'S, NOT THIS FILE'S
# -------------------------------------------------------------
# `--root` defaults to the CALLER'S enclosing git toplevel — the same answer
# `scripts/wt` and `lib.sh`'s `checkout_root` give, and the one bootstrap-home.sh's
# own `--help` documents: "the nearest enclosing git toplevel".
#
# It used to default to the SCRIPT'S enclosing toplevel, which is the same answer
# only in the one arrangement this file is usually tested in: a copy sitting in
# the target repo's own `scripts/`. Resolve it from anywhere else — which is what
# an agent does, since the copy it reaches is the INSTALLED one under
# `<home>/skills/git-integration-repo/scripts/` — and `--root` named the installed
# skill directory. Measured, from a plain repo, an integration repo AND a
# constituent, all three identical:
#
#   ✗ source and destination homes must not nest: <home> vs <home>/skills/git-integration-repo/.skill-manager
#   exit 1
#
# The refusal is correct and load-bearing: it is what stopped a 916 MB write into
# the operator's global home. What was wrong is the root it was asked about. Note
# the failure is invisible from `constituents/git-integration-repo`, where the two
# answers coincide, which is why it survived.
#
# The CANDIDATE SEARCH keeps its own base. "Where is a usable bootstrap-home.sh"
# and "which checkout is being bootstrapped" are different questions with
# different right answers: the copy beside THIS file is the one an operator
# reviewed and the one rungs 1 and 2 have always meant, while the target is
# wherever the caller is standing. Conflating them is the bug in mirror image —
# it would make a repo that ships no scripts/ unable to find the implementation
# it was invoked from.
set -euo pipefail

# The directory this file was resolved from — a checkout that vendored scripts/,
# or an installed `<home>/skills/git-integration-repo`. Used ONLY to find a
# bootstrap-home.sh, never as the target.
SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# The target. An explicit --root always wins; otherwise the caller's checkout.
# Read out of "$@" rather than re-derived after the exec, so the refusal below
# and the run that follows it agree about which checkout is in question.
#
# `--root DIR`, the two-word spelling, and only that one — because that is the
# only spelling bootstrap-home.sh's own parser accepts, and a locator that
# understood `--root=DIR` would resolve a target from an argument the script it
# execs then rejects as unknown.
ROOT=""
_prev=""
for _a in ${@+"$@"}; do
  [ "$_prev" = "--root" ] && { ROOT="$_a"; break; }
  _prev="$_a"
done
if [ -n "$ROOT" ]; then
  [ -d "$ROOT" ] || { printf 'error: --root is not a directory: %s\n' "$ROOT" >&2; exit 1; }
else
  # `git -C .` rather than a walk: it is the same resolution checkout_root() does,
  # and lib.sh is deliberately not sourced here — this file is copied into a repo
  # ALONE, so anything it needs it has to carry.
  ROOT="$(git -C . rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$ROOT" ] || {
    printf 'error: not inside a git repository: %s\n' "$(pwd -P)" >&2
    printf '  A home belongs to a CHECKOUT. cd into the repo you want to give one\n' >&2
    printf '  to, or name it: %s --root <repo>\n' "$0" >&2
    exit 1
  }
fi
ROOT="$(cd "$ROOT" && pwd -P)"
ACTIVE_HOME="${SKILL_MANAGER_HOME:-$HOME/.skill-manager}"

# The capability, spelled as the flag that came in with the projection work. It
# is asked of the help TEXT, because the incapable copy exits 0 on `--help` just
# as happily as the capable one does — a status-only probe accepts it.
REQUIRED_CAPABILITY='--allow-unprojected'

# Bash 3.2 (macOS): no associative arrays, so the labels are a parallel array.
candidates=(); labels=()
# Deduplicated, because rungs 3 and 4 are THE SAME PATH whenever
# SKILL_MANAGER_HOME is unset — the bare-shell case — and listing one file twice
# in a refusal reads as two independent findings.
add_candidate() {
  local existing
  for existing in ${candidates[@]+"${candidates[@]}"}; do
    [ "$existing" = "$1" ] && return 0
  done
  candidates+=("$1"); labels+=("$2")
}

# A home's label says GLOBAL whenever it is the global one, whether it got there
# as $SKILL_MANAGER_HOME or as the fallback. The old code decided that by
# comparing the two, and from a bare shell they are equal — which is how the
# global copy came to be described as the active home and not flagged.
home_label() {
  if [ "$1" = "$HOME/.skill-manager" ]; then
    printf "the operator's GLOBAL home"
  else
    printf 'the active home ($SKILL_MANAGER_HOME)'
  fi
}

# `if`, not `[ … ] && add_candidate …`: under `set -e` a trailing `&&` list whose
# condition is false is the whole command failing, and the unset case is the
# ordinary one.
if [ -n "${INTEGRATION_BOOTSTRAP_HOME:-}" ]; then
  add_candidate "$INTEGRATION_BOOTSTRAP_HOME" 'pinned by $INTEGRATION_BOOTSTRAP_HOME'
fi
# Rung 1, and the ONLY rung anchored on this file's own location: the copy that
# ships beside it. In the arrangement this file is documented for — one copy in a
# repo's scripts/ — this IS "$ROOT/scripts/bootstrap-home.sh", so the ordering is
# unchanged there; when the file was resolved from an installed home it is that
# home's copy, which is the implementation the caller actually invoked.
add_candidate "$SELF_ROOT/scripts/bootstrap-home.sh" \
  "the copy beside this file: $SELF_ROOT"
add_candidate "$ROOT/scripts/bootstrap-home.sh" \
  "the checkout being bootstrapped: $ROOT"
add_candidate "$ROOT/constituents/git-integration-repo/scripts/bootstrap-home.sh" \
  "$ROOT's git-integration-repo constituent"
add_candidate "$ACTIVE_HOME/skills/git-integration-repo/scripts/bootstrap-home.sh" \
  "$(home_label "$ACTIVE_HOME"): $ACTIVE_HOME"
add_candidate "$HOME/.skill-manager/skills/git-integration-repo/scripts/bootstrap-home.sh" \
  "the operator's GLOBAL home: $HOME/.skill-manager"

# Ask a candidate whether it can do the job, under a time bound.
#
# Bounded because the mode this file exists to catch is a copy that answers
# WRONGLY rather than not at all, and its neighbour is a copy that does not
# answer: an unbounded probe against that one does not go red, it goes away and
# takes the bootstrap with it (measured elsewhere in this skill, in `pick_cli`).
# Rolled by hand: macOS ships neither `timeout` nor `gtimeout`, and a probe that
# skipped itself on the platform the defect was found on would report the same
# green as a passing one. Every measured `--help` here is milliseconds.
probe_capability() {
  local candidate="$1" out pid waited=0 found=1
  out="$(mktemp "${TMPDIR:-/tmp}/agent-home-probe-XXXXXX")" || return 1
  bash "$candidate" --help > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 100 ]; then
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
  command grep -q -- "$REQUIRED_CAPABILITY" "$out" || found=0
  rm -f "$out"
  [ "$found" = 1 ]
}

chosen=""; chosen_label=""; verdicts=""
i=0
for candidate in "${candidates[@]}"; do
  label="${labels[$i]}"; i=$((i + 1))
  if [ ! -f "$candidate" ]; then
    verdicts="$verdicts  not there  $candidate
             ($label)
"
    continue
  fi
  if probe_capability "$candidate"; then
    chosen="$candidate"; chosen_label="$label"
    break
  fi
  verdicts="$verdicts  TOO OLD    $candidate
             ($label)
             its --help does not name $REQUIRED_CAPABILITY, so it predates
             projection support and would leave the agent homes EMPTY
"
done

if [ -n "$chosen" ]; then
  printf 'bootstrap: %s\n           (%s)\n' "$chosen" "$chosen_label" >&2
  exec bash "$chosen" --root "$ROOT" "$@"
fi

cat >&2 <<EOF
error: no copy of git-integration-repo's scripts/bootstrap-home.sh here can
       project a home's skills into its agent directories, so none was run.

$verdicts
A copy that predates projection support does not fail — it produces a home with
EMPTY .claude/.codex/.gemini directories and exits 0, and an agent started there
sees none of the skills the home holds. That is why this refuses instead of
running the newest thing it can find.

Fix it in one of these ways, most preferred first:

  skill-manager sync                       # refresh the installed unit in
                                           # ${ACTIVE_HOME}
  skill-manager install github:haydenrear/git-integration-skill
  INTEGRATION_BOOTSTRAP_HOME=/path/to/git-integration-skill/scripts/bootstrap-home.sh \\
    $0 $*

INTEGRATION_BOOTSTRAP_HOME is to this skill's scripts what SKILL_MANAGER_CLI is
to the CLI: nothing else pins which copy runs. Do not hand-roll the bootstrap —
it must clone the home before anything else touches one, or it writes into
~/.skill-manager.
EOF
exit 1
