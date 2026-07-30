#!/usr/bin/env bash
# bootstrap-home.sh [--root DIR] [options]
#
# Give one checkout — a repo root or a worktree — its own Skill Manager home,
# so every agent launched from it reads and writes that home instead of the
# operator's global one.
#
# This is the ONLY implementation of that sequence. `new-change.sh` calls it
# for every worktree it creates, and a repo's own `scripts/agent-home.sh`
# locates and calls this same file. There is deliberately no second copy of
# the ordering rules: getting them wrong writes into the operator's home,
# which is the one failure this script exists to make impossible.
#
# The order is not cosmetic
# ------------------------
#   clone  ->  point SKILL_MANAGER_HOME at the clone  ->  everything else
#
# `project resolve`, `sync`, `install`, `bind` and friends all write into
# whatever `SKILL_MANAGER_HOME` names (`SkillStore.defaultStore()`), and
# `project resolve` additionally writes a child-home record and a binding
# ledger into that store. Run any of them before the clone exists and they
# land in the global home. So: `skill-manager home clone` is the first
# command, it is the only command that names the source home, and every
# command after it runs with SKILL_MANAGER_HOME exported to the clone.
# `require_local_home` re-asserts that before any mutating step, so the rule
# is enforced by the script rather than remembered by a caller.
#
# What it produces under <root>:
#   .skill-manager/                     the home (a clone of the source home)
#   .skill-manager/home.runtime.json    the launch descriptor (HomeDescriptor)
#   .skill-manager/home.policy.toml     live | frozen (HomePolicy)
#   .skill-manager/bin/launch/{claude,codex,gemini}   launcher shims
#   .claude/ .codex/ .gemini/           agent homes, at the paths the
#                                       descriptor's env block names
#
# Add those to the PARENT repo's root .gitignore, never to a file inside a
# constituent (INTEGRATION.md rule 2).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: bootstrap-home.sh [--root DIR] [--source HOME] [--policy live|frozen]
                         [--print-env] [--force] [--quiet]

  --root DIR       Checkout to give a home to. Default: the nearest enclosing
                   git toplevel — which inside a constituent is the
                   CONSTITUENT, not the integration repo tracking its files.
  --source HOME    Home to clone from. Only ever read. Default: for a LINKED
                   WORKTREE, its project home (the main working tree's), which
                   is the home close-change.sh reconciles it back into; for a
                   main working tree, $SKILL_MANAGER_HOME, else ~/.skill-manager.
                   A --source that disagrees with a worktree's project home is
                   REFUSED, not silently honoured.
  --policy P       Policy to declare on the new home: live (default) or
                   frozen. A home that is ALREADY frozen is never touched.
  --print-env      Print the launch environment as `export` lines and exit.
                   Bootstraps first if needed. Safe to `eval`.
  --force          Re-run the steps on an existing live home. Never applies
                   to a frozen one, and never re-clones over an existing
                   store.
  --quiet          Only report failures.
EOF
}

ROOT=""; SOURCE=""; POLICY="live"; PRINT_ENV=0; FORCE=0; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --source)    SOURCE="${2:?--source needs a directory}"; shift 2 ;;
    --policy)    POLICY="${2:?--policy needs live|frozen}"; shift 2 ;;
    --print-env) PRINT_ENV=1; shift ;;
    --force)     FORCE=1; shift ;;
    --quiet)     QUIET=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "unknown argument: $1" ;;
  esac
done
case "$POLICY" in live|frozen) : ;; *) die "--policy must be live or frozen, got: $POLICY" ;; esac

say() { [ "$QUIET" = 1 ] || info "$*"; }
heading() { [ "$QUIET" = 1 ] || step "$*"; }

# ------------------------------------------------------------------ paths

# checkout_root, not repo_root: a home belongs to a CHECKOUT, and the checkout
# you are standing in inside constituents/deploy-helm is deploy-helm. repo_root
# answers the integration parent there, so a bare `bootstrap-home.sh` run from
# a constituent used to report on (or create) the parent's home instead — the
# same silent wrong-target as new-change.sh, one level quieter because the
# parent's home usually already exists and the run just says "already
# bootstrapped". Falls back to the integration root when there is no git repo
# here at all.
[ -n "$ROOT" ] || ROOT="$(checkout_root 2>/dev/null || repo_root)"
[ -d "$ROOT" ] || die "not a directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"
STORE="$ROOT/.skill-manager"

GLOBAL_HOME="$HOME/.skill-manager"
[ -d "$GLOBAL_HOME" ] && GLOBAL_HOME="$(cd "$GLOBAL_HOME" && pwd -P)"

# ------------------------------------------------- which home this clones FROM
#
# Issue #50. The source and the close-out destination must be THE SAME HOME BY
# CONSTRUCTION, and the only thing both scripts can derive it from without
# consulting the operator's environment is the checkout itself. So:
#
#   a LINKED WORKTREE clones from its PROJECT home — <main working tree>/.skill-manager,
#   which is exactly what close-change.sh reconciles it back into (project_home,
#   one definition, shared).
#
#   a MAIN working tree clones from $SKILL_MANAGER_HOME, else the global home.
#   That is the root -> project tier: there is no project above it to inherit.
#
# The old default was `${SKILL_MANAGER_HOME:-$HOME/.skill-manager}` for BOTH,
# and from a bare shell that made a worktree unclosable from birth: it cloned
# the operator's global home (measured: 845 MB) into the worktree, and
# `home close-out --into <project>/.skill-manager` then blocked on 17 units
# before any work existed, printing a remedy that would have synced those 17
# GLOBAL units into the project home. The launch shims export
# SKILL_MANAGER_HOME and never saw it; a human running the scripts by hand did.
PROJECT_HOME=""
project_home "$ROOT" >/dev/null 2>&1 && PROJECT_HOME="$(project_home "$ROOT")"
[ -n "$PROJECT_HOME" ] && [ -d "$PROJECT_HOME" ] \
  && PROJECT_HOME="$(cd "$PROJECT_HOME" && pwd -P)"

IS_WORKTREE=0
is_linked_worktree "$ROOT" && IS_WORKTREE=1 || true

if [ -n "$SOURCE" ]; then
  SOURCE_ORIGIN="--source"
elif [ "$IS_WORKTREE" = 1 ]; then
  # Refuse rather than fall back to the global home. Falling back is the bug:
  # it produces a worktree whose home came from a place close-out cannot
  # reconcile it into, and the failure surfaces at teardown, after the work.
  [ -d "$PROJECT_HOME" ] || die "this is a worktree of $(dirname "$PROJECT_HOME"), and that
  checkout has no Skill Manager home at
    $PROJECT_HOME
  A worktree home is a copy of its PROJECT home, and close-change.sh reconciles
  it back into that same path. Cloning from anywhere else — the global home
  included — makes this worktree unclosable from birth (issue #50).
  Give the project its home first, then re-run:
    $SCRIPT_DIR/bootstrap-home.sh --root '$(dirname "$PROJECT_HOME")'
  or name a source deliberately with --source."
  SOURCE="$PROJECT_HOME"
  SOURCE_ORIGIN="the project home of $(dirname "$PROJECT_HOME")"
else
  SOURCE="${SKILL_MANAGER_HOME:-$GLOBAL_HOME}"
  SOURCE_ORIGIN="\$SKILL_MANAGER_HOME"
  [ -n "${SKILL_MANAGER_HOME:-}" ] || SOURCE_ORIGIN="the global home"
  # A home cannot be cloned from itself, and this is how it happens by
  # accident: an agent launched through THIS checkout's shims has
  # SKILL_MANAGER_HOME already pointing at the home being (re-)bootstrapped, so
  # `scripts/agent-home.sh` — documented as idempotent — died on the
  # bootstrap-from-itself guard below. The tier above a project home is the
  # global home, so say so and use it.
  if [ -d "$SOURCE" ] && [ "$(cd "$SOURCE" && pwd -P)" = "$STORE" ]; then
    SOURCE="$GLOBAL_HOME"
    SOURCE_ORIGIN="the global home (\$SKILL_MANAGER_HOME names this checkout's own home)"
  fi
fi

# -P so a symlinked source and a symlinked target cannot compare unequal
# while naming the same directory.
[ -d "$SOURCE" ] || die "source home does not exist: $SOURCE ($SOURCE_ORIGIN)"
SOURCE="$(cd "$SOURCE" && pwd -P)"

# The agreement, asserted. Only reachable via an explicit --source, since the
# defaults above make the two equal by construction — which is the point: this
# turns the one remaining way to disagree into a refusal instead of a worktree
# that cannot be closed.
if [ "$IS_WORKTREE" = 1 ] && [ -n "$PROJECT_HOME" ] && [ "$SOURCE" != "$PROJECT_HOME" ]; then
  die "refusing to clone this worktree's home from a home it cannot be closed into.
    source (--source):  $SOURCE
    close-out --into:   $PROJECT_HOME
  close-change.sh reconciles <worktree>/.skill-manager INTO the project home, so
  a home cloned from anywhere else arrives holding units that home never had —
  every one of them a blocker at teardown (issue #50). Drop --source to use the
  project home, or bootstrap the project home from $SOURCE first so the two
  agree."
fi

# The guard. A bootstrap that can target the operator's own home is not a
# bootstrap, it is the bug — so the refusals come before anything is read,
# written, or exported.
[ "$ROOT" = "$HOME" ]          && die "refusing to bootstrap \$HOME as a project checkout ($ROOT)"
[ "$STORE" = "$GLOBAL_HOME" ]  && die "refusing to write the global home at $GLOBAL_HOME"
[ "$STORE" = "$SOURCE" ]       && die "refusing to bootstrap a home from itself ($STORE)"

# Every mutating step goes through this, so "point SKILL_MANAGER_HOME at the
# clone first" is a property of the script and not of the caller's memory.
require_local_home() {
  local what="$1"
  [ "${SKILL_MANAGER_HOME:-}" = "$STORE" ] \
    || die "$what: SKILL_MANAGER_HOME is '${SKILL_MANAGER_HOME:-unset}', not the local home $STORE"
  [ "$SKILL_MANAGER_HOME" != "$GLOBAL_HOME" ] \
    || die "$what: SKILL_MANAGER_HOME resolves to the global home"
  [ -d "$STORE" ] || die "$what: local home $STORE does not exist yet"
}

# -------------------------------------------------------------------- CLI

# Which skill-manager runs this. Same first rule as
# HomeDescriptor.resolveCli — an explicit SKILL_MANAGER_CLI pin wins — but
# deliberately NOT the same order after that: PATH comes before a CLI the
# checkout itself ships, because a checkout's copy can be older than the
# installed release. (Measured on this repo: a parent worktree carries the
# parent's *committed snapshot* of a constituent, which predated `home`
# entirely, while the main tree's working copy had it.)
#
# The capability probe exists because `home` is newer than the released CLI:
# without it a stale skill-manager is picked and fails deep inside the
# sequence, after directories have already been created.
#
# The probe reads the help TEXT rather than the exit status on purpose: the
# released 0.19.2 answers an unknown subcommand by printing top-level usage and
# exiting 0 (newer builds exit 2), so a status-only probe accepts a CLI with no
# `home` command at all and the failure surfaces later, mid-sequence.
cli_has_home() { "$1" home clone --help 2>&1 | grep -q -- '--to'; }

pick_cli() {
  local pinned="${SKILL_MANAGER_CLI:-}" c
  if [ -n "$pinned" ]; then
    [ -x "$pinned" ] || die "SKILL_MANAGER_CLI is not executable: $pinned"
    cli_has_home "$pinned" || die "SKILL_MANAGER_CLI ($pinned) has no \`home clone\` subcommand"
    printf '%s\n' "$pinned"; return 0
  fi
  c="$(command -v skill-manager || true)"
  if [ -n "$c" ] && cli_has_home "$c"; then printf '%s\n' "$c"; return 0; fi
  # A CLI the checkout itself ships, then one the enclosing INTEGRATION repo
  # ships. The second entry is what lets a constituent home find a capable
  # build: bootstrapping constituents/deploy-helm searched only deploy-helm,
  # which ships no skill-manager, so it died — or, worse, the caller exported
  # SKILL_MANAGER_CLI once by hand and the pin was never recorded anywhere.
  # The integration parent is where the epic build actually lives.
  local candidate integration
  integration="$(outermost_integration_root "$ROOT")"
  for candidate in "$ROOT/skill-manager" "$ROOT"/constituents/*/skill-manager \
                   ${integration:+"$integration/skill-manager" "$integration"/constituents/*/skill-manager}; do
    [ -x "$candidate" ] || continue
    [ -d "$candidate" ] && continue
    if cli_has_home "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  done
  die "no skill-manager CLI with a \`home\` subcommand was found.
  ${c:+  on PATH: $c (too old — \`home clone\` is missing)
}  Set SKILL_MANAGER_CLI to a build that has it, or install a newer skill-manager.
  Without it a worktree cannot get its own home, and an agent would run
  against the operator's global home."
}

CLI="$(pick_cli)"

# --------------------------------------------------------------- policy read

# HomePolicy is the predicate — asking the CLI keeps this script from becoming
# a second parser of home.policy.toml.
home_policy() { "$CLI" home policy --home "$STORE" 2>/dev/null | awk '/^policy:/ {print $2}'; }

# The agent-home directories this home declares. Read from the descriptor
# (HomeDescriptor.envFor) rather than hardcoded here, so this script cannot
# create `.claude` in a place the launcher will not look.
descriptor_env_dirs() {
  "$CLI" home describe --home "$STORE" --home-root "$ROOT" --json 2>/dev/null | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
env = d.get("env") or {}
for key in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_HOME"):
    value = env.get(key)
    if value:
        print(value)
'
}

# ------------------------------------------------------------- the CLI pin

# <home>/bin/cli/skill-manager decides which build every launch from this home
# runs. Both readers already exist — the generated launcher checks it before
# PATH, and HomeDescriptor.resolveCli documents it as rule 3.
#
# Two ways it goes wrong, and the second is why this is a function rather than
# a line inside the clone block:
#
#   * Empty. Every shim falls through to PATH, which on this machine is the
#     released 0.19.2 — no `exec`, no `home`, no `home close-out`. The shims
#     then fail unless the caller exports SKILL_MANAGER_CLI, which is the very
#     thing the shims exist to avoid.
#   * Occupied by `home shims`' own generated shim, which RESOLVES VIA PATH by
#     design (it is written to stay valid if the home is copied elsewhere).
#     Newer builds write it during step 5 above, so the old
#     `[ ! -e ]` guard saw an occupied slot and skipped the pin — and the home
#     ended up pointing at the released CLI anyway. Measured: the root home,
#     bootstrapped before `home shims` filled the slot, carries the absolute
#     pin; every constituent home bootstrapped after it carries the
#     PATH-resolving shim and therefore finds 0.19.2. That version answers
#     `home close-out --help` with top-level usage and exit 0, which is the
#     whole reason close-change.sh probes help TEXT instead of exit status.
#
# So: write the pin when the slot is empty, and REPLACE the generated
# PATH-resolving shim, which is not a tool anyone installed. Anything else in
# that slot is left alone — it could be a real CLI dep.
#
# REPLACING IT MEANS INHERITING ITS OBLIGATIONS. `LauncherShims.cliScript()` is
# the other author of this file, and anything it does that is about the FILE
# rather than about PATH resolution has to be carried across here or this
# script silently reverts it. That already happened once: cliScript exports
# SKILL_MANAGER_HOME from the script's own location so the entrypoint binds the
# home it lives in, this pin did not, and every home bootstrapped through here
# — all 17 of them — got an entrypoint that wrote to whichever home the caller
# was carrying. Two paths that should agree, didn't, and nothing detected it.
# Before changing the body below, diff it against cliScript().
#
# Deliberately absolute, and deliberately without a PATH fallback: falling back
# is the behaviour being removed, and a silent downgrade to a CLI missing whole
# subcommands is worse than a loud failure.
PIN_MARKER='git-integration-repo:cli-pin'

ensure_cli_pin() {
  local slot="$STORE/bin/cli/skill-manager" why=""
  if [ ! -e "$slot" ]; then
    why="empty"
  elif command grep -q -F "$PIN_MARKER" "$slot" 2>/dev/null; then
    why="refreshing this script's own pin"
  elif command grep -q -F 'home shims' "$slot" 2>/dev/null; then
    why="replacing the PATH-resolving shim from \`home shims\`"
  else
    return 0    # someone else's tool; not ours to overwrite
  fi
  say "cli pin:   $slot ($why) -> $CLI"
  mkdir -p "$STORE/bin/cli"
  cat > "$slot" <<EOF
#!/usr/bin/env bash
# $PIN_MARKER — written by git-integration-repo's bootstrap-home.sh.
#
# The skill-manager build that goes with THIS home. The launcher shims and
# HomeDescriptor.resolveCli both look here before PATH, so a home does not
# depend on whichever version happens to be installed globally — the released
# CLI on PATH can be older than the build the home was created with and lack
# whole subcommands (\`exec\`, \`home\`, \`home close-out\`).
#
# There is no PATH fallback on purpose. Falling through to an older CLI is the
# failure this file exists to remove, and that CLI answers unknown subcommands
# with top-level usage and exit 0 — a downgrade that looks like success.
set -euo pipefail

# BIND THE HOME. This file REPLACES the entrypoint \`skill-manager home shims\`
# generates (see ensure_cli_pin), and that generated script exports
# SKILL_MANAGER_HOME from its own location. Replacing it without carrying the
# export across un-fixed a fix: the pin exec'd the CLI with whatever
# SKILL_MANAGER_HOME the caller happened to carry, which unset is the
# operator's global home. Measured on all 17 homes bootstrapped before this
# line existed — \`<home>/bin/cli/skill-manager --version\` against an empty
# decoy created TEN directories in the decoy. So the one command whose entire
# purpose is "the CLI for THIS home" was the command most likely to mutate a
# different one, and it is the command the onboarding checklist tells an agent
# to run to prove the home works.
#
# Derived from this script's own location rather than baked in, so a home that
# is copied to a new root binds the copy. No override on purpose, for the same
# reason there is no PATH fallback: deferring to the environment would make
# this indistinguishable from the bare CLI. Name a different home with --home.
self_dir="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd -P)"
export SKILL_MANAGER_HOME="\$(cd -- "\$self_dir/../.." && pwd -P)"

cli="\${SKILL_MANAGER_CLI:-$CLI}"
if [ ! -x "\$cli" ]; then
  echo "skill-manager: the CLI pinned for this home is missing or not executable:" >&2
  echo "  \$cli" >&2
  echo "  Re-pin it: bootstrap-home.sh --root '$ROOT' --force" >&2
  exit 127
fi
exec "\$cli" "\$@"
EOF
  chmod +x "$slot"
}

bootstrapped=0; frozen_skip=0
# Whether THIS run actually ran `home clone`. Distinct from `bootstrapped`, and
# the distinction is the #38 defect: the closing caveat about skipped directories
# was gated on `bootstrapped`, which stays 0 on the `--force` path — so
# `--force` against an existing non-empty home printed "The home is a clone:
# cache/, tmp/, logs/, venvs/, tools/ and npm/ were not copied" about a clone
# that had not happened, and named a `sync --force-scripts` remedy for shims
# that were never broken. `--force` is exactly the invocation the onboarding
# recipe uses, so it was the common case rather than the edge one.
cloned=0
if [ -e "$STORE/home.runtime.json" ]; then
  existing="$(home_policy)"
  if [ "$existing" = "frozen" ]; then
    # A frozen home's contents are evidence (HomePolicy). Re-running shims,
    # the descriptor or the drift baseline would all be writes, so a frozen
    # home is reported and then left exactly as it is — including when the
    # caller passed --force.
    say "home:      $STORE (frozen — left untouched)"
    bootstrapped=1
    frozen_skip=1
    FORCE=0
  elif [ "$FORCE" = 0 ]; then
    say "home:      $STORE (already bootstrapped, policy ${existing:-unknown})"
    bootstrapped=1
  fi
fi

# ------------------------------------------------------------------- clone

if [ "$bootstrapped" = 0 ]; then
  heading "Bootstrapping a Skill Manager home for $ROOT"
  say "source:    $SOURCE  ($SOURCE_ORIGIN)"
  say "cli:       $CLI"
  # Printed for a worktree because it is the fact the operator cannot otherwise
  # see, and the one #50 got wrong: this home will have to reconcile back into
  # exactly the home it came from.
  [ "$IS_WORKTREE" = 1 ] && say "close-out into: $PROJECT_HOME  (same home — issue #50)" || true

  need_clone=1
  if [ -e "$STORE" ]; then
    # `home clone` requires an absent or empty destination; say so here rather
    # than letting it fail after the guard work is done.
    [ -d "$STORE" ] || die "$STORE exists and is not a directory"
    if [ -n "$(ls -A "$STORE" 2>/dev/null)" ]; then
      # --force re-runs the steps AFTER the clone on an existing live home. It
      # never re-clones: a second clone over a home an agent has been editing
      # would be the destructive interpretation of the word.
      [ "$FORCE" = 1 ] \
        || die "$STORE exists and is not empty — inspect it, then pass --force to re-run the steps on it, or remove it"
      need_clone=0
      say "existing:  $STORE (--force: re-running the steps, not re-cloning)"
    fi
  fi

  # 1. Clone. The only step that names the source, and it only reads it.
  if [ "$need_clone" = 1 ]; then
    "$CLI" home clone --from "$SOURCE" --to "$STORE" \
      || die "home clone failed; $STORE is not usable"
    cloned=1
  fi

  # 2. From here on, every command binds to the clone.
  export SKILL_MANAGER_HOME="$STORE"
  require_local_home "bootstrap"

  # 3. live first, so `home shims` (which refuses on a frozen home) can run.
  #    A requested `frozen` is applied last, once the home is complete.
  "$CLI" home policy live --home "$STORE" >/dev/null || die "could not declare the home live"

  # 4. Agent homes, at the paths the descriptor names — not at paths this
  #    script decides. HomeDescriptor.envFor owns that layout.
  descriptor_env_dirs | while IFS= read -r dir; do [ -n "$dir" ] && mkdir -p "$dir"; done

  # 5. Launcher shims, then the descriptor last so it records the finished
  #    state (policy, resolved CLI, gateway ownership, unit snapshot).
  "$CLI" home shims --home "$STORE" >/dev/null || die "could not write the launcher shims"

  # 5b. see ensure_cli_pin below — it runs for existing homes too.
  ensure_cli_pin

  "$CLI" home describe --home "$STORE" --home-root "$ROOT" --write >/dev/null \
    || die "could not write home.runtime.json"

  # 6. Baseline the drift digest, so a later sync has something to be a
  #    change *from*. Without it the first `exec` after a sync cannot tell
  #    "changed" from "never recorded".
  "$CLI" home drift --home "$STORE" --record >/dev/null 2>&1 || true

  if [ "$POLICY" = frozen ]; then
    "$CLI" home policy frozen --home "$STORE" >/dev/null || die "could not freeze the home"
  fi
fi

export SKILL_MANAGER_HOME="$STORE"

# Repair an ALREADY-bootstrapped home too. Homes created before this pin
# existed — or created after `home shims` started filling the slot itself —
# carry the PATH-resolving shim and quietly run whatever CLI is installed
# globally. Re-running bootstrap-home.sh should fix that without --force,
# because the operator has no way to know the slot is wrong. A frozen home is
# evidence and is never written, here as everywhere else.
if [ "$bootstrapped" = 1 ] && [ "$frozen_skip" = 0 ]; then
  ensure_cli_pin
fi

# --------------------------------------------------------------- assertions

# Asserted, not reported. Each of these has a way of being quietly false, and
# a quietly false one means an agent silently running against another home.
verify() {
  local descriptor="$STORE/home.runtime.json"
  [ -f "$descriptor" ] || die "verify: $descriptor is missing"

  local policy; policy="$(home_policy)"
  [ -n "$policy" ] || die "verify: could not read the home policy"

  # The launch environment comes from `skill-manager exec`, which is the same
  # code path a shim takes (LaunchEnv). Asking it is how we learn what an
  # agent would actually get, rather than what we hope it would get.
  local env_out
  env_out="$("$CLI" exec --home "$STORE" --no-reconcile --ack-drift --print-env)" \
    || die "verify: \`skill-manager exec --print-env\` refused this home"

  local declared_home declared_claude launch_path
  declared_home="$(printf '%s\n' "$env_out" | awk -F= '/^SKILL_MANAGER_HOME=/ {print substr($0,index($0,"=")+1)}')"
  declared_claude="$(printf '%s\n' "$env_out" | awk -F= '/^CLAUDE_CONFIG_DIR=/ {print substr($0,index($0,"=")+1)}')"
  launch_path="$(printf '%s\n' "$env_out" | awk -F= '/^PATH=/ {print substr($0,index($0,"=")+1)}')"

  [ "$declared_home" = "$STORE" ] \
    || die "verify: descriptor SKILL_MANAGER_HOME is $declared_home, expected $STORE"
  case "$declared_claude" in
    "$ROOT"/*) : ;;
    *) die "verify: CLAUDE_CONFIG_DIR is $declared_claude, which is outside $ROOT" ;;
  esac
  [ "$declared_claude" != "$HOME/.claude" ] \
    || die "verify: CLAUDE_CONFIG_DIR still points at the operator's ~/.claude"

  # A shim must work with NO environment help — that is its entire purpose.
  # It resolves its CLI as SKILL_MANAGER_CLI, then <home>/bin/cli/skill-manager,
  # then PATH, so at least one of the last two has to be a capable build or
  # every launch from this home fails at exec time.
  local home_cli="$STORE/bin/cli/skill-manager" path_cli
  path_cli="$(command -v skill-manager || true)"
  if [ -x "$home_cli" ] && cli_has_home "$home_cli"; then :
  elif [ -n "$path_cli" ] && cli_has_home "$path_cli"; then :
  else
    die "verify: the shims in $STORE/bin/launch cannot find a usable skill-manager.
  Neither $home_cli nor a CLI on PATH answers \`home clone\`, so every launch
  from this home would fail unless the caller exports SKILL_MANAGER_CLI."
  fi

  # claude/codex must resolve to THIS home's shims. Resolving to another
  # home's bin/ is the failure mode LaunchEnv prunes for, so check it on the
  # launch PATH rather than on the ambient one.
  local agent found
  for agent in claude codex; do
    found="$(PATH="$launch_path" command -v "$agent" 2>/dev/null || true)"
    [ -n "$found" ] || die "verify: $agent does not resolve on the launch PATH"
    [ "$found" = "$STORE/bin/launch/$agent" ] \
      || die "verify: $agent resolves to $found, not this home's shim $STORE/bin/launch/$agent"
  done

  # Advisory, not fatal: another home's bin/ surviving on the launch PATH.
  # LaunchEnv prunes foreign-home bin/ directories by walking at most three
  # parents up looking for a store root, so it removes <other>/bin/cli but
  # NOT a deeper one such as
  # <other>/plugin-marketplace/plugins/<plugin>/bin. A tool resolved from
  # there reads and writes that other home. Reported rather than refused
  # because the bound lives in skill-manager, not here, and a refusal would
  # make every bootstrap fail on a shell that has such an entry.
  local foreign
  foreign="$(printf '%s\n' "$launch_path" | tr ':' '\n' \
    | grep -F '/.skill-manager/' | grep -v "^$STORE/" || true)"
  if [ -n "$foreign" ]; then
    printf '  WARNING: another home'"'"'s bin/ survives on the launch PATH:\n' >&2
    printf '    %s\n' $foreign >&2
    printf '    Tools resolved from there read and write that home. LaunchEnv only\n' >&2
    printf '    prunes entries within three levels of a store root; remove it from\n' >&2
    printf '    your shell PATH until skill-manager prunes it too.\n' >&2
  fi

  [ "$QUIET" = 1 ] || {
    info "home:      $STORE"
    info "policy:    $policy"
    info "descriptor:$descriptor"
    info "shims:     $STORE/bin/launch (claude, codex, gemini)"
    info "verified:  descriptor env inside $ROOT; claude/codex resolve to this home's shims"
  }
}

if [ "$frozen_skip" = 1 ]; then
  say "verify:    skipped — a frozen home is not modified, so it is not repaired either"
else
  verify
fi

if [ "$PRINT_ENV" = 1 ]; then
  "$CLI" exec --home "$STORE" --no-reconcile --ack-drift --print-env \
    | while IFS= read -r line; do printf 'export %s=%q\n' "${line%%=*}" "${line#*=}"; done
  exit 0
fi

[ "$QUIET" = 1 ] || cat >&2 <<EOF

Launch an agent bound to this home:
  $STORE/bin/launch/claude
or put the shims on PATH for this shell:
  eval "\$($SCRIPT_DIR/bootstrap-home.sh --root $ROOT --print-env)"
EOF

# Only after a clone actually ran: the caveat is about what just happened, so it
# is gated on `cloned`, not on `bootstrapped`. See the note beside `cloned=0`.
[ "$QUIET" = 1 ] || [ "$cloned" = 0 ] || cat >&2 <<EOF

The home is a clone: cache/, tmp/, logs/, venvs/, tools/ and npm/ were not
copied. Any CLI shim whose target lived under one of those is reported by the
clone above and is re-provisioned with:
  SKILL_MANAGER_HOME=$STORE $CLI sync --force-scripts
EOF
