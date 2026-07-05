#!/usr/bin/env bash
# refresh.sh [name]
# Refresh constituents from upstream: fetch --all + reset --hard origin/<branch>.
# DESTRUCTIVE: discards any un-pushed local content in the constituent. Propagate
# and push first. With no name, refreshes every constituent; with a name, one.
# Afterward the parent working tree will show upstream drift as ordinary diffs —
# review and commit those to the parent to record the new baseline.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

ONLY="${1:-}"
ROOT="$(repo_root)"; cd "$ROOT"

step "Refreshing constituents from upstream (destructive)"
while IFS=$'\t' read -r name path remote branch; do
  [ -n "$name" ] || continue
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  [ -d "$path/.git" ] || { info "$name: no .git, skipping"; continue; }
  if [ -n "$(git -C "$path" status --porcelain)" ]; then
    info "$name: has local changes — propagate/push before refreshing. SKIPPING."
    continue
  fi
  def="$(constituent_default_branch "$path" "$branch")"
  git -C "$path" fetch -q --all
  git -C "$path" checkout -q "$def" 2>/dev/null || git -C "$path" checkout -q -B "$def" "origin/$def"
  git -C "$path" reset -q --hard "origin/$def"
  info "$name: reset --hard to origin/$def"
done < <(manifest "$ROOT" constituents)

step "Parent status after refresh (upstream drift shows as diffs to review)"
git -C "$ROOT" status --short >&2 || true
cat >&2 <<EOF

If the diff above is expected upstream drift, record the new baseline:
  git -C "$ROOT" add -A && git -C "$ROOT" commit -m "refresh constituents from upstream"
EOF
