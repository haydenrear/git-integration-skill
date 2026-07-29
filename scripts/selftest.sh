#!/usr/bin/env bash
# selftest.sh [--keep]
#
# Prove the worktree-home lifecycle on a DISPOSABLE fixture, from a BARE SHELL.
#
# Why this exists
# ---------------
# Issue #50 was a disagreement between two scripts about which home a worktree
# belongs to, and it was invisible to every existing check: `bootstrap-home.sh`
# exited 0, the home it produced was a perfectly valid home, and the damage only
# showed up at teardown, where `close-change.sh` blocked on 17 units the
# worktree had never touched. Nothing failed. Nothing could fail — no assertion
# anywhere named the source and the destination in the same breath.
#
# So the fixture is built to make that pair observable, and every check below is
# about BYTES OR FILE PRESENCE, never about an exit code:
#
#   * the decoy GLOBAL home holds a unit no other home has  (global-only-unit)
#   * the fixture PROJECT home holds a unit no other home has (project-only-unit)
#
# After a bare-shell bootstrap, exactly one of those two names may appear in the
# worktree's home, and which one it is answers "where did this come from" with a
# directory rather than with a log line. Both halves are asserted: a check that
# only looked for the project unit would pass just as happily on a home that
# carried both.
#
# BARE SHELL is load-bearing. SKILL_MANAGER_HOME is UNSET for every invocation
# here, because that is the shape #50 lives in: the launch shims export it and
# so never met the bug, while a human running these scripts by hand does not.
# A self-test that exported it would be testing the one configuration that
# already worked.
#
# Nothing outside the scratch directory is read or written: HOME is redirected
# into the fixture, so the "global home" these scripts fall back to IS the decoy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) printf 'usage: selftest.sh [--keep]\n' >&2; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ------------------------------------------------------------------- the CLI

# A capable build, pinned for every child. The fixture repos ship no
# skill-manager and sit outside any integration repo, so pick_cli has nowhere
# else to look, and PATH on this machine is the released build with no `home`
# subcommand at all. Refuse loudly rather than "skip": a skipped check reports
# the same green as a passing one.
CLI="${SKILL_MANAGER_CLI:-}"
if [ -z "$CLI" ]; then
  for c in "$SCRIPT_DIR/../../skill-manager/skill-manager" \
           "$SCRIPT_DIR/../../../skill-manager/skill-manager"; do
    [ -f "$c" ] && [ -x "$c" ] && { CLI="$(cd "$(dirname "$c")" && pwd -P)/$(basename "$c")"; break; }
  done
fi
[ -n "$CLI" ] || die "no skill-manager CLI. Set SKILL_MANAGER_CLI to a build with \`home clone\`."
"$CLI" home clone --help 2>&1 | command grep -q -- '--to' \
  || die "SKILL_MANAGER_CLI ($CLI) has no \`home clone\` subcommand"

# ------------------------------------------------------------------ scoring

PASSED=0; FAILED=0
# Predicates as functions, never as a `case` inside "$( )": an unquoted `)` in a
# case pattern closes the command substitution, and the check then fails for a
# reason that has nothing to do with what it is asserting.
contains()  { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
ends_with() { case "$2" in *"$1") return 0 ;; esac; return 1; }
exists()    { [ -e "$1" ]; }
absent_pattern() { ! command grep -q "$1" "$2"; }
absent()    { [ ! -e "$1" ]; }
executable() { [ -n "${1:-}" ] && [ -f "$1" ] && [ -x "$1" ]; }
yesno()     { if "$@"; then printf 1; else printf 0; fi; }
ok()   { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$1" >&2; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n      %s\n' "$1" "$2" >&2; }
check() { if [ "$1" = 1 ]; then ok "$2"; else bad "$2" "$3"; fi; }

# ------------------------------------------------------------------ fixture

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gir-selftest-XXXXXX")"
SCRATCH="$(cd "$SCRATCH" && pwd -P)"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$SCRATCH"; }
trap cleanup EXIT
[ "$KEEP" = 1 ] && info "scratch:   $SCRATCH (kept)" || true

FAKE_HOME="$SCRATCH/fakehome"
GLOBAL_HOME="$FAKE_HOME/.skill-manager"
PROJ="$SCRATCH/proj"
PROJ_HOME="$PROJ/.skill-manager"

# A directory is a home when it has installed/ + skills/ (LaunchEnv.looksLikeStoreRoot,
# which NotAHomeException reuses). Scaffolded rather than installed through the
# CLI on purpose: `install` projects units into agent homes, and a self-test that
# needed the projection machinery to be correct in order to test the home
# machinery would fail for reasons it is not about.
seed_home() {
  local home="$1" unit="$2"
  mkdir -p "$home/installed" "$home/skills/$unit"
  cat > "$home/skills/$unit/SKILL.md" <<EOF
---
name: $unit
description: git-integration-repo selftest marker unit
---
Present only in the home that was seeded with it.
EOF
  cat > "$home/skills/$unit/skill-manager.toml" <<EOF
[skill]
name = "$unit"
version = "0.1.0"
description = "git-integration-repo selftest marker unit"
EOF
}

mkdir -p "$FAKE_HOME"
seed_home "$GLOBAL_HOME" "global-only-unit"

mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email selftest@example.invalid
git -C "$PROJ" config user.name "selftest"
printf 'fixture\n' > "$PROJ/README.md"
git -C "$PROJ" add -A
git -C "$PROJ" -c commit.gpgsign=false commit -qm "fixture"
seed_home "$PROJ_HOME" "project-only-unit"

# Every child runs the way an operator does: no SKILL_MANAGER_HOME, HOME
# pointing at the decoy so the "global home" fallback is the decoy, and
# user.home overridden because the JVM on macOS derives it from the OS and
# ignores $HOME.
bare() {
  env -u SKILL_MANAGER_HOME \
      HOME="$FAKE_HOME" \
      JAVA_TOOL_OPTIONS="-Duser.home=$FAKE_HOME" \
      SKILL_MANAGER_CLI="$CLI" \
      "$@"
}

# ------------------------------------------- 1. where a worktree home comes from

step "A worktree home is a copy of its PROJECT home (#50)"

WT="$SCRATCH/proj-T1"
WT2="$SCRATCH/proj-T2"
git -C "$PROJ" worktree add -q -b feature/T1 "$WT" main
git -C "$PROJ" worktree add -q -b feature/T2 "$WT2" main

BOOTSTRAP_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT" > "$SCRATCH/bootstrap.log" 2>&1 \
  || BOOTSTRAP_RC=$?
[ "$BOOTSTRAP_RC" = 0 ] || command sed 's/^/      /' "$SCRATCH/bootstrap.log" >&2

WT_HOME="$WT/.skill-manager"
check "$(yesno exists "$WT_HOME/skills/project-only-unit")" \
  "the_worktree_home_carries_the_project_homes_unit" \
  "$WT_HOME/skills/project-only-unit is missing (bootstrap rc=$BOOTSTRAP_RC)"
check "$(yesno absent "$WT_HOME/skills/global-only-unit")" \
  "the_worktree_home_does_not_carry_the_global_homes_unit" \
  "$WT_HOME/skills/global-only-unit exists — cloned from $GLOBAL_HOME"

# --------------------------------------------- 2. where close-out reconciles to

step "close-change.sh reconciles into that SAME home"

# Deliberately run from a SIBLING WORKTREE, not from the project root: --into
# used to be derived from checkout_root(), i.e. from $PWD, so where the operator
# stood changed which home the work was reconciled into.
CLOSE_RC=0
( cd "$WT2" && bare bash "$SCRIPT_DIR/close-change.sh" "$WT" --dry-run ) \
  > "$SCRATCH/closeout.log" 2>&1 || CLOSE_RC=$?

INTO_LINE="$(command grep -m1 '^  into:' "$SCRATCH/closeout.log" || true)"
check "$(yesno ends_with "$PROJ_HOME" "$INTO_LINE")" \
  "close_out_reconciles_into_the_home_the_worktree_was_cloned_from" \
  "expected 'into: $PROJ_HOME', got '${INTO_LINE:-<no into: line>}'"

check "$(yesno command grep -q 'gate:      clean' "$SCRATCH/closeout.log")" \
  "a_freshly_bootstrapped_worktree_holds_nothing_that_removing_it_would_destroy" \
  "the gate did not report clean (rc=$CLOSE_RC); see $SCRATCH/closeout.log"
check "$(yesno absent_pattern 'BLOCKED' "$SCRATCH/closeout.log")" \
  "a_freshly_bootstrapped_worktree_is_blocked_by_nothing" \
  "$(command grep -c 'BLOCKED' "$SCRATCH/closeout.log" || true) blockers before any work existed"

# ------------------------------------------------- 3. the remedy an operator runs

step "A printed remedy names a CLI that exists"

# Real work in the worktree home: a unit the project home has never seen. This
# is what the gate is FOR, and it is the only way to make it print a remedy.
mkdir -p "$WT_HOME/skills/wt-only-unit"
cat > "$WT_HOME/skills/wt-only-unit/SKILL.md" <<'EOF'
---
name: wt-only-unit
description: work that only exists in the worktree home
---
EOF
cat > "$WT_HOME/skills/wt-only-unit/skill-manager.toml" <<'EOF'
[skill]
name = "wt-only-unit"
version = "0.1.0"
description = "work that only exists in the worktree home"
EOF

( cd "$WT2" && bare bash "$SCRIPT_DIR/close-change.sh" "$WT" --dry-run ) \
  > "$SCRATCH/blocked.log" 2>&1 || true

REMEDY="$(command grep -m1 '^      run: ' "$SCRATCH/blocked.log" | command sed 's/^      run: //' || true)"
REMEDY_CMD="${REMEDY%% *}"
check "$(yesno test -n "$REMEDY")" \
  "the_gate_blocks_on_a_unit_only_the_worktree_home_has" \
  "no 'run:' remedy was printed; see $SCRATCH/blocked.log"
check "$(yesno executable "$REMEDY_CMD")" \
  "the_printed_remedy_names_an_executable_that_exists" \
  "remedy command '${REMEDY_CMD:-<none>}' is not an executable file — a bare \`skill-manager\` here is the stale PATH build, which exits 2"
check "$(yesno contains "home sync --from " "$REMEDY")" \
  "the_rewritten_remedy_is_still_the_command_the_gate_ran" \
  "remedy lost its subcommand: '$REMEDY'"

# ------------------------------------------------------------- 4. the refusals

step "A source that cannot be closed into is refused, not honoured"

bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT2" --source "$GLOBAL_HOME" \
  > "$SCRATCH/refuse-source.log" 2>&1 || true
check "$(yesno absent "$WT2/.skill-manager")" \
  "a_source_that_disagrees_with_the_project_home_creates_no_home" \
  "$WT2/.skill-manager exists — the disagreeing source was honoured"

NOHOME="$SCRATCH/nohome"
mkdir -p "$NOHOME"
git -C "$NOHOME" init -q -b main
git -C "$NOHOME" config user.email selftest@example.invalid
git -C "$NOHOME" config user.name "selftest"
printf 'x\n' > "$NOHOME/README.md"
git -C "$NOHOME" add -A
git -C "$NOHOME" -c commit.gpgsign=false commit -qm "fixture"
WT3="$SCRATCH/nohome-T3"
git -C "$NOHOME" worktree add -q -b feature/T3 "$WT3" main
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT3" > "$SCRATCH/refuse-nohome.log" 2>&1 || true
check "$(yesno absent "$WT3/.skill-manager")" \
  "a_worktree_whose_project_has_no_home_creates_no_home" \
  "$WT3/.skill-manager exists — it was cloned from the global home instead"
check "$(yesno absent "$NOHOME/.skill-manager")" \
  "the_refusal_does_not_scaffold_a_home_at_the_project_either" \
  "$NOHOME/.skill-manager was created by a run that refused"

# ------------------------------------------------------------------- verdict

step "Result"
info "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
