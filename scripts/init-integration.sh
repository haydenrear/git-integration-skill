#!/usr/bin/env bash
# init-integration.sh <name> [dir]
# Scaffold a new integration repository: markers, root .gitignore, .integration/,
# and `git init` if needed. Run add-constituent.sh next.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"
ASSETS="$SCRIPT_DIR/../assets"

usage() {
  cat >&2 <<'EOF'
usage: init-integration.sh <name> [dir]

  name        Name of the integration repository, written into integration.toml.
  dir         Where to scaffold it. Default: the current directory.
  -h, --help  This message. It is answered BEFORE anything is created — this
              script used to take `--help` as the NAME and scaffold an
              integration repo called `--help` into the caller's cwd.

Creates integration.toml, INTEGRATION.md, a root .gitignore, constituents/ and
.integration/, and runs `git init` if there is no repo here yet.
EOF
}
help_guard "$@"

NAME="${1:-}"; [ -n "$NAME" ] || { usage; die "a name is required"; }
DIR="${2:-.}"
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
cd "$DIR"

step "Initializing integration repo '$NAME' in $DIR"

[ -d .git ] || { git init -q; info "git init"; }

if [ -f integration.toml ]; then
  info "integration.toml exists — leaving it"
else
  sed "s/REPLACE_ME/$NAME/" "$ASSETS/integration.toml.scaffold" > integration.toml
  info "wrote integration.toml"
fi

[ -f INTEGRATION.md ] || { cp "$ASSETS/INTEGRATION.md.scaffold" INTEGRATION.md; info "wrote INTEGRATION.md"; }

if [ -f .gitignore ]; then
  info ".gitignore exists — review it against assets/gitignore.scaffold"
else
  cp "$ASSETS/gitignore.scaffold" .gitignore; info "wrote .gitignore (root-level ignores)"
fi

mkdir -p constituents .integration/tmp
touch .integration/.keep

cat >&2 <<EOF

Next:
  1. Add constituents:   $SCRIPT_DIR/add-constituent.sh <name> <remote-url> [branch]
  2. Commit them:        git add -A && git commit -m "onboard constituents"
  3. Finalize (restore each constituent's .git): $SCRIPT_DIR/finalize-constituents.sh
  4. Verify:             $SCRIPT_DIR/verify.sh
EOF
