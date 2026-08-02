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
# Which copy of bootstrap-home.sh it finds, in order:
#
#   0. $INTEGRATION_BOOTSTRAP_HOME            an explicit pin always wins
#   1. <repo>/scripts/bootstrap-home.sh       this repo ships the skill itself
#                                             (true in git-integration-repo's own
#                                             checkout, and in any repo that
#                                             vendored the whole scripts/ dir)
#   2. <repo>/constituents/git-integration-repo/scripts/bootstrap-home.sh
#                                             an integration repo tracking the
#                                             skill as a constituent — the copy
#                                             that is reviewed alongside the repo
#   3. $SKILL_MANAGER_HOME/skills/git-integration-repo/scripts/bootstrap-home.sh
#   4. $HOME/.skill-manager/skills/git-integration-repo/scripts/bootstrap-home.sh
#
# Rungs 3 and 4 are the installed skill, read and never written. Rung 4 is the
# operator's GLOBAL home and is deliberately last: on a fresh machine it is the
# only copy that exists, and reading an implementation from it is not the
# failure this whole mechanism exists to prevent — writing a home into it is,
# and bootstrap-home.sh refuses that on its own. It is announced rather than
# silent, because "the bootstrap ran" and "the bootstrap you reviewed ran" are
# different facts.
#
# There is no rung that resolves a skill-manager CLI, or this file, by a path
# relative to its own location beyond the repo root above it; see selftest.sh's
# "No script resolves a skill-manager by a path relative to itself".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ACTIVE_HOME="${SKILL_MANAGER_HOME:-$HOME/.skill-manager}"

candidates=(
  ${INTEGRATION_BOOTSTRAP_HOME:+"$INTEGRATION_BOOTSTRAP_HOME"}
  "$ROOT/scripts/bootstrap-home.sh"
  "$ROOT/constituents/git-integration-repo/scripts/bootstrap-home.sh"
  "$ACTIVE_HOME/skills/git-integration-repo/scripts/bootstrap-home.sh"
  "$HOME/.skill-manager/skills/git-integration-repo/scripts/bootstrap-home.sh"
)

for candidate in "${candidates[@]}"; do
  [ -f "$candidate" ] || continue
  case "$candidate" in
    "$HOME/.skill-manager/"*)
      [ "$ACTIVE_HOME" = "$HOME/.skill-manager" ] || printf \
        'note: running the bootstrap from the GLOBAL home (%s) — the active home\n      %s does not carry git-integration-repo.\n' \
        "$candidate" "$ACTIVE_HOME" >&2
      ;;
  esac
  exec bash "$candidate" --root "$ROOT" "$@"
done

cat >&2 <<EOF
error: could not find git-integration-repo's scripts/bootstrap-home.sh.
Looked in:
$(printf '  %s\n' "${candidates[@]}")

Install the skill (skill-manager install github:haydenrear/git-integration-skill)
or point INTEGRATION_BOOTSTRAP_HOME at a checkout of it. Do not hand-roll the
bootstrap: it must clone the home before anything else touches one, or it
writes into ~/.skill-manager.
EOF
exit 1
