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
#
# The resolution order is bootstrap-home.sh's, exactly and only:
#   $SKILL_MANAGER_CLI  ->  command -v skill-manager  ->  refuse.
#
# It used to have a third rung — `$SCRIPT_DIR/../../skill-manager/skill-manager`
# and one level above that — and a path relative to THIS FILE is not a fact about
# which build should run, it is a fact about where this file happens to be
# sitting. Measured: run from a worktree checked out beside the integration repo
# rather than inside `constituents/`, those two entries resolved to an unrelated
# April clone with no `home clone` subcommand at all, and the whole suite then
# failed for reasons that had nothing to do with what it was asserting. A
# relative rung cannot be told apart from the right answer by anything the
# script can check, so there is no rung. `assert_no_relative_cli_resolution`
# below keeps it that way for every script in this directory.
CLI="${SKILL_MANAGER_CLI:-}"
[ -n "$CLI" ] || CLI="$(command -v skill-manager || true)"
[ -n "$CLI" ] || die "no skill-manager CLI. Set SKILL_MANAGER_CLI to a build with \`home clone\`,
  or put one on PATH. There is deliberately no fallback to a path relative to
  this script: on this machine that resolved to a stale clone and the suite
  failed for reasons unrelated to what it asserts."
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
# `diff -q` writes "Files … differ" to STDOUT, so a bare `yesno command diff -q`
# nested inside another substitution captures that sentence along with the
# verdict and the outer test compares a paragraph to a digit. Measured here.
same_file()    { command diff -q "$1" "$2" >/dev/null 2>&1; }
differs_file() { ! same_file "$1" "$2"; }
executable() { [ -n "${1:-}" ] && [ -f "$1" ] && [ -x "$1" ]; }
yesno()     { if "$@"; then printf 1; else printf 0; fi; }
ok()   { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$1" >&2; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n      %s\n' "$1" "$2" >&2; }
check() { if [ "$1" = 1 ]; then ok "$2"; else bad "$2" "$3"; fi; }

# run_bounded <seconds> <command...> — run it, or kill it and return 124.
#
# For the one failure mode that does not fail: a shim that `exec`s itself
# resolves nothing, prints nothing, and never returns, so an unbounded check
# against it does not go red, it goes AWAY — and takes the rest of the suite
# with it. 124 is timeout(1)'s spelling and is used here so the exit code reads
# the same as the tool everyone knows.
#
# Rolled by hand rather than shelling out to `timeout`: macOS ships neither
# `timeout` nor `gtimeout` by default, and a check that skipped itself on the
# platform this defect was found on would report the same green as a passing
# one.
#
# The job gets its OWN PROCESS GROUP (`set -m`) and the GROUP is killed. The
# runaway is a grandchild — close-change.sh's command substitution execs the
# shim — so killing only the job leaves it spinning, which is exactly the
# orphan the pilot left behind: 7:03 of CPU over 13:06 of wall clock.
run_bounded() {
  local limit="$1"; shift
  local pid waited=0 rc=0
  set -m
  "$@" & pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((limit * 10)) ]; then
      kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  return "$rc"
}

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

# A CLI shim whose target lives under a directory `home clone` deliberately
# SKIPS (venvs/, tools/, npm/, cache/). Every real home on this machine has one
# — `bin/cli/jinja2 -> ../../venvs/jinja2-cli/bin/jinja2` is the measured case —
# and the copy therefore arrives with a link that does not resolve. That is what
# `skill-manager home verify` refuses a home for, and bootstrap-home.sh used to
# print `verified` beside it without a word. Seeded here so the fixture has the
# property the real homes have.
mkdir -p "$PROJ_HOME/bin/cli" "$PROJ_HOME/venvs/jinja2-cli/bin"
printf '#!/bin/sh\nexit 0\n' > "$PROJ_HOME/venvs/jinja2-cli/bin/jinja2"
chmod +x "$PROJ_HOME/venvs/jinja2-cli/bin/jinja2"
ln -s ../../venvs/jinja2-cli/bin/jinja2 "$PROJ_HOME/bin/cli/jinja2"

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

# The closing caveat describes what THIS run did. Both halves, because the #38
# defect was that it described a clone on a run that had not cloned: gated on
# `bootstrapped`, which stays 0 on the `--force` path. A one-sided check would
# pass against a banner that always prints AND against one that never does.
#
# Asserted on the printed BYTES rather than on an exit code — both invocations
# below exit 0, and the whole defect is what they said while doing so.
check "$(yesno command grep -q 'The home is a clone' "$SCRATCH/bootstrap.log")" \
  "a_run_that_cloned_says_which_directories_were_skipped" \
  "a real clone did not print the skipped-directory caveat"

FORCE_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT" --force \
  > "$SCRATCH/bootstrap-force.log" 2>&1 || FORCE_RC=$?
check "$(yesno absent_pattern 'The home is a clone' "$SCRATCH/bootstrap-force.log")" \
  "a_force_rerun_does_not_claim_a_clone_it_did_not_do" \
  "--force printed the clone caveat without cloning (rc=$FORCE_RC)"
check "$(yesno command grep -q 'not re-cloning' "$SCRATCH/bootstrap-force.log")" \
  "a_force_rerun_says_what_it_did_instead" \
  "--force did not say it was re-running rather than re-cloning (rc=$FORCE_RC)"
check "$(yesno exists "$WT_HOME/skills/project-only-unit")" \
  "a_force_rerun_leaves_the_existing_home_intact" \
  "$WT_HOME/skills/project-only-unit vanished across --force (rc=$FORCE_RC)"

# --------------------------------- 1b. what the banner claims about the home
#
# git-integration-skill#10 and the two findings beside it. Everything above is
# about WHERE the home came from; these are about what the run then SAYS about
# it, which is the half that fails open.

step "The banner describes the home it actually produced (#10)"

# The count is stated, and it is the count. A `verified:` line that names no
# number is how "verified" came to be printed over a home with nothing in it.
VERIFIED_LINE="$(command grep -m1 '^  verified:' "$SCRATCH/bootstrap.log" || true)"
check "$(yesno contains "1 skill(s) servable" "$VERIFIED_LINE")" \
  "the_verified_line_states_how_many_skills_the_home_can_serve" \
  "expected the servable-skill count in '${VERIFIED_LINE:-<no verified: line>}'"

# The dangling shim the fixture seeded. `skill-manager home verify` refuses this
# home for it; bootstrap must at minimum SAY so, or the two disagree and the
# operator believes the one that ran.
#
# Asserted against the --force log, NOT the clone log. On the clone path `home
# clone` prints the same link itself, so a check reading that log passes whether
# or not bootstrap says anything — measured while writing this, by reverting the
# report and watching the check stay green. --force runs no clone, so the only
# thing that can name the link there is bootstrap's own verify().
check "$(yesno command grep -q 'bin/cli/jinja2 -> ../../venvs/jinja2-cli/bin/jinja2' "$SCRATCH/bootstrap-force.log")" \
  "a_link_that_does_not_resolve_in_the_home_is_named_even_with_no_clone_report" \
  "verify() did not name the dangling shim on a run that printed no clone report (rc=$FORCE_RC); see $SCRATCH/bootstrap-force.log"

# The remedy the caveat prints is a command an operator copy-pastes, and run as
# it used to be spelled — SKILL_MANAGER_HOME alone — its binding step writes the
# OPERATOR'S ~/.claude.json. Measured: `ADDED claude (~/.claude.json)`. That is
# skill-manager#145 reached through a string printed here, so the agent-home
# variables are asserted on the same line as the command.
#
# Scoped to the caveat THIS SCRIPT writes — the tail of the log from `The home
# is a clone` onward — because `home clone` prints the unsafe spelling itself,
# higher up, and that string belongs to skill-manager. Measured while writing
# this check: the CLI's own line reads
#   re-provision with `SKILL_MANAGER_HOME=<home> skill-manager sync --force-scripts`
# which is the hijack verbatim. This repo cannot fix that line, so the caveat now
# contradicts it in words and the assertion is made where the fix lives.
CAVEAT="$(command sed -n '/The home is a clone/,$p' "$SCRATCH/bootstrap.log" || true)"
SYNC_LINE="$(printf '%s\n' "$CAVEAT" | command grep -m1 'sync --force-scripts' || true)"
check "$(yesno test -n "$SYNC_LINE")" \
  "the_clone_caveat_still_prints_a_sync_command_to_check" \
  "no 'sync --force-scripts' line in the caveat at all, so the next check would prove nothing"
check "$(yesno contains "CLAUDE_CONFIG_DIR=$WT" "$SYNC_LINE")" \
  "a_printed_sync_command_pins_the_agent_home_env_too" \
  "'$SYNC_LINE' names the home but not CLAUDE_CONFIG_DIR — run from a bare shell it
      writes the operator's ~/.claude.json (skill-manager#145)"
check "$(yesno contains "not the one" "$CAVEAT")" \
  "the_caveat_warns_off_the_unsafe_spelling_the_cli_printed_above_it" \
  "the CLI's own SKILL_MANAGER_HOME-only remedy is left standing as the last word"

# And it must not claim a repair it cannot make. Measured: `home verify` rc=1 ->
# run this exact remedy -> `home verify` rc=1, same message, <home>/venvs still
# empty. Nothing in `sync` recreates a venv the clone skipped.
check "$(yesno command grep -q 'does NOT recreate <home>/venvs' "$SCRATCH/bootstrap.log")" \
  "the_caveat_does_not_claim_the_sync_repairs_links_into_venvs" \
  "the caveat still presents sync --force-scripts as the fix for a dangling venv link; it is not a fixpoint"

# ------------------------------------------- 1c. a home with nothing in it (#10)

step "A home with no skills is refused, not reported as verified"

# The source is a WELL-FORMED home that holds nothing: installed/ + skills/,
# which is what LaunchEnv.looksLikeStoreRoot asks for, and zero units. Cloning it
# produces a home whose descriptor, policy, shims and `exec --print-env` are all
# correct — so every check bootstrap-home.sh had passed, it printed `verified`,
# and its last line invited the operator to launch an agent that would have no
# skills at all. `skill-manager onboard` is the step that installs the bundled
# ones, and it was named nowhere.
EMPTYP="$SCRATCH/emptyproj"
mkdir -p "$EMPTYP"
git -C "$EMPTYP" init -q -b main
git -C "$EMPTYP" config user.email selftest@example.invalid
git -C "$EMPTYP" config user.name "selftest"
printf 'x\n' > "$EMPTYP/README.md"
git -C "$EMPTYP" add -A
git -C "$EMPTYP" -c commit.gpgsign=false commit -qm "fixture"
mkdir -p "$EMPTYP/.skill-manager/installed" "$EMPTYP/.skill-manager/skills"
EMPTY_WT="$SCRATCH/emptyproj-T7"
git -C "$EMPTYP" worktree add -q -b feature/T7 "$EMPTY_WT" main

EMPTY_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$EMPTY_WT" \
  > "$SCRATCH/empty.log" 2>&1 || EMPTY_RC=$?

# Non-vacuity, and it is not optional here: a bootstrap that refused for some
# EARLIER reason — no source, a disagreeing source, no capable CLI — would also
# be non-zero and would also never print `verified`, and every check below would
# pass while proving nothing about emptiness. The clone must have HAPPENED.
check "$(yesno exists "$EMPTY_WT/.skill-manager/home.runtime.json")" \
  "the_empty_home_fixture_really_did_produce_a_wired_home" \
  "no descriptor at $EMPTY_WT/.skill-manager/home.runtime.json — the run failed before the emptiness could be the reason (rc=$EMPTY_RC)"

check "$(yesno test "$EMPTY_RC" = 5)" \
  "a_home_with_no_skills_exits_with_the_empty_home_code" \
  "expected exit 5, got $EMPTY_RC; see $SCRATCH/empty.log"
check "$(yesno absent_pattern '^  verified:' "$SCRATCH/empty.log")" \
  "a_home_with_no_skills_is_never_reported_as_verified" \
  "'verified:' was printed over a home holding zero skills; see $SCRATCH/empty.log"
check "$(yesno absent_pattern 'Launch an agent bound to this home' "$SCRATCH/empty.log")" \
  "a_home_with_no_skills_does_not_close_by_inviting_a_launch" \
  "the run ended by telling the operator to launch an agent against an empty home"
check "$(yesno command grep -q 'onboard' "$SCRATCH/empty.log")" \
  "the_refusal_names_onboard_the_step_that_installs_the_bundled_skills" \
  "the one command that fixes this is never mentioned; see $SCRATCH/empty.log"
# And it must send the operator to the PROJECT home. Onboarding the worktree's
# own copy would give it units the project home never had, every one of them a
# close-out blocker before any work exists (#50).
check "$(yesno command grep -q -- "--root '$EMPTYP' --onboard" "$SCRATCH/empty.log")" \
  "the_refusal_points_onboard_at_the_project_home_not_the_worktree_copy" \
  "the remedy does not name $EMPTYP; onboarding the worktree copy makes it unclosable (#50)"

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

# --------------------------------- 5b. the cheap path: `wt`, and its contract
#
# The output an agent acts on. `new-change.sh` closing banner was ~25 lines of
# prose and conditional remedies, and the measured consequence was not that
# agents read it slowly — it is that they stopped calling these scripts at all
# and wrote their own worktree provisioning, which knows none of the rules the
# prose exists to state.
#
# So the assertions here are about STDOUT and only stdout: the keys are the
# interface (git-issue-skill#4 — this primitive may later move to `git-issue` or
# into skill-manager, and a caller reading keys survives that move), every value
# has to be a path or a command that runs, and a refusal has to answer with a
# command rather than with a paragraph.

step "wt: the output is the next move"

CHEAP="$SCRATCH/cheap"
mkdir -p "$CHEAP"
git -C "$CHEAP" init -q -b main
git -C "$CHEAP" config user.email selftest@example.invalid
git -C "$CHEAP" config user.name "selftest"
printf '.skill-manager/\n.claude/\n.codex/\n.gemini/\n.claude.json\n' > "$CHEAP/.gitignore"
printf 'fixture\n' > "$CHEAP/README.md"
git -C "$CHEAP" add -A
git -C "$CHEAP" -c commit.gpgsign=false commit -qm "fixture"
seed_home "$CHEAP/.skill-manager" "cheap-project-unit"

NEW_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" new W1 ) \
  > "$SCRATCH/wt-new.out" 2> "$SCRATCH/wt-new.err" || NEW_RC=$?

# Non-vacuity before anything else: a run that failed would have an empty or
# two-line stdout, and "no prose on stdout" would be trivially true of it.
check "$(yesno test "$NEW_RC" = 0)" \
  "wt_new_creates_the_worktree_and_its_home_in_one_command" \
  "wt new exited $NEW_RC; see $SCRATCH/wt-new.err"

# Every line of stdout is a contract line. This is the assertion that the ~25
# lines of prose are gone rather than merely reordered — the clone report alone
# was ten lines, and it reached stdout until `home clone` was redirected.
UNKEYED=""
CONTRACT_LINES=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  CONTRACT_LINES=$((CONTRACT_LINES + 1))
  case "$line" in
    WORKTREE*|BRANCH*|LAUNCH*|IF-EXIT-8*|CLOSE*|PROPAGATE*) : ;;
    *) UNKEYED="${UNKEYED}      $line"$'\n' ;;
  esac
done < "$SCRATCH/wt-new.out"

check "$(yesno test -z "$UNKEYED")" \
  "wt_new_puts_nothing_but_the_contract_on_stdout" \
  "these lines are on stdout and are not contract lines:
$UNKEYED"
check "$(yesno test "$CONTRACT_LINES" -ge 4)" \
  "the_contract_has_the_lines_the_next_checks_read" \
  "only $CONTRACT_LINES contract line(s); the per-key checks below would prove nothing"

WT_LINE_V="$(command sed -n 's/^WORKTREE  *//p' "$SCRATCH/wt-new.out" | command sed -n 1p)"
LAUNCH_V="$(command sed -n 's/^LAUNCH  *//p' "$SCRATCH/wt-new.out" | command sed -n 1p)"
CLOSE_V="$(command sed -n 's/^CLOSE  *//p' "$SCRATCH/wt-new.out" | command sed -n 1p)"
DRIFT_V="$(command sed -n 's/^IF-EXIT-8  *//p' "$SCRATCH/wt-new.out" | command sed -n 1p)"

check "$(yesno test -d "$WT_LINE_V")" \
  "the_contract_names_a_worktree_that_exists" \
  "WORKTREE names '${WT_LINE_V:-<none>}', which is not a directory"

# "leaves it launchable" is the requirement, so the LAUNCH value is checked as a
# file that can be executed, not merely as a string that was printed.
check "$(yesno executable "$LAUNCH_V")" \
  "the_contract_names_a_launcher_that_exists_and_can_be_run" \
  "LAUNCH names '${LAUNCH_V:-<none>}', which is not an executable file"
check "$(yesno contains "$WT_LINE_V/" "$LAUNCH_V")" \
  "the_launcher_is_this_worktrees_own_not_some_other_homes" \
  "LAUNCH '$LAUNCH_V' is not inside $WT_LINE_V — an agent started with it would bind to another home"

check "$(yesno executable "${CLOSE_V%% *}")" \
  "the_contract_names_a_close_command_that_exists" \
  "CLOSE names '${CLOSE_V:-<none>}', whose first token is not an executable file"
check "$(yesno executable "${DRIFT_V%% *}")" \
  "the_contract_names_a_runnable_way_out_of_the_first_launch_refusal" \
  "IF-EXIT-8 names '${DRIFT_V:-<none>}', whose first token is not an executable file — an agent
      that meets exit 8 without it goes back to the reference pages"

# The failing half, and it must be equally tight. Re-running `new` on an
# existing worktree used to die with "worktree path already exists" and name the
# recovery nowhere, which is how an operator reaches for `rm -rf` and skips the
# close-out gate entirely.
DUP_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" new W1 ) \
  > "$SCRATCH/wt-dup.out" 2> "$SCRATCH/wt-dup.err" || DUP_RC=$?
check "$(yesno test "$DUP_RC" != 0)" \
  "a_second_wt_new_for_the_same_ticket_fails" \
  "it exited 0, so the checks below would be asserting against a success"
DUP_FAILED="$(command sed -n 's/^FAILED  *//p' "$SCRATCH/wt-dup.out" | command sed -n 1p)"
DUP_FIX="$(command sed -n 's/^FIX  *//p' "$SCRATCH/wt-dup.out" | command sed -n 1p)"
check "$(yesno test -n "$DUP_FAILED")" \
  "a_failing_run_says_what_failed_in_one_line" \
  "no FAILED line on stdout; see $SCRATCH/wt-dup.out"
check "$(yesno executable "${DUP_FIX%% *}")" \
  "a_failing_run_names_one_remedy_that_is_actually_runnable" \
  "FIX names '${DUP_FIX:-<none>}', whose first token is not an executable file"
check "$(yesno contains "close W1" "$DUP_FIX")" \
  "the_remedy_for_an_existing_worktree_is_the_gated_teardown" \
  "FIX is '$DUP_FIX' — anything but a 'wt close' here routes the operator around the close-out gate"

# And the closing half of the pair. The old trailing note printed the literal
# string `<branch>`, so the one fact still owed after a teardown was the one the
# operator had to go and look up.
CLOSE_RC2=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" close W1 ) \
  > "$SCRATCH/wt-close.out" 2> "$SCRATCH/wt-close.err" || CLOSE_RC2=$?
check "$(yesno test "$CLOSE_RC2" = 0)" \
  "wt_close_tears_the_worktree_down_in_one_command" \
  "wt close exited $CLOSE_RC2; see $SCRATCH/wt-close.err"
check "$(yesno absent "$WT_LINE_V")" \
  "wt_close_actually_removed_it" \
  "$WT_LINE_V is still there after a close that reported success"
DELETE_V="$(command sed -n 's/^DELETE  *//p' "$SCRATCH/wt-close.out" | command sed -n 1p)"
check "$(yesno contains "feature/W1" "$DELETE_V")" \
  "the_closing_contract_names_the_branch_it_left_behind" \
  "DELETE is '${DELETE_V:-<none>}' — the branch outlives the worktree, so naming it is the whole remaining move"

# ------------------------- 6. the gate does not make its own CLI exec itself

step "The gate runs the home's own CLI pin without wedging it"

# The pin at <home>/bin/cli/skill-manager is the candidate close-change.sh
# PREFERS, and since skill-manager issue #61 it resolves its own target as
# `cli="${SKILL_MANAGER_CLI:-<absolute>}"` and ends in `exec "$cli" "$@"`.
# close-change.sh used to invoke the gate as `SKILL_MANAGER_CLI="$CLI" "$CLI" …`
# — correct when the script owned the pin, and after #61 an instruction to the
# pin to exec ITSELF. Measured on the epic #2 pilot: 7:03 of CPU over 13:06 of
# wall clock, from one teardown, with no output and no exit.
#
# Everything here is a shell stub. The point is not to test skill-manager; it is
# that the ONE property under test — what environment close-change.sh hands the
# CLI it picked — must be observable without a JVM, must not take a minute, and
# must not go quiet if it regresses.
#
# The fixture is what the other sections cannot be: SKILL_MANAGER_CLI is UNSET.
# `bare` pins it to a real launcher, so `pick_cli` takes its first branch there
# and never reaches the home's own pin at all — which is why 26 green checks sat
# on top of this defect. Unsetting it is the whole fixture.

step_scratch="$SCRATCH/pinned"
STUB_DIR="$SCRATCH/stub"
STUB="$STUB_DIR/skill-manager"
STUB_LOG="$SCRATCH/stub-invocations.log"
# What the PIN itself was handed, which is the fact under test. The stub cannot
# answer it: when the pin is wedged the stub is never reached at all, so a check
# reading only the stub's record would pass on a livelock by seeing nothing.
PIN_LOG="$SCRATCH/pin-last-invocation.log"
mkdir -p "$STUB_DIR"

# Answers the capability probe with text carrying `--into` (a status-only probe
# would accept anything), answers the gate with a clean verdict, and records
# every invocation together with the value of SKILL_MANAGER_CLI it was handed —
# which is the variable the whole check is about.
cat > "$STUB" <<EOF
#!/usr/bin/env bash
printf 'argv=[%s] SKILL_MANAGER_CLI=[%s]\n' "\$*" "\${SKILL_MANAGER_CLI:-<unset>}" >> "$STUB_LOG"
case "\$*" in
  *"home close-out --help"*)
    printf 'Usage: skill-manager home close-out [--home <dir>] [--into <dir>] [--json]\n'
    printf '  --into <dir>   the project home to reconcile into\n'
    exit 0 ;;
esac
printf '{"units":[],"blockers":[]}\n'
EOF
chmod +x "$STUB"

mkdir -p "$step_scratch"
git -C "$step_scratch" init -q -b main
git -C "$step_scratch" config user.email selftest@example.invalid
git -C "$step_scratch" config user.name "selftest"
printf 'fixture\n' > "$step_scratch/README.md"
git -C "$step_scratch" add -A
git -C "$step_scratch" -c commit.gpgsign=false commit -qm "fixture"
seed_home "$step_scratch/.skill-manager" "pinned-project-unit"

PIN_WT="$SCRATCH/pinned-T6"
git -C "$step_scratch" worktree add -q -b feature/T6 "$PIN_WT" main
PIN_HOME="$PIN_WT/.skill-manager"
seed_home "$PIN_HOME" "pinned-worktree-unit"

# The generated pin, reproduced in the shape `home shims` writes it: the stable
# marker, the home binding, the `${SKILL_MANAGER_CLI:-<absolute>}` resolution and
# the closing `exec`. Written here rather than obtained from a real `home shims`
# run so the check keeps its meaning against a home pinned by an OLDER build —
# which is most of them, and which no guard added to the CLI now can reach.
mkdir -p "$PIN_HOME/bin/cli"
PIN="$PIN_HOME/bin/cli/skill-manager"
cat > "$PIN" <<EOF
#!/usr/bin/env bash
# skill-manager:cli-pin — generated by \`skill-manager home shims\`, do not edit.
set -euo pipefail
self_dir="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd -P)"
home="\$(cd -- "\$self_dir/../.." && pwd -P)"
export SKILL_MANAGER_HOME="\$home"
# TRUNCATING, not appending: a wedged pin re-execs thousands of times in the
# bound below, and the record has to stay a fixed size. The LAST invocation is
# the interesting one either way — it is the gate call.
printf 'SKILL_MANAGER_CLI=[%s] argv=[%s]\n' "\${SKILL_MANAGER_CLI:-<unset>}" "\$*" > "$PIN_LOG"
cli="\${SKILL_MANAGER_CLI:-$STUB}"
if [ ! -x "\$cli" ]; then
  echo "skill-manager: the CLI pinned for the home at \$home is missing:" >&2
  echo "  Re-pin it with \`skill-manager home shims\`, or set SKILL_MANAGER_CLI." >&2
  exit 127
fi
exec "\$cli" "\$@"
EOF
chmod +x "$PIN"

# `bare` with SKILL_MANAGER_CLI removed as well, run from the project root. The
# removal is the fixture: with the variable set, `pick_cli` returns it from its
# first branch and the home's own pin is never invoked.
close_the_pinned_worktree() {
  cd "$step_scratch" || return 1
  env -u SKILL_MANAGER_HOME -u SKILL_MANAGER_CLI \
      HOME="$FAKE_HOME" \
      JAVA_TOOL_OPTIONS="-Duser.home=$FAKE_HOME" \
      bash "$SCRIPT_DIR/close-change.sh" "$PIN_WT" --dry-run
}

PIN_RC=0
run_bounded 25 close_the_pinned_worktree > "$SCRATCH/pinned.log" 2>&1 || PIN_RC=$?

check "$(yesno test "$PIN_RC" != 124)" \
  "the_gate_returns_when_the_cli_it_picked_is_the_homes_own_pin" \
  "close-change.sh did not return within 25s (rc=$PIN_RC). The home's pin resolves
      its target as \${SKILL_MANAGER_CLI:-<absolute>} and ends in exec \"\$cli\", so
      naming the pin in that variable makes it exec itself forever; see $SCRATCH/pinned.log"

# Non-vacuity, twice over. A run that refused early — no CLI found, no home, no
# project home — would also "return within 25s", and would prove nothing.
CLI_LINE="$(command grep -m1 '^  cli:' "$SCRATCH/pinned.log" || true)"
check "$(yesno ends_with "$PIN" "$CLI_LINE")" \
  "the_cli_under_test_really_is_the_homes_own_pin" \
  "expected 'cli: $PIN', got '${CLI_LINE:-<no cli: line — pick_cli chose nothing>}'"
check "$(yesno command grep -q 'gate:      clean' "$SCRATCH/pinned.log")" \
  "the_gate_reached_a_verdict_through_the_pin" \
  "no clean verdict — the gate did not complete through the pin; see $SCRATCH/pinned.log"

# And the cause, named directly rather than inferred from the clock: whatever
# else close-change.sh hands the pin, it must not hand it the pin. Read from the
# PIN's own record, so it is still an assertion about the gate invocation when
# the pin never returns — and so it stays meaningful if the shim later grows a
# self-exec guard of its own and the livelock becomes a fast error rather than
# a hang.
PIN_SAW="$(cat "$PIN_LOG" 2>/dev/null || true)"
check "$(yesno contains 'SKILL_MANAGER_CLI=[<unset>]' "$PIN_SAW")" \
  "the_pin_is_invoked_with_no_SKILL_MANAGER_CLI_to_resolve_itself_through" \
  "the pin's last invocation was '${PIN_SAW:-<the pin was never invoked>}'"
check "$(yesno absent_substring "SKILL_MANAGER_CLI=[$PIN]" "$PIN_SAW")" \
  "the_pin_is_never_named_in_the_variable_it_resolves_itself_through" \
  "close-change.sh handed the pin its own path: '$PIN_SAW'"
# The stub is the other end of the same invocation, and it is what proves the
# pin resolved THROUGH to a real CLI rather than answering out of its own error
# path.
check "$(yesno command grep -q 'argv=\[home close-out --home' "$STUB_LOG")" \
  "the_pinned_build_behind_the_shim_is_what_answered_the_gate" \
  "the CLI behind the pin never saw the gate call; it recorded:
      $(command sed 's/^/        /' "$STUB_LOG" 2>/dev/null || printf '        <nothing>')"

# --------------------------------------------- the remedies this repo PRINTS
#
# Every `skill-manager <sub> --<opt>` this repo tells an operator to run must be
# a command that actually parses. This is not hypothetical: `home drift --show`
# shipped in FIVE places here -- new-change.sh's own closing banner, SKILL.md,
# worktrees.md and skill-homes.md twice -- and the option never existed. It
# exits 2 with `Unknown option`. That string is what a BLOCKED agent is told to
# run, so the one instruction that had to work was the one that did not.
#
# It is the third time this class has shipped. skill-manager grew an executable
# sweep over its own sources for it; this is the same invariant for the strings
# that live over here, which that sweep cannot see.
#
# Scoped to `--` options rather than whole command lines on purpose: a full
# parse would need every placeholder (`$WT`, `<that home>`, `<TICKET>`) resolved,
# and a check that cannot run is worse than no check. The option name is the
# part that was wrong all three times.

step "Every skill-manager option this repo prints is one the CLI accepts"

SWEPT=0
UNKNOWN=""
# `home drift --ack` -> subcommand "home drift", option "--ack". Read from the
# tracked files only, so scratch logs and this file's own examples cannot seed it.
while IFS= read -r pair; do
  sub="${pair%%|*}"; opt="${pair##*|}"
  [ -n "$sub" ] && [ -n "$opt" ] || continue
  SWEPT=$((SWEPT + 1))
  # shellcheck disable=SC2086
  if ! "$CLI" $sub --help 2>&1 | command grep -q -- "$opt"; then
    UNKNOWN="${UNKNOWN}    $sub $opt"$'\n'
  fi
done < <(
  # Both shapes, because both are printed here: a one-word subcommand
  # (`exec --print-env`, `sync --force-scripts`) and a two-word one
  # (`home close-out --home`, `project resolve --project-dir`). Keying only on
  # the two-word shape is how the first draft of this check matched 4 of the 7
  # strings that exist -- caught by the vacuity guard below, which is the only
  # reason this comment is accurate.
  cd "$SCRIPT_DIR/.." && git ls-files -z 2>/dev/null \
    | xargs -0 command grep -ohE 'skill-manager [a-z][a-z-]*( [a-z][a-z-]+)? --[a-z][a-z-]+' 2>/dev/null \
    | command sed -E 's/^skill-manager //; s/ (--[a-z-]+)$/|\1/' \
    | sort -u
)

# Vacuity guard FIRST. A sweep that matched nothing -- or matched only some of
# the shapes -- would report a clean result forever, which is exactly the
# failure mode this whole file exists to refuse. The floor is deliberately just
# under the current count: it must fail if the extraction silently narrows.
check "$(yesno test "$SWEPT" -ge 6)" \
  "the_option_sweep_actually_found_commands_to_check" \
  "the sweep matched $SWEPT option(s); it is not looking at the right files"

check "$(yesno test -z "$UNKNOWN")" \
  "every_skill_manager_option_this_repo_prints_is_accepted_by_the_cli" \
  "these are printed as instructions but the CLI rejects them:
$UNKNOWN"

# ------------------------------- a refusal with nowhere to go names a command
#
# The one path a genuinely fresh machine takes: no `~/.skill-manager` at all.
# `bootstrap-home.sh` refused with `error: source home does not exist: …` and
# nothing else — correct, and it wrote nothing, but it left the operator holding
# a checkout, an exit code and no command. Compare the exit-5 path, which prints
# three alternatives.
#
# Two properties, and the second is the more important one: the refusal must
# name something runnable, AND it must still have written nothing.

step "A refusal from a machine with no home at all names a command"

# A HOME with no `.skill-manager` under it. Deliberately NOT $FAKE_HOME, which
# is seeded: that is the difference between exit 1 (no source) and exit 5 (an
# empty source), and conflating them is how the check would measure the path
# that already had a remedy.
NOSRC_HOME="$SCRATCH/nosource-home"
NOSRC_PROJ="$SCRATCH/nosource-proj"
mkdir -p "$NOSRC_HOME" "$NOSRC_PROJ"
git -C "$NOSRC_PROJ" init -q -b main
git -C "$NOSRC_PROJ" config user.email selftest@example.invalid
git -C "$NOSRC_PROJ" config user.name "selftest"
printf 'x\n' > "$NOSRC_PROJ/README.md"
git -C "$NOSRC_PROJ" add -A
git -C "$NOSRC_PROJ" -c commit.gpgsign=false commit -qm "fixture"

# The "nothing was written" half is asserted against a listing taken BEFORE the
# run, and the listing is proved live further down by planting a file into a
# copy of it and watching the comparison notice.
listing() { command find "$1" -mindepth 1 2>/dev/null | LC_ALL=C sort; }
NOSRC_BEFORE="$SCRATCH/nosource-before.txt"
{ listing "$NOSRC_HOME"; listing "$NOSRC_PROJ"; } > "$NOSRC_BEFORE"

NOSRC_RC=0
env -u SKILL_MANAGER_HOME HOME="$NOSRC_HOME" \
    JAVA_TOOL_OPTIONS="-Duser.home=$NOSRC_HOME" SKILL_MANAGER_CLI="$CLI" \
    bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$NOSRC_PROJ" \
    > "$SCRATCH/nosource.log" 2>&1 || NOSRC_RC=$?

check "$(yesno test "$NOSRC_RC" != 0)" \
  "a_checkout_with_no_home_above_it_is_refused" \
  "bootstrap exited 0 with no home to copy from (rc=$NOSRC_RC); see $SCRATCH/nosource.log"

# "Runnable" as a predicate over a log, not as a grep for hopeful words: the
# first token of a candidate line must be a file this machine can execute, or a
# name PATH resolves. `error: … does not exist` has a first token of `error:`
# and fails it, which is the whole point.
first_runnable() {
  local log="$1" line cmd
  while IFS= read -r line; do
    cmd="$(printf '%s\n' "$line" | command sed -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//')"
    [ -n "$cmd" ] || continue
    if [ -f "$cmd" ] && [ -x "$cmd" ]; then printf '%s\n' "$cmd"; return 0; fi
    if command -v "$cmd" >/dev/null 2>&1; then printf '%s\n' "$cmd"; return 0; fi
  done < "$log"
  return 1
}

# Non-vacuity for the predicate itself, in the same run and in both directions.
# A predicate that answered "yes" to anything would make the assertion below
# meaningless, and the refusal it is about is exactly a log full of prose.
PROSE="$SCRATCH/prose-control.txt"
cat > "$PROSE" <<'EOF'
error: source home does not exist: /nowhere/.skill-manager (the global home)
  There is nothing here that an operator could run.
EOF
check "$(yesno test -z "$(first_runnable "$PROSE" || true)")" \
  "the_runnable_remedy_predicate_rejects_a_refusal_that_is_only_prose" \
  "the predicate accepted '$(first_runnable "$PROSE" || true)' from a log with no command in it"

NOSRC_FIX="$(first_runnable "$SCRATCH/nosource.log" || true)"
check "$(yesno test -n "$NOSRC_FIX")" \
  "the_no_source_refusal_names_a_command_that_exists_on_this_machine" \
  "no runnable command in the refusal; see $SCRATCH/nosource.log"
# And the exit-5 refusal, whose remedy was already good, measured by the SAME
# predicate — so a future edit cannot satisfy one and lose the other.
EMPTY_FIX="$(first_runnable "$SCRATCH/empty.log" || true)"
check "$(yesno test -n "$EMPTY_FIX")" \
  "the_empty_home_refusal_names_a_command_by_the_same_measure" \
  "the exit-5 remedy stopped being runnable by the predicate the exit-1 one now passes"

check "$(yesno command grep -q 'onboard' "$SCRATCH/nosource.log")" \
  "the_no_source_refusal_names_the_step_that_creates_the_home_above_this_one" \
  "\`onboard\` is the command that fills a fresh machine's global home and it is named nowhere"

# The half that matters more than the message. Asserted against the pre-run
# listing, and then the comparison is proved live: a copy of the baseline with
# one planted line must NOT compare equal, or "unchanged" means "not looked at".
{ listing "$NOSRC_HOME"; listing "$NOSRC_PROJ"; } > "$SCRATCH/nosource-after.txt"
check "$(yesno same_file "$NOSRC_BEFORE" "$SCRATCH/nosource-after.txt")" \
  "a_refusal_with_no_source_home_writes_nothing_anywhere" \
  "$(command diff "$NOSRC_BEFORE" "$SCRATCH/nosource-after.txt" | command head -10)"
command cp "$NOSRC_BEFORE" "$SCRATCH/nosource-planted.txt"
printf '%s/planted\n' "$NOSRC_HOME" >> "$SCRATCH/nosource-planted.txt"
check "$(yesno differs_file "$NOSRC_BEFORE" "$SCRATCH/nosource-planted.txt")" \
  "the_wrote_nothing_comparison_notices_a_planted_file" \
  "the comparison called a listing with an extra entry identical, so it proves nothing"

# ------------------------------ every scripts/ file this skill names, it ships
#
# `references/skill-homes.md` and `references/onboarding.md` both said "copy
# `scripts/agent-home.sh` into the repo root", and `close-change.sh` offered the
# same file as a remedy — and this skill did not ship it. The only copy on the
# machine belonged to one particular integration repo, so a literal first-time
# onboarding had nothing to copy and the documented step could not be taken.
#
# The assertion is the general one, because "the docs name a file that exists"
# is the property, not "agent-home.sh exists": every `scripts/<name>` token in
# any tracked file here must resolve to a file under THIS skill's root.

step "Every scripts/ path this skill names is one it ships"

# The extracted set first. A sweep that matched nothing would report a clean
# result forever — the same failure mode as every other grep assertion in this
# file — and the four names below are the ones the docs and the scripts have
# always instructed a reader to run, so the floor is stated as membership
# rather than as a count that drifts.
# `|| true`: `git ls-files` names the INDEX, so a tracked file that is missing
# from disk makes grep exit 2 and, under `set -u -e`, would abort the suite
# before the assertion that is about exactly that case could run. Measured while
# writing the mutation proof for this very check.
NAMED="$(cd "$SCRIPT_DIR/.." && git ls-files -z 2>/dev/null \
  | xargs -0 command grep -ohE 'scripts/[A-Za-z0-9_][A-Za-z0-9_.-]*' 2>/dev/null \
  | command sed 's#^scripts/##; s/[.,;:]*$//' | sort -u || true)"
MISSING_FLOOR=""
for want in bootstrap-home.sh new-change.sh close-change.sh wt agent-home.sh; do
  contains "$want" "$(printf '%s\n' "$NAMED")" || MISSING_FLOOR="$MISSING_FLOOR $want"
done
check "$(yesno test -z "$MISSING_FLOOR")" \
  "the_documented_script_sweep_found_the_scripts_that_are_always_documented" \
  "the sweep did not even name:$MISSING_FLOOR — it is not looking at the right files"

UNSHIPPED=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  [ -e "$SCRIPT_DIR/$name" ] || UNSHIPPED="$UNSHIPPED  scripts/$name"$'\n'
done <<EOF
$NAMED
EOF
check "$(yesno test -z "$UNSHIPPED")" \
  "every_scripts_path_this_skill_names_resolves_inside_this_skill" \
  "named in tracked files but not shipped here:
$UNSHIPPED"

# Resolution base, asserted. The whole defect survived because the file DID
# exist — one directory up, in the integration repo that happened to carry this
# skill as a constituent. A check that resolved `scripts/agent-home.sh` from
# there would have been green throughout. So: prove the base is the skill root
# by showing a path that exists ONLY outside it does not satisfy the rule.
#
# The decoy's own path is assembled from variables, never written as a
# `scripts/<name>` literal: this file is tracked, so a literal here would be
# swept up by the extraction above and the check would fail on its own fixture.
OUTSIDE="$SCRATCH/outside-base"
OUTSIDE_DIR="$OUTSIDE/scripts"
OUTSIDE_NAME="not-a-file-this-skill-ships.sh"
mkdir -p "$OUTSIDE_DIR"
printf '#!/bin/sh\nexit 0\n' > "$OUTSIDE_DIR/$OUTSIDE_NAME"
check "$(yesno absent "$SCRIPT_DIR/$OUTSIDE_NAME")" \
  "a_scripts_file_that_exists_only_outside_this_skill_does_not_satisfy_the_rule" \
  "the resolution base is not this skill's scripts/ directory"

# -------------------------------- no script resolves a CLI by a relative path
#
# The rule, for every script in this directory: a skill-manager is
# $SKILL_MANAGER_CLI, then whatever `command -v skill-manager` answers, then
# nothing. A path relative to the script's own location is not evidence about
# which build should run — it is evidence about where the checkout happens to be
# — and when the two disagree the script runs a build nobody chose. Measured on
# selftest.sh itself: from a worktree beside the integration repo,
# `$SCRIPT_DIR/../../skill-manager/skill-manager` named an unrelated April clone
# with no `home clone`, and the suite failed for reasons it is not about.
#
# bootstrap-home.sh's pick_cli is the deliberate exception and is NOT relative:
# its extra candidates are anchored on `$ROOT` (the checkout being bootstrapped)
# and on `outermost_integration_root "$ROOT"`, both derived from the target, not
# from where this file sits.

step "No script resolves a skill-manager by a path relative to itself"

# The pattern, and then proof the pattern still matches the shape it is for.
# A grep assertion that finds nothing reports the same green whether the defect
# is absent or the pattern is a typo, and this one is a regex over punctuation,
# which is the shape that rots. So the control is written to disk in the exact
# spelling that shipped, and the check that it MATCHES runs first.
REL_CLI_RE='\.\.(/\.\.)*/skill-manager/skill-manager'
CONTROL="$SCRATCH/rel-cli-control.txt"
# The control carries the two lines VERBATIM as they shipped, each behind a `#`
# so that this file's own copy of them is not itself a resolution site. The
# static sweep below drops comment lines for the same reason — a comment cannot
# run a CLI — and the count here is taken WITHOUT that filter, so the pattern is
# proved live against the real spelling before any filtering happens.
cat > "$CONTROL" <<'EOF'
#  for c in "$SCRIPT_DIR/../../skill-manager/skill-manager" \
#           "$SCRIPT_DIR/../../../skill-manager/skill-manager"; do
EOF
CONTROL_HITS="$(command grep -cE "$REL_CLI_RE" "$CONTROL" || true)"
check "$(yesno test "$CONTROL_HITS" -ge 2)" \
  "the_relative_cli_pattern_still_matches_the_spelling_that_shipped" \
  "the pattern matched $CONTROL_HITS of the 2 control lines, so a zero count over
      scripts/ would prove nothing"

REL_HITS="$(cd "$SCRIPT_DIR" && command grep -rnE "$REL_CLI_RE" . 2>/dev/null \
  | command grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
  | command grep -v 'REL_CLI_RE=' || true)"
check "$(yesno test -z "$REL_HITS")" \
  "no_script_here_resolves_a_skill_manager_by_a_path_relative_to_itself" \
  "these resolve a CLI from their own location:
$(printf '%s\n' "$REL_HITS" | command sed 's/^/        /')"

# The dynamic half. The static check can only see the spelling it knows; this one
# plants the file the old code reached for, at exactly the path it reached for it
# from, and asserts the refusal happens WITHOUT it being touched. Its own
# non-vacuity is the decoy's existence: if the plant is wrong the "never invoked"
# half is true for the wrong reason, so the plant is asserted first.
REL_ROOT="$SCRATCH/relcheck"
REL_SCRIPTS="$REL_ROOT/skill/scripts"
mkdir -p "$REL_SCRIPTS" "$REL_ROOT/skill-manager"
cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/wt" "$SCRIPT_DIR/_manifest.py" "$REL_SCRIPTS/" 2>/dev/null || true
DECOY="$REL_ROOT/skill-manager/skill-manager"
DECOY_LOG="$REL_ROOT/decoy.log"
cat > "$DECOY" <<EOF
#!/usr/bin/env bash
printf 'INVOKED %s\n' "\$*" >> "$DECOY_LOG"
exit 99
EOF
chmod +x "$DECOY"
check "$(yesno executable "$DECOY")" \
  "the_stale_clone_decoy_sits_at_the_path_the_old_fallback_reached_for" \
  "$DECOY is not an executable file, so 'it was never invoked' would prove nothing"

REL_RC=0
run_bounded 40 env -u SKILL_MANAGER_CLI PATH=/usr/bin:/bin \
  bash "$REL_SCRIPTS/selftest.sh" > "$REL_ROOT/child.log" 2>&1 || REL_RC=$?
check "$(yesno test "$REL_RC" != 0)" \
  "a_suite_with_no_pin_and_no_skill_manager_on_PATH_refuses" \
  "it exited 0 with nothing to run against (rc=$REL_RC); see $REL_ROOT/child.log"
check "$(yesno absent "$DECOY_LOG")" \
  "the_refusal_did_not_reach_for_the_clone_beside_the_checkout" \
  "the decoy was invoked: $(cat "$DECOY_LOG" 2>/dev/null | command tr '\n' ' ')"
check "$(yesno command grep -q 'no skill-manager CLI' "$REL_ROOT/child.log")" \
  "the_refusal_names_the_variable_that_fixes_it" \
  "expected the SKILL_MANAGER_CLI refusal; got:
$(command sed 's/^/        /' "$REL_ROOT/child.log" 2>/dev/null | command tail -5)"

# ------------------------------------------------------------------- verdict

step "Result"
info "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
