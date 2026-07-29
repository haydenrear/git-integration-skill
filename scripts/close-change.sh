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
                   the same path new-change.sh creates. A path may be given
                   instead.
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
case "$TARGET" in
  */*|.|..) WT="$TARGET" ;;
  *)        WT="$(ticket_worktree_path "$ROOT" "$TARGET")" ;;
esac
[ -d "$WT" ] || die "not a directory: $WT"
WT="$(cd "$WT" && pwd -P)"

[ "$WT" = "$ROOT" ] && die "refusing to remove the repo's main working tree ($ROOT)"

# Removing the directory the caller is standing in leaves the shell in a path
# that no longer exists, and `git worktree remove --force` will do it. Refuse
# where the operator can still read the message.
case "$INVOKED_FROM/" in
  "$WT"/*) die "refusing to remove $WT while you are standing in it
  cd elsewhere (e.g. $ROOT) and re-run." ;;
esac

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
cli_has_close_out() { "$1" home close-out --help 2>&1 | command grep -q -- '--into'; }

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

# `|| true` because pick_cli returning 1 under `set -e` would abort before the
# refusal below can explain itself.
CLI="$(pick_cli || true)"

# --------------------------------------------------------------- the verdict

# refuse <reason...> — stop, unless the operator asked to discard.
refuse() {
  printf '\n' >&2
  printf 'refusing to remove %s\n' "$WT" >&2
  printf '  %s\n' "$@" >&2
  if [ "$FORCE" = 1 ]; then
    printf '\n  --force given: removing anyway. Anything above is DISCARDED.\n' >&2
    return 0
  fi
  cat >&2 <<EOF

  Clear the blockers above, or discard them deliberately:
    $0 $TARGET --force
EOF
  exit "$REFUSED_EXIT"
}

gate_ran=0
if [ ! -d "$STORE" ]; then
  # The one case where absence really is proof: no home, no home-resident work.
  info "gate:      skipped — no home in this worktree, so it holds no unit work"
  gate_ran=1
elif [ -z "$CLI" ]; then
  refuse "no skill-manager with a \`home close-out\` subcommand was found," \
         "so whether this worktree still holds work could not be established." \
         "  looked at: \$SKILL_MANAGER_CLI, $STORE/bin/cli/skill-manager," \
         "             a skill-manager shipped by this checkout, then PATH." \
         "  Set SKILL_MANAGER_CLI to a build that has it and re-run."
elif [ ! -d "$INTO" ]; then
  refuse "the project home $INTO does not exist, so the worktree's work has" \
         "nowhere to go and the gate has nothing to check against." \
         "  Create it (scripts/agent-home.sh) or pass --into <home>."
else
  info "cli:       $CLI"
  step "Gate: does this worktree still hold work?"
  VERDICT="$("$CLI" home close-out --home "$STORE" --into "$INTO" --json 2>/dev/null)" && rc=0 || rc=$?

  if [ -z "$VERDICT" ]; then
    refuse "\`home close-out\` produced no verdict (exit $rc), so nothing was established."
  else
    # Render blockers from the JSON rather than re-deriving them: the CLI owns
    # the remedy strings, and a second opinion here is a second thing to keep
    # in step with HomeCloseOut.
    #
    # One rewrite, and it is not cosmetic. HomeCloseOut spells every remedy
    # `skill-manager ...`, and a bare `skill-manager` on this machine's PATH is
    # the released 0.19.2 — no `home` subcommand at all, so the remedy an
    # operator copy-pastes exits 2 while the gate that printed it went on
    # working. pick_cli above already resolved WHICH build understands this
    # home; substituting that answer is reusing it rather than inventing a
    # second one. Only the standalone token is replaced, so a unit NAMED
    # skill-manager-skill keeps its name.
    printf '%s' "$VERDICT" | "$PY" -c '
import json, re, shlex, sys

cli = shlex.quote(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else None
TOKEN = re.compile(r"(?<![\w./-])skill-manager(?![\w-])")

def remedy(text):
    # A function replacement, not a string one: re treats backslashes in a
    # replacement STRING as escapes, and a home path is not a regex.
    return TOKEN.sub(lambda m: cli, text) if cli else text

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
    print("      run: %s" % remedy(b["remedy"]))
' "$CLI" >&2

    if [ "$rc" != 0 ]; then
      # Only reachable with --force; refuse() exits otherwise. Do NOT fall
      # through to the "clean" line below — saying "clean" one line after
      # "DISCARDED" is how a forced teardown gets remembered as a safe one.
      refuse "\`home close-out\` exited $rc: this worktree holds work that removing it would destroy." \
             "Each blocker above names the command that clears it. Run them, then re-run this script."
      info "gate:      OVERRIDDEN — the work listed above is being discarded"
    else
      info "gate:      clean — $STORE holds nothing that removing it would destroy"
    fi
  fi
  gate_ran=1
fi

[ "$gate_ran" = 1 ] || die "internal: gate did not run"

# ------------------------------------------------------------------- removal

if [ "$DRY_RUN" = 1 ]; then
  step "Dry run — nothing removed"
  info "would run: git -C \"$ROOT\" worktree remove \"$WT\""
  exit 0
fi

step "Removing the worktree"
# --force here is about git's own refusal over the ignored home and any build
# output beside it, NOT about the gate: the gate has already had its say above,
# and reaching this line means it either passed or was consciously overridden.
if ! git -C "$ROOT" worktree remove --force "$WT"; then
  die "git worktree remove failed for $WT"
fi
info "removed:   $WT (and its home)"

cat >&2 <<EOF

The branch is still here. Delete it when the change has landed:
  git -C "$ROOT" branch -d <branch>
EOF
