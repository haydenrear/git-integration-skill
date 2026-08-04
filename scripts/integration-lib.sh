#!/usr/bin/env bash
# Shared helpers for git-integration-repo's own scripts. Source this:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/integration-lib.sh"
#
# TWO THINGS, AND THE FIRST ONE IS THE POINT
# ------------------------------------------
# 1. It sources the GENERAL library, `lib.sh`, from git-issue-workflow — which
#    is where it now lives, and where this skill's dependency points.
# 2. It defines the two helpers that are genuinely integration-only:
#    `manifest` and `constituent_default_branch`. Both are questions about
#    integration.toml's [[constituent]] list, and neither means anything in a
#    repo that has no constituents.
#
# WHY lib.sh IS NOT HERE
# ----------------------
# An integration repository is a SPECIALIZATION — it exists only when a repo has
# constituents. Tickets and worktrees exist for EVERY repo. So the worktree
# machinery (`wt`, new-change.sh, close-change.sh, bootstrap-home.sh,
# agent-home.sh) and the vocabulary they share (`die`/`info`/`step`/`help_guard`,
# the contract emitters, the checkout predicates) belong to `git-issue-workflow`,
# the skill an agent handed a ticket actually opens, and this skill depends on
# it:
#
#   git-integration-repo  ->  git-issue-workflow  ->  git-issue
#
# `die`/`info`/`step`/`help_guard` are used by the scripts that stayed here, so
# the tempting move is to keep a copy. That would be the same predicate spelled
# twice, and `help_guard` is the one predicate whose second spelling is measured
# in damage: git-integration-skill#7 was `propagate.sh --help` running a real
# fan-out. ONE definition, ONE home, ONE resolved path to it — which is this
# file, and it is the only place the cross-unit resolution is written.
#
# WHICH COPY, AND IN WHAT ORDER
# -----------------------------
#   0. $GIT_ISSUE_WORKFLOW_SCRIPTS/lib.sh   an explicit pin always wins. This is
#                                           to lib.sh what $SKILL_MANAGER_CLI is
#                                           to the CLI and what
#                                           $INTEGRATION_BOOTSTRAP_HOME is to
#                                           bootstrap-home.sh: the one way to
#                                           say "the copy I am developing, not
#                                           whatever a home happens to carry".
#   1. ${SKILL_MANAGER_HOME:-$HOME/.skill-manager}/skills/git-issue-workflow/scripts/lib.sh
#                                           the installed dependency. An
#                                           installed unit's files live at
#                                           $SKILL_MANAGER_HOME/skills/<unit>/,
#                                           and the `:-` fallback is what makes
#                                           the same path work from a bare
#                                           shell, which is how these scripts
#                                           are run by hand.
#
# There is deliberately NO rung that resolves lib.sh by a path relative to this
# file — no `../../git-issue-workflow/scripts/lib.sh`. A path relative to where
# this file happens to sit is evidence about the checkout, not about which copy
# should run; selftest.sh asserts the same rule for skill-manager CLIs, and it
# was written after a relative rung resolved to an unrelated April clone and a
# whole suite failed for reasons it was not about.
#
# It REFUSES rather than degrading. A missing lib.sh is a missing dependency,
# and the remedy is one command, so the refusal prints it.
set -euo pipefail

INTEGRATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SCRIPT_DIR:=$INTEGRATION_LIB_DIR}"

_GIW_LIB=""
for _c in ${GIT_ISSUE_WORKFLOW_SCRIPTS:+"$GIT_ISSUE_WORKFLOW_SCRIPTS/lib.sh"} \
          "${SKILL_MANAGER_HOME:-$HOME/.skill-manager}/skills/git-issue-workflow/scripts/lib.sh"; do
  [ -f "$_c" ] && { _GIW_LIB="$_c"; break; }
done
if [ -z "$_GIW_LIB" ]; then
  printf 'error: the git-issue-workflow library (lib.sh) was not found, so nothing here can run.\n' >&2
  printf '  It holds die/info/step/help_guard, the contract emitters and the checkout\n' >&2
  printf '  predicates this skill shares with the worktree front door. Looked at:\n' >&2
  printf '    $GIT_ISSUE_WORKFLOW_SCRIPTS/lib.sh  (%s)\n' \
    "${GIT_ISSUE_WORKFLOW_SCRIPTS:-unset}" >&2
  printf '    %s\n' "${SKILL_MANAGER_HOME:-$HOME/.skill-manager}/skills/git-issue-workflow/scripts/lib.sh" >&2
  printf '  Install the dependency:\n' >&2
  printf '    skill-manager install github:haydenrear/git-issue-workflow-skill\n' >&2
  printf '  or point at the copy you are working on:\n' >&2
  printf '    GIT_ISSUE_WORKFLOW_SCRIPTS=/path/to/git-issue-workflow/scripts %s\n' "$0" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_GIW_LIB"

# ------------------------------------------- the skew this split made possible
#
# While lib.sh and these scripts lived in ONE repository they versioned
# together: a function could not be called before it existed. They are two
# repositories now, with independent versions, so a home can perfectly well hold
# an OLD git-issue-workflow beside a NEW git-integration-repo. Nothing about
# that is exotic — `skill-manager sync` updates what it is asked to update — and
# nothing else detects it. The newer script then calls a function this lib.sh
# does not define, and under `set -u` that is a bare "command not found" from
# the MIDDLE of a fan-out: after some constituents have been branched and pushed
# and before the others have. A half-propagated change is damage this repository
# has already paid for, and it is not the kind you can re-run your way out of.
#
# So the check is at SOURCE time, before any script does anything, and it is two
# checks because each covers the other's blind spot:
#
#   * the ABI NUMBER catches a lib.sh too old to have been told about a
#     capability, including one whose function names all happen to still exist
#     but whose meaning changed.
#   * the FUNCTION ROLL-CALL catches the reverse — a lib.sh that carries a high
#     enough number but is missing something this skill actually calls, which is
#     what a bad merge or a partial sync produces.
#
# Both refuse with the same one-command remedy, because both have the same one:
# make the two units agree by syncing the dependency.
WORKTREE_LIB_ABI_MIN=1

_giw_skew() {
  printf 'error: %s\n' "$1" >&2
  printf '  git-integration-repo and git-issue-workflow are separate units with\n' >&2
  printf '  independent versions, and this home holds a pair that do not agree. The\n' >&2
  printf '  library in use is:\n    %s\n' "$_GIW_LIB" >&2
  printf '  Nothing has run. Make them agree:\n' >&2
  printf '    skill-manager sync git-issue-workflow\n' >&2
  printf '  or point at a copy that does:\n' >&2
  printf '    GIT_ISSUE_WORKFLOW_SCRIPTS=/path/to/git-issue-workflow/scripts %s\n' "$0" >&2
  exit 1
}

# `${VAR:-}` and a numeric case, not `-lt`: a lib.sh predating the marker leaves
# the variable UNSET, and `[ "" -lt 1 ]` is a syntax error rather than a
# refusal — which would report the skew as a bug in this file.
case "${WORKTREE_LIB_ABI:-}" in
  ''|*[!0-9]*) _giw_skew "the installed git-issue-workflow lib.sh declares no WORKTREE_LIB_ABI (needs >= $WORKTREE_LIB_ABI_MIN), so it predates the split and cannot be relied on." ;;
esac
[ "$WORKTREE_LIB_ABI" -ge "$WORKTREE_LIB_ABI_MIN" ] \
  || _giw_skew "the installed git-issue-workflow lib.sh is WORKTREE_LIB_ABI $WORKTREE_LIB_ABI, and this skill needs >= $WORKTREE_LIB_ABI_MIN."

# The roll-call. Exactly the functions this skill's scripts call, and nothing
# else: a list that drifted longer than the truth would refuse working homes,
# which is how a version gate gets disabled instead of fixed.
_giw_missing=""
for _f in die info step die_fix contract contract_fail help_guard repo_root assert_parent_clean; do
  command -v "$_f" >/dev/null 2>&1 || _giw_missing="$_giw_missing $_f"
done
[ -z "$_giw_missing" ] \
  || _giw_skew "the installed git-issue-workflow lib.sh declares WORKTREE_LIB_ABI ${WORKTREE_LIB_ABI}, but does not define:$_giw_missing"
[ -n "${PY:-}" ] || _giw_skew "the installed git-issue-workflow lib.sh set no \$PY interpreter, which every manifest read here needs."

# ------------------------------------------------- the integration-only half
#
# `_manifest.py` stays in THIS skill and is reached through $SCRIPT_DIR, which
# lib.sh no longer overwrites: it is the CALLER's directory, and every caller of
# `manifest` lives beside _manifest.py in this scripts/ directory. Anchored on
# this file's own directory as the fallback so a future caller elsewhere in this
# skill still resolves the helper that ships with it.
manifest() { "$PY" "${SCRIPT_DIR:-$INTEGRATION_LIB_DIR}/_manifest.py" "$@"; }

# Default branch of a constituent as its own git sees origin's HEAD, with the
# manifest value as the fallback.
constituent_default_branch() {
  local dir="$1" fallback="${2:-main}" b
  b="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')" || true
  [ -n "$b" ] && { printf '%s\n' "$b"; return 0; }
  printf '%s\n' "$fallback"
}
