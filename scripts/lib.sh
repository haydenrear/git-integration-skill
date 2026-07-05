#!/usr/bin/env bash
# Shared helpers for git-integration-repo scripts. Source this:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*" >&2; }

# Repo root = nearest ancestor with integration.toml. Falls back to git toplevel.
repo_root() {
  local d="${1:-$PWD}"
  d="$(cd "$d" && pwd)"
  while [ "$d" != "/" ]; do
    [ -f "$d/integration.toml" ] && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  git rev-parse --show-toplevel 2>/dev/null || die "not inside an integration repo (no integration.toml found)"
}

# Pick any Python 3 interpreter. _manifest.py is dependency-free (no tomllib),
# so the system python3 is fine; fall back to python / python3.x if needed.
_pick_py() {
  local c
  for c in python3 python python3.14 python3.13 python3.12 python3.11; do
    command -v "$c" >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
  done
  die "no python interpreter found (need python3 or python)"
}
PY="${INTEGRATION_PY:-$(_pick_py)}"

manifest() { "$PY" "$SCRIPT_DIR/_manifest.py" "$@"; }

# Default branch of a constituent as its own git sees origin's HEAD, with the
# manifest value as the fallback.
constituent_default_branch() {
  local dir="$1" fallback="${2:-main}" b
  b="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')" || true
  [ -n "$b" ] && { printf '%s\n' "$b"; return 0; }
  printf '%s\n' "$fallback"
}

# Assert the parent working tree is clean.
assert_parent_clean() {
  local root="$1"
  if [ -n "$(git -C "$root" status --porcelain)" ]; then
    git -C "$root" status --short >&2
    die "parent working tree is not clean (see above)"
  fi
}
