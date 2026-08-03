# Onboarding: creating an integration repository

Goal: turn a set of independent repos into one parent repo that tracks their
files directly. Read `references/git-model.md` first if you have not — the
ordering below is not cosmetic.

## Procedure

```bash
S="${SKILL_MANAGER_HOME:-$HOME/.skill-manager}/skills/git-integration-repo/scripts"

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

# 9. Give the repo its own skill-manager home, so agents working here never
#    touch the operator's global one (see references/skill-homes.md):
#      - RECOMMENDED, not required: add the ignore rules to the ROOT .gitignore
#        and prove them with `git check-ignore -v`. bootstrap-home.sh does NOT
#        need them — it writes a per-checkout rule into .git/info/exclude for
#        whatever it MEASURES a home leaving at the root, so onboarding never
#        requires a commit to the repo being onboarded (which a read-only
#        checkout, a CI job or a vendored constituent could not make). What
#        committing the rules buys is that everyone ELSE who clones this repo
#        gets a clean tree too: the exclude rule is invisible to them.
#      - write skill-project.toml declaring the units this repo's agents need
#      - OPTIONAL: cp $S/agent-home.sh scripts/  (the locator this skill ships),
#        after which `scripts/agent-home.sh` from the repo root does the same
#        thing as the line below. Convenience for a human only — an agent never
#        needs it, because `wt new` in a repo with no home prints this exact
#        line, absolute, as its `fix:`. Do not make it a required step.
$S/bootstrap-home.sh --root .
```

Step 9's recommended ignore rules are listed in `references/skill-homes.md`,
along with what the bootstrap actually writes and who does not see it.
`agent-home.sh` prints which copy of `bootstrap-home.sh` it ran, and refuses a
copy too old to project a home's skills into its agent directories.

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
- **Assuming a root ignore rule wins.** A constituent's own `.gitignore` is more
  specific, so a negated rule in it beats the root rule — that is how a 1.0 GB
  vendored IntelliJ distribution stayed visible to the parent. Always confirm
  with `git check-ignore -v <path>` and read which file it names.

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
