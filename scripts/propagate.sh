#!/usr/bin/env bash
# propagate.sh <TICKET> [--push] [--mr]
# Run from the integration MAIN tree AFTER a ticketed change has been merged
# back. For each constituent whose real .git shows changes, this creates a
# feature/<TICKET> branch, commits the constituent's slice of the diff, and
# (with --push) pushes it and (with --mr) opens a merge request. Finally it
# emits ONE tracking issue for a downstream agent to run tests and manage merges.
#
# Default is a DRY RUN (branch + commit locally, no network). Add --push to push
# and --mr to open MRs/issue. This keeps an accidental run from touching remotes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

TICKET="${1:-}"; [ -n "$TICKET" ] || die "usage: propagate.sh <TICKET> [--push] [--mr]"
shift || true
DO_PUSH=0; DO_MR=0
for a in "$@"; do case "$a" in --push) DO_PUSH=1;; --mr) DO_PUSH=1; DO_MR=1;; *) die "unknown flag $a";; esac; done

ROOT="$(repo_root)"; cd "$ROOT"
BRANCH="feature/$TICKET"
HOST="$(manifest "$ROOT" get host)"; HOST="${HOST:-gitlab}"
case "$HOST" in gitlab) HOSTCLI=glab;; github) HOSTCLI=gh;; *) HOSTCLI="";; esac

TMP="$ROOT/.integration/tmp"; mkdir -p "$TMP"
SUMMARY="$TMP/$TICKET-propagation.md"
: > "$SUMMARY"
changed=()

step "Propagating $TICKET to constituents (push=$DO_PUSH mr=$DO_MR)"
while IFS=$'\t' read -r name path remote branch; do
  [ -n "$name" ] || continue
  [ -d "$path/.git" ] || { info "$name: no .git, skipping (finalize first)"; continue; }
  # Participate if there are working-tree changes to commit, OR the feature
  # branch already exists (e.g. a prior dry run committed it and now we --push).
  dirty=0; hasbranch=0
  [ -n "$(git -C "$path" status --porcelain)" ] && dirty=1
  git -C "$path" show-ref --verify --quiet "refs/heads/$BRANCH" && hasbranch=1
  if [ "$dirty" -eq 0 ] && [ "$hasbranch" -eq 0 ]; then
    info "$name: no changes"
    continue
  fi
  changed+=("$name")
  def="$(constituent_default_branch "$path" "$branch")"
  step "  $name (base $def)"

  # Create or switch to the feature branch, then commit the working slice.
  if git -C "$path" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$path" checkout -q "$BRANCH"
  else
    git -C "$path" checkout -q -b "$BRANCH"
  fi
  git -C "$path" add -A
  git -C "$path" commit -q -m "$TICKET: integration change" || info "nothing to commit"
  info "committed on $BRANCH"

  url=""
  if [ "$DO_PUSH" -eq 1 ]; then
    git -C "$path" push -q -u origin "$BRANCH"
    info "pushed origin/$BRANCH"
  fi
  if [ "$DO_MR" -eq 1 ] && [ -n "$HOSTCLI" ] && command -v "$HOSTCLI" >/dev/null 2>&1; then
    case "$HOSTCLI" in
      glab) url="$(cd "$path" && glab mr create --source-branch "$BRANCH" --target-branch "$def" \
              --title "$TICKET: integration change" \
              --description "Part of integration ticket $TICKET. See tracking issue." \
              --yes 2>/dev/null | grep -Eo 'https?://[^ ]+' | head -1)" || true ;;
      gh)   url="$(cd "$path" && gh pr create --head "$BRANCH" --base "$def" \
              --title "$TICKET: integration change" \
              --body "Part of integration ticket $TICKET. See tracking issue." 2>/dev/null | grep -Eo 'https?://[^ ]+' | head -1)" || true ;;
    esac
    [ -n "$url" ] && info "MR: $url"
  fi
  printf -- '- **%s** (`%s`) → `%s`%s\n' "$name" "$def" "$BRANCH" "${url:+  \n  MR: $url}" >> "$SUMMARY"
done < <(manifest "$ROOT" constituents)

if [ "${#changed[@]}" -eq 0 ]; then
  info "no constituents changed — nothing to propagate"
  exit 0
fi

# ---- one tracking issue for the downstream agent ----
ISSUE_TITLE="[$TICKET] Integration change: run tests and manage merges"
ISSUE_BODY="$TMP/$TICKET-issue.md"
{
  echo "Integration ticket **$TICKET** has been fanned out to the constituents below."
  echo
  echo "Each has a \`$BRANCH\` branch (and MR, if opened). Please, per constituent:"
  echo "1. Run the constituent's tests plus the shared test_graph / tla-spec-dev checks."
  echo "2. Review and merge the MR when green."
  echo "3. Report status back on this issue."
  echo
  echo "## Constituents"
  cat "$SUMMARY"
} > "$ISSUE_BODY"

step "Tracking issue"
TRACKER="$(manifest "$ROOT" get integration.tracker)"
if [ "$DO_MR" -eq 1 ] && [ -n "$HOSTCLI" ] && command -v "$HOSTCLI" >/dev/null 2>&1 && [ -n "$TRACKER" ]; then
  case "$HOSTCLI" in
    glab) ( cd "$ROOT"; glab issue create --repo "$TRACKER" --title "$ISSUE_TITLE" --description "$(cat "$ISSUE_BODY")" --yes ) || info "issue create failed" ;;
    gh)   ( cd "$ROOT"; gh issue create --repo "$TRACKER" --title "$ISSUE_TITLE" --body "$(cat "$ISSUE_BODY")" ) || info "issue create failed" ;;
  esac
else
  info "no tracker configured (or --mr not set). Issue body written to:"
  info "  $ISSUE_BODY"
  info "Set [integration].tracker = \"org/coordination-repo\" in integration.toml to auto-file it."
fi

info "changed constituents: ${changed[*]}"
