#!/usr/bin/env bash
# close-change.sh <TICKET|WORKTREE-PATH> [--into HOME] [--force] [--dry-run]
#
# Tear down a ticket worktree — but only after proving that removing it
# destroys nothing.
#
# This is the other half of new-change.sh. That script gives a worktree its own
# Skill Manager home so an agent cannot write the operator's global one; this
# one makes sure the work that home accumulated has somewhere to go before the
# directory is deleted.
#
# Why a script at all
# -------------------
# `git worktree remove` deletes `<wt>/.skill-manager` without asking, and it
# succeeds just as quietly whether the home held a week of skill edits or
# nothing at all. The edits are invisible to the parent diff (the home is
# gitignored, so `git add -A` never sees them and propagate.sh can never carry
# them), so the loss leaves no trace anywhere. Until now "push back before
# teardown" was a sentence in references/skill-homes.md — a discipline, not a
# mechanism. `skill-manager home close-out` answers exactly the right question
# and nothing called it.
#
# So: the gate runs BEFORE the removal, and a non-zero verdict stops the
# removal and prints each blocking unit with the command that clears it.
#
# Why --force exists
# ------------------
# Sometimes the operator really does want to discard: a spike, a worktree whose
# home was scribbled in while debugging, an experiment already published
# elsewhere. A gate with no escape hatch does not stop those people, it just
# routes them around it — `rm -rf` on the directory, or `git worktree remove
# --force` by hand, both of which skip the gate AND every other check this
# script makes. An override that is named, logged and loud is safer than one
# the operator improvises. --force therefore still RUNS the gate and still
# PRINTS the blockers; it only declines to stop.
#
# How it degrades
# ---------------
# The rule is: proceed only when the gate has actually established that there is
# nothing to lose. Anything else refuses and points at --force.
#
#   * worktree has no home      -> ALLOW. There is provably nothing to lose;
#                                  this is the --no-home case new-change.sh
#                                  supports on purpose.
#   * no CLI with `close-out`   -> REFUSE. Cannot establish safety. A gate that
#                                  opens when it cannot check is not a gate.
#   * project home missing      -> REFUSE. Same reason: nowhere to check against.
#   * gate says blocked         -> REFUSE, and print the remedies.
#
# Note the asymmetry is deliberate: "no home" is a proof of safety, while "no
# tool" and "no destination" are absences of proof, and those are not the same
# thing.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

REFUSED_EXIT=4          # the gate stopped this; distinct from a usage error (1)

usage() {
  cat >&2 <<'EOF'
usage: close-change.sh <TICKET|WORKTREE-PATH> [--into HOME] [--force] [--dry-run]

  TICKET           Ticket id; the worktree is <parent-dir>/<repo>-<TICKET>,
                   the same path new-change.sh creates. If that path is not
                   there, the ticket is resolved against the worktrees that
                   ARE — so this runs from any directory, not only from the
                   repo that opened the worktree. Ambiguity is named, never
                   guessed. A path may be given instead.
  --into HOME      Project home the worktree's work must reach first.
                   Default: the project home the worktree's own home was cloned
                   FROM — <main working tree>/.skill-manager. bootstrap-home.sh
                   derives the clone source from the same function, so the two
                   agree by construction rather than by exported variable.
  --force          Remove even if the gate refuses. The gate still runs and its
                   blockers are still printed; the work is DISCARDED.
  --dry-run        Run the gate and report; remove nothing.
  -h, --help       This message.

Exit codes: 0 removed (or dry run clean) - 1 usage/setup error
            4 refused by the close-out gate
EOF
}

TARGET=""; INTO=""; FORCE=0; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --into)     INTO="${2:?--into needs a home directory}"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         usage; die "unknown option: $1" ;;
    *)          [ -z "$TARGET" ] || die "unexpected argument: $1"; TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { usage; die "a ticket or worktree path is required"; }

# checkout_root, not repo_root, and for the same reason new-change.sh uses it:
# a constituent has its own .git, so the repo whose worktree this is, is the
# nearest git toplevel. Resolving the integration parent here would look for
# the worktree in the wrong repo's `worktree list` and refuse a perfectly real
# one. The two scripts must answer this identically or close-change.sh cannot
# close what new-change.sh opened.
#
# Then up to that repo's MAIN working tree. checkout_root() answers $PWD, and
# $PWD may itself be a worktree — from inside one, `ticket_worktree_path`
# produced `<repo>-T1-T2` and `--into` named a SIBLING WORKTREE's home instead
# of the project's. The project is where new-change.sh branched from and where
# the worktree's home was cloned from, and it is the same whichever worktree the
# operator happens to be standing in.
INVOKED_FROM="$(pwd -P)"     # physical: /tmp vs /private/tmp must not decide this
ROOT="$(checkout_root)"
ROOT="$(main_checkout_root "$ROOT")" || die "cannot resolve the main working tree for $ROOT"
cd "$ROOT"

# A path if it looks like one or exists; otherwise the new-change.sh
# convention, computed by the SAME helper so the two cannot drift apart.
#
# AND THEN, IF THAT PATH IS NOT THERE, THE TICKET IS RESOLVED AGAINST THE
# WORKTREES THAT ACTUALLY EXIST. The convention alone made this command
# cwd-sensitive: it spells the worktree `<parent>/<basename $ROOT>-<TICKET>` and
# $ROOT is the nearest git toplevel to $PWD, so `wt close B1-EDIT` run from a
# repo that is not the one that opened B1-EDIT composed a path out of the wrong
# repo's name and refused with `not a directory: …/skill-manager-B1-EDIT`. The
# contract prints that close command as a bare absolute path with no `cd`, which
# says run-from-anywhere; making it true is cheaper than qualifying it, and a
# `cd` prefix would still be wrong for a caller that does not know which repo to
# cd to — which is the caller this whole front door is for.
#
# Only ever consulted when the conventional path is ABSENT, so the ordinary
# in-repo case is unchanged and cannot be redirected by a sibling with the same
# ticket id.
case "$TARGET" in
  */*|.|..) WT="$TARGET" ;;
  *)        WT="$(ticket_worktree_path "$ROOT" "$TARGET")"
            if [ ! -d "$WT" ]; then
              FOUND="$(ticket_worktree_candidates "$(worktree_parent_dir "$ROOT")" "$TARGET")"
              N_FOUND="$(printf '%s\n' "$FOUND" | command grep -c . || true)"
              if [ "$N_FOUND" = 1 ]; then
                WT="$(printf '%s\n' "$FOUND" | command sed -n 1p)"
                info "resolved:  $TARGET -> $WT"
                info "           (not $(basename "$ROOT")'s worktree — the repo \$PWD is in does not own this ticket)"
              elif [ "${N_FOUND:-0}" -gt 1 ]; then
                # Named, never guessed. Two repos can legitimately carry the same
                # ticket id in one integration tree, and closing the wrong one
                # destroys a home.
                printf '%s\n' "$FOUND" | while IFS= read -r c; do
                  [ -n "$c" ] && printf '    %s\n' "$c" >&2
                done
                die_fix 1 "$SCRIPT_DIR/wt close <one of the paths in the log>" \
                  "$N_FOUND worktrees are named $TARGET (each one named in the log) — name the one you mean by path"
              fi
            fi ;;
esac
[ -d "$WT" ] || die "not a directory: $WT
  That is where new-change.sh would have put $TARGET for $(basename "$ROOT"), the repo
  \$PWD is in, and no worktree named '*-$TARGET' exists in
    $(worktree_parent_dir "$ROOT")
  either. Check the ticket id, or name the worktree by path."
WT="$(cd "$WT" && pwd -P)"

# THE WORKTREE DECIDES WHICH REPO THIS IS, not $PWD. Re-derived here because the
# resolution above may have landed on another repo's worktree entirely, and
# because every remaining question — is it really a worktree, which project home
# does it close INTO, which branch is left dangling — is a question about the
# repo the WORKTREE belongs to. Deriving it from $PWD is what made the whole
# command cwd-sensitive.
ROOT="$(main_checkout_root "$WT")" || die "cannot resolve the main working tree for $WT"
cd "$ROOT"

[ "$WT" = "$ROOT" ] && die "refusing to remove the repo's main working tree ($ROOT)"

# It must actually be a worktree of THIS repo, checked before anything else so
# a mistyped path cannot reach `git worktree remove`. Compared by PHYSICAL path
# so /tmp vs /private/tmp (or any symlinked parent) cannot make a real worktree
# look foreign.
is_worktree_of_root() {
  local listed physical
  while IFS= read -r listed; do
    physical="$(cd "$listed" 2>/dev/null && pwd -P)" || continue
    [ "$physical" = "$WT" ] && return 0
  done <<EOF
$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{ $1=""; sub(/^ /,""); print }')
EOF
  return 1
}
if ! is_worktree_of_root; then
  die "$WT is not a worktree of $ROOT
  git -C \"$ROOT\" worktree list   # to see what is"
fi

STORE="$WT/.skill-manager"

# Read BEFORE the removal, because after it there is no worktree to ask. The
# branch outlives the worktree deliberately (the change may not have landed yet),
# so "which branch is now dangling" is a fact the closing contract owes the
# caller — and `<branch>` as a literal placeholder, which is what the old
# trailing note printed, is not that fact.
WT_BRANCH="$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

# Same reason: after the removal there is no home to ask. Whether this worktree
# HAD one decides whether the closing contract owes the caller the last-mile
# note below — a worktree created with --no-home reconciled nothing anywhere and
# telling it that its work reached the project home would be false.
HAD_HOME=0
[ -d "$STORE" ] && HAD_HOME=1 || true

# The destination is the PROJECT home — the main working tree's — and it is
# derived from the same lib.sh function bootstrap-home.sh clones the worktree
# home from. That is issue #50: the two used to answer separately, bootstrap
# from `${SKILL_MANAGER_HOME:-$HOME/.skill-manager}` and this from
# `$ROOT/.skill-manager`, and from a bare shell they named different homes.
#
# `$ROOT/.skill-manager` was also wrong in a second, quieter way: $ROOT is
# checkout_root(), the nearest git toplevel to $PWD, so running this from
# INSIDE another worktree of the same repo aimed --into at THAT worktree's
# home. project_home answers the main working tree wherever it is run.
[ -n "$INTO" ] || INTO="$(project_home "$ROOT")" \
  || die "cannot resolve the project home for $ROOT — pass --into <home>"

step "Closing out $WT"
info "worktree:  $WT"
info "home:      ${STORE}"
info "into:      ${INTO}"

# ------------------------------------------------------------------ the CLI

# Same probe shape as bootstrap-home.sh, and for the same measured reason: the
# released 0.19.2 answers an unknown subcommand by printing TOP-LEVEL usage and
# exiting 0. A status-only probe therefore accepts a CLI with no `close-out` at
# all, and the teardown would sail past a gate that never ran. So read the help
# TEXT and require an option only the real subcommand documents.
#
# Search order puts the worktree's OWN bin/cli first: that slot names the build
# the home was created with, which is the build that understands its layout.
# That preference is right and is kept — but since #61 that slot holds a shim
# that resolves ITSELF through $SKILL_MANAGER_CLI, so every invocation of a
# chosen CLI goes through `run_cli` below, probes included. The probe is not
# exempt: the variable can already be set in the caller's environment, and then
# the hang happens here, before the `cli:` line is ever printed.
cli_has_close_out() { run_cli "$1" home close-out --help 2>&1 | command grep -q -- '--into'; }

# Would naming $1 in $SKILL_MANAGER_CLI make it exec ITSELF?
#
# Since skill-manager issue #61 the home's own pin — `<home>/bin/cli/skill-manager`,
# which is the candidate the search below PREFERS, and which `skill-manager exec`
# also puts first on an agent session's PATH — resolves its own target as
#
#   cli="${SKILL_MANAGER_CLI:-<absolute path of the build that pinned it>}"
#   …
#   exec "$cli" "$@"
#
# It already knows its absolute target; that is the whole point of a pin. Naming
# the pin in that variable REPLACES the target with a path to itself, and it
# re-execs forever. Measured on the epic #2 pilot: 7:03 of CPU over 13:06 of
# wall clock, from one teardown. It hangs rather than failing, so on a fan-out
# it is indistinguishable from slow work.
#
# Two predicates, because each covers the other's blind spot:
#
#   * the home's own pin SLOT, by path. That file's identity is "the CLI for
#     this home", so pointing the variable at it is never what we mean — and
#     this answer survives an unreadable file, a stripped comment header, or any
#     future rewrite of the generated body.
#   * any candidate whose bytes EXPAND the variable. That is the one that
#     catches the PATH candidate: inside an agent session `command -v
#     skill-manager` is some OTHER home's pin, whose path this script has no
#     reason to recognise.
#
# Matched as FIXED strings, for the same reason bootstrap-home.sh matches
# GENERATED_PIN_PREFIX that way: `${`, `:-` and `$` are each metacharacters in
# some dialect of some grep, and a pattern that quietly matches nothing here
# means the check never fires. Matched on an EXPANSION (`${NAME` / `$NAME`)
# rather than on the bare name, so a shim that merely mentions the variable in a
# diagnostic — as the generated pin's own error message does — is not caught by
# that mention alone.
#
# This deliberately does not lean on skill-manager's companion self-exec guard.
# The homes most likely to be torn down are the ones pinned by the build that
# provisioned them, which is older than any guard added now.
cli_resolves_through_the_pin_variable() {
  local cli="$1" spelling
  [ "$cli" = "$STORE/bin/cli/skill-manager" ] && return 0
  for spelling in '${SKILL_MANAGER_CLI' '$SKILL_MANAGER_CLI'; do
    if command grep -q -F -- "$spelling" "$cli" 2>/dev/null; then return 0; fi
  done
  return 1
}

# Invoke $1, with the environment that makes its remedies runnable and cannot
# make it exec itself.
#
# The export is NOT dead weight for the candidates that are not self-pinning.
# HomeCloseOut names the CLI in every remedy through HomeDescriptor.resolveCli,
# whose rules are, in order: $SKILL_MANAGER_CLI, the running process's own
# command (only when it looks like a launcher — a jbang/JVM process does not),
# then <store>/bin/cli/skill-manager, then a bare `skill-manager` off PATH. When
# `pick_cli` answered with a checkout's or the integration parent's launcher,
# dropping the export lets resolution fall through to that last rule, and a bare
# `skill-manager` on this machine is the released 0.19.2, which exits 2 for the
# operator who copy-pastes the remedy. That is the defect selftest.sh's
# `the_printed_remedy_names_an_executable_that_exists` exists to hold shut, so
# the export is kept exactly where it is still doing that job.
#
# When the CLI IS self-pinning the export buys nothing anyway: rule 3 already
# answers <store>/bin/cli/skill-manager, which is the same runnable absolute
# path. So an INHERITED value is scrubbed rather than merely not set — the
# livelock does not care who exported it, and `skill-manager exec` puts a pin
# first on PATH, which is precisely how one gets picked with the variable
# already set in the agent's environment.
run_cli() {
  local cli="$1"; shift
  if cli_resolves_through_the_pin_variable "$cli"; then
    env -u SKILL_MANAGER_CLI "$cli" "$@"
  else
    SKILL_MANAGER_CLI="$cli" "$cli" "$@"
  fi
}

pick_cli() {
  local pinned="${SKILL_MANAGER_CLI:-}" c integration
  if [ -n "$pinned" ] && [ -x "$pinned" ] && cli_has_close_out "$pinned"; then
    printf '%s\n' "$pinned"; return 0
  fi
  # The enclosing integration repo is in the list because a CONSTITUENT
  # worktree's $ROOT is the constituent, which ships no skill-manager of its
  # own; the epic build lives in the parent. Same addition as
  # bootstrap-home.sh's pick_cli, for the same reason.
  integration="$(outermost_integration_root "$ROOT")"
  for c in "$STORE/bin/cli/skill-manager" "$ROOT/skill-manager" "$ROOT"/constituents/*/skill-manager \
           ${integration:+"$integration/skill-manager" "$integration"/constituents/*/skill-manager}; do
    [ -f "$c" ] && [ -x "$c" ] && cli_has_close_out "$c" && { printf '%s\n' "$c"; return 0; }
  done
  c="$(command -v skill-manager || true)"
  if [ -n "$c" ] && cli_has_close_out "$c"; then printf '%s\n' "$c"; return 0; fi
  return 1
}

# Announced, because this loop is silent and not fast: every candidate it
# considers costs a CLI start, and there are up to five of them. Until this line
# existed the last thing printed before the search was `into:`, so a search that
# never returned looked exactly like a search that was still going — which is how
# the self-exec livelock below was mistaken for slow work.
info "probing:   for a skill-manager that answers \`home close-out\` (one CLI start per candidate)"

# `|| true` because pick_cli returning 1 under `set -e` would abort before the
# refusal below can explain itself.
CLI="$(pick_cli || true)"

# --------------------------------------------------------------- the verdict

# The one command that clears the refusal about to be printed. Set by the caller
# when it knows something better than "discard it all", which is the only
# universally-true answer and the worst one to lead with. Read by refuse().
REFUSE_FIX=""

# refuse <reason...> — stop, unless the operator asked to discard.
refuse() {
  # THE CONTRACT KEY SETS ARE EXCLUSIVE. `wt --help` states "either, on failure
  # FAILED / FIX", and a run that goes on to remove the worktree and print
  # CLOSED / BRANCH / DELETE is not a failure — it is a success the operator
  # asked for. Measured: `wt close ACME-2 --force` exited 0 having printed
  # FAILED and FIX and then CLOSED, BRANCH and DELETE, so a caller parsing
  # stdout saw a failure on a run that succeeded, and a caller that keys on
  # FAILED first saw the opposite of what happened.
  #
  # So on the forced path the refusal is EXPLANATION, not verdict, and
  # explanation lives on stderr like all the other prose here. It is not
  # quieter: the same lines are printed, plus the DISCARDED banner. What
  # changes is which stream carries the answer.
  if [ "$FORCE" = 1 ]; then
    printf '\n' >&2
    printf 'the gate refused to remove %s\n' "$WT" >&2
    printf '  %s\n' "$@" >&2
    printf '\n  Clearing it would have been:\n    %s\n' \
      "${REFUSE_FIX:-$0 $TARGET --force}" >&2
    printf '\n  --force given: removing anyway. Anything above is DISCARDED.\n' >&2
    return 0
  fi
  # The contract first, on stdout: FIRST argument as the one-line summary, since
  # the remaining ones are the explanation and an agent acting on stdout alone
  # needs the headline and a command, not a paragraph.
  contract_fail "${REFUSE_FIX:-$0 $TARGET --force}" "$1"
  printf '\n' >&2
  printf 'refusing to remove %s\n' "$WT" >&2
  printf '  %s\n' "$@" >&2
  cat >&2 <<EOF

  Clear the blockers above, or discard them deliberately:
    $0 $TARGET --force
EOF
  exit "$REFUSED_EXIT"
}

gate_ran=0
# Did the gate ESTABLISH that nothing would be lost? Distinct from "the script is
# still running": --force lets a refusal continue, and a --dry-run that then
# reported CLEAN would be reporting the opposite of what happened.
gate_clean=0
if [ ! -d "$STORE" ]; then
  # The one case where absence really is proof: no home, no home-resident work.
  info "gate:      skipped — no home in this worktree, so it holds no unit work"
  gate_ran=1; gate_clean=1
elif [ -z "$CLI" ]; then
  # The home's OWN pin is the candidate this script prefers, and re-provisioning
  # it is one command — so the fix is to repair the home, not to discard it.
  REFUSE_FIX="$SCRIPT_DIR/bootstrap-home.sh --root $WT --force"
  refuse "no skill-manager with a \`home close-out\` subcommand was found," \
         "so whether this worktree still holds work could not be established." \
         "  looked at: \$SKILL_MANAGER_CLI, $STORE/bin/cli/skill-manager," \
         "             a skill-manager shipped by this checkout, then PATH." \
         "  Set SKILL_MANAGER_CLI to a build that has it and re-run."
elif [ ! -d "$INTO" ]; then
  REFUSE_FIX="$SCRIPT_DIR/bootstrap-home.sh --root $(dirname "$INTO")"
  refuse "the project home $INTO does not exist, so the worktree's work has" \
         "nowhere to go and the gate has nothing to check against." \
         "  Create it (scripts/agent-home.sh) or pass --into <home>."
else
  info "cli:       $CLI"
  step "Gate: does this worktree still hold work?"
  # Say what is about to run, and say it BEFORE running it. This is the script's
  # longest step by an order of magnitude — a CLI start plus a full compare of
  # two homes — and when it went wrong it went wrong by not returning. A step
  # banner alone ("Gate: …") cannot be told apart from a hang; the command can,
  # because the operator can run it by hand and watch it do the same thing.
  info "running:   $CLI home close-out --home $STORE --into $INTO --json"
  # The remedy strings the gate prints have to name a CLI the operator can run,
  # and it is HomeCloseOut that names it, through HomeDescriptor.resolveCli.
  # `run_cli` supplies the environment that makes that resolution land on a
  # runnable path — passing this script's already-probed answer in through
  # $SKILL_MANAGER_CLI when doing so is safe, and staying out of the way when
  # the chosen CLI is a self-pinning shim that would otherwise exec itself
  # forever. See cli_resolves_through_the_pin_variable.
  #
  # Naming the CLI at all replaced a regex substitution over the rendered
  # remedy, which was the wrong shape twice over: it fixed only the --json
  # consumer and left `home close-out`'s own human output printing the
  # un-runnable spelling, and its token boundary matched inside
  # `skill-manager.toml` — the most common conflicted file there is — rewriting
  # the operator's conflict list into a path in a different repository.
  VERDICT="$(run_cli "$CLI" home close-out \
      --home "$STORE" --into "$INTO" --json 2>/dev/null)" && rc=0 || rc=$?

  if [ -z "$VERDICT" ]; then
    # Re-running the gate by hand is the fix, because the reason it said nothing
    # is on its stderr, which --json swallowed.
    REFUSE_FIX="$CLI home close-out --home $STORE --into $INTO"
    refuse "\`home close-out\` produced no verdict (exit $rc), so nothing was established."
  else
    # Render blockers from the JSON rather than re-deriving them: the CLI owns
    # the remedy strings, and a second opinion here is a second thing to keep
    # in step with HomeCloseOut.
    #
    # It renders the remedy VERBATIM. The CLI owns that string and now names
    # itself in it (HomeCloseOut.cliInvocation); a second opinion here was a
    # regex over someone else's sentence, and it corrupted the one thing a
    # remedy tail carries — the conflicted-file list, where `skill-manager.toml`
    # matched the token and became a path in another repository.
    # Captured, then printed, so the FIX line can name the FIRST blocker's own
    # remedy. `--force` is the only fix that is always true and the worst one to
    # lead with — it is the one that throws the work away — so the contract names
    # the command that clears the blocker instead, and leaves --force to the
    # prose. Rendered once and reused, never rendered twice: the remedy string
    # belongs to HomeCloseOut and a second render is a second chance to differ
    # from it.
    RENDERED="$(printf '%s' "$VERDICT" | "$PY" -c '
import json, sys

try:
    v = json.load(sys.stdin)
except Exception as exc:
    print("  could not parse the verdict: %s" % exc); raise SystemExit(0)
if v.get("error"):
    print("  %s" % v.get("message", v["error"]))
    raise SystemExit(0)
for u in v.get("units", []):
    if u.get("status") != "unchanged":
        print("  %-14s %s - %s" % (u["status"], u["unit"], u["detail"]))
for b in v.get("blockers", []):
    print("")
    print("  BLOCKED  %s (%s)" % (b["unit"], b["status"]))
    for c in b.get("conflicts", []):
        print("      conflict  %s" % c)
    print("      run: %s" % b["remedy"])
')"
    printf '%s\n' "$RENDERED" >&2

    if [ "$rc" != 0 ]; then
      FIRST_REMEDY="$(printf '%s\n' "$RENDERED" | command sed -n 's/^      run: //p' | command sed -n 1p)"
      REFUSE_FIX="${FIRST_REMEDY:-$0 $TARGET --force}"
      # Only reachable with --force; refuse() exits otherwise. Do NOT fall
      # through to the "clean" line below — saying "clean" one line after
      # "DISCARDED" is how a forced teardown gets remembered as a safe one.
      refuse "\`home close-out\` exited $rc: this worktree holds work that removing it would destroy." \
             "Each blocker above names the command that clears it. Run them, then re-run this script."
      info "gate:      OVERRIDDEN — the work listed above is being discarded"
    else
      info "gate:      clean — $STORE holds nothing that removing it would destroy"
      gate_clean=1
    fi
  fi
  gate_ran=1
fi

[ "$gate_ran" = 1 ] || die "internal: gate did not run"

# ------------------------------------------------------------------- removal

if [ "$DRY_RUN" = 1 ]; then
  step "Dry run — nothing removed"
  info "would run: git -C \"$ROOT\" worktree remove \"$WT\""
  if [ "$gate_clean" = 1 ]; then
    contract CLEAN "$WT — the gate found nothing that removing it would destroy"
    contract CLOSE "$SCRIPT_DIR/wt close $TARGET"
  fi
  exit 0
fi

# Removing the directory the caller is standing in leaves the shell in a path
# that no longer exists, and `git worktree remove --force` will do it. Refuse
# where the operator can still read the message.
#
# BELOW the dry-run exit, deliberately. A dry run removes nothing, so it is the
# safest thing an operator can do and the most natural one to run from inside
# the worktree they are asking about; refusing it there made the read-only
# gesture the one that was blocked while the destructive one was still a cd
# away.
case "$INVOKED_FROM/" in
  "$WT"/*) die_fix 1 "bash -c \"cd '$ROOT' && '$SCRIPT_DIR/wt' close '$TARGET'\"" \
    "refusing to remove $WT while you are standing in it — cd elsewhere and re-run, or use --dry-run to just ask" ;;
esac

step "Removing the worktree"
# --force here is about git's own refusal over the ignored home and any build
# output beside it, NOT about the gate: the gate has already had its say above,
# and reaching this line means it either passed or was consciously overridden.
if ! git -C "$ROOT" worktree remove --force "$WT"; then
  die "git worktree remove failed for $WT"
fi
info "removed:   $WT (and its home)"

# The contract, on stdout. The branch outlives the worktree on purpose, so the
# only thing still owed is what it is called and how to delete it — and it is
# named, not left as the literal `<branch>` the old trailing note printed.
contract CLOSED "$WT"
if [ -n "$WT_BRANCH" ]; then
  contract BRANCH "$WT_BRANCH (still here — the change may not have landed yet)"
  contract DELETE "git -C $ROOT branch -d $WT_BRANCH"
fi

# THE LAST MILE, WHICH THIS TEARDOWN USED TO LEAVE UNSAID.
#
# The gate above is about whether removing the worktree would DESTROY work, and
# the remedy it names is `home sync`. What `home sync` does is move an edit ONE
# TIER UP — from `<worktree>/.skill-manager` into this checkout's own project
# home — and that is the whole of it. Two fresh-agent evals noticed the gap
# unprompted, from opposite directions: the edit is not in the skill's own
# repository, so a later reinstall or upgrade of that unit overwrites it and no
# other checkout ever sees it; and the push cannot be done from the worktree
# anyway, because the copy of the skill that holds the edit is inside a home
# that is being deleted in the same breath.
#
# So the successful close states where the work now is and what it still owes.
# A key, not a paragraph on stderr: the removal is exactly the moment the
# obligation becomes invisible — the home is gone and the loss appears in no
# diff — and `wt` carries it onto its one line for the same reason. See
# git-integration-skill#8.
[ "$HAD_HOME" = 0 ] || contract HOME-WORK \
  "$INTO (as far as \`home sync\` moves it — this checkout only. A skill edit is not in that skill's OWN repository until it is pushed from $ROOT, and until then a reinstall can overwrite it and no other checkout sees it.)"

cat >&2 <<EOF

The branch is still here. Delete it when the change has landed:
  git -C "$ROOT" branch -d ${WT_BRANCH:-<branch>}
EOF

[ "$HAD_HOME" = 0 ] || cat >&2 <<EOF

Where this worktree's HOME work now lives, and what it still owes:
  $INTO
That is one tier up, and one tier only. \`skill-manager home sync\` reconciles a
worktree home into the checkout's own home; it does NOT push a skill edit back
to that skill's repository, and \`propagate.sh\` does not either — propagate
fans out the PARENT's tracked files, and a home is gitignored.
So if you edited a skill in that worktree:
  * the edit is now in $INTO and nowhere else,
  * a later \`skill-manager install\`/\`upgrade\`/\`sync\` of that unit can
    overwrite it, and no other checkout will ever see it,
  * push it from $ROOT — not from a worktree, whose copy of the skill lived in
    the home that has just been deleted.
See references/skill-homes.md.
EOF
