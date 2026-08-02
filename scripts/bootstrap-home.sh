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
                         [--onboard [--onboard-gateway]] [--allow-empty]

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
  --onboard        When the finished home has NO skills, run
                   `skill-manager onboard --skip-gateway` on it instead of
                   refusing. Only legal for a MAIN working tree: onboarding a
                   WORKTREE home would give it units its project home never had,
                   and every one of those blocks teardown (issue #50).
  --onboard-gateway  With --onboard, also start the gateway. Off by default
                   because the gateway is a contended singleton
                   (skill-manager#132) and a bootstrap is not the place to
                   contend for it.
  --allow-empty    Accept a home with zero skills. Downgrades the refusal to a
                   warning; the home is still reported as EMPTY, never as
                   verified.
  --no-project     Do not run the `sync --skip-mcp` that projects this home's
                   skills into its agent homes. The home will hold skills that
                   no agent launched here can read; combine with
                   --allow-unprojected or the run refuses.
  --allow-unprojected  Accept a home whose skills are not reachable from its
                   agent homes. Downgrades the refusal to a warning; the home is
                   never reported as verified.

Exit codes: 0 ok - 1 usage/setup error - 5 the home has no skills
            6 the home's skills are not projected into its agent homes
            7 this checkout's .gitignore does not cover what the home
              machinery left at the root, so the tree is not clean
EOF
}

# A home with zero skills is a distinct outcome from a broken one, and callers
# (new-change.sh, `wt`) route it to a different remedy, so it gets its own code.
EMPTY_EXIT=5
# And a home that HOLDS skills no agent can read is a third outcome, with a
# third remedy. It used to be reported as `verified`.
UNPROJECTED_EXIT=6
# A fourth: the home is fine, the REPOSITORY is not — its `.gitignore` does not
# cover what a home leaves at the root, so `git status` reports it and the next
# documented command (`wt new`) refuses the checkout. The remedy is an edit to a
# tracked file plus a commit, which is the operator's to make and not this
# script's; see the block below for why it refuses rather than repairs.
UNIGNORED_EXIT=7

ROOT=""; SOURCE=""; POLICY="live"; PRINT_ENV=0; FORCE=0; QUIET=0
ONBOARD=0; ONBOARD_GATEWAY=0; ALLOW_EMPTY=0; NO_PROJECT=0; ALLOW_UNPROJECTED=0
# Set when `--onboard`'s install step exits non-zero. It is a fact about what
# this home HOLDS, so it survives to the closing banner rather than being turned
# into an exit code on the spot — the gates below own the codes.
ONBOARD_SHORTFALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --source)    SOURCE="${2:?--source needs a directory}"; shift 2 ;;
    --policy)    POLICY="${2:?--policy needs live|frozen}"; shift 2 ;;
    --print-env) PRINT_ENV=1; shift ;;
    --force)     FORCE=1; shift ;;
    --quiet)     QUIET=1; shift ;;
    --onboard)   ONBOARD=1; shift ;;
    --onboard-gateway) ONBOARD=1; ONBOARD_GATEWAY=1; shift ;;
    --allow-empty) ALLOW_EMPTY=1; shift ;;
    --no-project)  NO_PROJECT=1; shift ;;
    --allow-unprojected) ALLOW_UNPROJECTED=1; shift ;;
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

# ------------------------------------------- what this run leaves in the tree
#
# git-integration-skill: onboarding created `<root>/.claude.json` — a file no
# documented ignore rule covers, because the documented rules are `/.claude/`,
# `/.codex/`, `/.gemini/`, `/.skill-manager/` and `/.claude/` does not match
# `/.claude.json`. The next command an operator runs is `wt new`, which asserts
# a clean tree, and it refused: `working tree is not clean`. Onboarding a repo
# made the repo unusable by the next step of onboarding it.
#
# WHAT is wrong is measured, never enumerated: LIST THE UNTRACKED TOP-LEVEL
# ENTRIES BEFORE ANY WORK, LIST THEM AGAIN AFTER, AND REPORT THE DIFFERENCE.
# Whatever this run created is by construction this run's to account for,
# whatever it is called. A hardcoded list of the four documented rules is the
# failure this exists to catch; a fifth entry would be the same enumeration one
# entry longer, and it fails again the moment the product moves or renames the
# file — which it is doing, since the `.claude.json` location is skill-manager's
# own defect and is being fixed there.
#
# THE TRACKED `.gitignore` IS THE MECHANISM, and this block's job is to make
# that true rather than merely documented. It writes no ignore rule anywhere. It
# measures, and it REFUSES (exit 7) when the repository's own `.gitignore` does
# not cover what the home machinery left, naming the exact lines to add.
#
# The two ways a script could repair this itself, and why neither is taken:
#
#   * APPEND TO `.gitignore`. It is TRACKED, so appending makes the tree dirty a
#     different way — one modified file instead of one untracked one — and
#     `wt new` refuses either way. To be the mechanism it would have to be
#     COMMITTED, and a commit is a far larger authority than "create a
#     directory": it lands on whatever branch happens to be checked out (`main`
#     during onboarding, a ticket branch under new-change.sh), it has no quiet
#     undo, and a path-limited commit of `.gitignore` would sweep up whatever
#     else the operator had in that file.
#   * APPEND TO `$GIT_COMMON_DIR/info/exclude`. Per-clone, in no diff, leaves
#     the tree clean — and that is precisely the problem. It makes THIS clone
#     clean while the repository keeps shipping rules that do not cover a home,
#     so every other clone, every CI checkout and every teammate still hits it;
#     it puts an ignore rule where no review ever sees it; and it makes a green
#     "the tree is clean" check read as "the documented rules are correct" when
#     they are not. `git check-ignore -v` is the only thing that tells the two
#     apart, because BOTH leave the tree clean.
#
# So the repair is a small edit the operator commits once, for everybody, and
# this refuses until they have.

# Top-level untracked entries, one per line, directories with a trailing slash.
# Deliberately depth-1: the unit of ignoring here is "a thing the home
# machinery put at the root", never a file inside the operator's own new
# directory.
untracked_root_entries() {
  git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null \
    | while IFS= read -r line; do
        case "$line" in
          '?? "'*) continue ;;   # a path git had to quote; leave it alone
          '?? '*) : ;;
          *) continue ;;
        esac
        local path="${line#?? }"
        case "$path" in
          */*) printf '%s/\n' "${path%%/*}" ;;
          *)   printf '%s\n' "$path" ;;
        esac
      done | sort -u
}

IGNORE=1
UNTRACKED_BEFORE=""
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || IGNORE=0
[ "$IGNORE" = 0 ] || UNTRACKED_BEFORE="$(untracked_root_entries)"

# The names the home machinery owns at the root, as PREFIXES, read from the
# descriptor rather than listed here. `<agent dir basename>*` is the predicate,
# and it is the one that generalises: `.claude` and `.claude.json` are the same
# agent's state under different suffixes, which is exactly the distinction the
# documented four-rule `.gitignore` could not make. It also survives the file
# moving or being renamed, which skill-manager is in the middle of doing.
#
# Nothing outside those prefixes is ever matched by this rule, so the widest it
# can reach is `.claude*`, `.codex*`, `.gemini*`, `.skill-manager*` — names that
# belong to a per-checkout home by construction.
home_owned_root_prefixes() {
  printf '%s\n' "$(basename "$STORE")"
  descriptor_env_dirs | while IFS= read -r dir; do
    [ -n "$dir" ] && basename "$dir"
  done
}

# Does the home machinery own this root name? Exact match on a declared
# basename, or that basename plus a dotted suffix — `.claude` and `.claude.json`
# are the same agent's state, which is exactly the distinction a `/`-anchored
# directory rule cannot make, and exactly the one the four documented rules got
# wrong. The prefixes are passed in rather than re-read, because reading them
# costs a CLI call.
home_owns_name() {
  local name="${1%/}" owned="$2" prefix
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    case "$name" in "$prefix"|"$prefix".*) return 0 ;; esac
  done <<EOF
$owned
EOF
  return 1
}

# WHICH FILE ignores a path — the first field of `git check-ignore -v`, i.e.
# `.gitignore`, `.git/info/exclude`, or the operator's global excludes file.
# Empty when nothing ignores it.
#
# This function is the whole reason the check below can tell the two candidate
# mechanisms apart. "The tree is clean" is true under a `.gitignore` rule and
# under an `info/exclude` rule alike, so cleanliness alone proves nothing about
# which one is doing the work — and the point of this change is that it must be
# the tracked, reviewed, shared one.
ignore_source() {
  local out
  out="$(git -C "$ROOT" check-ignore -v --no-index -- "$1" 2>/dev/null | command head -1 || true)"
  [ -n "$out" ] || return 0
  # `<source>:<line>:<pattern>\t<path>`; the source is everything before the
  # first colon, and every source git can name here is a path without one.
  printf '%s\n' "${out%%:*}"
}

# Refuse unless the repository's own `.gitignore` covers what a home leaves at
# this root. Writes nothing; the whole contract is that the tracked file is the
# mechanism.
#
# Two populations, measured separately, because they answer different questions:
#
#   (1) UNTRACKED AND ATTRIBUTABLE — the rules that are missing. Untracked means
#       not ignored (git never reports an ignored path as untracked), so every
#       line here is a hole in `.gitignore`. Attributable means: new since the
#       snapshot this run took, whatever it is called — or a name the home
#       machinery owns, which is what covers the ordinary RE-RUN, where an
#       earlier `install` / `sync` / `project resolve` left the file behind
#       before this script started and the "new since" set is therefore empty.
#       The documented onboarding order is bootstrap-then-install, so that
#       re-run IS the common case. Anything untracked that is neither is the
#       operator's own work and is none of this script's business.
#
#   (2) IGNORED, BUT NOT BY A `.gitignore` — the rules that are in the wrong
#       place. This clone is clean and the repository is still broken for every
#       other clone of it. Reported, not refused: the checkout in hand does
#       work, so stopping the operator would be the wrong trade.
assert_run_artifacts_ignored() {
  [ "$IGNORE" = 1 ] || return 0
  local after owned entry name src prefix cand rules
  local uncovered="" mislocated=""
  after="$(untracked_root_entries)"
  owned="$(home_owned_root_prefixes)"

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if printf '%s\n' "$UNTRACKED_BEFORE" | command grep -qxF "$entry"; then
      home_owns_name "$entry" "$owned" || continue
    fi
    uncovered="$uncovered$entry
"
  done <<EOF
$after
EOF

  # Measured from the filesystem, not from a list: every root entry that exists
  # and whose name the home machinery owns. An entry that reaches here is
  # ignored by something (an unignored one is in `uncovered` above instead), so
  # the only open question is which file said so.
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    for cand in "$ROOT/$prefix" "$ROOT/$prefix".*; do
      [ -e "$cand" ] || continue
      name="$(basename "$cand")"
      src="$(ignore_source "$name")"
      [ -n "$src" ] || continue
      case "$src" in .gitignore|*/.gitignore) continue ;; esac
      mislocated="$mislocated$name -> $src
"
    done
  done <<EOF
$owned
EOF

  if [ -n "$mislocated" ]; then
    printf '  NOTE: ignored, but not by a .gitignore — this clone is clean and the\n' >&2
    printf '        repository still is not, so every other clone of it is dirty:\n' >&2
    printf '%s' "$mislocated" | while IFS= read -r name; do
      printf '          %s\n' "$name" >&2
    done
    printf '        Move the rule into the tracked .gitignore (references/skill-homes.md).\n' >&2
  fi

  if [ -n "$uncovered" ]; then
    rules="$(printf '%s' "$uncovered" | while IFS= read -r entry; do
      [ -n "$entry" ] && printf '/%s\n' "$entry"
    done)"
    {
      printf '\n%s is not clean after the bootstrap, and its .gitignore is why.\n\n' "$ROOT"
      printf 'git still reports these top-level entries as untracked, and they belong to\n'
      printf 'the home machinery, not to you:\n\n'
      printf '%s' "$uncovered" | command sed 's/^/    /'
      printf '\n`wt new` asserts a clean tree, so it will refuse this checkout until they\n'
      printf 'are ignored. Add these lines to %s/.gitignore\n' "$ROOT"
      printf 'and COMMIT it — an uncommitted .gitignore is a dirty tree in its own right,\n'
      printf 'so the commit is part of the fix and not a follow-up:\n\n'
      printf '%s\n' "$rules" | command sed 's/^/    /'
      printf '\nThen prove the rule and re-run this script:\n\n'
      printf '%s' "$uncovered" | while IFS= read -r entry; do
        [ -n "$entry" ] && printf '    git -C %s check-ignore -v %s\n' "$ROOT" "${entry%/}"
      done
      printf '\nEach must name .gitignore as the source. Nothing writes these for you: an\n'
      printf 'ignore rule hides files from everyone who ever clones this repo, and\n'
      printf '.git/info/exclude would hide the rule itself from review while leaving the\n'
      printf 'repository just as broken for every other checkout.\n\n'
    } >&2
    die_fix "$UNIGNORED_EXIT" "\$EDITOR $ROOT/.gitignore   # then: git -C $ROOT commit .gitignore" \
      "$ROOT/.gitignore does not cover what the home machinery leaves at the root"
  fi

  # Say it either way. "The tree is clean" is the property the next command
  # (`wt new`) depends on, and reporting it only when something was wrong makes
  # the silent case indistinguishable from the case where the check never ran.
  local still; still="$(git -C "$ROOT" status --porcelain 2>/dev/null | command head -5)"
  if [ -n "$still" ]; then
    printf '  WARNING: %s is not clean after the bootstrap, so `wt new` will refuse it.\n' "$ROOT" >&2
    printf '    None of this is the home machinery'"'"'s — it is your own work:\n' >&2
    printf '    %s\n' "$still" >&2
    printf '    Commit or revert it before `wt new`.\n' >&2
  else
    say "tree:      clean — .gitignore covers everything the home machinery left here"
  fi
}

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
#
# The refusal names a command. This is the ONE path a genuinely fresh machine
# takes — no `~/.skill-manager` at all — and it used to end at "source home does
# not exist", full stop: correct, wrote nothing, and left the operator with
# nothing to run. The exit-5 path two hundred lines down prints three
# alternatives; this one printed none.
#
# Which command depends on why the source is missing, so it is branched rather
# than generalised. An explicit --source that does not exist is a typo and
# `onboard` is the wrong answer to it; a missing GLOBAL home on a fresh machine
# is the ordinary case and `onboard` is exactly the answer.
#
# `onboard` is spelled WITHOUT the agent-home env here, and that is deliberate
# rather than an oversight of the #145 rule: the home being created is the
# global one, whose agent directories ARE ~/.claude, ~/.codex and ~/.gemini. The
# rule is "pin the agent-home env to the home you are writing", and for the
# global home the default environment already is that pin.
#
# `${SKILL_MANAGER_CLI:-skill-manager}` rather than $CLI: pick_cli has not run
# yet — it cannot, the refusal has to come before any work — so the remedy names
# the pin if there is one and the PATH spelling if there is not, which is the
# same order pick_cli itself uses.
if [ ! -d "$SOURCE" ]; then
  SM_SPELLING="${SKILL_MANAGER_CLI:-skill-manager}"
  case "$SOURCE_ORIGIN" in
    --source)
      die "source home does not exist: $SOURCE (named with --source)
  Nothing was read or written. Name a home that exists, or drop --source to use
  ${SKILL_MANAGER_HOME:+\$SKILL_MANAGER_HOME}${SKILL_MANAGER_HOME:-the global home $GLOBAL_HOME}:
    $SCRIPT_DIR/bootstrap-home.sh --root '$ROOT' --source '<an existing home>'
    $SCRIPT_DIR/bootstrap-home.sh --root '$ROOT'" ;;
    *)
      die "source home does not exist: $SOURCE ($SOURCE_ORIGIN)
  Nothing was read or written. A home is a COPY of the home above it, and on a
  fresh machine the home above a project is the global one — which does not
  exist yet. \`onboard\` is the step that creates and fills it, and cloning a
  home never runs it. Two commands, in this order:
    $SM_SPELLING onboard --skip-gateway
    $SCRIPT_DIR/bootstrap-home.sh --root '$ROOT'
  (No agent-home env on that first line, deliberately: the home it creates is
  the global one, whose agent directories already are ~/.claude, ~/.codex and
  ~/.gemini. Every other command this script prints pins them, because every
  other command writes a home that is not the global one.)
  Or copy a home that already exists somewhere else:
    $SCRIPT_DIR/bootstrap-home.sh --root '$ROOT' --source '<an existing home>'" ;;
  esac
fi
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

# The agent-home env as `NAME=VALUE` words, ready to hand to `env`. Any command
# that writes agent bindings — `sync` above all — must run with these set, or it
# writes the OPERATOR'S ~/.claude.json, ~/.codex/config.toml and
# ~/.gemini/settings.json instead of this home's. Measured: `SKILL_MANAGER_HOME=<home>
# skill-manager sync --force-scripts`, the remedy this script used to print
# verbatim, reported `ADDED claude (~/.claude.json)` — the global-binding hijack
# recorded as skill-manager#145, printed as an instruction by THIS file. Naming
# the home is not enough; the agent-home variables are a separate axis.
agent_env_words() {
  local dir
  descriptor_env_dirs | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$dir" in
      */.claude) printf 'CLAUDE_CONFIG_DIR=%s\n' "$dir" ;;
      */.codex)  printf 'CODEX_HOME=%s\n' "$dir" ;;
      */.gemini) printf 'GEMINI_HOME=%s\n' "$dir" ;;
    esac
  done
}

# A shell-quoted `env ...` prefix that pins BOTH axes. This is the only spelling
# of a home-mutating command this script is allowed to print.
home_env_prefix() {
  local out="env SKILL_MANAGER_HOME=$STORE" word
  while IFS= read -r word; do [ -n "$word" ] && out="$out ${word%%=*}=${word#*=}"; done <<EOF
$(agent_env_words)
EOF
  printf '%s\n' "$out"
}

# How many skills this home can actually serve. Directories only, and only ones
# carrying a SKILL.md, so a stray file or an empty leftover directory cannot
# make an empty home look populated — which is the whole point of the count.
home_skill_count() { skill_count "$STORE"; }
skill_count() {
  local d n=0
  for d in "$1"/skills/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/SKILL.md" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Symlinks inside the home that do not resolve. `home clone` skips venvs/,
# tools/, npm/ and cache/ by design, so any link INTO one of them arrives
# dangling — and `skill-manager home verify` refuses the home for exactly this,
# which is how bootstrap came to report `verified` on a home `home verify`
# rejects. Found here with `find` rather than with a second CLI start: it is the
# same fact, it costs no JVM, and it is still answerable on the --force path
# where no clone report exists.
dangling_home_links() {
  command find "$STORE/bin" -type l 2>/dev/null | while IFS= read -r link; do
    [ -e "$link" ] || printf '%s -> %s\n' "${link#"$STORE"/}" "$(readlink "$link")"
  done
}

# ------------------------------------------------------------- the CLI pin
#
# <home>/bin/cli/skill-manager decides which build every launch from this home
# runs: the generated launchers read it, and HomeDescriptor.resolveCli
# documents it as rule 3. Since issue #61 the launchers have NO PATH fallback
# at all, so a wrong or missing pin is not a downgrade, it is a home that
# cannot launch.
#
# THIS SCRIPT NO LONGER WRITES THAT FILE.
#
# It used to, and it was right to: `skill-manager home shims` wrote a
# PATH-RESOLVING shim, and PATH's skill-manager on this machine is the released
# 0.19.2 — which has no `exec` subcommand, so every generated launcher ended in
# `Unmatched arguments: 'exec'`. Homes bootstrapped through this script worked
# and homes provisioned by `home shims` alone did not, and because this script
# masked the difference for the whole 24-repo onboarding fan-out, nobody saw
# it.
#
# skill-manager fixed it (issue #61, commit e65962e): `home shims` now writes
# the absolute pin itself, derived from the build that is running it
# (RunningCli), with no PATH fallback. At that moment two writers of one file
# stopped being a redundancy and became a race with exactly one correct answer
# — and this script's predicate lost it. It decided whether to overwrite by
# grepping the slot for the literal words `home shims`, which the FIXED
# generated file also contains. Measured: 17 of 25 homes had a correct pin
# replaced with a pin to whatever `pick_cli` had chosen, and an 18th — written
# before this script marked its own output — was not repaired at all. A
# predicate that keys on prose cannot distinguish versions of the prose.
#
# So `ensure_cli_pin` VERIFIES, and delegates every repair to the one writer:
#
#   marker present   -> check the pinned target is executable, and STOP.
#   absent, or ours,
#   or a pre-#61
#   PATH shim        -> re-run `home shims`. Never write the body here.
#   anything else    -> someone else's tool. Leave it alone.

# The token LauncherShims.PIN_MARKER puts on line 2 of the generated
# entrypoint, existing precisely so a predicate has something stable to key on.
# Checked against the generated BYTES, not against the javadoc that names it:
# a predicate that matches nothing fails silently, and that is this function's
# entire failure history.
GENERATED_PIN_MARKER='skill-manager:cli-pin'

# The generated pin's assignment line is, verbatim,
#   cli="${SKILL_MANAGER_CLI:-<absolute path>}"
# Matched as a FIXED string and stripped with parameter expansion rather than
# parsed with a regex: `${`, `:-`, `}` and `$` are each metacharacters in some
# dialect of some grep or sed, and a pattern that quietly matches nothing here
# means the pin is never checked at all.
GENERATED_PIN_PREFIX='cli="${SKILL_MANAGER_CLI:-'

# What `home shims` generated BEFORE #61: a shim that searched PATH with its
# own directory filtered out. It carries no marker of its own — the marker
# above was added by the fix — so the search itself is the only thing that
# identifies it, and it is the shape most likely still sitting in an
# already-bootstrapped home on this machine.
PATH_SHIM_MARKER='command -v skill-manager'

# What THIS script wrote while it was still a writer, and (LEGACY) what an even
# older version wrote before it marked its own output. Both are stale by
# construction now: they pin whatever `pick_cli` chose at the time rather than
# the build `home shims` ran as, and neither is re-derived when the build
# moves.
#
# LEGACY_PIN_MARKER is kept deliberately. Without it `ensure_cli_pin` cannot
# recognise its own past output and takes the "someone else's tool" branch — so
# the homes most likely to carry a stale pin become the only ones it refuses to
# repair. That gap was measured once already (16 homes repaired by re-running
# this script, the 17th and oldest silently not), and dropping the marker while
# rewriting the function would re-open it for exactly those homes.
PIN_MARKER='git-integration-repo:cli-pin'
LEGACY_PIN_MARKER="Written by git-integration-repo's bootstrap-home.sh"

# `home shims` writes the launchers AND the pin, and it REFUSES rather than
# guessing: RunningCli probes SKILL_MANAGER_CLI, the running process's own
# command, SKILL_MANAGER_INSTALL_DIR and the jar's own location, and when none
# of them answers it exits 127 having written NOTHING. That is the right
# behaviour — the PATH fallback is what #61 removed — but it means a caller
# that swallows the output reports a bare 127 for the one failure the CLI took
# care to explain.
#
# Every candidate `pick_cli` can return is a launcher that exports
# SKILL_MANAGER_INSTALL_DIR before it execs the JVM, because that is how each
# distribution finds its bundled gateway sources: a source checkout is
# `<repo>/skill-manager` and a release/Homebrew install is
# `<prefix>/bin/skill-manager`, and RunningCli probes both layouts. Verified on
# this machine — `pick_cli` resolves the integration parent's
# constituents/skill-manager/skill-manager, which exports the variable, and
# `home shims` pins it. What the probe cannot survive is a $CLI that is not a
# launcher at all (a bare `jbang SkillManager.java`, a wrapper that drops the
# variable). That is a configuration mistake rather than a defect, so it gets a
# diagnostic naming the fix instead of a 127 with no context.
write_shims() {
  local out status=0
  out="$("$CLI" home shims --home "$STORE" 2>&1)" || status=$?
  [ "$status" = 0 ] && return 0
  die "\`home shims\` failed (exit $status), so $STORE has no launcher shims and
  no CLI pin — it writes nothing when it cannot identify the running build.
  The command was:
    $CLI home shims --home '$STORE'
  and it said:

$out

  If that is about identifying which build is running, \$CLI has to be a
  skill-manager LAUNCHER — one that exports SKILL_MANAGER_INSTALL_DIR before it
  execs the JVM — not the jbang entrypoint underneath one. Set
  SKILL_MANAGER_CLI to such a launcher and re-run."
}

ensure_cli_pin() {
  local slot="$STORE/bin/cli/skill-manager"

  # 1. Written by `home shims`. Not ours: verify, never rewrite.
  if command grep -q -F -- "$GENERATED_PIN_MARKER" "$slot" 2>/dev/null; then
    local line pinned
    line="$(command grep -m1 -F -- "$GENERATED_PIN_PREFIX" "$slot" 2>/dev/null || true)"
    [ -n "$line" ] && pinned="${line#*"$GENERATED_PIN_PREFIX"}" || pinned=""
    pinned="${pinned%\"}"; pinned="${pinned%\}}"
    [ -n "$pinned" ] || die "$slot carries the '$GENERATED_PIN_MARKER' marker but no
  readable '$GENERATED_PIN_PREFIX…' line, so the pinned CLI cannot be checked.
  Either the file is truncated or \`home shims\` changed the shape this script
  reads. Re-provision it with
    $CLI home shims --home '$STORE'
  and if the shape has genuinely changed, fix GENERATED_PIN_PREFIX here rather
  than letting the check pass on nothing."
    [ -x "$pinned" ] || die "the CLI pinned for $STORE is missing or not executable:
    $pinned
  Every launch from this home exits 127 until it is re-pinned; there is
  deliberately no PATH fallback. Re-pin it from the build this home should use:
    <that build>/skill-manager home shims --home '$STORE'
  This script will not repair it by writing the file itself — substituting a
  CLI of its own choosing is what overwrote 17 correct pins."
    say "cli pin:   $slot -> $pinned (pinned by \`home shims\`; left as written)"
    return 0
  fi

  # 2. Shapes this script is entitled to replace — and replaces by asking the
  #    one writer, not by writing.
  local why=""
  if [ ! -e "$slot" ]; then
    why="absent"
  elif command grep -q -F -- "$PIN_MARKER" "$slot" 2>/dev/null; then
    why="this script's own pin, from when it was a writer"
  elif command grep -q -F -- "$LEGACY_PIN_MARKER" "$slot" 2>/dev/null; then
    why="this script's own pin, from before it marked its output"
  elif command grep -q -F -- "$PATH_SHIM_MARKER" "$slot" 2>/dev/null; then
    why="a pre-#61 PATH-resolving shim from \`home shims\`"
  else
    say "cli pin:   $slot (not written by this script or by \`home shims\` — left alone)"
    return 0
  fi
  say "cli pin:   $slot ($why) -> re-running \`home shims\`"
  write_shims
  # `home shims` reporting success is not the same as the slot being correct,
  # and this whole function exists because nobody checked the difference.
  command grep -q -F -- "$GENERATED_PIN_MARKER" "$slot" 2>/dev/null \
    || die "\`home shims\` exited 0 but $slot still carries no
  '$GENERATED_PIN_MARKER' marker, so the repair did not happen. Inspect the
  file; do not re-run and hope."
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
  #
  # `>&2` because `home clone`'s report is diagnostics, and THIS SCRIPT'S STDOUT
  # IS RESERVED. It carries the FAILED/FIX contract, and `--print-env` output
  # meant to be `eval`ed; a caller that captures it must get those bytes and
  # nothing else. Without the redirect the clone's ten-line report was prepended
  # to the contract `wt new` prints — measured, and exactly the "25 lines of
  # prose" this work exists to remove. Every other CLI call here is already
  # captured or sent to /dev/null; this was the one that was not.
  if [ "$need_clone" = 1 ]; then
    "$CLI" home clone --from "$SOURCE" --to "$STORE" >&2 \
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

  # 5. Launcher shims AND the CLI pin — one command writes both, and since #61
  #    the pin it writes is the absolute path of the build running right here.
  #    Through write_shims so its refusal is reported rather than reduced to an
  #    exit code.
  write_shims

  # 5b. Assert what step 5 just claimed. ensure_cli_pin no longer writes
  #     anything on this path; it reads the marker `home shims` left and checks
  #     the pinned build is still there. It runs for existing homes too, below.
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

# Check — and where it is this script's business, repair — an ALREADY-bootstrapped
# home too. Homes provisioned before #61 carry the PATH-resolving shim and
# quietly run whatever CLI is installed globally; homes provisioned by an older
# version of this script carry a pin it chose. Re-running bootstrap-home.sh
# should fix both without --force, because the operator has no way to know the
# slot is wrong. A frozen home is evidence and is never written, here as
# everywhere else.
if [ "$bootstrapped" = 1 ] && [ "$frozen_skip" = 0 ]; then
  ensure_cli_pin
fi

# Before the emptiness gate, not after it: exit 5 is a refusal about what the
# home HOLDS, and the home directories already exist by then, so this is the
# first point at which what the run leaves in the tree can be measured at all.
# Both are refusals now, and the order decides which the operator is told about
# first — the tree one goes first because its remedy is one commit and it is the
# precondition of the next documented command, while exit 5's remedy is an
# install that will itself write more into the root.
assert_run_artifacts_ignored

# ------------------------------------------------------- the home has to HOLD something
#
# git-integration-skill#10. A home cloned from an unpopulated source is a
# perfectly well-formed home with nothing in it: the descriptor is right, the
# policy is right, the shims resolve, `exec --print-env` is happy — and an agent
# launched against it has ZERO skills. Every check this script had was about the
# home's WIRING, so all of them passed, the banner said `verified`, and the last
# thing the operator read was "Launch an agent bound to this home". The one
# command that would have fixed it, `skill-manager onboard`, was named nowhere.
#
# Two decisions, made deliberately rather than by default:
#
# 1. REFUSE AND NAME, do not run. `onboard` clones bundled skills from github and
#    touches the gateway; a bootstrap that silently did that would make the
#    cheapest, most-repeated command in this repo the most expensive and the most
#    contended (skill-manager#132). --onboard opts in.
#
# 2. Only when skills/ came up EMPTY. A home with skills is not this script's
#    business — deciding it needs MORE of them is the operator's call, and
#    running `onboard` on every bootstrap would re-install into every worktree.
#
# And onboarding a WORKTREE home is refused outright even with --onboard. The
# worktree home is a COPY of the project home and close-change.sh reconciles it
# back into that same home (#50); installing three units here that the project
# home never had makes each of them a teardown blocker before any work exists.
# The empty home is the PROJECT's problem, so the remedy names the project.
SKILLS_N="$(home_skill_count)"

if [ "$SKILLS_N" = 0 ] && [ "$ONBOARD" = 1 ] && [ "$frozen_skip" = 0 ]; then
  if [ "$IS_WORKTREE" = 1 ]; then
    say "onboard:   refused for a worktree home — see the refusal below"
  else
    require_local_home "onboard"
    heading "Installing the bundled skills (--onboard)"
    ONBOARD_ARGS=""
    [ "$ONBOARD_GATEWAY" = 1 ] || ONBOARD_ARGS="--skip-gateway"
    # Through the agent-home env, not a bare SKILL_MANAGER_HOME: `onboard` ends
    # in the same projection/binding write `sync` does, and with the agent-home
    # variables unset that write lands in the operator's ~/.claude.json.
    # shellcheck disable=SC2046
    ONBOARD_RC=0
    env $(agent_env_words) SKILL_MANAGER_HOME="$STORE" "$CLI" onboard $ONBOARD_ARGS >&2 \
      || ONBOARD_RC=$?
    SKILLS_N="$(home_skill_count)"
    # A non-zero `onboard` used to `die` with "the home is wired but empty;
    # nothing was installed" and exit 1. Measured: it had installed 3 units. The
    # message was a guess about what the failure meant, the count was never
    # looked at, and exit 1 is this script's code for a USAGE OR SETUP error —
    # so the caller was told the wrong thing three ways at once, and the gates
    # below, which own the accurate codes and the accurate remedies, never ran.
    #
    # So: say what actually landed, and let the gates decide. A home that is
    # still empty falls to the emptiness gate (exit 5, with the remedy for an
    # empty home); a home holding units an agent cannot reach falls to the
    # projection gate (exit 6, with the remedy for that). Both are more
    # accurate than a blanket 1, and neither is guessed here.
    if [ "$ONBOARD_RC" != 0 ]; then
      printf '  WARNING: `onboard` exited %s. It installed %s skill(s) — fewer than it\n' \
        "$ONBOARD_RC" "$SKILLS_N" >&2
      printf '    intended, so treat this home as INCOMPLETE however this run ends. Re-run\n' >&2
      printf '    it by hand to see why:\n      %s %s onboard %s\n' \
        "$(home_env_prefix)" "$CLI" "$ONBOARD_ARGS" >&2
      # Recorded so the closing banner cannot report an unqualified success for a
      # home whose own install step failed.
      ONBOARD_SHORTFALL=1
    fi
  fi
fi

if [ "$SKILLS_N" = 0 ] && [ "$frozen_skip" = 0 ]; then
  if [ "$ALLOW_EMPTY" = 1 ]; then
    say "skills:    0 (--allow-empty) — an agent launched against this home has NO skills"
  elif [ "$IS_WORKTREE" = 1 ]; then
    printf 'error: this home has no skills, so an agent launched against it has none.\n' >&2
    printf '  home:    %s\n' "$STORE" >&2
    printf '  source:  %s  (its project home — a worktree home is a copy of it)\n' "$SOURCE" >&2
    # Which of the two it is decides the remedy, so it is measured rather than
    # assumed: an empty SOURCE is the ordinary #10 case and the fix is at the
    # project, while a populated source that produced an empty copy is a clone
    # defect and pointing the operator at `onboard` would send them to install
    # units the project already has.
    if [ "$(skill_count "$SOURCE")" != 0 ]; then
      cat >&2 <<EOF
The source home has $(skill_count "$SOURCE") skill(s) and this copy has none, so the CLONE dropped
them — installing here would not be a repair, it would hide one. Compare the two
and re-clone:
  ls '$SOURCE/skills' '$STORE/skills'
  rm -rf '$STORE' && $SCRIPT_DIR/bootstrap-home.sh --root '$ROOT'
EOF
      exit "$EMPTY_EXIT"
    fi
    cat >&2 <<EOF
Install into the PROJECT home, not this one: units installed here are units the
project home never had, and close-change.sh blocks on every one of them at
teardown (issue #50). Two commands, in this order:
  $SCRIPT_DIR/bootstrap-home.sh --root '$(dirname "$PROJECT_HOME")' --onboard
  $SCRIPT_DIR/bootstrap-home.sh --root '$ROOT' --force
Or accept an empty home deliberately with --allow-empty.
EOF
    exit "$EMPTY_EXIT"
  else
    printf 'error: this home has no skills, so an agent launched against it has none.\n' >&2
    printf '  home:    %s\n' "$STORE" >&2
    printf '  source:  %s  (%s — it is empty too)\n' "$SOURCE" "$SOURCE_ORIGIN" >&2
    cat >&2 <<EOF
The step that installs the bundled skills is \`onboard\`, and cloning a home
never runs it. Run it here:
  $(home_env_prefix) $CLI onboard --skip-gateway
or let this script do it:
  $SCRIPT_DIR/bootstrap-home.sh --root '$ROOT' --force --onboard
Or accept an empty home deliberately with --allow-empty.
EOF
    exit "$EMPTY_EXIT"
  fi
fi

# ------------------------------------------- the skills have to REACH an agent
#
# git-integration-skill: `home clone` copies the STORE. The agent homes —
# `<root>/.claude`, `<root>/.codex`, `<root>/.gemini` — live BESIDE the store, so
# they are not in the copy, and this script created them empty. Measured on a
# `wt new` worktree: rc 0, the full contract, `verified: 20 skill(s) servable`,
# and `ls -a <wt>/.claude` answering `.` `..` — no `skills/` directory at all.
# Every agent launched in that worktree saw zero skills.
#
# `skill-manager exec` documents `--no-reconcile` as "skip refreshing the home's
# agent symlinks", and the reconcile DOES run: it prints one line per missing
# projection, naming the exact destination and the command that would create it,
# and creates nothing. So the fact was available on stdout of every launch and
# nothing acted on it.
#
# `sync --skip-mcp` is that command. It is the product's own remedy, printed by
# the product, and running it here is one call rather than a second
# implementation of where a projection goes — which matters, because the
# destination is `<agent dir>/skills/<unit>` with a `default:<agent>:<unit>`
# ledger record beside it, and a hand-rolled symlink would be the link without
# the record.
#
# What it costs, measured: ~3s on a 1-unit home, ~8s on a 5-unit one, and NOTHING
# on a re-run, because the step is skipped when the projection is already
# complete. Only the first bootstrap of a home pays.
#
# What it must not do is INSTALL. On a worktree home, a unit the project home
# never had is a close-out blocker before any work exists (#50), and `sync`
# resolves declared dependencies. That cannot happen when the source home is
# complete — the copy already holds everything — so it is asserted rather than
# assumed: the unit set is compared across the call and any addition is named.

# `<agent dir>/skills` for every agent this home declares, read from the
# descriptor. Same source as the directories themselves, so this cannot check a
# place the launcher will not look.
projection_dirs() {
  descriptor_env_dirs | while IFS= read -r dir; do
    [ -n "$dir" ] && printf '%s/skills\n' "$dir"
  done
}

# Store skills that are NOT reachable from some agent's own view, one
# `<agent dir>|<unit>` per line.
#
# `-e`, not `-L`: a dangling symlink is an entry in the directory and would
# satisfy a check that counted names. And then the resolved path is required to
# be inside $ROOT — a link that resolves into another checkout's store is a link
# to another home's copy of the unit, which is the whole failure class this
# per-checkout mechanism exists to close.
unprojected_pairs() {
  local dir unit dest real
  for unit in "$STORE"/skills/*/; do
    [ -d "$unit" ] || continue
    [ -f "$unit/SKILL.md" ] || continue
    unit="$(basename "$unit")"
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      dest="$dir/$unit"
      if [ ! -e "$dest" ]; then printf '%s|%s\n' "$dir" "$unit"; continue; fi
      real="$(cd "$dest" 2>/dev/null && pwd -P)" || real=""
      case "$real" in
        "$ROOT"/*) : ;;
        *) printf '%s|%s\n' "$dir" "$unit" ;;
      esac
    done <<EOF
$(projection_dirs)
EOF
  done
}

projected_unit_count() {
  local unit dir ok n=0
  for unit in "$STORE"/skills/*/; do
    [ -d "$unit" ] || continue
    [ -f "$unit/SKILL.md" ] || continue
    unit="$(basename "$unit")"
    ok=1
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      case "$(cd "$dir/$unit" 2>/dev/null && pwd -P)" in
        "$ROOT"/*) : ;;
        *) ok=0 ;;
      esac
    done <<EOF
$(projection_dirs)
EOF
    [ "$ok" = 1 ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

store_unit_list() { command ls -1 "$STORE/skills" 2>/dev/null | LC_ALL=C sort; }

# The projections this home's OWN LEDGER already declares, as
# `<destPath>\t<sourcePath>`, restricted to SYMLINK records whose destination is
# inside $ROOT.
#
# This is the cheap half, and it is the one that matters for a worktree. A
# `home clone` copies `installed/<unit>.projections.json` AND RE-ANCHORS IT: the
# records in a fresh worktree home already read
#   default:claude:debugging  DEFAULT_AGENT
#     SYMLINK $SKILL_MANAGER_HOME/skills/debugging
#          -> <wt>/.claude/skills/debugging
# — the right destination, under the right root, with the right binding id. The
# ledger is correct and the FILESYSTEM SIDE IS MISSING, which is exactly what
# `exec`'s reconcile reports and does not fix.
#
# So this materializes records that exist. It is not a second opinion about
# where a projection goes: every path here is read out of the home, none is
# constructed. `$SKILL_MANAGER_HOME` is the store's own placeholder in the
# record and is expanded to $STORE.
declared_projections() {
  # ROOT and STORE are passed as ARGUMENTS, not read from the environment: they
  # are ordinary shell variables in this script and are not exported, so an
  # `os.environ[...]` lookup raises, the interpreter dies, `2>/dev/null` eats the
  # traceback and this function quietly returns nothing — a silent no-op that
  # looks exactly like "there were no records". Measured, and it cost a run.
  command find "$STORE/installed" -maxdepth 1 -name '*.projections.json' -print0 2>/dev/null \
    | xargs -0 "$PY" -c '
import json, os, sys
root = sys.argv[1].rstrip("/")
store = sys.argv[2]
for path in sys.argv[3:]:
    try:
        doc = json.load(open(path))
    except Exception:
        continue
    for binding in doc.get("bindings") or []:
        for proj in binding.get("projections") or []:
            if proj.get("kind") != "SYMLINK":
                continue
            dest = proj.get("destPath") or ""
            src = (proj.get("sourcePath") or "").replace("$SKILL_MANAGER_HOME", store)
            if not dest or not src:
                continue
            if dest != root and not dest.startswith(root + os.sep):
                continue
            print("%s\t%s" % (dest, src))
' "$ROOT" "$STORE" 2>/dev/null
}

# Create the ones that are missing. Only ever creates: an existing directory or
# file at a destination is someone's data and is left alone, so it shows up in
# the shortfall report rather than being silently replaced. A symlink that does
# NOT resolve inside $ROOT is the one exception — that is a stale link from the
# home this one was copied from, and leaving it would leave an agent reading
# another checkout's copy of the unit.
materialize_declared_projections() {
  local dest src made=0 real
  while IFS="$(printf '\t')" read -r dest src; do
    [ -n "$dest" ] && [ -n "$src" ] || continue
    [ -e "$src" ] || continue
    if [ -L "$dest" ]; then
      real="$(cd "$dest" 2>/dev/null && pwd -P)" || real=""
      case "$real" in "$ROOT"/*) continue ;; esac
      command rm -f "$dest"
    elif [ -e "$dest" ]; then
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    ln -s "$src" "$dest" && made=$((made + 1))
  done <<EOF
$(declared_projections)
EOF
  [ "$made" = 0 ] || say "projected: $made link(s) materialized from this home's own binding ledger"
  return 0
}

project_agent_homes() {
  [ "$frozen_skip" = 0 ] || return 0
  [ "$NO_PROJECT" = 0 ] || { say "project:   skipped (--no-project)"; return 0; }
  [ -n "$(unprojected_pairs)" ] || { say "project:   already projected — nothing to do"; return 0; }
  require_local_home "project"

  # Ledger first, sync only if the ledger cannot answer. The order is not a
  # preference, it is the difference between a closable worktree and an
  # unclosable one:
  #
  #   `sync` refreshes UNIT CONTENT. Measured on a worktree whose home was a
  #   correct copy of a complete project home: `sync --skip-mcp` projected every
  #   unit AND left `skills/deploy-helm/.git/index` differing from the project
  #   home's, and `home close-out` then refused the teardown —
  #   `BLOCKED skill:deploy-helm (merged) - 1 file(s) come from the source`.
  #   That is issue #50 reintroduced by the fix for #10. With the ledger step
  #   first, the same worktree needs no sync at all, and close-out exits 0.
  #
  #   (`.git/index` is stat-dependent and is not unit work; that `close-out`
  #   counts it is a skill-manager finding, reported separately. This ordering
  #   is correct regardless of how that lands, because it also makes the common
  #   path instant and offline.)
  materialize_declared_projections
  [ -n "$(unprojected_pairs)" ] || { say "project:   done from the ledger — no sync needed"; return 0; }

  # What is left is a unit with NO binding record — a home that was scaffolded
  # rather than installed into, or a unit installed before the ledger existed.
  # Only `sync` can create the record, so only now is it worth its cost.
  heading "Projecting the remaining skills into the agent homes"
  local pass before after added
  # AT MOST TWO PASSES, and the second one only when the first INSTALLED
  # something. `sync` is not a fixpoint across an install: measured on a home
  # whose source lacked two transitive deps, one `sync --skip-mcp` installed
  # `deploy-helm` and `tracing-observability` and projected only the three units
  # that existed when it started, leaving the two it had just installed reported
  # by its own reconcile as unprojected. The second pass installs nothing and
  # projects them (10s). Bounded at two rather than looped to a fixpoint on
  # purpose: a loop over a step that can install would be a loop over a step
  # that can grow the work, and "it added units again" is a finding to print,
  # not a condition to iterate on.
  for pass in 1 2; do
    before="$(store_unit_list)"
    # `>&2` for the same reason the clone is: stdout carries the contract and
    # --print-env output, nothing else.
    #
    # The exit code is deliberately not consulted. `sync` exits non-zero for
    # persisted error records that have nothing to do with the projection —
    # measured: rc 7 from NEEDS_GIT_MIGRATION, rc 1 from a markdown import
    # violation — on runs that projected every unit correctly. The verdict comes
    # from re-measuring the links, which is what the word `verified` is about.
    # shellcheck disable=SC2046
    env $(agent_env_words) SKILL_MANAGER_HOME="$STORE" "$CLI" sync --skip-mcp >&2 || true
    after="$(store_unit_list)"
    added="$(command comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null || true)"
    # The sync creates the missing records; materialize whatever it declared but
    # did not write, for the same reason as above.
    materialize_declared_projections
    [ -n "$added" ] || break
    printf '  WARNING: the projection sync also INSTALLED unit(s) this home did not have:\n' >&2
    printf '    %s\n' $added >&2
    if [ "$IS_WORKTREE" = 1 ]; then
      printf '    This is a worktree home, and every unit its project home lacks is a\n' >&2
      printf '    close-out blocker at teardown (issue #50). The cause is a project home\n' >&2
      printf '    that is missing its own declared dependencies; resolve them THERE:\n' >&2
      printf '      %s\n' "$SCRIPT_DIR/bootstrap-home.sh --root '$(dirname "$PROJECT_HOME")' --force" >&2
    fi
    [ -n "$(unprojected_pairs)" ] || break
    [ "$pass" = 1 ] && say "project:   re-running — the units it installed are not projected yet"
  done
}

project_agent_homes
# Again, after the sync: `sync` writes <root>/.claude.json and may create other
# root-level state, and the call above the emptiness gate ran before it existed.
# Side-effect-free, so the cost of asking twice is one `git status`, and asking
# twice is the point — the second call is the only one that can see what the
# sync just made. It is measured both times, so a rule this repo does not carry
# is reported here even if it was not needed on the earlier pass.
assert_run_artifacts_ignored

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
  # Since #61 it resolves its CLI as SKILL_MANAGER_CLI, then
  # <home>/bin/cli/skill-manager, and then NOTHING. The PATH branch is gone
  # because the launcher's last line is `exec "$cli" exec --home …` and the
  # released CLI on PATH has no `exec` subcommand, so that branch could only
  # ever produce `Unmatched arguments: 'exec'`.
  #
  # This check used to accept "some capable skill-manager exists on PATH" as
  # the alternative. It is not one any more, and keeping it would pass a home
  # whose every launch exits 127 — the false green this file exists to remove.
  # The pin itself is the launch surface now, so it is asserted directly.
  local home_cli="$STORE/bin/cli/skill-manager"
  [ -x "$home_cli" ] || die "verify: $home_cli is missing or not executable, so every
  launch from this home exits 127 — the shims have no PATH fallback to reach
  for. Re-provision it with
    $CLI home shims --home '$STORE'"
  cli_has_home "$home_cli" || die "verify: $home_cli does not answer \`home clone\`,
  so the build it pins is older than the commands this home needs. Re-pin it
  from the build this home should run:
    <that build>/skill-manager home shims --home '$STORE'"

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

  # Can this home SERVE a skill? Every check above is about wiring, and wiring
  # is exactly what an empty home gets right (#10). Repeated here rather than
  # left to the gate above so that verify() is not itself the fail-open: the
  # gate can be waved through with --allow-empty, and this function is what the
  # word "verified" is printed on the strength of.
  local skills; skills="$(home_skill_count)"
  if [ "$skills" = 0 ] && [ "$ALLOW_EMPTY" != 1 ]; then
    die "verify: $STORE/skills holds no skill with a SKILL.md, so this home cannot
  serve one. Install the bundled skills:
    $(home_env_prefix) $CLI onboard --skip-gateway"
  fi

  # And can an AGENT reach it? The count above is of `$STORE/skills`, which no
  # agent reads. An agent reads `<root>/.claude/skills` and its two siblings, and
  # a home whose store is full and whose agent homes are empty passes every
  # other check in this function — descriptor right, policy right, shims right,
  # `exec --print-env` happy — while serving nothing. That is what `verified: 20
  # skill(s) servable` was printed over.
  #
  # So the word is earned here or it is not printed. `projected` is the number of
  # store skills reachable from EVERY declared agent's own view, by a link that
  # resolves inside $ROOT.
  local projected shortfall
  projected="$(projected_unit_count)"
  shortfall="$(unprojected_pairs)"
  if [ -n "$shortfall" ] && [ "$ALLOW_UNPROJECTED" != 1 ]; then
    printf 'error: this home holds %s skill(s) and an agent launched here can reach %s.\n' \
      "$skills" "$projected" >&2
    printf '  A skill is served through <root>/.<agent>/skills/<unit>, not out of the\n' >&2
    printf '  store. These are missing or resolve outside %s:\n' "$ROOT" >&2
    while IFS='|' read -r d u; do
      [ -n "$u" ] && printf '    %s/%s\n' "$d" "$u" >&2
    done <<EOF
$shortfall
EOF
    cat >&2 <<EOF
  The command that creates them is:
    $(home_env_prefix) $CLI sync --skip-mcp
  This script runs it for you; reaching this message means it ran and the links
  are still not there, so run it by hand and read what it says. Or accept an
  unservable home deliberately with --allow-unprojected.
EOF
    exit "$UNPROJECTED_EXIT"
  fi
  if [ -n "$shortfall" ]; then
    printf '  WARNING: %s of %s skill(s) are not reachable from an agent launched here\n' \
      "$((skills - projected))" "$skills" >&2
    printf '           (--allow-unprojected). This home is NOT verified.\n' >&2
  fi

  # Advisory, and the reason bootstrap used to disagree with `skill-manager home
  # verify`: that command REFUSES a home holding an unresolvable reference, and
  # a clone always produces some, because it skips venvs/, tools/, npm/ and
  # cache/ by design. Reported rather than fatal because the remedy `home verify`
  # prints is NOT a fixpoint — see the closing note — so refusing here would make
  # every honest bootstrap fail on a defect this repo cannot fix.
  local dangling; dangling="$(dangling_home_links)"
  if [ -n "$dangling" ] && [ "$QUIET" != 1 ]; then
    printf '  WARNING: link(s) in this home do not resolve, so the tools they name\n' >&2
    printf '           fail at exec time and `skill-manager home verify` REFUSES this\n' >&2
    printf '           home until they do:\n' >&2
    # One printf per line, never `printf fmt $(cmd)`: a target with a space in it
    # would be split into two bogus lines by the shell before printf ever saw it.
    while IFS= read -r entry; do
      [ -n "$entry" ] && printf '             %s\n' "$entry" >&2
    done <<EOF
$dangling
EOF
    printf '           See the closing note: `sync --force-scripts` re-provisions\n' >&2
    printf '           script shims but does not recreate <home>/venvs.\n' >&2
  fi

  [ "$QUIET" = 1 ] || {
    local agents; agents="$(projection_dirs | while IFS= read -r d; do
      [ -n "$d" ] && printf '%s ' "$(basename "$(dirname "$d")")"; done)"
    info "home:      $STORE"
    info "policy:    $policy"
    info "descriptor:$descriptor"
    info "shims:     $STORE/bin/launch (claude, codex, gemini)"
    info "skills:    $skills"
    info "projected: $projected of $skills into each of ${agents% }"
    # Printed ONLY when every store skill is reachable from every declared
    # agent. The number is the projected count, not the store count: they are
    # equal here by construction, and stating the one that was measured is the
    # difference between a report and a claim.
    # `--onboard`'s own install step failing is a second reason not to print it.
    # A home can be fully projected and still be missing whatever `onboard` did
    # not get to, and `verified` is a claim about what an agent can serve, not
    # about what the store happens to hold.
    if [ "$ONBOARD_SHORTFALL" = 1 ]; then
      info "incomplete: $projected skill(s) servable, but \`onboard\` failed partway — this home holds less than it was asked to"
    elif [ -z "$shortfall" ]; then
      info "verified:  $projected skill(s) servable — an agent launched here reads them from ${agents% }; descriptor env inside $ROOT; claude/codex resolve to this home's shims"
    fi
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

# Reachable with zero skills only via --allow-empty (the gate above exits
# otherwise) or on a frozen home, and in both cases the invitation to launch has
# to carry the caveat rather than stand alone. "Verified, now launch an agent" on
# a home with no skills is the half of #10 that is a defect under every option.
[ "$QUIET" = 1 ] || [ "$SKILLS_N" != 0 ] || cat >&2 <<EOF

This home has NO SKILLS. An agent launched against it has none of them; that is
not a working home, it is an empty one. Install the bundled skills first:
  $(home_env_prefix) $CLI onboard --skip-gateway
EOF

[ "$QUIET" = 1 ] || cat >&2 <<EOF

Launch an agent bound to this home:
  $STORE/bin/launch/claude
or put the shims on PATH for this shell:
  eval "\$($SCRIPT_DIR/bootstrap-home.sh --root $ROOT --print-env)"
EOF

# Only after a clone actually ran: the caveat is about what just happened, so it
# is gated on `cloned`, not on `bootstrapped`. See the note beside `cloned=0`.
#
# Two things about the sentence below were wrong, and both were printed as
# instructions:
#
#   * `SKILL_MANAGER_HOME=<home> skill-manager sync --force-scripts` names ONE of
#     the two axes. With CLAUDE_CONFIG_DIR / CODEX_HOME / GEMINI_HOME unset, the
#     binding step of that sync writes the OPERATOR'S ~/.claude.json,
#     ~/.codex/config.toml and ~/.gemini/settings.json — measured: `ADDED claude
#     (~/.claude.json) -> http://127.0.0.1:<port>/mcp`. That is the global-binding
#     hijack of skill-manager#145, reached by copy-pasting a line this file
#     printed. `home_env_prefix` pins both axes; re-measured with it, the same
#     sync wrote only <root>/.claude.json.
#
#   * it is not a fixpoint, and the claim that it re-provisions the reported
#     links is false for the links that actually get reported. Measured:
#     `home verify` rc=1 on `bin/cli/jinja2 -> ../../venvs/jinja2-cli/bin/jinja2`
#     -> run this remedy (rc=1, but it completes its sync) -> `home verify` rc=1
#     again, identical message, and <home>/venvs is still empty. Nothing in
#     `sync` recreates a venv the clone deliberately skipped, so a home whose
#     tools live in one can never pass `home verify` by following the instruction
#     `home verify` itself prints. That belongs to skill-manager, not here; this
#     file's job is to stop asserting a repair it cannot make.
[ "$QUIET" = 1 ] || [ "$cloned" = 0 ] || cat >&2 <<EOF

The home is a clone: cache/, tmp/, logs/, venvs/, tools/ and npm/ were not
copied, so a shim whose target lived under one of those arrived dangling. Any
such link is listed above.

Run THIS spelling, not the one \`home clone\` printed above: that one sets
SKILL_MANAGER_HOME alone, and a sync with the agent-home variables unset writes
the OPERATOR'S ~/.claude.json, ~/.codex/config.toml and ~/.gemini/settings.json
(skill-manager#145).
  $(home_env_prefix) $CLI sync --force-scripts
re-provisions the shims it can re-derive. It does NOT recreate <home>/venvs, so
a link INTO venvs/ stays dangling and \`skill-manager home verify\` keeps
refusing this home — running its printed remedy does not change its verdict.
That is a skill-manager gap, not something to keep re-running here; only the
tools those links name are affected.
EOF
