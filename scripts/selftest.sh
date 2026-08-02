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

# The log file a run NAMED on its own console output. bootstrap-home.sh prints
# five lines and puts the transcript in a file, so every check below that is
# about DETAIL reads it through this, and every check that is about the CONSOLE
# reads the captured output directly. Keeping the two apart is the whole point of
# the change and therefore of these assertions: a detail line that leaked back
# onto the console fails a budget check, and a log that was named but never
# written fails every check that reads it.
run_log() { command sed -n 's/^log:  *//p' "$1" 2>/dev/null | command sed -n 1p; }
# Lines of console output, blank lines included — the thing an agent pays for.
lines_of() { command wc -l < "$1" | command tr -d ' '; }
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

# The log this run named, and its contents. Everything below that is about DETAIL
# reads it; the console is asserted separately, further down, against a line
# budget. Its own non-vacuity comes first — a log path that was printed but never
# written would make every `grep` over it report a clean absence forever, which is
# the failure mode this whole file exists to refuse.
BOOT_LOG="$(run_log "$SCRATCH/bootstrap.log")"
check "$(yesno test -n "$BOOT_LOG")" \
  "a_successful_bootstrap_names_the_log_that_holds_its_detail" \
  "no 'log:' line on the console; the detail is not reachable at all (rc=$BOOTSTRAP_RC):
$(command sed 's/^/        /' "$SCRATCH/bootstrap.log")"
check "$(yesno test -s "${BOOT_LOG:-/nonexistent}")" \
  "the_named_log_is_a_file_that_was_actually_written" \
  "'${BOOT_LOG:-<none>}' is missing or empty, so every check that reads it would pass on nothing"

# The closing caveat describes what THIS run did. Both halves, because the #38
# defect was that it described a clone on a run that had not cloned: gated on
# `bootstrapped`, which stays 0 on the `--force` path. A one-sided check would
# pass against a banner that always prints AND against one that never does.
#
# Asserted on the WRITTEN BYTES rather than on an exit code — both invocations
# below exit 0, and the whole defect is what they said while doing so. In the log
# now rather than on the console: which directories a clone skipped is detail, and
# the fact that matters — that a link in this home does not resolve — is on the
# console as one counted line, checked below.
check "$(yesno command grep -q 'The home is a clone' "$BOOT_LOG")" \
  "a_run_that_cloned_says_which_directories_were_skipped" \
  "a real clone did not record the skipped-directory caveat"

FORCE_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT" --force \
  > "$SCRATCH/bootstrap-force.log" 2>&1 || FORCE_RC=$?
FORCE_LOG="$(run_log "$SCRATCH/bootstrap-force.log")"
check "$(yesno test -s "${FORCE_LOG:-/nonexistent}")" \
  "the_force_rerun_names_a_log_of_its_own" \
  "'${FORCE_LOG:-<none>}' is missing or empty (rc=$FORCE_RC); the checks below would read nothing"
check "$(yesno test "$FORCE_LOG" != "$BOOT_LOG")" \
  "each_run_gets_its_own_log_rather_than_appending_to_a_shared_one" \
  "both runs named $BOOT_LOG — two concurrent bootstraps would interleave into one file"
check "$(yesno absent_pattern 'The home is a clone' "$FORCE_LOG")" \
  "a_force_rerun_does_not_claim_a_clone_it_did_not_do" \
  "--force recorded the clone caveat without cloning (rc=$FORCE_RC)"
check "$(yesno command grep -q 'not re-cloning' "$FORCE_LOG")" \
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
VERIFIED_LINE="$(command grep -m1 '^verified:' "$SCRATCH/bootstrap.log" || true)"
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
check "$(yesno command grep -q 'bin/cli/jinja2 -> ../../venvs/jinja2-cli/bin/jinja2' "$FORCE_LOG")" \
  "a_link_that_does_not_resolve_in_the_home_is_named_even_with_no_clone_report" \
  "verify() did not name the dangling shim on a run that recorded no clone report (rc=$FORCE_RC); see $FORCE_LOG"

# And the fact itself reaches the CONSOLE, as one line carrying the count. This
# is the half the log cannot do: an operator who never opens the log still has to
# learn that `skill-manager home verify` will refuse this home. Both halves are
# asserted, because "the detail moved to the log" and "the finding was dropped"
# are the same log file and different outcomes.
DANGLING_LINE="$(command grep -m1 '^warning:.*do not resolve' "$SCRATCH/bootstrap-force.log" || true)"
check "$(yesno contains "1 link(s)" "$DANGLING_LINE")" \
  "the_console_still_says_how_many_links_in_this_home_do_not_resolve" \
  "expected a counted one-line warning, got '${DANGLING_LINE:-<no warning: line>}'"
check "$(yesno contains "home verify" "$DANGLING_LINE")" \
  "the_console_warning_says_what_the_unresolved_links_cost" \
  "'${DANGLING_LINE:-<none>}' does not say that \`home verify\` refuses the home over them"

# --------------- what was DELETED, and the property that outlived it
#
# This spot used to assert three things about a nine-line closing paragraph that
# told the operator to run `<pinned env> skill-manager sync --force-scripts` and
# then, three lines later in its own text, that the command "does NOT recreate
# <home>/venvs, so a link INTO venvs/ stays dangling and `skill-manager home
# verify` keeps refusing this home". Measured, and that is why the sentence
# existed: `home verify` rc=1 -> run the remedy -> `home verify` rc=1, identical
# message, <home>/venvs still empty.
#
# A remedy whose own paragraph says it does not remedy is not detail. It is
# deleted rather than demoted, and the assertion is that NO SCRIPT HERE OFFERS IT
# ANY MORE — a static sweep, with the sentence that shipped as its control, so
# "no script contains it" cannot be true of a pattern that matches nothing.
FS_CONTROL="$SCRATCH/force-scripts-control.txt"
cat > "$FS_CONTROL" <<'EOF'
  $(home_env_prefix) $CLI sync --force-scripts
re-provisions the shims it can re-derive.
EOF
check "$(yesno command grep -q 'sync --force-scripts$' "$FS_CONTROL")" \
  "the_deleted_remedy_pattern_matches_the_line_that_shipped" \
  "the pattern does not match the text it is meant to keep out, so the next check proves nothing"
FS_OFFERS=""
for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/wt"; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in selftest.sh) continue ;; esac
  # Offered as a COMMAND — a line ending in the option — rather than merely
  # mentioned: bootstrap-home.sh still names the spelling in prose, to warn the
  # reader off the one `home clone` prints for itself, and that sentence is the
  # opposite of the defect.
  if command grep -q 'sync --force-scripts$' "$f"; then
    FS_OFFERS="$FS_OFFERS $(basename "$f")"
  fi
done
check "$(yesno test -z "$FS_OFFERS")" \
  "no_script_here_still_offers_the_sync_that_cannot_repair_what_it_names" \
  "these print it as a remedy:$FS_OFFERS"

# The property that paragraph was carrying, kept and re-anchored. Every
# home-mutating command this script prints must pin BOTH axes: run with
# SKILL_MANAGER_HOME alone, a sync's binding step writes the OPERATOR'S
# ~/.claude.json — measured, `ADDED claude (~/.claude.json)`, skill-manager#145,
# reached by copy-pasting a line this file printed. `home_env_prefix` pins both,
# and the exit-5 refusal further down is a string this script owns end to end, so
# that is where the property is now asserted. See
# `a_printed_remedy_pins_the_agent_home_env_too` below.

# --------------------------- and the console budget the detail was moved for
#
# Measured on this fixture before the change: 151 lines / 18717 bytes on a
# SUCCESSFUL bootstrap. An agent reading that pays for it on every onboarding,
# and pays it on the run where nothing went wrong.
#
# THE BUDGET AND THE EVIDENCE ARE ONE CHECK, deliberately. "The output is short"
# passes trivially when a command prints nothing, and a bootstrap that printed
# nothing would be a worse regression than the one being fixed — `projected:` and
# `verified:` exist so that a claim about this home can be CHECKED rather than
# believed. So the predicate is a conjunction: under budget AND still carrying
# every line that constitutes evidence AND naming the log that holds the rest.
# Individual checks follow it for diagnosis; the conjunction is the assertion.
#
# EIGHT: five summary lines — home, projected, verified, launch, log — plus up to
# three conditional one-line warnings, of which this fixture (a seeded dangling
# shim) triggers one. It is not a round number chosen for comfort; it is the
# shape of the output, and anything that pushes past it is a line that has been
# added rather than a line that was already there.
CONSOLE_BUDGET=8

under_budget_with_evidence() {
  local f="$1"
  [ "$(lines_of "$f")" -le "$CONSOLE_BUDGET" ] || return 1
  command grep -q '^projected: [0-9][0-9]* of [0-9][0-9]* into each of ' "$f" || return 1
  command grep -q '^verified: .*[0-9] skill(s) servable' "$f" || return 1
  command grep -q '^log: *[^ ]' "$f" || return 1
  return 0
}

check "$(yesno under_budget_with_evidence "$SCRATCH/bootstrap.log")" \
  "a_successful_bootstrap_is_under_budget_AND_still_prints_its_evidence" \
  "$(lines_of "$SCRATCH/bootstrap.log") line(s) / $(command wc -c < "$SCRATCH/bootstrap.log" | command tr -d ' ') byte(s),
      budget $CONSOLE_BUDGET, and the evidence lines present are:
$(command grep -E '^(projected|verified|log):' "$SCRATCH/bootstrap.log" | command sed 's/^/        /' || printf '        <none>')
      Both halves matter: short-with-no-evidence is not an improvement on long."

check "$(yesno command grep -q "^projected: 1 of 1 into each of " "$SCRATCH/bootstrap.log")" \
  "the_projection_evidence_survives_on_the_console" \
  "'projected: N of M into each of …' was demoted; it is what makes 'verified' checkable"
check "$(yesno command grep -q '^launch: ' "$SCRATCH/bootstrap.log")" \
  "the_console_ends_by_naming_the_next_move" \
  "no 'launch:' line — the one thing the operator does next"

# The other side of the same coin: the CLI transcript that used to be printed is
# not merely shorter, it is somewhere. A budget check alone is satisfied by
# throwing the detail away.
check "$(yesno test "$(lines_of "$BOOT_LOG")" -gt "$(lines_of "$SCRATCH/bootstrap.log")")" \
  "the_detail_the_console_no_longer_carries_is_in_the_log" \
  "the log has $(lines_of "$BOOT_LOG") line(s) and the console $(lines_of "$SCRATCH/bootstrap.log") — the detail was dropped, not moved"

# --verbose restores it, on stderr, live. Without this the quiet path is a way of
# hiding a failure rather than of deferring detail.
VERB_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT" --force --verbose \
  > "$SCRATCH/bootstrap-verbose.out" 2> "$SCRATCH/bootstrap-verbose.err" || VERB_RC=$?
check "$(yesno test "$(lines_of "$SCRATCH/bootstrap-verbose.err")" -gt "$CONSOLE_BUDGET")" \
  "verbose_puts_the_whole_transcript_back_on_stderr" \
  "--verbose printed $(lines_of "$SCRATCH/bootstrap-verbose.err") line(s) (rc=$VERB_RC), no more than the quiet path's budget"
check "$(yesno command grep -q '^verified: ' "$SCRATCH/bootstrap-verbose.err")" \
  "verbose_still_ends_with_the_evidence" \
  "--verbose lost the verified: line while restoring everything else"

# ----------------------- 1b2. the skills have to reach an AGENT, not the store
#
# The highest-leverage check in this file. `verified: 20 skill(s) servable` was
# printed over a worktree whose `.claude`, `.codex` and `.gemini` held no
# `skills/` directory at all — because the count came from `$STORE/skills`, and
# no agent reads the store. An agent reads `<root>/.<agent>/skills/<unit>`.
#
# Everything below therefore asserts on THE LINKS AN AGENT WOULD FOLLOW, and
# every assertion is shown able to fail by breaking a link three different ways
# in the same run. A node that recounted the store would stay green through all
# three, which is exactly how the defect survived.

step "The skills reach an agent, and 'verified' is printed only when they do"

WTP="$SCRATCH/proj-P1"
git -C "$PROJ" worktree add -q -b feature/P1 "$WTP" main
WTP_HOME="$WTP/.skill-manager"
PROJ_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WTP" > "$SCRATCH/proj.log" 2>&1 || PROJ_RC=$?

# The agent directories, read the way the script reads them, so this cannot
# check a place the launcher does not look.
AGENT_DIRS=".claude .codex .gemini"

# Non-vacuity first: a store with nothing in it makes "every unit is projected"
# true over an empty set, which is the exact shape of the bug in mirror image.
STORE_UNITS=0
for d in "$WTP_HOME"/skills/*/; do
  [ -d "$d" ] && [ -f "$d/SKILL.md" ] && STORE_UNITS=$((STORE_UNITS + 1))
done
check "$(yesno test "$STORE_UNITS" -ge 1)" \
  "the_projection_fixture_home_actually_holds_a_skill" \
  "the home holds $STORE_UNITS skill(s); 'all of them are projected' would be true of nothing"
check "$(yesno test "$PROJ_RC" = 0)" \
  "a_bootstrapped_worktree_home_is_accepted" \
  "bootstrap exited $PROJ_RC; see $SCRATCH/proj.log"

# All three agents, independently and named, so a future agent-specific
# regression says which one.
for agent in $AGENT_DIRS; do
  missing=""
  for d in "$WTP_HOME"/skills/*/; do
    [ -d "$d" ] && [ -f "$d/SKILL.md" ] || continue
    u="$(basename "$d")"
    dest="$WTP/$agent/skills/$u"
    # -e, not -L: a dangling symlink is still a directory entry, and a check
    # that counted entries would accept one.
    if [ ! -e "$dest" ]; then missing="$missing $u(absent)"; continue; fi
    real="$(cd "$dest" 2>/dev/null && pwd -P)" || real=""
    case "$real" in
      "$WTP"/*) : ;;
      *) missing="$missing $u(resolves to ${real:-<nothing>})" ;;
    esac
  done
  check "$(yesno test -z "$missing")" \
    "every_skill_in_the_home_is_readable_by_${agent#.}_from_inside_the_worktree" \
    "an agent launched here would not see:$missing"
done

# The banner. Vacuity guard first — if the run had failed earlier there would be
# no `verified:` line and "it did not claim what it could not do" would be
# trivially true — then the POSITIVE direction, with the number matching the
# links that were just counted rather than the store.
PROJ_LOG="$(run_log "$SCRATCH/proj.log")"
PROJ_SKILLS_LINE="$(command grep -m1 '^  skills:' "${PROJ_LOG:-/nonexistent}" 2>/dev/null || true)"
check "$(yesno test -n "$PROJ_SKILLS_LINE")" \
  "the_projection_run_got_far_enough_to_report_on_the_home" \
  "no 'skills:' line in ${PROJ_LOG:-<no log named>} — the checks below would be about a run that died first"
PROJ_VERIFIED="$(command grep -m1 '^verified:' "$SCRATCH/proj.log" || true)"
check "$(yesno contains "$STORE_UNITS skill(s) servable" "$PROJ_VERIFIED")" \
  "a_fully_projected_home_is_reported_as_verified_with_the_projected_count" \
  "expected '$STORE_UNITS skill(s) servable', got '${PROJ_VERIFIED:-<no verified: line>}'"
check "$(yesno command grep -q "^projected: $STORE_UNITS of $STORE_UNITS" "$SCRATCH/proj.log")" \
  "the_run_states_how_many_of_the_stores_skills_an_agent_can_reach" \
  "no 'projected: $STORE_UNITS of $STORE_UNITS' line; see $SCRATCH/proj.log"

# --- and now break it, three ways, and require the measurement to notice.
#
# `--no-project --allow-unprojected` re-measures WITHOUT repairing: the repair is
# the other half of the fix and would hide the mutation. Each case re-runs the
# real measurement code, so what is proved is that the SCRIPT can see it, not
# that this file can.
BROKEN_UNIT="$(basename "$(command ls -d "$WTP_HOME"/skills/*/ | command head -1)")"
remeasure() { # $1 = log name
  bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WTP" --force \
    --no-project --allow-unprojected > "$SCRATCH/$1" 2>&1 || true
}

# `mkdir -p` and `|| true` around every mutation below: when the fix is reverted
# these directories do not exist AT ALL (that is the defect), and a bare `ln -s`
# into a missing directory kills the suite under `set -e` before the checks that
# are about exactly that state can run. Measured while taking the mutation proof.
mkdir -p "$WTP/.claude/skills"

# (1) the link is simply gone — the case the store count could not see.
command rm -f "$WTP/.claude/skills/$BROKEN_UNIT"
remeasure "proj-deleted.log"
check "$(yesno command grep -q "^projected: 0 of $STORE_UNITS" "$SCRATCH/proj-deleted.log")" \
  "deleting_one_agent_link_changes_the_reported_projection_count" \
  "the count did not move when a link was removed — it is counting the store, not the links:
$(command grep -m1 '^projected:' "$SCRATCH/proj-deleted.log" || printf '        <no projected: line>')"
check "$(yesno absent_pattern '^verified:' "$SCRATCH/proj-deleted.log")" \
  "a_home_with_a_missing_agent_link_is_not_reported_as_verified" \
  "'verified:' was printed over a home an agent cannot read $BROKEN_UNIT from"

# (2) the entry exists and resolves to nothing. A directory listing cannot tell
#     this from a working link.
ln -s "$WTP_HOME/skills/no-such-unit-at-all" "$WTP/.claude/skills/$BROKEN_UNIT" || true
remeasure "proj-dangling.log"
check "$(yesno command grep -q "^projected: 0 of $STORE_UNITS" "$SCRATCH/proj-dangling.log")" \
  "a_dangling_agent_link_does_not_count_as_a_projection" \
  "a link to a nonexistent target was counted; see $SCRATCH/proj-dangling.log"

# (3) the entry resolves — into ANOTHER checkout's store. This is the one a
#     "does it resolve" check misses, and it is a per-checkout isolation failure:
#     the agent would be reading the project home's copy of the unit.
command rm -f "$WTP/.claude/skills/$BROKEN_UNIT"
ln -s "$PROJ_HOME/skills/$BROKEN_UNIT" "$WTP/.claude/skills/$BROKEN_UNIT" || true
remeasure "proj-foreign.log"
check "$(yesno command grep -q "^projected: 0 of $STORE_UNITS" "$SCRATCH/proj-foreign.log")" \
  "an_agent_link_that_resolves_into_another_checkout_does_not_count" \
  "a link into $PROJ_HOME was counted as this home serving the unit; see $SCRATCH/proj-foreign.log"

# The refusal, and its code. Without --allow-unprojected the run must not exit 0
# on a home an agent cannot read, and it must name the exact destination.
UNPROJ_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WTP" --force --no-project \
  > "$SCRATCH/proj-refuse.log" 2>&1 || UNPROJ_RC=$?
check "$(yesno test "$UNPROJ_RC" = 6)" \
  "an_unservable_home_exits_with_the_unprojected_code" \
  "expected exit 6, got $UNPROJ_RC; see $SCRATCH/proj-refuse.log"
check "$(yesno command grep -q "\.claude/skills/$BROKEN_UNIT" "$SCRATCH/proj-refuse.log")" \
  "the_refusal_names_the_link_an_agent_would_have_followed" \
  "the refusal does not name $WTP/.claude/skills/$BROKEN_UNIT; see $SCRATCH/proj-refuse.log"

# And the repair, because a check that only proves the script can refuse leaves
# the operator with a refusal and no way out. This is the whole D1 fix in one
# line: a plain re-run makes the home servable again.
command rm -f "$WTP/.claude/skills/$BROKEN_UNIT"
REPAIR_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$WTP" --force \
  > "$SCRATCH/proj-repair.log" 2>&1 || REPAIR_RC=$?
check "$(yesno test "$REPAIR_RC" = 0)" \
  "a_plain_rerun_repairs_the_projection" \
  "bootstrap exited $REPAIR_RC on a home with one missing link; see $SCRATCH/proj-repair.log"
check "$(yesno exists "$WTP/.claude/skills/$BROKEN_UNIT")" \
  "the_repaired_link_is_there_and_resolves" \
  "$WTP/.claude/skills/$BROKEN_UNIT still does not resolve after the repair run"
check "$(yesno command grep -q '^verified:' "$SCRATCH/proj-repair.log")" \
  "the_repaired_home_is_reported_as_verified_again" \
  "the repair run did not print 'verified:'; see $SCRATCH/proj-repair.log"

# The teardown property, which is what makes the REPAIR MECHANISM the one it is.
# Projecting through `sync` refreshes unit CONTENT — measured: it left
# skills/<unit>/.git/index differing from the project home's and `home close-out`
# then refused the worktree, which is issue #50 reintroduced by the fix for #10.
# The ledger-first path touches no unit content, so the worktree stays closable.
( cd "$PROJ" && bare bash "$SCRIPT_DIR/close-change.sh" "$WTP" --dry-run ) \
  > "$SCRATCH/proj-closeout.log" 2>&1 || true
check "$(yesno command grep -q 'gate:      clean' "$SCRATCH/proj-closeout.log")" \
  "projecting_a_worktree_home_does_not_make_it_unclosable" \
  "the close-out gate refused a worktree whose only change was its own projection:
$(command grep -E 'BLOCKED|^  [a-z]+ +skill' "$SCRATCH/proj-closeout.log" | command sed 's/^/        /')"

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
check "$(yesno absent_pattern '^verified:' "$SCRATCH/empty.log")" \
  "a_home_with_no_skills_is_never_reported_as_verified" \
  "'verified:' was printed over a home holding zero skills; see $SCRATCH/empty.log"
# `launch:` is the console's closing line on a good run, so its ABSENCE here is
# the property — and a negative check needs the positive one beside it or a
# renamed key would satisfy it forever. The positive is taken from the run at the
# top of this file, which is the same script printing the same key.
check "$(yesno absent_pattern '^launch:' "$SCRATCH/empty.log")" \
  "a_home_with_no_skills_does_not_close_by_inviting_a_launch" \
  "the run ended by telling the operator to launch an agent against an empty home"
check "$(yesno command grep -q '^launch:' "$SCRATCH/bootstrap.log")" \
  "the_key_whose_absence_is_asserted_above_is_one_this_script_really_prints" \
  "no 'launch:' line on a GOOD run either, so its absence on an empty home proves nothing"
check "$(yesno command grep -q 'onboard' "$SCRATCH/empty.log")" \
  "the_refusal_names_onboard_the_step_that_installs_the_bundled_skills" \
  "the one command that fixes this is never mentioned; see $SCRATCH/empty.log"

# skill-manager#145, re-anchored here from the deleted clone caveat: every
# home-mutating command this script prints must pin the agent-home variables as
# well as the home. With CLAUDE_CONFIG_DIR / CODEX_HOME / GEMINI_HOME unset, the
# binding step writes the OPERATOR'S ~/.claude.json — measured, `ADDED claude
# (~/.claude.json)`, from a line this file printed. This refusal is a string
# bootstrap-home.sh owns end to end, so it is where the property is checked.
EMPTY_PROJ_RC=0
# --force because the fixture scaffolded this project home directly: without it
# the run stops at "exists and is not empty" and never reaches the gate whose
# remedy is the subject here.
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$EMPTYP" --force \
  > "$SCRATCH/empty-project.log" 2>&1 || EMPTY_PROJ_RC=$?
ONBOARD_LINE="$(command grep -m1 'onboard --skip-gateway' "$SCRATCH/empty-project.log" || true)"
check "$(yesno test -n "$ONBOARD_LINE")" \
  "the_empty_project_refusal_prints_an_onboard_command_to_check" \
  "no 'onboard --skip-gateway' line at all (rc=$EMPTY_PROJ_RC), so the next check would prove nothing:
$(command sed 's/^/        /' "$SCRATCH/empty-project.log")"
check "$(yesno contains "CLAUDE_CONFIG_DIR=$EMPTYP" "$ONBOARD_LINE")" \
  "a_printed_remedy_pins_the_agent_home_env_too" \
  "'$ONBOARD_LINE' names the home but not CLAUDE_CONFIG_DIR — run from a bare shell it
      writes the operator's ~/.claude.json (skill-manager#145)"
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

# ------------------------- 5a. the DOCUMENTED first-time path actually works
#
# skill-project.toml's header comment is the highest-value page in this repo for
# a fresh agent — measured: it is the only place the `skill-project.toml` schema
# and the four-step home sequence are written down, and an eval agent found it
# and followed it. It opened with `mkdir -p .skill-manager/skills`, and that one
# line broke the sequence on its FIRST use, both ways round:
#
#   without --force  `.skill-manager exists and is not empty — inspect it, then
#                     pass --force …`, exit 1
#   with --force     (which the recipe itself carried) the clone is SKIPPED,
#                    because --force means "re-run the steps on an existing
#                    home"; three steps later `home policy --live` refuses a
#                    directory that "carries neither a descriptor nor the
#                    installed/ + skills/ pair", exit 1
#
# Both fixed, and the fix is in two places on purpose. The recipe lost the
# mkdir, because bootstrap-home.sh creates the home and `home clone` requires an
# absent or empty destination. And the check learned the difference between
# "non-empty" and "is a home", because the recipe is copied by hand and
# pre-creating a directory is a habit — the advice it used to give for that case
# made the outcome worse rather than better, which is the part that is not
# merely inconvenient.

step "The documented first-time home recipe works, and pre-creating cannot break it"

# THE RECIPE ITSELF, asserted on the file rather than restated here, because a
# test that restates the documentation cannot notice the documentation drifting.
# Both halves in one place: the mkdir is gone AND the line it used to precede is
# still there. Without the second, deleting the whole recipe would pass.
RECIPE="$SCRIPT_DIR/../skill-project.toml"
recipe_creates_nothing_before_bootstrapping() {
  [ -f "$RECIPE" ] || return 1
  command grep -q 'bootstrap-home.sh --root' "$RECIPE" || return 1
  ! command grep -qE '^#[[:space:]]+mkdir .*\.skill-manager' "$RECIPE"
}
check "$(yesno recipe_creates_nothing_before_bootstrapping)" \
  "the_documented_recipe_still_has_a_bootstrap_step_and_no_longer_creates_the_home_first" \
  "$RECIPE either lost its bootstrap-home.sh line or still tells the reader to
      mkdir .skill-manager first:
$(command grep -nE 'mkdir .*\.skill-manager|bootstrap-home.sh --root' "$RECIPE" | command sed 's/^/        /')"

# THE BEHAVIOUR, for the habit the recipe used to teach. A checkout where
# `.skill-manager/skills` was created by hand must still bootstrap — and the
# evidence is a real home, not exit 0: a bootstrap that skipped the clone exits
# 0 in some shapes and leaves a directory with no store at all.
RECIPEP="$SCRATCH/recipe-premade"
mkdir -p "$RECIPEP"
git -C "$RECIPEP" init -q -b main
git -C "$RECIPEP" config user.email selftest@example.invalid
git -C "$RECIPEP" config user.name "selftest"
printf 'fixture\n' > "$RECIPEP/README.md"
git -C "$RECIPEP" add -A
git -C "$RECIPEP" -c commit.gpgsign=false commit -qm "fixture"
mkdir -p "$RECIPEP/.skill-manager/skills"        # the habit, verbatim
PREMADE_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$RECIPEP" \
  > "$SCRATCH/recipe-premade.log" 2>&1 || PREMADE_RC=$?
premade_bootstrapped_a_real_home() {
  [ "$PREMADE_RC" = 0 ] || return 1
  [ -e "$RECIPEP/.skill-manager/home.runtime.json" ] || return 1
  exists "$RECIPEP/.skill-manager/skills/global-only-unit"
}
check "$(yesno premade_bootstrapped_a_real_home)" \
  "a_precreated_skill_manager_directory_no_longer_stops_the_first_bootstrap" \
  "rc=$PREMADE_RC, descriptor $(yesno exists "$RECIPEP/.skill-manager/home.runtime.json"),
      cloned unit $(yesno exists "$RECIPEP/.skill-manager/skills/global-only-unit"); see $SCRATCH/recipe-premade.log"

# AND THE CASE THAT MUST STILL REFUSE — with advice that is not the opposite of
# helpful. A directory holding FILES is somebody's, and --force would skip the
# clone and leave it exactly as it is, so the refusal must not name --force as
# the remedy. That sentence is the defect: it is what sent the recipe's own
# `--force` down the path that died three steps later about descriptors.
RECIPEF="$SCRATCH/recipe-foreign"
mkdir -p "$RECIPEF"
git -C "$RECIPEF" init -q -b main
git -C "$RECIPEF" config user.email selftest@example.invalid
git -C "$RECIPEF" config user.name "selftest"
printf 'fixture\n' > "$RECIPEF/README.md"
git -C "$RECIPEF" add -A
git -C "$RECIPEF" -c commit.gpgsign=false commit -qm "fixture"
mkdir -p "$RECIPEF/.skill-manager"
printf 'not a home\n' > "$RECIPEF/.skill-manager/notes.txt"
FOREIGN_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$RECIPEF" --force \
  > "$SCRATCH/recipe-foreign.log" 2>&1 || FOREIGN_RC=$?
check "$(yesno test "$FOREIGN_RC" != 0)" \
  "a_directory_that_is_not_a_home_is_still_refused_even_with_force" \
  "exit 0 over $RECIPEF/.skill-manager, which holds files and no home; see $SCRATCH/recipe-foreign.log"
# `holds files but is not a Skill Manager home`, which is BOOTSTRAP-HOME.SH'S
# OWN sentence and nothing else's. The obvious spelling — grep for "not a Skill
# Manager home" — passes on the defect too, because the old code accepted
# --force, skipped the clone, and let `home policy --live` say almost exactly
# that three steps later. Same words, different program, and the difference is
# the whole point: this must be refused BEFORE anything is written.
check "$(yesno command grep -q 'holds files but is not a Skill Manager home' "$SCRATCH/recipe-foreign.log")" \
  "and_the_refusal_is_this_scripts_own_before_the_clone_not_the_CLIs_three_steps_later" \
  "the refusal does not distinguish 'not empty' from 'not a home' in this script's own
      voice; see $SCRATCH/recipe-foreign.log"
check "$(yesno command grep -q 'force will NOT help' "$SCRATCH/recipe-foreign.log")" \
  "and_it_does_not_send_the_operator_to_force_which_would_skip_the_clone" \
  "the refusal for a non-home directory still points at --force; see $SCRATCH/recipe-foreign.log"
check "$(yesno absent "$RECIPEF/.skill-manager/home.runtime.json")" \
  "the_refused_run_wrote_nothing_into_the_directory_it_refused" \
  "$RECIPEF/.skill-manager gained a descriptor on a run that exited $FOREIGN_RC"

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

# ---- new-change.sh called DIRECTLY, which is the path `wt` does not cover.
#
# `wt` captures its child's stderr and discards it on success, so every
# measurement of "how much does provisioning a worktree print" taken through `wt`
# reads zero no matter what the child does. Measured on the direct call: 44 lines
# / 3970 bytes on stderr, of which 28 were a prose restatement of the five
# contract lines already on stdout.
#
# Budget and evidence in ONE check again, and here the evidence is the CONTRACT:
# a script that printed nothing at all on both streams would satisfy a line
# budget perfectly.
NCD_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/new-change.sh" WD1 ) \
  > "$SCRATCH/nc-direct.out" 2> "$SCRATCH/nc-direct.err" || NCD_RC=$?
NCD_LOG="$(run_log "$SCRATCH/nc-direct.err")"
nc_under_budget_with_contract() {
  [ "$NCD_RC" = 0 ] || return 1
  [ "$(lines_of "$SCRATCH/nc-direct.err")" -le 1 ] || return 1
  command grep -q '^WORKTREE ' "$SCRATCH/nc-direct.out" || return 1
  command grep -q '^LAUNCH ' "$SCRATCH/nc-direct.out" || return 1
  command grep -q '^CLOSE ' "$SCRATCH/nc-direct.out" || return 1
  return 0
}
check "$(yesno nc_under_budget_with_contract)" \
  "a_direct_new_change_prints_one_line_of_stderr_AND_the_whole_contract_on_stdout" \
  "rc=$NCD_RC, stderr $(lines_of "$SCRATCH/nc-direct.err") line(s), stdout:
$(command sed 's/^/        /' "$SCRATCH/nc-direct.out")
      stderr:
$(command sed 's/^/        /' "$SCRATCH/nc-direct.err")"
# And the narration is somewhere, in ONE file — this script's and
# bootstrap-home.sh's alike, which is the reason fd 2 is redirected rather than
# each call site rewritten.
check "$(yesno test -s "${NCD_LOG:-/nonexistent}")" \
  "the_direct_run_names_a_log_that_was_written" \
  "'${NCD_LOG:-<none>}' is missing or empty"
check "$(yesno command grep -q '^verified: ' "${NCD_LOG:-/nonexistent}")" \
  "the_worktrees_own_bootstrap_narration_lands_in_that_same_log" \
  "no 'verified:' line in ${NCD_LOG:-<none>} — bootstrap-home.sh's output went somewhere else"
check "$(yesno command grep -q 'Teardown note' "${NCD_LOG:-/nonexistent}")" \
  "and_so_does_new_changes_own_closing_prose" \
  "the closing notes were deleted rather than moved; they are the explanation of the contract"
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" close WD1 --force ) >/dev/null 2>&1 || true

NEW_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" new W1 ) \
  > "$SCRATCH/wt-new.out" 2> "$SCRATCH/wt-new.err" || NEW_RC=$?

# Non-vacuity before anything else: a run that failed would have an empty or
# two-line stdout, and "no prose on stdout" would be trivially true of it.
check "$(yesno test "$NEW_RC" = 0)" \
  "wt_new_creates_the_worktree_and_its_home_in_one_command" \
  "wt new exited $NEW_RC; see $SCRATCH/wt-new.err"

# ---- ONE LINE, and the path is on it.
#
# The budget and the evidence in the SAME check, always, and here it is not a
# style preference — three tests in this file have already been caught passing
# because the thing they measured printed nothing at all. "wt new's console is
# one line" is satisfied perfectly by a `wt` that exits 0 in silence, and by one
# that prints `created worktree ` with an empty path. So the assertion is: ONE
# line on stdout, NOTHING on stderr, and the path on that line is a directory
# that exists.
#
# Measured before this change, on the fixture below: 5 lines / 746 bytes, of
# which four restated the first — LAUNCH and IF-EXIT-8 are
# <WORKTREE>/.skill-manager/... by construction, CLOSE is the command the caller
# typed the other half of, BRANCH is feature/<TICKET>. IF-EXIT-8 was the most
# expensive of them and the least often useful: a remedy for a gate that had not
# fired, paid for on every run in which it never fires.
WT_LINE_V="$(command sed -n 's/^created worktree //p' "$SCRATCH/wt-new.out" | command sed -n 1p)"
new_is_one_line_naming_a_real_worktree() {
  [ "$(lines_of "$SCRATCH/wt-new.out")" = 1 ] || return 1
  [ "$(lines_of "$SCRATCH/wt-new.err")" = 0 ] || return 1
  [ -n "$WT_LINE_V" ] && [ -d "$WT_LINE_V" ]
}
check "$(yesno new_is_one_line_naming_a_real_worktree)" \
  "a_successful_wt_new_costs_one_line_AND_that_line_names_the_worktree" \
  "stdout $(lines_of "$SCRATCH/wt-new.out") line(s), stderr $(lines_of "$SCRATCH/wt-new.err") line(s),
      worktree '${WT_LINE_V:-<none>}' (is a directory: $(yesno test -d "${WT_LINE_V:-/nonexistent}")). stdout was:
$(command sed 's/^/        /' "$SCRATCH/wt-new.out")"

# And the four keys are ANSWERABLE, not merely derivable-in-principle. This is
# what makes dropping them from the constant path a move rather than a loss:
# every one of them is still a runnable path, one command away, and that command
# creates and removes nothing.
INFO_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" info W1 ) \
  > "$SCRATCH/wt-info.out" 2> "$SCRATCH/wt-info.err" || INFO_RC=$?
check "$(yesno test "$INFO_RC" = 0)" \
  "wt_info_answers_for_a_worktree_that_exists" \
  "wt info exited $INFO_RC; see $SCRATCH/wt-info.err"

INFO_WT_V="$(command sed -n 's/^WORKTREE  *//p' "$SCRATCH/wt-info.out" | command sed -n 1p)"
LAUNCH_V="$(command sed -n 's/^LAUNCH  *//p' "$SCRATCH/wt-info.out" | command sed -n 1p)"
CLOSE_V="$(command sed -n 's/^CLOSE  *//p' "$SCRATCH/wt-info.out" | command sed -n 1p)"
DRIFT_V="$(command sed -n 's/^IF-EXIT-8  *//p' "$SCRATCH/wt-info.out" | command sed -n 1p)"

# The two answers about the same ticket must be the SAME worktree. Without this
# the summary and the lookup could disagree and every check below would still
# pass — which is exactly the shape of issue #50.
check "$(yesno test -n "$INFO_WT_V" -a "$INFO_WT_V" = "$WT_LINE_V")" \
  "wt_info_names_the_same_worktree_the_one_line_summary_did" \
  "wt new said '${WT_LINE_V:-<none>}' and wt info said '${INFO_WT_V:-<none>}'"

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
#
# A refusal is allowed to cost more than a success — the next move is not
# derivable from anything — but it is allowed THREE LINES, not the 11 it used
# to take: `wt` dumped the whole of the child's stderr to the console on every
# failure, and the reason it went wrong is not the answer to "what do I run".
DUP_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" new W1 ) \
  > "$SCRATCH/wt-dup.out" 2> "$SCRATCH/wt-dup.err" || DUP_RC=$?
check "$(yesno test "$DUP_RC" != 0)" \
  "a_second_wt_new_for_the_same_ticket_fails" \
  "it exited 0, so the checks below would be asserting against a success"
DUP_FAILED="$(command sed -n 's/^error creating worktree: //p' "$SCRATCH/wt-dup.out" | command sed -n 1p)"
DUP_FIX="$(command sed -n 's/^fix: //p' "$SCRATCH/wt-dup.out" | command sed -n 1p)"
DUP_LOG="$(command sed -n 's/^log: //p' "$SCRATCH/wt-dup.out" | command sed -n 1p)"

# Budget AND evidence together again: three lines with the reason on them, not
# three lines of anything.
dup_is_three_lines_that_say_what_happened() {
  [ "$(lines_of "$SCRATCH/wt-dup.out")" -le 3 ] || return 1
  [ "$(lines_of "$SCRATCH/wt-dup.err")" = 0 ] || return 1
  [ -n "$DUP_FAILED" ]
}
check "$(yesno dup_is_three_lines_that_say_what_happened)" \
  "a_failing_wt_new_costs_three_lines_AND_one_of_them_says_what_failed" \
  "stdout $(lines_of "$SCRATCH/wt-dup.out") line(s), stderr $(lines_of "$SCRATCH/wt-dup.err") line(s), reason '${DUP_FAILED:-<none>}':
$(command sed 's/^/        /' "$SCRATCH/wt-dup.out")
      stderr:
$(command sed 's/^/        /' "$SCRATCH/wt-dup.err")"
check "$(yesno executable "${DUP_FIX%% *}")" \
  "a_failing_run_names_one_remedy_that_is_actually_runnable" \
  "fix names '${DUP_FIX:-<none>}', whose first token is not an executable file"
check "$(yesno contains "close W1" "$DUP_FIX")" \
  "the_remedy_for_an_existing_worktree_is_the_gated_teardown" \
  "fix is '$DUP_FIX' — anything but a 'wt close' here routes the operator around the close-out gate"

# THE REASONING MOVED, IT WAS NOT DELETED. A `wt` that simply stopped printing
# the child's stderr would satisfy every budget above and would have thrown the
# only diagnosis away; the log line is what makes the saving a relocation. Both
# halves in one check, because "a log was named" is trivially true of a script
# that names a path it never wrote.
TICKET_W1_MARKER="Repository for W1"
dup_named_a_log_that_holds_the_narration() {
  [ -n "$DUP_LOG" ] || return 1
  [ -s "$DUP_LOG" ] || return 1
  command grep -q "$TICKET_W1_MARKER" "$DUP_LOG"
}
check "$(yesno dup_named_a_log_that_holds_the_narration)" \
  "the_failure_names_a_log_that_exists_and_holds_the_prose_it_replaced" \
  "log is '${DUP_LOG:-<none>}' (size $(command wc -c < "${DUP_LOG:-/nonexistent}" 2>/dev/null | command tr -d ' ')) and does not contain '$TICKET_W1_MARKER'"

# And the closing half of the pair. The old trailing note printed the literal
# string `<branch>`, so the one fact still owed after a teardown was the one the
# operator had to go and look up. It is still owed, and it is still named — as a
# clause on the one line rather than as a third keyed line, because
# `feature/<TICKET>` is only the DEFAULT spelling and the path does not carry it.
CLOSE_RC2=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" close W1 ) \
  > "$SCRATCH/wt-close.out" 2> "$SCRATCH/wt-close.err" || CLOSE_RC2=$?
check "$(yesno test "$CLOSE_RC2" = 0)" \
  "wt_close_tears_the_worktree_down_in_one_command" \
  "wt close exited $CLOSE_RC2; see $SCRATCH/wt-close.err"
check "$(yesno absent "$WT_LINE_V")" \
  "wt_close_actually_removed_it" \
  "$WT_LINE_V is still there after a close that reported success"
CLOSED_LINE="$(command sed -n 1p "$SCRATCH/wt-close.out")"
close_is_one_line_naming_the_worktree_and_the_branch() {
  [ "$(lines_of "$SCRATCH/wt-close.out")" = 1 ] || return 1
  [ "$(lines_of "$SCRATCH/wt-close.err")" = 0 ] || return 1
  contains "$WT_LINE_V" "$CLOSED_LINE" || return 1
  contains "feature/W1" "$CLOSED_LINE"
}
check "$(yesno close_is_one_line_naming_the_worktree_and_the_branch)" \
  "a_successful_wt_close_costs_one_line_AND_that_line_names_the_worktree_and_the_dangling_branch" \
  "stdout $(lines_of "$SCRATCH/wt-close.out") line(s), stderr $(lines_of "$SCRATCH/wt-close.err") line(s); the line was:
      $CLOSED_LINE
      it must name both $WT_LINE_V and feature/W1 — the branch outlives the worktree,
      so which branch that is, is the whole remaining move"

# ------------------------------- 5c. the two contract key sets are EXCLUSIVE
#
# `wt --help` states "either, on failure FAILED / FIX". Measured on the pilot:
# `wt close <T> --force` exited 0 having printed FAILED and FIX and then CLOSED,
# BRANCH and DELETE. A caller parsing stdout saw a failure on a run that
# succeeded; a caller that keys on FAILED first saw the opposite of what
# happened. The forced run is a SUCCESS the operator asked for — the refusal is
# still printed, in full, on stderr where every other explanation here lives.

step "wt close --force reports one outcome, not both"

FORCED_WT=""
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" new W2 ) \
  > "$SCRATCH/wt-new2.out" 2> "$SCRATCH/wt-new2.err" || true
FORCED_WT="$(command sed -n 's/^created worktree //p' "$SCRATCH/wt-new2.out" | command sed -n 1p)"

# Work the gate must block on: a unit the PROJECT home has never seen. Without
# it the forced path is never reached and the check below measures the clean
# path twice.
if [ -n "$FORCED_WT" ] && [ -d "$FORCED_WT/.skill-manager" ]; then
  seed_home "$FORCED_WT/.skill-manager" "forced-wt-only-unit"
fi

BLOCK_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" close W2 ) \
  > "$SCRATCH/wt-block.out" 2> "$SCRATCH/wt-block.err" || BLOCK_RC=$?

# Anchored on `^KEY` followed by whitespace, always: `CLOSE` is a substring of
# `CLOSED`, and a substring match here would report the failure key set present
# on every successful `new`.
has_key() { command grep -qE "^$1[[:space:]]" "$2"; }

# Non-vacuity, and it is the whole fixture: the forced run below only proves
# something if the gate really refused first.
check "$(yesno test "$BLOCK_RC" != 0)" \
  "the_gate_blocks_the_unforced_close_so_the_forced_one_has_something_to_override" \
  "wt close exited $BLOCK_RC with a unit only the worktree home holds; see $SCRATCH/wt-block.err"
# A refused close is the failure a `wt` caller meets most often, so it gets its
# own budget as well as its own shape. Three lines, and the second of them is
# the FIRST BLOCKER'S OWN REMEDY — the command that clears the thing the gate
# stopped on, not `--force`, which is always available and always the wrong one
# to lead with. Measured before: 25 lines / 3.3 KB, of which 23 were the gate's
# transcript printed a second time.
BLOCK_REASON="$(command sed -n 's/^error closing worktree: //p' "$SCRATCH/wt-block.out" | command sed -n 1p)"
BLOCK_FIX="$(command sed -n 's/^fix: //p' "$SCRATCH/wt-block.out" | command sed -n 1p)"
BLOCK_LOG="$(command sed -n 's/^log: //p' "$SCRATCH/wt-block.out" | command sed -n 1p)"
block_is_three_lines_that_say_what_happened() {
  [ "$(lines_of "$SCRATCH/wt-block.out")" -le 3 ] || return 1
  [ "$(lines_of "$SCRATCH/wt-block.err")" = 0 ] || return 1
  [ -n "$BLOCK_REASON" ]
}
check "$(yesno block_is_three_lines_that_say_what_happened)" \
  "a_blocked_close_costs_three_lines_AND_one_of_them_says_why_it_refused" \
  "stdout $(lines_of "$SCRATCH/wt-block.out") line(s), stderr $(lines_of "$SCRATCH/wt-block.err") line(s), reason '${BLOCK_REASON:-<none>}':
$(command sed 's/^/        /' "$SCRATCH/wt-block.out")
      stderr:
$(command sed 's/^/        /' "$SCRATCH/wt-block.err")"
check "$(yesno contains "home sync" "$BLOCK_FIX")" \
  "the_remedy_on_a_refused_close_is_the_blockers_own_not_force" \
  "fix is '${BLOCK_FIX:-<none>}' — --force is always true and is the one that DESTROYS the work,
      so a refusal that leads with it teaches the operator to discard"
# And the gate's transcript — the list of what would be lost — is not gone, it
# is in the file the third line names. Named-and-empty is the failure this pair
# exists to catch: an assertion phrased as "a log was named" passes over a path
# that was never written.
block_named_a_log_holding_the_blocker() {
  [ -n "$BLOCK_LOG" ] || return 1
  [ -s "$BLOCK_LOG" ] || return 1
  command grep -q 'forced-wt-only-unit' "$BLOCK_LOG"
}
check "$(yesno block_named_a_log_holding_the_blocker)" \
  "the_refusal_names_a_log_that_holds_the_blocking_unit_it_no_longer_prints" \
  "log is '${BLOCK_LOG:-<none>}' and does not name forced-wt-only-unit"

check "$(yesno test "$(yesno has_key CLOSED "$SCRATCH/wt-block.out")" = 0)" \
  "a_blocked_close_does_not_also_claim_it_closed" \
  "CLOSED and a refusal on the same run; see $SCRATCH/wt-block.out"

FORCE_RC2=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" close W2 --force ) \
  > "$SCRATCH/wt-force.out" 2> "$SCRATCH/wt-force.err" || FORCE_RC2=$?

check "$(yesno test "$FORCE_RC2" = 0)" \
  "a_forced_close_succeeds" \
  "wt close --force exited $FORCE_RC2; see $SCRATCH/wt-force.err"
check "$(yesno has_key CLOSED "$SCRATCH/wt-force.out")" \
  "a_forced_close_reports_the_success_key_set" \
  "no CLOSED line on a run that removed the worktree; see $SCRATCH/wt-force.out"
check "$(yesno test "$(yesno has_key FAILED "$SCRATCH/wt-force.out")" = 0)" \
  "a_forced_close_does_not_also_report_the_failure_contract" \
  "FAILED is on stdout of a run that exited 0 and removed the worktree:
$(command sed 's/^/        /' "$SCRATCH/wt-force.out")"
check "$(yesno test "$(yesno has_key FIX "$SCRATCH/wt-force.out")" = 0)" \
  "a_forced_close_does_not_print_a_fix_for_a_thing_it_did_anyway" \
  "FIX is on stdout of a successful forced close; see $SCRATCH/wt-force.out"

# The explanation must not have been LOST, only moved. A fix that silenced the
# refusal instead of re-routing it would satisfy every check above.
check "$(yesno command grep -q 'DISCARDED' "$SCRATCH/wt-force.err")" \
  "a_forced_close_still_says_on_stderr_what_it_discarded" \
  "the forced run threw work away and said so nowhere; see $SCRATCH/wt-force.err"
check "$(yesno command grep -q 'forced-wt-only-unit' "$SCRATCH/wt-force.err")" \
  "a_forced_close_names_the_work_it_discarded" \
  "the discarded unit is not named on stderr; see $SCRATCH/wt-force.err"

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

# ------------- onboarding leaves the tree clean, AND info/exclude is why
#
# Measured: after a documented bootstrap + install, `git status --porcelain`
# read `?? .claude.json`, and the next documented step — `wt new`, which asserts
# a clean tree — refused with `working tree is not clean`. Onboarding a repo
# made it unusable by the next step of onboarding it. `/.claude/` does not match
# `/.claude.json`, and the documented rule list had four entries.
#
# THREE PROPERTIES, and only the first is what a naive test would check:
#
#   1. after the bootstrap, nothing the home machinery put at the root is
#      reported by git status, whatever it is called — and the operator's own
#      untracked work IS still reported, because a bootstrap that silenced
#      `git status` wholesale would satisfy (1) and be far worse.
#
#   2. `$GIT_COMMON_DIR/info/exclude` IS WHY. It leaves a tree exactly as clean
#      as a `.gitignore` rule does, so (1) alone passes under either mechanism
#      and proves nothing about which one is running. `git check-ignore -v` names
#      the source file, and it is the only thing that tells them apart. Asserted
#      as an exact string, so "nothing ignores it" cannot satisfy it either.
#
#   3. THE TRACKED `.gitignore` WAS NOT TOUCHED. That is the whole reason this
#      mechanism was chosen over writing the tracked file: onboarding a repo must
#      never require a commit TO that repo, because read-only checkouts, CI, and
#      vendored third-party constituents cannot make one. A bootstrap that
#      modified `.gitignore` would leave a dirty tree in a different way and
#      `wt new` would refuse it just the same — so `git status` must show no
#      change to it, and the fixture's four rules must still be four.
#
# The fixture carries EXACTLY the four documented rules and no fifth, so the
# artefact really is uncovered by them and this section is about the mechanism
# rather than about a `.gitignore` that already happened to be right.

step "A bootstrapped checkout is clean, and info/exclude — not .gitignore — is why"

CLEANP="$SCRATCH/cleanproj"
mkdir -p "$CLEANP"
git -C "$CLEANP" init -q -b main
git -C "$CLEANP" config user.email selftest@example.invalid
git -C "$CLEANP" config user.name "selftest"
# EXACTLY the four documented rules, and no fifth. The omission is the subject
# of the defect, so the fixture must not pre-fix it — a `.gitignore` copied from
# a working setup would make this whole section assert nothing.
printf '/.skill-manager/\n/.claude/\n/.codex/\n/.gemini/\n' > "$CLEANP/.gitignore"
printf 'x\n' > "$CLEANP/README.md"
git -C "$CLEANP" add -A
git -C "$CLEANP" -c commit.gpgsign=false commit -qm "fixture"
check "$(yesno test "$(command grep -c . "$CLEANP/.gitignore")" = 4)" \
  "the_clean_tree_fixture_carries_only_the_four_documented_ignore_rules" \
  "the fixture .gitignore has $(command grep -c . "$CLEANP/.gitignore") rules; a fifth would pre-fix the defect"

# No seeded home here, deliberately: this fixture is a repo being onboarded, so
# the bootstrap has to CLONE (from the decoy global home `bare` points HOME at).
# Seeding one would make the run refuse with "exists and is not empty" and every
# assertion below would be about a bootstrap that never happened.

# The artefact, planted at the root the way `install`/`sync` writes it, BEFORE
# the bootstrap — that is the ordinary case, since the documented order is
# bootstrap, then install. Its own non-vacuity: it must be reported as untracked
# by the four documented rules, or nothing below proves anything.
printf '{"mcpServers":{"virtual-mcp-gateway":{"type":"http","url":"http://127.0.0.1:0/mcp"}}}\n' \
  > "$CLEANP/.claude.json"
printf 'the operator was in the middle of something\n' > "$CLEANP/NOTES.md"
git -C "$CLEANP" status --porcelain > "$SCRATCH/clean-before.txt"
check "$(yesno command grep -q '^?? \.claude\.json$' "$SCRATCH/clean-before.txt")" \
  "the_four_documented_rules_really_do_leave_claude_json_untracked" \
  "the fixture's .claude.json is already ignored, so every check below would pass for the wrong reason:
$(command sed 's/^/        /' "$SCRATCH/clean-before.txt")"

# The tracked file as it stands before the bootstrap. Property 3 is a
# comparison, so it needs a baseline taken before the mechanism could have
# touched anything.
CLEAN_EXCL="$CLEANP/.git/info/exclude"
command cp "$CLEANP/.gitignore" "$SCRATCH/clean-gitignore-before.txt"

CLEAN_RC=0
bare bash "$SCRIPT_DIR/bootstrap-home.sh" --root "$CLEANP" \
  > "$SCRATCH/clean.log" 2>&1 || CLEAN_RC=$?
check "$(yesno test "$CLEAN_RC" = 0)" \
  "the_clean_tree_fixture_bootstrapped" \
  "bootstrap exited $CLEAN_RC; the cleanliness checks would be about a run that did nothing. See $SCRATCH/clean.log"

git -C "$CLEANP" status --porcelain > "$SCRATCH/clean-after.txt"
check "$(yesno absent_pattern '\.claude\.json' "$SCRATCH/clean-after.txt")" \
  "nothing_the_home_machinery_put_at_the_root_is_left_dirty" \
  "still reported by git status after the bootstrap:
$(command sed 's/^/        /' "$SCRATCH/clean-after.txt")"

# PROPERTY 2, and it is the whole reason this section is worth more than a
# `git status` call. `check-ignore -v` prints `<source>:<line>:<pattern>\t<path>`;
# the source must be the per-clone exclude file. Asserted as an exact string
# rather than as "not .gitignore", so an empty result — nothing ignoring the
# path at all — cannot satisfy it either, and the fixture's own four rules
# (which do NOT cover this path, asserted above) cannot be mistaken for it.
CLEAN_SRC="$(git -C "$CLEANP" check-ignore -v --no-index -- .claude.json 2>/dev/null | command head -1 || true)"
CLEAN_SRC="${CLEAN_SRC%%:*}"
check "$(yesno test "$CLEAN_SRC" = ".git/info/exclude")" \
  "the_per_clone_exclude_file_is_what_makes_the_tree_clean" \
  "git check-ignore names '${CLEAN_SRC:-nothing}' as the source of the rule covering .claude.json,
        not .git/info/exclude — 'the tree is clean' is true under either mechanism, so this is
        the only assertion that says which one ran"

# And the rule itself, in the file, by name. The `-x` is deliberate: a rule that
# merely mentions the path inside the header comment would satisfy a loose grep.
check "$(yesno command grep -qxF '/.claude.json' "$CLEAN_EXCL")" \
  "the_exclude_file_carries_the_measured_rule_verbatim" \
  "$CLEAN_EXCL has no \`/.claude.json\` line:
$(command sed 's/^/        /' "$CLEAN_EXCL")"

# PROPERTY 3. Writing the tracked file was the other candidate mechanism, and it
# was rejected because onboarding a repo must not require a commit TO that repo
# — a read-only checkout, a CI job or a vendored constituent cannot make one.
# Both halves: the bytes are unchanged, and git agrees the file is unmodified
# (a bootstrap that rewrote it identically would pass the first and still be
# doing the wrong thing on some other repo).
check "$(yesno same_file "$CLEANP/.gitignore" "$SCRATCH/clean-gitignore-before.txt")" \
  "the_bootstrap_did_not_write_the_tracked_gitignore" \
  "bootstrap-home.sh modified the tracked .gitignore, which no read-only checkout could commit:
$(command diff "$SCRATCH/clean-gitignore-before.txt" "$CLEANP/.gitignore" | command sed 's/^/        /')"

check "$(yesno absent_pattern '\.gitignore' "$SCRATCH/clean-after.txt")" \
  "git_does_not_report_the_gitignore_as_modified_either" \
  "git status reports .gitignore after the bootstrap, so the tree is dirty the other way:
$(command sed 's/^/        /' "$SCRATCH/clean-after.txt")"

# The other half of property 1, and it is the one that makes the section worth
# having: a bootstrap that ignored everything would satisfy every check above.
check "$(yesno command grep -q 'NOTES.md' "$SCRATCH/clean-after.txt")" \
  "the_operators_own_untracked_work_is_still_reported" \
  "the bootstrap silenced a file it did not create — git status no longer names NOTES.md"

# And the consequence, end to end, because "clean" is only interesting as the
# precondition of the next command.
git -C "$CLEANP" add NOTES.md
git -C "$CLEANP" -c commit.gpgsign=false commit -qm "the operator's work"
WTNEW_RC=0
( cd "$CLEANP" && bare bash "$SCRIPT_DIR/wt" new C1 ) \
  > "$SCRATCH/clean-wtnew.out" 2> "$SCRATCH/clean-wtnew.err" || WTNEW_RC=$?
check "$(yesno test "$WTNEW_RC" = 0)" \
  "wt_new_is_not_refused_by_a_tree_the_bootstrap_left_behind" \
  "wt new exited $WTNEW_RC after a clean bootstrap:
$(command sed 's/^/        /' "$SCRATCH/clean-wtnew.out")"

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

# --------------------- agent-home.sh runs a copy that can do the job, and says which
#
# Measured, one fixture, one command, two answers:
#
#   the checkout's scripts/bootstrap-home.sh   (941ec20, 71 KB)  18/18 skills
#                                                                projected
#   $HOME/.skill-manager's copy                (c5abdab, 33 KB)  EMPTY agent homes
#
# `agent-home.sh` took the second and said nothing. Its "running from the GLOBAL
# home" note was conditional on the active home being something ELSE, and from a
# bare shell SKILL_MANAGER_HOME is unset — so the active home IS the global home,
# the condition was false, and the one case where the answer was wrong was the
# one case that was silent.
#
# Two properties, and the second is what a weaker test would miss: the locator
# must not run an incapable copy, AND WHICH COPY IT RAN MUST BE OBSERVABLE. A
# check that only asserted "the bootstrap ran" passes under the defect — the
# stale copy runs, exits 0, and prints an ordinary-looking report. So every
# decoy here prints a MARKER naming itself, and the assertions are about which
# marker appears.

step "agent-home.sh refuses a stale bootstrap copy, and names the one it runs"

LOC="$SCRATCH/locator"
LOC_HOME="$SCRATCH/locator-home"
LOC_GLOBAL="$LOC_HOME/.skill-manager/skills/git-integration-repo/scripts/bootstrap-home.sh"
LOC_REPO="$LOC/scripts/bootstrap-home.sh"
mkdir -p "$LOC/scripts" "$LOC_HOME"
command cp "$SCRIPT_DIR/agent-home.sh" "$LOC/scripts/agent-home.sh"
# A REAL checkout, and every invocation below is made from inside it. `--root`
# defaults to the CALLER'S git toplevel (see the next section), so a locator run
# from wherever this suite happens to be standing would resolve the target — and
# therefore candidate rungs 2 and 3 — against THIS repository, and the decoys
# planted here would be competing with git-integration-repo's own real
# scripts/bootstrap-home.sh. That is a fixture leak, not a finding.
git -C "$LOC" init -q -b main
git -C "$LOC" config user.email selftest@example.invalid
git -C "$LOC" config user.name "selftest"
printf 'fixture\n' > "$LOC/README.md"
git -C "$LOC" add -A
git -C "$LOC" -c commit.gpgsign=false commit -qm "fixture"

# A decoy bootstrap-home.sh. `$2` decides whether its `--help` names the
# capability the locator probes for; `$3` is the marker it prints when it is
# actually RUN. Two separate facts on purpose — "was it accepted" and "was it
# executed" are exactly what the locator has to get right, and decoys that could
# not be told apart would let a wrong choice through.
make_decoy() {
  local path="$1" capable="$2" marker="$3"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = --help ]; then\n'
    printf '  printf "usage: bootstrap-home.sh [--root DIR] [--force]\\n"\n'
    if [ "$capable" = capable ]; then
      printf '  printf "  --allow-unprojected  accept an unprojected home\\n"\n'
    fi
    printf '  exit 0\nfi\n'
    printf 'printf "RAN:%s\\n"\n' "$marker"
  } > "$path"
  chmod +x "$path"
}

# HOME of its own, not the suite's $FAKE_HOME: this section plants a
# git-integration-repo skill into a global home, and doing that to the decoy
# home the rest of the file measures would change what those checks are about.
locbare() { env -u SKILL_MANAGER_HOME HOME="$LOC_HOME" SKILL_MANAGER_CLI="$CLI" "$@"; }

# Non-vacuity of the decoys themselves, before anything is asserted with them.
# If the "stale" one happened to name the capability, every refusal check below
# would be measuring nothing.
make_decoy "$LOC_GLOBAL" stale global-stale
check "$(yesno absent_substring '--allow-unprojected' "$(bash "$LOC_GLOBAL" --help 2>&1)")" \
  "the_stale_decoy_really_does_lack_the_capability_the_locator_probes_for" \
  "the stale decoy's --help names --allow-unprojected, so 'it was refused' would prove nothing"

LOC_STALE_RC=0
( cd "$LOC" && locbare bash "$LOC/scripts/agent-home.sh" ) > "$SCRATCH/loc-stale.out" 2> "$SCRATCH/loc-stale.err" \
  || LOC_STALE_RC=$?
check "$(yesno test "$LOC_STALE_RC" != 0)" \
  "a_locator_that_can_only_find_a_stale_bootstrap_refuses" \
  "agent-home.sh exited 0 with nothing but a pre-projection copy to run"

# The assertion that separates "refused" from "ran it and failed afterwards".
check "$(yesno absent_pattern 'RAN:global-stale' "$SCRATCH/loc-stale.out")" \
  "the_stale_copy_was_not_executed_only_rejected" \
  "the stale copy RAN — a home whose agent directories would have been left empty:
$(command sed 's/^/        /' "$SCRATCH/loc-stale.out")"

check "$(yesno command grep -q 'TOO OLD' "$SCRATCH/loc-stale.err")" \
  "the_refusal_names_the_copy_it_rejected_and_why" \
  "the refusal does not say which candidate was too old:
$(command sed 's/^/        /' "$SCRATCH/loc-stale.err")"

check "$(yesno command grep -q 'skill-manager sync' "$SCRATCH/loc-stale.err")" \
  "the_refusal_names_a_command_that_clears_it" \
  "the refusal is a diagnosis with no remedy"

# Now a capable copy in the same place. The bare-shell case, and the exact one
# whose announcement used to be suppressed: SKILL_MANAGER_HOME is unset, so the
# copy that answers is the GLOBAL home's.
make_decoy "$LOC_GLOBAL" capable global-fresh
LOC_G_RC=0
( cd "$LOC" && locbare bash "$LOC/scripts/agent-home.sh" ) > "$SCRATCH/loc-global.out" 2> "$SCRATCH/loc-global.err" \
  || LOC_G_RC=$?
check "$(yesno command grep -q 'RAN:global-fresh' "$SCRATCH/loc-global.out")" \
  "a_capable_installed_copy_is_used_when_the_checkout_ships_none" \
  "agent-home.sh exited $LOC_G_RC and never reached the capable copy:
$(command sed 's/^/        /' "$SCRATCH/loc-global.err")"

check "$(yesno contains "$LOC_GLOBAL" "$(cat "$SCRATCH/loc-global.err")")" \
  "the_run_says_which_copy_it_chose_even_from_a_bare_shell" \
  "the copy that ran was the GLOBAL home's and stderr never named it — this is the
        note that was conditional on the active home differing from \$HOME/.skill-manager,
        which from a bare shell it never does:
$(command sed 's/^/        /' "$SCRATCH/loc-global.err")"

# And the ordering, with BOTH copies capable and distinguishable. This is the
# check a "did the bootstrap run" test cannot make: both answers are a successful
# run, and only the marker says which file produced it.
make_decoy "$LOC_REPO" capable repo-fresh
LOC_R_RC=0
( cd "$LOC" && locbare bash "$LOC/scripts/agent-home.sh" ) > "$SCRATCH/loc-repo.out" 2> "$SCRATCH/loc-repo.err" \
  || LOC_R_RC=$?
check "$(yesno command grep -q 'RAN:repo-fresh' "$SCRATCH/loc-repo.out")" \
  "the_checkouts_own_copy_wins_over_an_equally_capable_installed_one" \
  "with two capable copies the locator ran the wrong one (exit $LOC_R_RC):
$(command sed 's/^/        /' "$SCRATCH/loc-repo.out")"

check "$(yesno contains "$LOC_REPO" "$(cat "$SCRATCH/loc-repo.err")")" \
  "the_announcement_names_the_copy_that_actually_ran" \
  "stderr does not name $LOC_REPO, so the announcement cannot be used to tell the copies apart:
$(command sed 's/^/        /' "$SCRATCH/loc-repo.err")"

# ------------------- agent-home.sh bootstraps the CALLER'S checkout, not its own
#
# The locator section above proves WHICH COPY runs. This one proves WHICH
# CHECKOUT it is run against, and the two were answered by the same variable.
#
# `--root` defaulted to the SCRIPT's enclosing git toplevel. That is the right
# answer in exactly one arrangement — a copy sitting in the target repo's own
# `scripts/` — which is the arrangement every existing check here uses, and the
# arrangement a real agent never has: the copy an agent reaches is the INSTALLED
# one, under `<home>/skills/git-integration-repo/scripts/`. Measured from a plain
# repo, from an integration repo and from a constituent, all three identical:
#
#   ✗ source and destination homes must not nest: <home> vs <home>/skills/git-integration-repo/.skill-manager
#   exit 1
#
# The nesting refusal is CORRECT — it is what stopped a 916 MB write into the
# operator's global home — so an exit code proves nothing here: the defect and
# the fix both end in a refusal when the target is wrong, and both end in exit 0
# when it is right. WHICH ROOT WAS CHOSEN is the fact, so the bootstrap is a
# decoy that reports the `--root` it was handed, and every assertion is about
# that string, in both directions: the caller's checkout must appear AND the
# script's own enclosing directory must not.

step "agent-home.sh gives the home to the checkout the CALLER is standing in"

AHR="$SCRATCH/agent-home-root"
AH_SKILL="$AHR/installed-skill"          # where agent-home.sh is resolved FROM
AH_HOME="$AHR/home"                      # a HOME with no git-integration-repo in it
mkdir -p "$AH_SKILL/scripts" "$AH_HOME"
command cp "$SCRIPT_DIR/agent-home.sh" "$AH_SKILL/scripts/agent-home.sh"

# A bootstrap that does nothing but say which checkout it was pointed at. It
# answers `--help` with the probed capability so the locator accepts it, and it
# writes nothing at all — the subject here is the ARGUMENT, and a decoy that also
# created a home would make "nothing was written" ambiguous.
AH_DECOY="$AH_SKILL/scripts/bootstrap-home.sh"
cat > "$AH_DECOY" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf 'usage: bootstrap-home.sh [--root DIR]\n'
  printf '  --allow-unprojected  accept an unprojected home\n'
  exit 0
fi
root=""; prev=""
for a in "$@"; do
  [ "$prev" = "--root" ] && { root="$a"; break; }
  prev="$a"
done
printf 'ROOT:%s\n' "$root"
EOF
chmod +x "$AH_DECOY"

ahbare() { env -u SKILL_MANAGER_HOME HOME="$AH_HOME" SKILL_MANAGER_CLI="$CLI" "$@"; }

# The three shapes the defect was measured in. Each is its own git toplevel, and
# none of them is the directory agent-home.sh lives in — which is the whole
# fixture.
AH_PLAIN="$AHR/plain"
AH_INTEG="$AHR/integ"
AH_CONST="$AH_INTEG/constituents/leaf"
for d in "$AH_PLAIN" "$AH_INTEG" "$AH_CONST"; do
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email selftest@example.invalid
  git -C "$d" config user.name "selftest"
  printf 'x\n' > "$d/README.md"
  git -C "$d" add -A
  git -C "$d" -c commit.gpgsign=false commit -qm "fixture"
done
printf '[integration]\nname = "ah-integ"\n' > "$AH_INTEG/integration.toml"

# Non-vacuity, three ways, before a single assertion is made with this fixture.

# 1. The decoy really does report the root it is handed. Without this, every
#    `ROOT:<x>` check below could be measuring a decoy that prints a constant.
AH_PROBE="$(bash "$AH_DECOY" --root "$AH_PLAIN" 2>&1 || true)"
check "$(yesno contains "ROOT:$AH_PLAIN" "$AH_PROBE")" \
  "the_root_reporting_decoy_reports_the_root_it_is_handed" \
  "handed --root $AH_PLAIN the decoy said '$AH_PROBE', so 'it reported the caller's checkout' would prove nothing"

# 2. The decoy is not merely echoing its argument list — handed a DIFFERENT root
#    it must say something different, or `absent ROOT:$AH_SKILL` is true of any
#    decoy at all.
AH_PROBE2="$(bash "$AH_DECOY" --root "$AH_SKILL" 2>&1 || true)"
check "$(yesno contains "ROOT:$AH_SKILL" "$AH_PROBE2")" \
  "the_decoy_can_also_report_the_root_the_defect_would_have_chosen" \
  "the decoy cannot express the defect's answer, so the negative half of each check below is vacuous"

# 3. The script's own enclosing directory differs from every target. If they
#    coincided — which is exactly the arrangement that hid this for so long —
#    both halves of every check would be true no matter which root was picked.
AH_SAME=""
for d in "$AH_PLAIN" "$AH_INTEG" "$AH_CONST"; do
  [ "$d" = "$AH_SKILL" ] && AH_SAME="$AH_SAME $d"
done
check "$(yesno test -z "$AH_SAME")" \
  "the_script_is_resolved_from_somewhere_that_is_not_any_of_the_targets" \
  "agent-home.sh lives at $AH_SKILL, which is also a target:$AH_SAME — the defect is invisible from there"

# And now the measurement, per shape. `plain` is an ordinary repo, `integ` holds
# integration.toml, and `leaf` is a git repo INSIDE integ — the constituent case,
# which is the one place the two answers used to coincide for the operators who
# tested this, and therefore the one that has to be named separately.
ah_case() { # $1 = label, $2 = checkout to stand in
  local label="$1" dir="$2" log="$SCRATCH/ah-$1.log" rc=0
  ( cd "$dir" && ahbare bash "$AH_SKILL/scripts/agent-home.sh" ) > "$log" 2>&1 || rc=$?
  check "$(yesno command grep -qxF "ROOT:$dir" "$log")" \
    "from_a_${label}_checkout_the_home_is_bootstrapped_for_that_checkout" \
    "standing in $dir, the bootstrap was pointed at '$(command grep -m1 '^ROOT:' "$log" || printf '<no ROOT: line>')' (rc=$rc)"
  # Fixed-string, whole-line: the scratch path can carry `.` and a BRE would
  # match more than it is asked to, which for a NEGATIVE check means failing on
  # a run that was correct.
  check "$(yesno test "$(yesno command grep -qxF "ROOT:$AH_SKILL" "$log")" = 0)" \
    "from_a_${label}_checkout_the_scripts_own_directory_is_not_the_target" \
    "the bootstrap was pointed at $AH_SKILL — the installed skill directory, which nests inside
      the home it would clone from. This is the defect, and it exits non-zero either way, so only
      the root can tell the two apart."
}
ah_case plain       "$AH_PLAIN"
ah_case integration "$AH_INTEG"
ah_case constituent "$AH_CONST"

# An explicit --root still wins over the cwd, from a cwd that would answer
# differently — otherwise "it reads the cwd" would have replaced one hardcoded
# answer with another.
AH_EXPLICIT="$SCRATCH/ah-explicit.log"
( cd "$AH_INTEG" && ahbare bash "$AH_SKILL/scripts/agent-home.sh" --root "$AH_PLAIN" ) \
  > "$AH_EXPLICIT" 2>&1 || true
check "$(yesno command grep -qxF "ROOT:$AH_PLAIN" "$AH_EXPLICIT")" \
  "an_explicit_root_still_wins_over_the_callers_checkout" \
  "--root $AH_PLAIN given from inside $AH_INTEG resolved to '$(command grep -m1 '^ROOT:' "$AH_EXPLICIT" || printf '<none>')'"

# --------------------- no entry point here runs on --help, or takes a flag as a name
#
# git-integration-skill#7, filed against propagate.sh and found again in
# init-integration.sh during a budget eval: `--help` was consumed as the repo
# NAME and the script executed against the caller's cwd — which that time was the
# operator's own repository. It was idempotent and did no damage; `refresh.sh`,
# with the same shape, reaches `git reset --hard`.
#
# An exit-code check cannot see this. `init-integration.sh --help` exited 0 under
# the defect, because scaffolding an integration repo called `--help` SUCCEEDED.
# So the property asserted here is that NOTHING WAS EXECUTED: a listing of the
# directory taken before the run must equal the listing taken after it. And
# because "the listing did not change" is also true of a script that cannot run
# at all, the same script is run in the same fixture with a REAL argument first,
# and that listing must change.

step "No entry point runs on --help, and none takes a flag as a name"

HELPP="$SCRATCH/helpguard"
mkdir -p "$HELPP/control" "$HELPP/subject" "$HELPP/sweep"
for d in "$HELPP/control" "$HELPP/subject" "$HELPP/sweep"; do
  git -C "$d" init -q -b main
  git -C "$d" config user.email selftest@example.invalid
  git -C "$d" config user.name "selftest"
  printf 'x\n' > "$d/README.md"
  git -C "$d" add -A
  git -C "$d" -c commit.gpgsign=false commit -qm "fixture"
done

# THE CONTROL, and it is the mutation proof: the same script, the same kind of
# directory, one real argument. init-integration.sh is the one the eval measured,
# and what it does is exactly what `--help` must not do.
HELP_CTL_BEFORE="$SCRATCH/help-ctl-before.txt"
listing "$HELPP/control" > "$HELP_CTL_BEFORE"
( cd "$HELPP/control" && bare bash "$SCRIPT_DIR/init-integration.sh" helpguard-control ) \
  > "$SCRATCH/help-control.log" 2>&1 || true
listing "$HELPP/control" > "$SCRATCH/help-ctl-after.txt"
check "$(yesno differs_file "$HELP_CTL_BEFORE" "$SCRATCH/help-ctl-after.txt")" \
  "the_scaffolder_really_does_write_into_the_directory_it_is_run_from" \
  "init-integration.sh with a real name changed nothing, so 'it changed nothing on --help' proves nothing"
check "$(yesno command grep -q 'helpguard-control' "$HELPP/control/integration.toml")" \
  "the_control_run_wrote_the_name_it_was_given" \
  "no integration.toml naming helpguard-control; the control did not do the thing --help must not do"

# THE SUBJECT. Same script, same shape of directory, `--help` instead of a name.
HELP_SUBJ_BEFORE="$SCRATCH/help-subj-before.txt"
listing "$HELPP/subject" > "$HELP_SUBJ_BEFORE"
HELP_RC=0
( cd "$HELPP/subject" && bare bash "$SCRIPT_DIR/init-integration.sh" --help ) \
  > "$SCRATCH/help-subject.log" 2>&1 || HELP_RC=$?
listing "$HELPP/subject" > "$SCRATCH/help-subj-after.txt"
check "$(yesno same_file "$HELP_SUBJ_BEFORE" "$SCRATCH/help-subj-after.txt")" \
  "help_does_not_scaffold_an_integration_repo_called_help" \
  "--help executed against the caller's cwd:
$(command diff "$HELP_SUBJ_BEFORE" "$SCRATCH/help-subj-after.txt" | command sed 's/^/        /')"
check "$(yesno test "$HELP_RC" = 0)" \
  "help_is_answered_rather_than_refused" \
  "init-integration.sh --help exited $HELP_RC; see $SCRATCH/help-subject.log"
check "$(yesno command grep -q '^usage: init-integration.sh' "$SCRATCH/help-subject.log")" \
  "help_prints_that_scripts_own_usage" \
  "the run exited 0 and printed no usage — which is also what the defect did, having
      scaffolded a repo called --help instead"

# A FIRST POSITIONAL BEGINNING WITH `-` IS REFUSED, not taken as a name. `--help`
# is only the spelling that got noticed; the class is every option a caller
# guesses at, and a mistyped one must not become a repo name either.
HELP_TYPO_RC=0
( cd "$HELPP/subject" && bare bash "$SCRIPT_DIR/init-integration.sh" --pushh ) \
  > "$SCRATCH/help-typo.log" 2>&1 || HELP_TYPO_RC=$?
listing "$HELPP/subject" > "$SCRATCH/help-typo-after.txt"
check "$(yesno test "$HELP_TYPO_RC" != 0)" \
  "an_unknown_leading_dash_argument_is_refused_rather_than_used_as_a_name" \
  "init-integration.sh --pushh exited 0; see $SCRATCH/help-typo.log"
check "$(yesno same_file "$HELP_SUBJ_BEFORE" "$SCRATCH/help-typo-after.txt")" \
  "a_refused_flag_leaves_the_callers_directory_untouched" \
  "$(command diff "$HELP_SUBJ_BEFORE" "$SCRATCH/help-typo-after.txt" | command sed 's/^/        /')"

# THE SWEEP. The property is not "init-integration.sh was fixed" — it is that
# every operator entry point this skill ships answers --help without acting.
# Enumerated from the directory rather than listed, so a script added later is
# covered by construction. `_manifest.py` is deliberately not in it: it is a
# private helper (the leading underscore says so), it is never invoked by an
# operator, and its first positional is a repo ROOT rather than a name.
HELP_SWEPT=0
HELP_ACTED=""
HELP_NOUSAGE=""
HELP_WRONGNAME=""
HELP_SWEEP_BEFORE="$SCRATCH/help-sweep-before.txt"
listing "$HELPP/sweep" > "$HELP_SWEEP_BEFORE"
for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/wt"; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  # lib.sh is SOURCED, never run: it defines helpers and has no main, so it has
  # no --help to answer and nothing to guard. Every other file here is something
  # an operator or an agent is told to invoke.
  case "$n" in lib.sh) continue ;; esac
  HELP_SWEPT=$((HELP_SWEPT + 1))
  hrc=0
  ( cd "$HELPP/sweep" && bare bash "$f" --help ) > "$SCRATCH/help-sweep-$n.log" 2>&1 || hrc=$?
  listing "$HELPP/sweep" > "$SCRATCH/help-sweep-after.txt"
  same_file "$HELP_SWEEP_BEFORE" "$SCRATCH/help-sweep-after.txt" \
    || { HELP_ACTED="$HELP_ACTED $n"; command cp "$SCRATCH/help-sweep-after.txt" "$HELP_SWEEP_BEFORE"; }
  if [ "$hrc" != 0 ] || ! command grep -q '^usage:' "$SCRATCH/help-sweep-$n.log"; then
    HELP_NOUSAGE="$HELP_NOUSAGE $n(rc=$hrc)"
  fi
  # ITS OWN usage, and this is the half that was missing.
  #
  # agent-home.sh `exec`s bootstrap-home.sh and forwarded "$@" verbatim, so
  # `agent-home.sh --help` printed `usage: bootstrap-home.sh …` — a different
  # program's name, a different option set, and no word about the two facts a
  # caller of agent-home.sh needs (that it is a locator, and that --print-env is
  # how a shell binds). It satisfied `^usage:` perfectly, which is why the check
  # above did not see it, and it cost a fresh agent ~4.5 KB reading the same
  # help twice under two names before noticing they were one text.
  #
  # `usage: <name>` rather than "mentions its name somewhere": the defect's
  # output mentioned agent-home.sh in prose further down and would have passed.
  command grep -q "^usage: $n\([[:space:]]\|$\)" "$SCRATCH/help-sweep-$n.log" \
    || HELP_WRONGNAME="$HELP_WRONGNAME $n(said: $(command sed -n 's/^usage: //p' "$SCRATCH/help-sweep-$n.log" | command sed -n 1p | command awk '{print $1}'))"
done

# Vacuity guard for the sweep itself, in this file's usual shape: a loop that
# matched no files would report both properties clean forever. The floor is just
# under the current count so it fails if the enumeration silently narrows.
check "$(yesno test "$HELP_SWEPT" -ge 9)" \
  "the_help_sweep_actually_found_the_entry_points_to_check" \
  "the sweep ran $HELP_SWEPT script(s); it is not looking at the right directory"

check "$(yesno test -z "$HELP_ACTED")" \
  "no_entry_point_writes_anything_when_asked_for_help" \
  "these changed the caller's directory on --help:$HELP_ACTED"
check "$(yesno test -z "$HELP_NOUSAGE")" \
  "every_entry_point_answers_help_with_a_usage_and_exit_0" \
  "these did not:$HELP_NOUSAGE"
check "$(yesno test -z "$HELP_WRONGNAME")" \
  "every_entry_point_answers_help_with_ITS_OWN_usage_not_some_other_scripts" \
  "these printed a usage line naming a different program:$HELP_WRONGNAME
      A locator that forwards --help to the thing it execs answers a question
      about a program the caller did not run."

# --------------------- no refusal here claims a fact it did not measure
#
# `--onboard`'s failure path said "The home is wired but empty; nothing was
# installed" and exited 1. Measured: `onboard` had installed 3 units, the count
# was never looked at, and 1 is this script's code for a USAGE OR SETUP error —
# wrong claim, wrong number, and the gates that own the accurate codes (5 empty,
# 6 unprojected) were skipped because the script died before reaching them.
#
# The property is narrow and stated as such: no script here asserts "nothing was
# installed" in prose. What actually landed is countable, so it is counted.
# Behavioural coverage of the shortfall path itself needs an `onboard` that fails
# halfway, which this fixture cannot produce deterministically; this guard is
# about the sentence, and it says so rather than implying more.

step "No refusal claims 'nothing was installed' instead of counting"

# The pattern's own non-vacuity, in this file's usual shape: it must match the
# sentence that shipped, or "no script contains it" is true of any pattern.
CLAIM_DECOY="$SCRATCH/claim-decoy.txt"
printf 'The home is wired but empty; nothing was\n  installed. Re-run the command by hand to see why:\n' \
  > "$CLAIM_DECOY"
check "$(yesno command grep -q 'nothing was$' "$CLAIM_DECOY")" \
  "the_unmeasured_claim_pattern_matches_the_sentence_that_shipped" \
  "the pattern does not match the text it is meant to keep out, so the next check proves nothing"

CLAIMERS=""
for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/wt"; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in selftest.sh) continue ;; esac
  # `if`, not `grep … && …`: under `set -e` a trailing `&&` list whose condition
  # is false is the whole command failing, and no-match is the expected case.
  if command grep -q 'nothing was$' "$f"; then
    CLAIMERS="$CLAIMERS $(basename "$f")"
  fi
done
check "$(yesno test -z "$CLAIMERS")" \
  "no_script_here_claims_nothing_was_installed_without_counting" \
  "these still assert it in prose instead of reporting the measured count:$CLAIMERS"

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

# ------------- a run you can WAIT ON, and a close that runs from anywhere
#
# Four defects, measured by fresh agents against this skill, all of which cost
# ROUND-TRIPS rather than output:
#
#   * `wt new` prints nothing until it finishes, and it can run longer than a
#     caller's foreground timeout — so the caller backgrounds it and POLLS, and
#     each poll re-sends the whole growing transcript. Measured at ~14k of one
#     agent's ~48k total. The fix is a run that can be WAITED on: a caller-named
#     transcript (--log) and one line naming it once the run is slow enough to
#     need it.
#   * `wt close <TICKET>` composed the worktree path out of whatever repo $PWD
#     was in, so the close command the contract prints — a bare absolute path
#     with no `cd` — failed from anywhere else with `not a directory: …`.
#   * every printed invocation must be runnable AS PRINTED, and `wt` is not on
#     PATH.
#   * a successful close said nothing about where the home work went or what it
#     still owed (git-integration-skill#8).
#
# The fixture reuses $CHEAP, and every check below pairs its budget with the
# evidence, for the reason stated throughout this file: a script that printed
# nothing at all satisfies a line count perfectly.

step "wt: a run you can wait on, and a close that is not cwd-sensitive"

# ---- --log: the CALLER names the transcript, before the run starts.
#
# This is what makes the run watchable at all. Without it the transcript path is
# chosen by mktemp inside a child that prints nothing until it is done, so there
# is nothing to tail and the only way to wait is to poll.
NAMED_RUN="$SCRATCH/named-run.log"
NL_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/new-change.sh" WL1 --log "$NAMED_RUN" ) \
  > "$SCRATCH/nc-named.out" 2> "$SCRATCH/nc-named.err" || NL_RC=$?
log_flag_is_honoured() {
  [ "$NL_RC" = 0 ] || return 1
  [ -s "$NAMED_RUN" ] || return 1
  command grep -q 'Repository for WL1' "$NAMED_RUN" || return 1
  # bootstrap-home.sh's narration lands in the SAME file, which is the property
  # that makes one tail enough to watch the whole provisioning.
  command grep -q '^verified: ' "$NAMED_RUN"
}
check "$(yesno log_flag_is_honoured)" \
  "--log_puts_this_scripts_AND_the_bootstraps_narration_in_the_file_the_caller_named" \
  "rc=$NL_RC, $NAMED_RUN is $(command wc -c < "$NAMED_RUN" 2>/dev/null | command tr -d ' ') byte(s):
$(command sed 's/^/        /' "$NAMED_RUN" 2>/dev/null | command tail -5)"

# ---- the progress line, on a run slow enough to need one.
#
# WT_PROGRESS_AFTER=1 makes it deterministic; the default is 25 s, which is why
# the plain `wt new` above still prints NOTHING on stderr and that check still
# holds. Both halves asserted together: the line must name a file that EXISTS
# and HOLDS THE NARRATION, because a `wt` that printed a plausible sentence
# about a path it never wrote would pass a grep for the sentence.
PROG_RC=0
( cd "$CHEAP" && bare env WT_PROGRESS_AFTER=1 bash "$SCRIPT_DIR/wt" new WL2 ) \
  > "$SCRATCH/wt-prog.out" 2> "$SCRATCH/wt-prog.err" || PROG_RC=$?
PROG_LOG="$(command sed -n 's/.*watch: tail -f //p' "$SCRATCH/wt-prog.err" | command sed -n 1p)"
PROG_WT="$(command sed -n 's/^created worktree //p' "$SCRATCH/wt-prog.out" | command sed -n 1p)"
progress_line_names_a_log_that_holds_the_run() {
  [ "$PROG_RC" = 0 ] || return 1
  # The stdout contract is UNTOUCHED by any of this: still one line, still the
  # path, and the path is still a directory that exists.
  [ "$(lines_of "$SCRATCH/wt-prog.out")" = 1 ] || return 1
  [ -n "$PROG_WT" ] && [ -d "$PROG_WT" ] || return 1
  # And the whole of stderr is that one line.
  [ "$(lines_of "$SCRATCH/wt-prog.err")" = 1 ] || return 1
  [ -n "$PROG_LOG" ] && [ -s "$PROG_LOG" ] || return 1
  command grep -q 'Repository for WL2' "$PROG_LOG"
}
check "$(yesno progress_line_names_a_log_that_holds_the_run)" \
  "a_slow_wt_new_names_a_log_to_tail_AND_still_costs_one_line_of_stdout" \
  "rc=$PROG_RC, stdout $(lines_of "$SCRATCH/wt-prog.out") line(s), stderr $(lines_of "$SCRATCH/wt-prog.err") line(s),
      worktree '${PROG_WT:-<none>}', named log '${PROG_LOG:-<none>}'
      (exists: $(yesno test -s "${PROG_LOG:-/nonexistent}")). stderr was:
$(command sed 's/^/        /' "$SCRATCH/wt-prog.err")"

# ---- CLOSING FROM SOMEWHERE ELSE ENTIRELY.
#
# $PROJ is a different repository in the same parent directory, which is the
# exact shape that failed: `ticket_worktree_path` would answer
# $SCRATCH/proj-WL2, that does not exist, and the old code refused there —
# reporting a missing ticket when what was wrong was the directory.
XCLOSE_RC=0
( cd "$PROJ" && bare bash "$SCRIPT_DIR/wt" close WL2 ) \
  > "$SCRATCH/wt-xclose.out" 2> "$SCRATCH/wt-xclose.err" || XCLOSE_RC=$?
XCLOSE_LINE="$(command sed -n 1p "$SCRATCH/wt-xclose.out")"
closed_from_an_unrelated_repo() {
  [ "$XCLOSE_RC" = 0 ] || return 1
  # It really removed the worktree that belongs to the OTHER repo, rather than
  # exiting 0 having found nothing to do.
  [ -n "$PROG_WT" ] && [ ! -d "$PROG_WT" ] || return 1
  contains "$PROG_WT" "$XCLOSE_LINE"
}
check "$(yesno closed_from_an_unrelated_repo)" \
  "wt_close_resolves_a_ticket_from_a_directory_in_a_completely_different_repo" \
  "rc=$XCLOSE_RC from inside $PROJ; worktree '${PROG_WT:-<none>}' still present: $(yesno test -d "${PROG_WT:-/nonexistent}").
      stdout: $XCLOSE_LINE
      stderr:
$(command sed 's/^/        /' "$SCRATCH/wt-xclose.err" | command tail -5)"

# ---- THE LAST MILE, on the one line.
#
# `home sync` moves a worktree's unit work ONE TIER UP — into this checkout's
# own home — and no further. Both fresh agents noticed the gap unprompted: after
# a close the edit is in one place, a later reinstall can overwrite it, and no
# other checkout sees it. The close is the moment that becomes invisible (the
# home is gone and the loss is in no diff), so it is the moment that has to say
# so. Budget and evidence together again: still ONE line, and the fact is on it.
close_one_line_states_where_the_home_work_went() {
  [ "$(lines_of "$SCRATCH/wt-xclose.out")" = 1 ] || return 1
  contains "$CHEAP/.skill-manager" "$XCLOSE_LINE" || return 1
  contains "push skill edits" "$XCLOSE_LINE"
}
check "$(yesno close_one_line_states_where_the_home_work_went)" \
  "a_successful_close_says_where_the_home_work_now_lives_and_what_it_still_owes" \
  "the one line was:
      $XCLOSE_LINE
      it must name $CHEAP/.skill-manager — one tier up, and no further — and say the
      push to the skill's own repo is still owed (git-integration-skill#8)"

# And the same fact as a CONTRACT KEY, since the keys are the interface and the
# one-line summary is prose. Run directly, and from $PROJ again.
KEY_RC=0
( cd "$PROJ" && bare bash "$SCRIPT_DIR/close-change.sh" WL1 ) \
  > "$SCRATCH/cc-key.out" 2> "$SCRATCH/cc-key.err" || KEY_RC=$?
HOMEWORK_V="$(command sed -n 's/^HOME-WORK  *//p' "$SCRATCH/cc-key.out" | command sed -n 1p)"
home_work_key_names_the_project_home() {
  [ "$KEY_RC" = 0 ] || return 1
  [ -n "$HOMEWORK_V" ] || return 1
  case "$HOMEWORK_V" in "$CHEAP/.skill-manager"*) : ;; *) return 1 ;; esac
  contains "OWN repository" "$HOMEWORK_V"
}
check "$(yesno home_work_key_names_the_project_home)" \
  "close_change_emits_a_HOME_WORK_key_whose_value_is_the_project_home" \
  "rc=$KEY_RC, HOME-WORK is '${HOMEWORK_V:-<none>}', expected it to start with $CHEAP/.skill-manager.
      stdout:
$(command sed 's/^/        /' "$SCRATCH/cc-key.out")"

# ---- and it is not CLAIMED when there was nothing to reconcile.
#
# A --no-home worktree reconciled nothing anywhere, and a key saying its work
# reached the project home would be the same class of defect as `verified` over
# an empty home: a true-sounding sentence about something that did not happen.
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/new-change.sh" WL5 --no-home ) \
  > "$SCRATCH/nc-nohome.out" 2> "$SCRATCH/nc-nohome.err" || true
NOHOME_RC=0
( cd "$PROJ" && bare bash "$SCRIPT_DIR/close-change.sh" WL5 ) \
  > "$SCRATCH/cc-nohome.out" 2> "$SCRATCH/cc-nohome.err" || NOHOME_RC=$?
nohome_close_claims_nothing_about_a_home_it_never_had() {
  [ "$NOHOME_RC" = 0 ] || return 1
  command grep -q '^CLOSED ' "$SCRATCH/cc-nohome.out" || return 1
  ! command grep -q '^HOME-WORK ' "$SCRATCH/cc-nohome.out"
}
check "$(yesno nohome_close_claims_nothing_about_a_home_it_never_had)" \
  "a_no_home_worktree_closes_without_claiming_its_work_reached_a_project_home" \
  "rc=$NOHOME_RC; stdout was:
$(command sed 's/^/        /' "$SCRATCH/cc-nohome.out")"

# ---- ambiguity is NAMED, never guessed.
#
# Two repos under one integration root may legitimately carry the same ticket
# id, and closing the wrong one destroys a home. Fabricated rather than
# bootstrapped: the resolver's test for "is this a linked worktree" is that
# `.git` is a FILE, and two such directories are all this needs.
mkdir -p "$SCRATCH/aaa-WL9" "$SCRATCH/bbb-WL9"
printf 'gitdir: /nonexistent\n' > "$SCRATCH/aaa-WL9/.git"
printf 'gitdir: /nonexistent\n' > "$SCRATCH/bbb-WL9/.git"
AMBIG_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" close WL9 ) \
  > "$SCRATCH/wt-ambig.out" 2> "$SCRATCH/wt-ambig.err" || AMBIG_RC=$?
AMBIG_REASON="$(command sed -n 's/^error closing worktree: //p' "$SCRATCH/wt-ambig.out" | command sed -n 1p)"
ambiguity_is_refused_and_named() {
  [ "$AMBIG_RC" != 0 ] || return 1
  contains "WL9" "$AMBIG_REASON" || return 1
  contains "2 worktrees" "$AMBIG_REASON"
}
check "$(yesno ambiguity_is_refused_and_named)" \
  "two_worktrees_with_the_same_ticket_id_are_reported_not_guessed_between" \
  "rc=$AMBIG_RC, reason '${AMBIG_REASON:-<none>}'; stdout:
$(command sed 's/^/        /' "$SCRATCH/wt-ambig.out")"

# ---- every invocation this skill PRINTS is runnable AS PRINTED.
#
# `wt` is not on PATH and never has been, and the pages told an agent to run
# `wt close TICKET-123`. It has been broken four times, so it is asserted rather
# than remembered: no line in the shipped documentation may BEGIN with a bare
# `wt <verb>`. Mid-sentence prose about `wt new` is fine and is not an
# instruction; a line that starts with one is.
BARE_WT="$(command grep -nE '^[[:space:]]*wt[[:space:]]+(new|close|info)([[:space:]]|$)' \
  "$SCRIPT_DIR/../SKILL.md" "$SCRIPT_DIR/../references/worktrees.md" 2>/dev/null || true)"
check "$(yesno test -z "$BARE_WT")" \
  "no_documented_line_starts_with_a_bare_wt_which_is_not_on_PATH" \
  "these lines would not run as printed:
$(printf '%s\n' "$BARE_WT" | command sed 's/^/        /')"

# And the runtime half of the same rule: the CLOSE key `wt info` prints has to
# name a file that exists and is executable — and `info`, like `close`, has to
# answer from a directory in another repo entirely.
#
# `info` is run FROM $PROJ, not from $CHEAP. It carried the identical
# cwd-sensitivity — `no worktree for T4 at <the wrong repo>-T4`, measured — and
# it is the command an agent reaches for when it has only the ticket id, which
# is exactly when it is least likely to be standing in the right repo. Both
# verbs now resolve through the same helper, so they cannot answer about
# different worktrees.
INFO2_RC=0
( cd "$CHEAP" && bare bash "$SCRIPT_DIR/wt" new WL6 --no-home ) >/dev/null 2>&1 || true
( cd "$PROJ" && bare bash "$SCRIPT_DIR/wt" info WL6 ) \
  > "$SCRATCH/wt-info2.out" 2> "$SCRATCH/wt-info2.err" || INFO2_RC=$?
CLOSE2_V="$(command sed -n 's/^CLOSE  *//p' "$SCRATCH/wt-info2.out" | command sed -n 1p)"
INFO2_WT="$(command sed -n 's/^WORKTREE  *//p' "$SCRATCH/wt-info2.out" | command sed -n 1p)"
close_key_is_an_absolute_runnable_path() {
  [ "$INFO2_RC" = 0 ] || return 1
  # Non-vacuity: it really answered about the OTHER repo's worktree.
  [ "$INFO2_WT" = "$SCRATCH/cheap-WL6" ] || return 1
  [ -n "$CLOSE2_V" ] || return 1
  case "$CLOSE2_V" in /*) : ;; *) return 1 ;; esac
  [ -x "${CLOSE2_V%% *}" ]
}
check "$(yesno close_key_is_an_absolute_runnable_path)" \
  "wt_info_answers_from_another_repo_AND_its_CLOSE_key_is_an_executable_path" \
  "rc=$INFO2_RC from inside $PROJ; WORKTREE is '${INFO2_WT:-<none>}' (expected $SCRATCH/cheap-WL6),
      CLOSE is '${CLOSE2_V:-<none>}'; its first token must be an executable file"
# And it runs AS PRINTED, from a directory that is not the repo it belongs to.
AS_PRINTED_RC=0
( cd "$PROJ" && bare bash -c "$CLOSE2_V" ) >/dev/null 2>&1 || AS_PRINTED_RC=$?
check "$(yesno test "$AS_PRINTED_RC" = 0)" \
  "the_CLOSE_line_runs_verbatim_from_an_unrelated_directory" \
  "running '$CLOSE2_V' from $PROJ exited $AS_PRINTED_RC"

# ------------------------------------------------------------------- verdict

step "Result"
info "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
