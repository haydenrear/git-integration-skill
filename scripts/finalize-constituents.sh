#!/usr/bin/env bash
# finalize-constituents.sh
# For every constituent in the manifest that has no .git yet: git init, add the
# remote, fetch --all, and reset --hard origin/<branch>. This restores each
# constituent as its own repo AFTER the parent already committed its files, so
# the parent index holds real blobs (not gitlinks) and stays clean.
#
# Run this only AFTER `git add -A && git commit` of the onboarded files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

ROOT="$(repo_root)"; cd "$ROOT"

# Guard the invariant: constituent files must already be committed to the parent.
if git -C "$ROOT" status --porcelain -- constituents | grep -q .; then
  git -C "$ROOT" status --short -- constituents >&2
  die "constituent files are not committed yet. Commit them BEFORE finalizing:
    git add -A && git commit -m \"onboard constituents\""
fi

rc=0
while IFS=$'\t' read -r name path remote branch; do
  [ -n "$name" ] || continue
  step "Finalizing $name"
  if [ -d "$path/.git" ]; then
    info "already has .git — skipping"
    continue
  fi
  ( cd "$path"
    git init -q
    git remote add origin "$remote"
    git fetch -q --all
    if git rev-parse --verify -q "origin/$branch" >/dev/null; then
      git reset -q --hard "origin/$branch"
    else
      # fall back to origin's HEAD
      def="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
      [ -n "$def" ] || die "cannot resolve default branch for $name (tried origin/$branch)"
      git reset -q --hard "origin/$def"
    fi
  ) || { rc=1; info "FAILED to finalize $name"; continue; }
  info "$name wired to $remote ($branch), reset --hard to match"
done < <(manifest "$ROOT" constituents)

step "Verifying parent working tree is clean"
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  git -C "$ROOT" status --short >&2
  die "parent tree not clean after finalize. A constituent's upstream content
differs from what was committed. Investigate the diff above before continuing."
fi
info "clean — onboarding is consistent"
exit $rc
