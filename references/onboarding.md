# Onboarding: creating an integration repository

Goal: turn a set of independent repos into one parent repo that tracks their
files directly. Read `references/git-model.md` first if you have not — the
ordering below is not cosmetic.

## Procedure

```bash
S=<this-skill>/scripts

# 1. Scaffold the parent (markers, root .gitignore, git init).
$S/init-integration.sh my-integration /path/to/parent

cd /path/to/parent

# 2. Add each constituent. This clones it, DELETES its .git (so its files become
#    plain files), and registers it in integration.toml. It does NOT commit and
#    does NOT restore .git yet.
$S/add-constituent.sh service-a git@gitlab.com:org/service-a.git main
$S/add-constituent.sh service-b git@gitlab.com:org/service-b.git main
$S/add-constituent.sh shared-lib git@gitlab.com:org/shared-lib.git main

# 3. Review the root .gitignore. Ensure build/artifact dirs for these
#    constituents are covered (path-scoped: constituents/<name>/target/, etc.).

# 4. Commit the constituent files to the parent — BEFORE restoring any .git.
git add -A
git commit -m "onboard constituents: service-a, service-b, shared-lib"

# 5. Finalize: for each constituent, git init + remote add + fetch --all +
#    reset --hard origin/<branch>. Restores each as its own repo. Asserts the
#    parent tree is clean at the end.
$S/finalize-constituents.sh

# 6. Verify health (parent clean, no gitlinks, every constituent wired).
$S/verify.sh

# 7. Scaffold compositions (see references/composition.md): tla-spec-dev spec
#    doubles, test_graph, and optionally deploy-helm.

# 8. Commit the compositions and the markers.
git add -A && git commit -m "scaffold compositions + markers"
```

## What each step guarantees

| Step | Guarantee |
|---|---|
| 2 (add) | Constituent is present as plain files; no `.git`; manifest updated. |
| 4 (commit) | Parent index holds real blobs (`100644`), never gitlinks. |
| 5 (finalize) | Each constituent is its own repo again; parent still clean. |
| 6 (verify) | No submodules leaked; remotes wired; tree clean. |

## Common pitfalls

- **Committing after finalize instead of before.** If a `.git` exists when you
  first `git add` a constituent, it becomes a gitlink. Always: strip `.git` →
  commit → restore `.git`. `add-constituent.sh` and `finalize-constituents.sh`
  enforce this split; do not hand-run them out of order.
- **Upstream moved between clone and finalize.** `reset --hard origin/<branch>`
  may then differ from what you committed, so the parent won't be clean.
  Re-commit the refreshed content, or pin a tag.
- **Ignoring artifacts inside a constituent.** Put path-scoped rules in the root
  `.gitignore`, not a file inside the constituent (it would be wiped by
  `reset --hard`). See `references/git-model.md`.

## Adding a constituent later

Same split, on an existing integration repo:

```bash
$S/add-constituent.sh new-svc git@gitlab.com:org/new-svc.git main
git add -A && git commit -m "onboard new-svc"
$S/finalize-constituents.sh    # only the un-finalized one gets a .git restored
$S/verify.sh
```

## Removing a constituent

```bash
rm -rf constituents/<name>          # includes its .git
# remove its [[constituent]] block from integration.toml
git add -A && git commit -m "drop <name>"
```
