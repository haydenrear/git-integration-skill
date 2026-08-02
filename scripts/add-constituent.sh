#!/usr/bin/env bash
# add-constituent.sh <name> <remote-url> [default-branch]
# Clone a constituent into constituents/<name>/, STRIP its .git (so its files
# become plain files the parent will track), and register it in integration.toml.
# Does NOT commit and does NOT restore .git — that is finalize-constituents.sh,
# run after you commit. This ordering is the load-bearing invariant.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: add-constituent.sh <name> <remote-url> [default-branch]

  name            Directory name under constituents/.
  remote-url      Clone source, kept as the constituent's origin.
  default-branch  Branch to clone. Default: the remote's HEAD.
  -h, --help      This message, answered BEFORE the clone.

Clones the constituent, STRIPS its .git so the parent tracks plain files, and
registers it in integration.toml. Does not commit; run finalize-constituents.sh
after you do.
EOF
}
help_guard "$@"

NAME="${1:-}"; REMOTE="${2:-}"; BRANCH="${3:-}"
[ -n "$NAME" ] && [ -n "$REMOTE" ] || { usage; die "a name and a remote url are required"; }

ROOT="$(repo_root)"; cd "$ROOT"
REL="constituents/$NAME"
[ -e "$REL" ] && die "$REL already exists"

step "Cloning constituent '$NAME'"
if [ -n "$BRANCH" ]; then
  git clone -q --branch "$BRANCH" "$REMOTE" "$REL"
else
  git clone -q "$REMOTE" "$REL"
  BRANCH="$(git -C "$REL" symbolic-ref --quiet --short HEAD || echo main)"
fi
info "cloned into $REL (default branch: $BRANCH)"

# Strip .git so the parent will track ordinary files, never a gitlink.
rm -rf "$REL/.git"
info "removed $REL/.git — constituent is now plain files"

manifest "$ROOT" add "$NAME" "$REL" "$REMOTE" "$BRANCH"
info "registered in integration.toml"

cat >&2 <<EOF

'$NAME' staged as plain files. When you have added all constituents:
  git add -A && git commit -m "onboard constituents"
  $SCRIPT_DIR/finalize-constituents.sh      # restores each .git, wires remotes
EOF
