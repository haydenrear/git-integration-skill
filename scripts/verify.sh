#!/usr/bin/env bash
# verify.sh
# Assert the integration repo is healthy:
#   - parent working tree is clean
#   - every manifest constituent exists, has its own .git, has an origin remote,
#     and is NOT tracked by the parent as a gitlink (mode 160000)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$SCRIPT_DIR/lib.sh"

ROOT="$(repo_root)"; cd "$ROOT"
fail=0

step "Parent working tree"
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  git -C "$ROOT" status --short >&2; info "NOT clean"; fail=1
else
  info "clean"
fi

step "No gitlinks in parent index (never submodules)"
if git -C "$ROOT" ls-files -s | awk '$1=="160000"{print $4}' | grep -q .; then
  git -C "$ROOT" ls-files -s | awk '$1=="160000"{print "  gitlink: "$4}' >&2
  info "FOUND gitlinks — a constituent got added while it had a .git. Broken."; fail=1
else
  info "none — constituent files are tracked as blobs"
fi

step "Constituents"
while IFS=$'\t' read -r name path remote branch; do
  [ -n "$name" ] || continue
  if [ ! -d "$path" ]; then info "$name: MISSING dir $path"; fail=1; continue; fi
  if [ ! -d "$path/.git" ]; then info "$name: no .git (run finalize-constituents.sh)"; fail=1; continue; fi
  got="$(git -C "$path" remote get-url origin 2>/dev/null || echo '')"
  if [ -z "$got" ]; then info "$name: no origin remote"; fail=1; continue; fi
  info "$name: ok ($branch -> $got)"
done < <(manifest "$ROOT" constituents)

step "Result"
if [ "$fail" -eq 0 ]; then info "PASS"; else info "FAIL"; fi
exit $fail
