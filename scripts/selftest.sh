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
absent_substring() { ! contains "$1" "$2"; }
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

# --------------------------------------- 2b. which worktree a TICKET resolves to

step "A ticket resolves to the same worktree from anywhere in the repo"

# The destination check above cannot see this. `project_home` derives from
# `git worktree list`, not from $PWD, so reverting close-change.sh's ROOT alone
# leaves the `into:` line correct and every assertion green -- the two edits
# were only jointly observable, which is a finding about the test, not about the
# code. THIS is the one that fails on the ROOT site alone: ticket_worktree_path
# is `<parent>/<basename $ROOT>-<TICKET>`, so with $ROOT resolved from $PWD the
# ticket T1 named `proj-T2-T1` from inside the T2 worktree and the script died
# on a path that never existed.
( cd "$WT2" && bare bash "$SCRIPT_DIR/close-change.sh" T1 --dry-run ) \
  > "$SCRATCH/byticket.log" 2>&1 || true
WT_LINE="$(command grep -m1 '^  worktree:' "$SCRATCH/byticket.log" || true)"
check "$(yesno ends_with "$WT" "$WT_LINE")" \
  "a_ticket_resolves_to_the_same_worktree_from_a_sibling_worktree" \
  "expected 'worktree: $WT', got '${WT_LINE:-<no worktree: line — the ticket path did not resolve>}'"

# ------------------------------------------- 2c. the read-only gesture is allowed

step "From inside the worktree: --dry-run answers, removal refuses"

( cd "$WT" && bare bash "$SCRIPT_DIR/close-change.sh" "$WT" --dry-run ) \
  > "$SCRATCH/inside-dry.log" 2>&1 || true
check "$(yesno command grep -q 'Dry run — nothing removed' "$SCRATCH/inside-dry.log")" \
  "a_dry_run_from_inside_the_worktree_is_answered_not_refused" \
  "a dry run removes nothing and is the safest thing to ask; see $SCRATCH/inside-dry.log"

( cd "$WT" && bare bash "$SCRIPT_DIR/close-change.sh" "$WT" ) \
  > "$SCRATCH/inside-real.log" 2>&1 || true
check "$(yesno exists "$WT/.git")" \
  "a_removal_from_inside_the_worktree_removes_nothing" \
  "$WT was removed out from under the caller"
check "$(yesno command grep -q 'standing in it' "$SCRATCH/inside-real.log")" \
  "a_removal_from_inside_the_worktree_says_why_it_refused" \
  "no 'standing in it' refusal; see $SCRATCH/inside-real.log"

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

# And a CONFLICTED unit, because a conflict is the only status whose remedy has
# a TAIL: `--merge  (then resolve: <files>)`. Both homes edit the same two files
# of the unit the clone gave them, so the merge cannot pick a side. The manifest
# is edited deliberately -- `skill-manager.toml` is in every unit there is, so a
# manifest conflict is the most likely remedy this gate will ever print, and it
# is the string a token substitution over the remedy corrupts.
printf 'WORKTREE EDIT\n' >> "$WT_HOME/skills/project-only-unit/SKILL.md"
printf '# worktree edit\n' >> "$WT_HOME/skills/project-only-unit/skill-manager.toml"
printf 'PROJECT EDIT\n' >> "$PROJ_HOME/skills/project-only-unit/SKILL.md"
printf '# project edit\n' >> "$PROJ_HOME/skills/project-only-unit/skill-manager.toml"

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
  "the_remedy_is_still_the_command_the_gate_ran" \
  "remedy lost its subcommand: '$REMEDY'"

# The TAIL. Both assertions above read only the HEAD of the command -- the first
# token, and the subcommand right after it -- which is the one-sided shape: a
# remedy whose conflicted-file list had been rewritten into paths in another
# repository would satisfy both of them. Measured, that is exactly what a token
# substitution over the remedy did to `skill-manager.toml`, the most common
# conflicted file there is.
CONFLICT_REMEDY="$(command grep -m1 'then resolve: ' "$SCRATCH/blocked.log" || true)"
CONFLICT_TAIL="${CONFLICT_REMEDY#*then resolve: }"
check "$(yesno test -n "$CONFLICT_REMEDY")" \
  "the_gate_reports_a_conflicted_unit_with_the_files_to_resolve" \
  "no 'then resolve:' remedy was printed; see $SCRATCH/blocked.log"
check "$(yesno contains "skill-manager.toml" "$CONFLICT_TAIL")" \
  "the_remedy_tail_names_the_conflicted_manifest" \
  "expected skill-manager.toml among the conflicts, got '${CONFLICT_TAIL:-<none>}'"
check "$(yesno absent_substring "/skill-manager.toml" "$CONFLICT_TAIL")" \
  "the_remedy_tail_names_conflicts_by_their_in_unit_path_not_an_absolute_one" \
  "a conflicted file became an absolute path — the operator is pointed at the wrong file: '$CONFLICT_TAIL'"

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

# ------------------------------------- 5. a refused bootstrap leaves no residue

step "new-change.sh rolls back a worktree whose home could not be created"

# The refusal above is correct; the state it USED to leave was not. The worktree
# and its branch survived, so `new-change.sh <TICKET>` then died with "worktree
# path already exists", and the trailing text told the operator to re-run the
# bootstrap against the WORKTREE -- which refuses identically, because the cause
# is that the PROJECT has no home. The last thing an operator reads has to be
# the thing that works, and this fires on 17 of the 24 constituents in the
# integration repo this ships with.
NC_WT="$SCRATCH/nohome-T9"
( cd "$NOHOME" && bare bash "$SCRIPT_DIR/new-change.sh" T9 ) \
  > "$SCRATCH/newchange.log" 2>&1 || true

git -C "$NOHOME" branch --format='%(refname:short)' > "$SCRATCH/branches.txt" 2>/dev/null || true

check "$(yesno absent "$NC_WT")" \
  "a_worktree_whose_home_could_not_be_created_is_rolled_back" \
  "$NC_WT survives a failed new-change.sh; the next run dies on 'already exists'"
# Non-vacuity for the check below: an empty or missing branches.txt would make
# "feature/T9 is absent" true for the wrong reason. This is the §7.4 shape and it
# costs one line to close.
check "$(yesno command grep -qx 'main' "$SCRATCH/branches.txt")" \
  "the_branch_listing_that_the_next_check_reads_is_real" \
  "branches.txt does not list main, so 'feature/T9 is absent' would prove nothing"
check "$(yesno absent_pattern 'feature/T9' "$SCRATCH/branches.txt")" \
  "the_branch_of_a_rolled_back_worktree_is_deleted_too" \
  "feature/T9 is still a branch of $NOHOME"
check "$(yesno contains "bootstrap-home.sh --root \"$NOHOME\"" "$(cat "$SCRATCH/newchange.log")")" \
  "the_failure_names_a_remedy_that_actually_works" \
  "the trailing remedy does not name the PROJECT root; see $SCRATCH/newchange.log"

# ------------------------------------------------------------------- verdict

step "Result"
info "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
