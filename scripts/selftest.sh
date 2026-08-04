#!/usr/bin/env bash
# selftest.sh [--keep]
#
# Prove the properties of the scripts THIS skill still ships, on a DISPOSABLE
# fixture, from a BARE SHELL.
#
# WHAT MOVED, AND WHERE ITS COVERAGE WENT
# ---------------------------------------
# The worktree lifecycle — `wt`, new-change.sh, close-change.sh,
# bootstrap-home.sh, agent-home.sh and the shared lib.sh — is now owned by
# `git-issue-workflow`, because a ticket and a worktree exist for EVERY repo
# while an integration repository is a specialization that exists only when a
# repo has constituents. Every check about those files moved WITH them, into
# `git-issue-workflow/scripts/selftest.sh`, and both suites must pass. A
# relocation that dropped a check would be a regression that no longer has a
# suite to show up in, which is the worst kind.
#
# What is left here is what this skill still owns, and it is not "the leftovers":
#
#   * NO ENTRY POINT ACTS ON `--help`, and none takes a flag as a name.
#     git-integration-skill#7 was `propagate.sh --help` running a real fan-out
#     and `init-integration.sh --help` scaffolding a repo called `--help` into
#     the operator's own directory. `refresh.sh` has the same shape and reaches
#     `git reset --hard`. The guard lives in git-issue-workflow's lib.sh now,
#     which is exactly why it is asserted HERE: a dependency's function is not
#     a fact about this skill's scripts until this skill's scripts are measured
#     using it.
#   * EVERY `scripts/<name>` THIS SKILL NAMES, IT SHIPS. The failure this comes
#     from is a page instructing a reader to run a file that is not there.
#   * NO SCRIPT RESOLVES A skill-manager BY A PATH RELATIVE TO ITSELF.
#   * THE GENERAL LIBRARY IS SOURCED, NEVER COPIED. This is the property the
#     whole relocation rests on, so it is measured rather than remembered:
#     nothing here redefines `die`/`info`/`step`/`help_guard`, the resolver has
#     no rung anchored on this file's own location, and when the dependency is
#     genuinely missing every entry point REFUSES with a runnable remedy instead
#     of half-running.
#
# It needs no skill-manager CLI at all — that requirement moved with the home
# machinery — so it runs in seconds and in any checkout.
#
# Nothing outside the scratch directory is read or written.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------- THE DEV LOOP TESTS WHAT
#                                                      YOU JUST EDITED
#
# integration-lib.sh resolves lib.sh from the INSTALLED home and deliberately
# has no rung relative to its own location — a path relative to where a script
# happens to sit is evidence about the checkout, not about which copy should
# run. That rule is right at RUNTIME and wrong for a TEST: someone editing
# `constituents/git-issue-workflow/scripts/lib.sh` and running this suite from
# the source tree would silently measure the OLD installed lib.sh and see green.
# That is exactly the staleness that let `propagate.sh --help` stay dangerous
# after the fix had merged.
#
# So the harness — and only the harness — prefers the SIBLING SOURCE CHECKOUT
# when one is there, using the pin integration-lib.sh already honours, set
# BEFORE it is sourced so the suite and every child agree on one library. An
# explicit $GIT_ISSUE_WORKFLOW_SCRIPTS from the caller still wins, and with
# neither present this falls through to the installed unit, which is the shape
# CI runs in.
if [ -z "${GIT_ISSUE_WORKFLOW_SCRIPTS:-}" ]; then
  for _sib in "$SCRIPT_DIR/../../git-issue-workflow/scripts" \
              "$SCRIPT_DIR/../../../git-issue-workflow/scripts"; do
    if [ -f "$_sib/lib.sh" ]; then
      GIT_ISSUE_WORKFLOW_SCRIPTS="$(cd "$_sib" && pwd -P)"
      export GIT_ISSUE_WORKFLOW_SCRIPTS
      break
    fi
  done
fi

. "$SCRIPT_DIR/integration-lib.sh"
printf 'lib:       %s\n' "$_GIW_LIB" >&2

# THIS SUITE READS THIS UNIT'S GIT INDEX. Two checks below sweep every tracked
# file for the `scripts/<name>` paths the documentation promises, which is only
# answerable in a CHECKOUT. Run from an installed copy under
# `<home>/skills/git-integration-repo` there is no work tree, `git ls-files`
# answers nothing, and the vacuity guard fires with "it is not looking at the
# right files" — which is true and reads like a bug in the check. Say what is
# actually wrong instead, before anything runs.
git -C "$SCRIPT_DIR/.." rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "selftest.sh must be run from a CHECKOUT of git-integration-repo, not from
  an installed copy: $SCRIPT_DIR
  Two of its checks sweep this unit's tracked files for the scripts/ paths the
  documentation promises, and an installed unit has no git work tree to sweep."

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) printf 'usage: selftest.sh [--keep]\n' >&2; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

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

# ------------------------------------------------------------------ fixture

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gir-selftest-XXXXXX")"
SCRATCH="$(cd "$SCRATCH" && pwd -P)"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$SCRATCH"; }
trap cleanup EXIT
[ "$KEEP" = 1 ] && info "scratch:   $SCRATCH (kept)" || true

FAKE_HOME="$SCRATCH/fakehome"
mkdir -p "$FAKE_HOME"

# The listing a "nothing was written" assertion is taken against. Proved live by
# the CONTROL runs below, which must change it.
listing() { command find "$1" -mindepth 1 2>/dev/null | LC_ALL=C sort; }

# Every child runs the way an operator does: no SKILL_MANAGER_HOME, HOME
# pointing at a scratch directory so the "global home" fallback cannot be the
# operator's.
#
# GIT_ISSUE_WORKFLOW_SCRIPTS IS PASSED THROUGH, AND IT IS THE COPY THIS SUITE
# ITSELF RESOLVED. `bare` unsets SKILL_MANAGER_HOME and redirects HOME, so a
# child re-resolving the dependency by the ordinary rung would look inside the
# scratch home and find nothing — and every check below would then be measuring
# a refusal rather than the script it names. Handing the child the same lib.sh
# the parent is running keeps the two in agreement, and `$_GIW_LIB` is
# integration-lib.sh's own answer, not a second opinion about it.
GIW_SCRIPTS="$(cd "$(dirname "$_GIW_LIB")" && pwd -P)"
bare() {
  env -u SKILL_MANAGER_HOME \
      HOME="$FAKE_HOME" \
      GIT_ISSUE_WORKFLOW_SCRIPTS="$GIW_SCRIPTS" \
      "$@"
}

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
for f in "$SCRIPT_DIR"/*.sh; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  # integration-lib.sh is SOURCED, never run: it resolves the general library and
  # defines the two integration-only helpers, and has no main, so it has no
  # --help to answer and nothing to guard. Every other file here is something an
  # operator or an agent is told to invoke.
  case "$n" in integration-lib.sh) continue ;; esac
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
check "$(yesno test "$HELP_SWEPT" -ge 6)" \
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
for f in "$SCRIPT_DIR"/*.sh; do
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
# git-issue-workflow's `agent-home.sh` into the repo root", and close-change.sh
# offered the
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
# `(^|[^/…])scripts/…` — a LEADING SLASH disqualifies the match. Since the
# worktree machinery moved to git-issue-workflow, this skill's pages name that
# skill's files the way every cross-unit path in these skills is named:
# `\$SKILL_MANAGER_HOME/skills/git-issue-workflow/scripts/wt`. Those resolve
# inside a DIFFERENT unit and are not this skill's to ship, and sweeping them up
# would make the rule below assert the opposite of what it means. A bare
# `scripts/<name>` — at a line start, after a space, a backtick or a quote — is
# still a promise about THIS skill, and is still checked.
NAMED="$(cd "$SCRIPT_DIR/.." && git ls-files -z 2>/dev/null \
  | xargs -0 command grep -ohE '(^|[^/A-Za-z0-9_.-])scripts/[A-Za-z0-9_][A-Za-z0-9_.-]*' 2>/dev/null \
  | command sed 's#^.*[^A-Za-z0-9_.-]scripts/##; s#^scripts/##; s/[.,;:]*$//' | sort -u || true)"
MISSING_FLOOR=""
for want in propagate.sh init-integration.sh add-constituent.sh finalize-constituents.sh verify.sh refresh.sh; do
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
# skill as a constituent. A check that resolved a bare `scripts/<name>` from
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


# ---------------- the general library is SOURCED across the dependency, not copied
#
# THIS IS THE PROPERTY THE WHOLE RELOCATION RESTS ON, so it is measured.
#
# `die`, `info`, `step` and `help_guard` are used by the scripts that stayed in
# this skill and are DEFINED in git-issue-workflow's lib.sh. The tempting shape
# — and the one a future edit will reach for when the dependency is briefly
# inconvenient — is a local copy of "just the four helpers". That is one
# predicate spelled twice, and `help_guard` is the predicate whose second
# spelling is measured in damage: git-integration-skill#7 is what a stale copy
# of it costs. So: exactly one definition, reached by exactly one resolved path.

step "The general library is sourced across the dependency, never copied"

# 1. It really did come from somewhere else. Without this, every check below is
#    true of a suite that quietly defines the helpers itself.
check "$(yesno test -f "${_GIW_LIB:-/nonexistent}")" \
  "the_general_library_was_resolved_to_a_file_that_exists" \
  "integration-lib.sh resolved '_GIW_LIB=${_GIW_LIB:-<unset>}'"
check "$(yesno test "$(dirname "$(dirname "$GIW_SCRIPTS")")" != "$(dirname "$SCRIPT_DIR")")" \
  "the_general_library_lives_outside_this_skill" \
  "$GIW_SCRIPTS resolves inside this skill ($SCRIPT_DIR/..), so 'it is not copied here' proves nothing"

# 2. The functions are actually in scope in a child. Asserted by RUNNING one,
#    not by grepping for a name: a `help_guard` that is defined but broken
#    passes a grep and fails an operator.
HG_PROBE="$SCRATCH/helpguard-probe.log"
HG_RC=0
( cd "$SCRATCH" && bare bash "$SCRIPT_DIR/verify.sh" --nope ) > "$HG_PROBE" 2>&1 || HG_RC=$?
check "$(yesno test "$HG_RC" != 0)" \
  "the_sourced_help_guard_refuses_a_leading_dash_first_positional" \
  "verify.sh --nope exited $HG_RC; the guard came from the dependency and is not in force"
check "$(yesno command grep -q 'unknown option: --nope' "$HG_PROBE")" \
  "the_refusal_is_the_dependencys_help_guard_and_not_a_local_lookalike" \
  "expected lib.sh's 'unknown option:' refusal; got:
$(command sed 's/^/        /' "$HG_PROBE" | command tail -5)"

# 3. NOTHING HERE REDEFINES THEM. The pattern is proved against a decoy first,
#    in this suite's usual shape: a grep that matches nothing reports the same
#    green whether the defect is absent or the pattern is a typo.
DUP_RE='^[[:space:]]*(die|info|step|help_guard|contract|contract_fail|die_fix|repo_root|checkout_root|project_home)\(\)'
DUP_DECOY="$SCRATCH/dup-decoy.sh"
printf 'help_guard() {\n  :\n}\n' > "$DUP_DECOY"
check "$(yesno command grep -qE "$DUP_RE" "$DUP_DECOY")" \
  "the_duplicate_definition_pattern_matches_a_real_redefinition" \
  "the pattern does not match a plain 'help_guard() {', so a zero count over scripts/ would prove nothing"
DUPES=""
for f in "$SCRIPT_DIR"/*.sh; do
  [ -f "$f" ] || continue
  if command grep -qE "$DUP_RE" "$f"; then DUPES="$DUPES $(basename "$f")"; fi
done
check "$(yesno test -z "$DUPES")" \
  "no_script_here_redefines_a_helper_the_general_library_owns" \
  "these carry a second definition of a function git-issue-workflow's lib.sh owns:$DUPES
      One definition, one home, one resolved path to it — see integration-lib.sh."

# 4. The resolver has no rung anchored on this file's own location. Same rule,
#    and same reason, as the skill-manager one above: a path relative to where
#    this file happens to sit is evidence about the checkout, not about which
#    copy should run.
REL_LIB_RE='\$\{?(SCRIPT_DIR|INTEGRATION_LIB_DIR|BASH_SOURCE)[^ ]*/\.\.'
REL_LIB_DECOY="$SCRATCH/rel-lib-decoy.txt"
printf '  . "$SCRIPT_DIR/../../git-issue-workflow/scripts/lib.sh"\n' > "$REL_LIB_DECOY"
check "$(yesno command grep -qE "$REL_LIB_RE" "$REL_LIB_DECOY")" \
  "the_relative_library_pattern_matches_the_shape_it_forbids" \
  "the pattern does not match a sibling-checkout source line, so a zero count would prove nothing"
REL_LIB_HITS="$(command grep -nE "$REL_LIB_RE" "$SCRIPT_DIR/integration-lib.sh" \
  | command grep -vE '^[0-9]+:[[:space:]]*#' || true)"
check "$(yesno test -z "$REL_LIB_HITS")" \
  "the_library_resolver_has_no_rung_relative_to_its_own_location" \
  "integration-lib.sh resolves the dependency from where it happens to sit:
$(printf '%s\n' "$REL_LIB_HITS" | command sed 's/^/        /')"

# 5. AND WHEN THE DEPENDENCY IS GENUINELY ABSENT, EVERY ENTRY POINT REFUSES —
#    with a remedy that runs — rather than half-running against undefined
#    functions. `set -u` would make an undefined `die` a bare "command not
#    found" from somewhere in the middle of a fan-out, which is the shape that
#    gets worked around instead of fixed.
NOLIB_HOME="$SCRATCH/nolib-home"
mkdir -p "$NOLIB_HOME/.skill-manager/skills"
NOLIB_MISSING=""
NOLIB_NOREMEDY=""
NOLIB_SWEPT=0
for f in "$SCRIPT_DIR"/*.sh; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  # integration-lib.sh is sourced, not run. selftest.sh is excluded for a
  # DIFFERENT reason and it is not an exemption from the property: this file
  # deliberately pins GIT_ISSUE_WORKFLOW_SCRIPTS to the sibling source checkout
  # before sourcing anything, so the dev loop measures the library you just
  # edited. It therefore cannot be made to see an absent dependency, which is
  # the whole point of the pin — and asserting the refusal on a file that pins
  # its way past it would be asserting nothing.
  case "$n" in integration-lib.sh|selftest.sh) continue ;; esac
  NOLIB_SWEPT=$((NOLIB_SWEPT + 1))
  nrc=0
  ( cd "$SCRATCH" && env -u SKILL_MANAGER_HOME -u GIT_ISSUE_WORKFLOW_SCRIPTS \
      HOME="$NOLIB_HOME" bash "$f" --help ) > "$SCRATCH/nolib-$n.log" 2>&1 || nrc=$?
  [ "$nrc" = 0 ] && NOLIB_MISSING="$NOLIB_MISSING $n(exit 0)"
  command grep -q 'skill-manager install github:haydenrear/git-issue-workflow-skill' \
    "$SCRATCH/nolib-$n.log" || NOLIB_NOREMEDY="$NOLIB_NOREMEDY $n"
done
check "$(yesno test "$NOLIB_SWEPT" -ge 5)" \
  "the_missing_dependency_sweep_found_the_entry_points_to_check" \
  "it swept $NOLIB_SWEPT script(s); it is not looking at the right directory"
check "$(yesno test -z "$NOLIB_MISSING")" \
  "every_entry_point_refuses_when_the_general_library_is_not_installed" \
  "these ran anyway:$NOLIB_MISSING"
check "$(yesno test -z "$NOLIB_NOREMEDY")" \
  "the_missing_dependency_refusal_names_the_install_that_fixes_it" \
  "these refused without naming the remedy:$NOLIB_NOREMEDY"

# --------------- an OLD git-issue-workflow beside a NEW git-integration-repo
#
# THE FAILURE CLASS THE SPLIT CREATED. These two units version independently
# now, so a home can hold a lib.sh that predates a function this skill calls.
# Under `set -u` that is a bare "command not found" from the MIDDLE of a fan-out
# — after some constituents are branched and pushed and before the rest are —
# and a half-propagated change is not something you re-run your way out of.
#
# Measured against a REAL old library rather than a hand-written stub: the
# fixture is this skill's actual dependency with the ABI marker removed, which
# is byte-for-byte what a pre-split copy looks like.

step "A git-issue-workflow too old for this skill is refused before anything runs"

SKEW="$SCRATCH/skew/scripts"
mkdir -p "$SKEW"
command sed 's/^WORKTREE_LIB_ABI=.*/# (marker removed: this is what a pre-split copy looks like)/' \
  "$_GIW_LIB" > "$SKEW/lib.sh"

# Non-vacuity, both halves, before anything is asserted with this fixture.
check "$(yesno absent_pattern '^WORKTREE_LIB_ABI=' "$SKEW/lib.sh")" \
  "the_stale_library_fixture_really_has_no_abi_marker" \
  "the fixture still declares WORKTREE_LIB_ABI, so 'the skew was refused' would prove nothing"
check "$(yesno command grep -q '^help_guard()' "$SKEW/lib.sh")" \
  "the_stale_library_fixture_is_otherwise_a_real_library" \
  "the fixture lost more than the marker, so a refusal would not be about the marker"

SKEW_RC=0
( cd "$SCRATCH" && env -u SKILL_MANAGER_HOME HOME="$FAKE_HOME" \
    GIT_ISSUE_WORKFLOW_SCRIPTS="$SKEW" bash "$SCRIPT_DIR/propagate.sh" --help ) \
  > "$SCRATCH/skew.log" 2>&1 || SKEW_RC=$?
check "$(yesno test "$SKEW_RC" != 0)" \
  "a_library_with_no_abi_marker_is_refused_rather_than_used" \
  "propagate.sh exited $SKEW_RC against a pre-split lib.sh; see $SCRATCH/skew.log"
check "$(yesno command grep -q 'WORKTREE_LIB_ABI' "$SCRATCH/skew.log")" \
  "the_skew_refusal_says_what_disagreed" \
  "the refusal does not name the marker it checked:
$(command sed 's/^/        /' "$SCRATCH/skew.log" | command tail -6)"
check "$(yesno command grep -q 'skill-manager sync git-issue-workflow' "$SCRATCH/skew.log")" \
  "the_skew_refusal_names_the_command_that_makes_the_two_units_agree" \
  "the refusal is a diagnosis with no remedy"

# And the OTHER blind spot: a marker high enough, but a function missing. This
# is what a bad merge or a partial sync produces, and the number alone cannot
# see it.
SKEW2="$SCRATCH/skew2/scripts"
mkdir -p "$SKEW2"
command sed 's/^help_guard() {/_disabled_help_guard() {/' "$_GIW_LIB" > "$SKEW2/lib.sh"
check "$(yesno command grep -q '^WORKTREE_LIB_ABI=' "$SKEW2/lib.sh")" \
  "the_incomplete_library_fixture_still_declares_a_current_abi" \
  "the fixture lost its marker too, so the number would refuse it and the roll-call would prove nothing"
SKEW2_RC=0
( cd "$SCRATCH" && env -u SKILL_MANAGER_HOME HOME="$FAKE_HOME" \
    GIT_ISSUE_WORKFLOW_SCRIPTS="$SKEW2" bash "$SCRIPT_DIR/propagate.sh" --help ) \
  > "$SCRATCH/skew2.log" 2>&1 || SKEW2_RC=$?
check "$(yesno test "$SKEW2_RC" != 0)" \
  "a_library_missing_a_function_this_skill_calls_is_refused_even_with_a_current_abi" \
  "propagate.sh exited $SKEW2_RC against a lib.sh with no help_guard; see $SCRATCH/skew2.log"
check "$(yesno command grep -q 'help_guard' "$SCRATCH/skew2.log")" \
  "the_rollcall_refusal_names_the_function_that_was_missing" \
  "the refusal does not say what was absent:
$(command sed 's/^/        /' "$SCRATCH/skew2.log" | command tail -6)"

# ------------------------------------------------------------------- verdict

step "Result"
info "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
