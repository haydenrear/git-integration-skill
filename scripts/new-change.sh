#!/usr/bin/env bash
# new-change.sh <TICKET> [base-branch] [--integration] [--no-home]
#
# Create a ticketed worktree, with its own Skill Manager home, for the repo you
# are standing in.
#
# Which repo that is
# ------------------
# The nearest enclosing git toplevel — and the script SAYS which one before it
# does anything. It used to resolve the nearest ancestor holding
# integration.toml instead (repo_root), which is right for propagate/refresh/
# verify and wrong here: a constituent has its own real .git, so run from
# constituents/deploy-helm that answer was the integration PARENT, and the
# script branched and worktree'd a different repository than the one the
# operator was standing in — with exit 0 and no warning. Three shapes now, all
# supported, all announced:
#
#   integration   the checkout holds integration.toml. Constituent files are
#                 plain files in the worktree; propagate.sh fans the change out
#                 afterwards. (Includes a NESTED integration repo such as
#                 meta-orchestrator, which is an integration repo in its own
#                 right and correct to branch here.)
#   constituent   a git repo living inside an integration repo's tree. Branch
#                 the constituent itself. Nothing to fan out; the integration
#                 parent refreshes its snapshot after the change merges.
#   standalone    an ordinary repo, outside any integration repo.
#
# Supporting all three rather than refusing two of them is deliberate. The
# script's value is that the per-worktree home is not optional; sending an
# operator to `git worktree add` + `bootstrap-home.sh` by hand makes the home
# step something to remember again, which is the exact failure the home exists
# to prevent. What must never happen is a SILENT wrong target, and that is
# fixed by resolving correctly and printing the answer, not by refusing.
#
# Pass --integration to target the enclosing integration repo instead of the
# constituent you happen to be standing in.
#
# Where the worktree goes
# -----------------------
# Beside the OUTERMOST enclosing integration repo — see worktree_parent_dir in
# lib.sh. Unchanged for a top-level repo; for anything inside an integration
# repo it is the difference between a clean parent and a parent whose
# `git add -A` stages the worktree as a gitlink.
#
# The home
# --------
# The worktree gets its OWN Skill Manager home (bootstrap-home.sh) before this
# script returns, and therefore before any agent can run in it. That is on
# purpose: an agent that has to remember to export SKILL_MANAGER_HOME will
# sometimes not, and the failure is invisible — it just edits the operator's
# global home instead. Pass --no-home (or INTEGRATION_SKIP_HOME=1) only when
# you know the worktree will never host an agent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: new-change.sh <TICKET> [base-branch] [--integration] [--no-home]

  TICKET          Ticket id. The branch is feature/<TICKET>; the worktree is
                  <repo>-<TICKET>, placed beside the outermost enclosing
                  integration repo.
  base-branch     Branch to start from. Default: the checkout's current branch.
  --integration   Target the enclosing INTEGRATION repo rather than the
                  constituent you are standing in.
  --no-home       Skip the per-worktree Skill Manager home. Agents launched in
                  the worktree then use the operator's global home.
  --quiet         Print nothing at all on stderr. The contract on stdout is
                  unaffected — it is what `wt` shows.
  --verbose       Put the whole log on stderr as it happens, instead of the one
                  line naming it.
  --info          Print the contract for a worktree that ALREADY exists, and
                  create nothing. `wt info <TICKET>` is this.
  -h, --help      This message.

Stdout is the contract and nothing else: WORKTREE / BRANCH / LAUNCH / IF-EXIT-8
/ CLOSE (/ PROPAGATE) on success, FAILED / FIX on failure. Stderr on a
successful run is one line: the log file holding the narration, this script's
and bootstrap-home.sh's alike. `wt new <TICKET>` runs this and prints a ONE-LINE
summary of the contract instead; `wt info <TICKET>` prints the contract itself.
EOF
}

TICKET=""; BASE=""; SKIP_HOME="${INTEGRATION_SKIP_HOME:-0}"; WANT_INTEGRATION=0
QUIET=0; VERBOSE=0; INFO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-home)     SKIP_HOME=1; shift ;;
    --integration) WANT_INTEGRATION=1; shift ;;
    --quiet)       QUIET=1; shift ;;
    --verbose|-v)  VERBOSE=1; shift ;;
    --info)        INFO=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            usage; die "unknown option: $1" ;;
    *)             if [ -z "$TICKET" ]; then TICKET="$1"; elif [ -z "$BASE" ]; then BASE="$1";
                   else die "unexpected argument: $1"; fi; shift ;;
  esac
done
[ -n "$TICKET" ] || { usage; die "a ticket id is required"; }

# ------------------------------------------------------------------ the log
#
# Same shape as bootstrap-home.sh's, and for the same measured reason: 44 lines
# / 4.0 KB on a successful run, of which 28 were a prose restatement of the five
# contract lines already on stdout. The contract is the output; the prose is the
# explanation of it, and an explanation belongs where it can be read when it is
# wanted rather than paid for when it is not.
#
# fd 2 becomes the log, so this script's narration, its closing notes AND every
# byte bootstrap-home.sh writes land in ONE file — which is the point: a worktree
# provisioning is one story, and it used to be told in two places. fd 3 is the
# operator's real stderr and carries one line.
#
# --quiet is unchanged in meaning and is what `wt` passes: nothing on stderr at
# all, because `wt` prints its own contract and captures this one.
_LOG_TMP="${TMPDIR:-/tmp}"
_LOG_TMP="$(mktemp "${_LOG_TMP%/}/new-change-XXXXXX")"
LOG="$_LOG_TMP.log"
mv "$_LOG_TMP" "$LOG"
exec 3>&2
if [ "$VERBOSE" = 1 ]; then
  exec 2> >(command tee -a "$LOG" >&3)
else
  exec 2>>"$LOG"
fi

# 20, the tail, and the log line first — all three for the reasons spelled out
# beside bootstrap-home.sh's copy. The one that matters most here: `wt` quotes
# the LAST NON-EMPTY STDERR LINE as its FAILED reason when a child dies without a
# contract, so the failure's own last line has to stay last.
LOG_TAIL=20
report_failure() {
  local total
  total="$(command wc -l < "$LOG" 2>/dev/null | command tr -d ' ')" || total=0
  [ -n "$total" ] || total=0
  if [ "$total" -gt "$LOG_TAIL" ]; then
    printf 'log:       %s  (%s earlier line(s) omitted below)\n' "$LOG" "$((total - LOG_TAIL))" >&3
  else
    printf 'log:       %s\n' "$LOG" >&3
  fi
  command tail -n "$LOG_TAIL" "$LOG" >&3 2>/dev/null || true
}
on_exit() {
  local rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$VERBOSE" = 1 ]; then
      printf 'log:       %s\n' "$LOG" >&3
    else
      report_failure
    fi
  fi
  return "$rc"
}
trap on_exit EXIT

# ------------------------------------------------------------------ the contract
#
# STDOUT, and nothing else on it. These are the facts an agent needs to take its
# next step, and they are emitted HERE rather than assembled by `wt` afterwards
# because this script is the only thing that authoritatively knows them: $WT came
# from `ticket_worktree_path`, which is the same function close-change.sh
# resolves the ticket with, and $ROOT/$KIND came from the resolution this script
# already printed. A front door that re-derived them would be a second opinion
# about which worktree belongs to which repo, and issue #50 is what a second
# opinion about that costs.
#
# ONE function, called from the creating path and from `--info`, because those
# two answer the same question about the same worktree and a second copy is a
# second chance to disagree. `wt new` prints a one-line summary OF THIS, and
# `wt info` prints THIS; neither assembles it.
#
# The LAUNCH branch keys on whether the home is THERE, not on whether --no-home
# was passed. The two coincide on the creating path; on `--info` only the first
# is knowable, and it is the one that is true — printing a shim that does not
# exist is the same class of defect as `verified` over an empty home.
emit_contract() {
  local wt="$1" branch_desc="$2"
  contract WORKTREE  "$wt"
  contract BRANCH    "$branch_desc"
  if [ -d "$wt/.skill-manager" ]; then
    contract LAUNCH    "$wt/.skill-manager/bin/launch/claude"
    # The first launch from a fresh home is REFUSED with exit 8 until the change
    # to its units has been read. That is not an error, it is the drift gate, and
    # an agent that meets it without this line goes looking for a reference page.
    # It is NOT on `wt new`'s one-line summary on purpose: a remedy for a gate
    # that has not fired is paid for on every run in which it never fires, and
    # `wt info` is where an agent that HAS met exit 8 looks.
    contract IF-EXIT-8 "$wt/.skill-manager/bin/cli/skill-manager home drift --ack"
  else
    contract LAUNCH    "none — this worktree has no home; an agent here uses the operator's GLOBAL home"
  fi
  contract CLOSE     "$SCRIPT_DIR/wt close $TICKET"
  [ "$KIND" != integration ] || contract PROPAGATE "$SCRIPT_DIR/propagate.sh $TICKET"
}

# ------------------------------------------------------- which repo, out loud

FROM="$PWD"
ROOT="$(checkout_root)"
KIND="$(checkout_kind "$ROOT")"
INTEGRATION="$(outermost_integration_root "$ROOT")"

if [ "$WANT_INTEGRATION" = 1 ]; then
  [ -n "$INTEGRATION" ] || die "--integration: no integration.toml in any ancestor of $ROOT"
  ROOT="$(repo_root)"                 # the NEAREST one: from inside a nested
  KIND="$(checkout_kind "$ROOT")"     # integration repo that is the right target
fi

step "Repository for $TICKET"
info "from:      $FROM"
info "repo:      $ROOT"
info "kind:      $KIND"
case "$KIND" in
  constituent)
    # The announcement is the point: this is the case that used to be answered
    # wrongly, silently, with exit 0.
    info "note:      a constituent of $INTEGRATION — branching the CONSTITUENT."
    info "           Pass --integration (or cd there) to branch $INTEGRATION."
    ;;
  integration)
    if [ -n "$INTEGRATION" ] && [ "$INTEGRATION" != "$ROOT" ]; then
      info "note:      a NESTED integration repo inside $INTEGRATION."
      info "           Branching it is correct; its worktree is kept OUTSIDE"
      info "           $INTEGRATION so that tree stays clean."
    fi
    ;;
esac

cd "$ROOT"

BRANCH="feature/$TICKET"
WT="$(ticket_worktree_path "$ROOT" "$TICKET")"

# ------------------------------------------------------------------- --info
#
# The same contract, for a worktree that already exists. It exists because `wt
# new` now prints ONE line — the worktree path, the only fact on the old
# five-line contract that does not follow from the others — and the rest has to
# stay ANSWERABLE rather than merely derivable-in-principle.
#
# It is here, and not in `wt`, for the reason the contract block below is here:
# $WT is `ticket_worktree_path`'s answer and $KIND is this script's resolution,
# and a front door that recomputed either would be a second opinion about which
# worktree belongs to which repo. That is issue #50.
#
# Above `assert_parent_clean` deliberately. Asking where a worktree is must work
# while the parent is dirty — that is most of the time an agent asks — and this
# path writes nothing at all.
if [ "$INFO" = 1 ]; then
  [ -d "$WT" ] || die_fix 1 "$SCRIPT_DIR/wt new $TICKET" \
    "no worktree for $TICKET at $WT"
  # What the worktree is ACTUALLY on, not what `new` would have called it: a
  # worktree may have been rebranched, and reporting the default spelling of a
  # branch that is not checked out is the class of defect the literal `<branch>`
  # in the old teardown note was.
  BRANCH="$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '%s' "$BRANCH")"
  emit_contract "$WT" "$BRANCH ($KIND repo $(basename "$ROOT"))"
  exit 0
fi

assert_parent_clean "$ROOT"
assert_worktree_outside_integration "$WT"
# The recovery for this used to be named nowhere, which is how an operator who
# hit it reached for `rm -rf` or a bare `git worktree remove` — both of which
# skip the close-out gate and delete the home silently. It is one command, so it
# is the FIX.
[ -e "$WT" ] && die_fix 1 "$SCRIPT_DIR/wt close $TICKET" \
  "a worktree for $TICKET already exists at $WT"

: "${BASE:=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)}"

step "Creating worktree for $TICKET"
git -C "$ROOT" worktree add -q -b "$BRANCH" "$WT" "$BASE"
info "worktree:  $WT"
info "branch:    $BRANCH  (base: $BASE)"

# Sanity: no constituent .git leaked into an integration worktree. Only an
# integration repo has constituents, so only it can have this problem.
if [ "$KIND" = integration ] && [ -d "$WT/constituents" ]; then
  if command find "$WT/constituents" -maxdepth 2 -name .git 2>/dev/null | command grep -q .; then
    info "WARNING: found a .git inside the worktree's constituents — unexpected"
  fi
fi

# The worktree's own Skill Manager home. One implementation, shared with a
# repo root's scripts/agent-home.sh — see bootstrap-home.sh for why the clone
# has to happen before anything else touches a home.
if [ "$SKIP_HOME" = 1 ]; then
  info "home:      skipped (--no-home) — agents launched here will use the global home"
else
  step "Giving the worktree its own Skill Manager home"
  HOME_RC=0
  "$SCRIPT_DIR/bootstrap-home.sh" --root "$WT" || HOME_RC=$?
  if [ "$HOME_RC" != 0 ]; then
    # ROLL THE WORKTREE BACK. Leaving it was the wrong half of a two-step
    # operation: the worktree and the branch survived, `new-change.sh <TICKET>`
    # then refused with "worktree path already exists", and the recovery
    # (close-change.sh) was named nowhere. The most common cause is a project
    # with no home yet — 17 of this repo's 24 constituents — so the state an
    # operator lands in matters more than the rarity of the failure.
    #
    # Removal is safe precisely here and nowhere else: this worktree was created
    # seconds ago by this script, nothing has been edited in it, and the home
    # bootstrap FAILED so there is no home in it to lose. That is the one case
    # close-change.sh's gate would also wave through, so this is not a bypass of
    # it.
    rolled_back=0
    if git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null; then
      git -C "$ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
      rolled_back=1
    fi
    # Exit 5 is bootstrap-home.sh's "the home has no skills" (#10). Distinct
    # remedy, and the generic one below is actively wrong for it: re-running the
    # bootstrap against the PROJECT does not install anything, so the operator
    # would loop. The fix is `--onboard` against the project, because a worktree
    # home is a copy of the project home and onboarding the copy instead makes it
    # unclosable (#50).
    if [ "$HOME_RC" = 5 ]; then
      contract_fail "$SCRIPT_DIR/bootstrap-home.sh --root $ROOT --onboard" \
        "the project home $ROOT/.skill-manager holds no skills, so this worktree's copy would hold none either"
      cat >&2 <<EOF

The worktree's home was created but holds NO SKILLS, because the project home it
is copied from holds none either. Install into the PROJECT home, then re-run:

  $SCRIPT_DIR/bootstrap-home.sh --root "$ROOT" --onboard
  $0 $TICKET${BASE:+ $BASE}
EOF
    # Exit 6 is "the home holds skills that no agent launched here can read":
    # the store copied fine, the projection into <wt>/.claude|.codex|.gemini did
    # not complete. Distinct from 5, and the generic remedy below is wrong for
    # it — the project home is not the problem, it has no projection to give
    # (the agent homes live BESIDE the store and are not part of a clone).
    #
    # The FIX names THIS script, not `bootstrap-home.sh --root $WT`: the
    # worktree was rolled back a few lines above, so $WT no longer exists and a
    # remedy pointing at it would fail on a path that is gone. Re-running is
    # right because bootstrap-home.sh will re-attempt the projection; the
    # diagnosis, if it recurs, is in the sync output it already printed.
    elif [ "$HOME_RC" = 6 ]; then
      contract_fail "$0 $TICKET${BASE:+ $BASE}" \
        "this worktree's home held skills that no agent launched in it could read (the projection into .claude/.codex/.gemini did not complete)"
      cat >&2 <<EOF

The home was cloned and held units, but they were not linked into the worktree's
agent homes, so an agent started there would have seen NONE of them. That used
to be reported as \`verified\` and exit 0. bootstrap-home.sh named the exact
missing links and the \`sync --skip-mcp\` that creates them, above.

  $0 $TICKET${BASE:+ $BASE}

If it refuses the same way again, the sync itself is failing: run the command
bootstrap-home.sh printed, by hand, and read what it says.
EOF
    else
    contract_fail "$SCRIPT_DIR/bootstrap-home.sh --root $ROOT" \
      "no Skill Manager home could be created for this worktree (usually: $ROOT has no project home yet)"
    cat >&2 <<EOF

No home could be created for this worktree, so an agent started in it would
read and write the operator's GLOBAL home. The cause is printed above, and the
remedy that clears it is in that message — it is usually that this repo has no
project home yet, which one command fixes:

  $SCRIPT_DIR/bootstrap-home.sh --root "$ROOT"
  $0 $TICKET${BASE:+ $BASE}
EOF
    fi
    if [ "$rolled_back" = 1 ]; then
      cat >&2 <<EOF

The worktree and branch $BRANCH were removed, so re-running the line above
works as if this attempt had not happened.
EOF
    else
      cat >&2 <<EOF

The worktree at $WT could NOT be rolled back automatically. Remove it before
re-running, through the gate rather than by hand:
  $SCRIPT_DIR/close-change.sh "$TICKET"
EOF
    fi
    cat >&2 <<EOF

Or, if this worktree will never host an agent, create it with --no-home.
EOF
    exit 3
  fi
fi

emit_contract "$WT" "$BRANCH (from $BASE, $KIND repo $(basename "$ROOT"))"

# ----------------------------------------------------------------- next steps

cat >&2 <<EOF

Edit in:
  $WT
Launch an agent bound to this worktree's own home:
  $WT/.skill-manager/bin/launch/claude
If that first launch is REFUSED with exit 8, the home is fine — its units
changed and skill-manager gates the next launch until the change has been read.
Read it and clear it, through this home's own CLI entrypoint:
  $WT/.skill-manager/bin/cli/skill-manager home drift
  $WT/.skill-manager/bin/cli/skill-manager home drift --ack
Then commit and bring it back:
  git -C "$WT" add -A && git -C "$WT" commit -m "$TICKET: <what changed>"
  git -C "$ROOT" merge --no-ff "$BRANCH"
Close the worktree through the gate (NOT a bare "git worktree remove"):
  $SCRIPT_DIR/close-change.sh "$TICKET"
EOF

if [ "$KIND" = integration ]; then
  cat >&2 <<EOF
Finally fan it out to the constituents:
  $SCRIPT_DIR/propagate.sh "$TICKET"
EOF
else
  cat >&2 <<EOF

This is a $KIND worktree, so propagate.sh does NOT apply — there are no
constituents beneath it to fan out to. Once the change has merged here, refresh
the integration parent's snapshot of this repo from the parent's own main tree.
EOF
fi

cat >&2 <<EOF

Teardown note: the home lives inside the worktree, so removing the worktree
removes the home, and because the home is gitignored that loss appears in no
diff. close-change.sh runs "skill-manager home close-out" first and refuses
while the home still holds unit work, naming each blocker and its remedy; pass
--force to discard deliberately. See references/skill-homes.md. Reconciling
into the project home is NOT the same as pushing a skill edit back to that
skill's own repo — that is the separate push-back flow, and it is not
propagate.sh.
EOF

# The whole of stderr on a successful run. Everything above is in the file it
# names, including bootstrap-home.sh's own narration, which this script's fd 2
# collected on the way past.
[ "$QUIET" = 1 ] || [ "$VERBOSE" = 1 ] || printf 'log:       %s\n' "$LOG" >&3
