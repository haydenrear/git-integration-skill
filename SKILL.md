---
name: git-integration-repo
description: >-
  Create and operate "integration repositories" — a parent git repo that
  contains multiple constituent git repositories as ordinary tracked files
  (never submodules), so cross-repo features can be made in a single worktree
  and then fanned back out to each constituent as feature branches, MRs, and a
  tracking issue. Use when the user wants to onboard several repos into one
  integration repo, make a ticketed multi-repo change with worktrees, propagate
  a merged change out to the underlying repos, or scaffold spec-double-compiler
  / test-graph / deploy-helm support across all of them.
skill-imports:
  - unit: spec-double-compiler
    path: SKILL.md
    reason: Integration features use tla-spec-dev spec doubles and spec unit tests across all constituents.
  - unit: test-graph
    path: SKILL.md
    reason: Integration features are validated with test_graph spec/validation graphs spanning constituents.
  - unit: deploy-helm
    path: SKILL.md
    reason: Optional environment-repo composition deploys the constituents together to a test cluster.
  - unit: skill-manager
    path: references/workflows.md
    reason: This skill is installed and synced as a skill-manager unit.
---

# git-integration-repo

An **integration repository** is a single parent git repo whose working tree
contains several other repositories' files. The parent tracks those files as
**ordinary blobs** — it does not know, and must never be told, that the content
originally came from nested git repos. There are **no git submodules and no
gitlinks**. Each constituent still has its own real `.git` (with its own remote)
sitting inside the parent working tree, but the parent ignores it.

This gives you two things at once:

- **One place to make a cross-repo change.** Create a parent worktree, edit
  files that span many constituents, commit once, review once.
- **Clean fan-out on the way back.** When the change merges into the parent,
  each constituent's real `.git` sees exactly its slice of the diff. You branch,
  commit, and push per constituent, open an MR each, and file one tracking issue
  for a downstream agent to run tests and manage the merges.

## The load-bearing invariant

The whole scheme rests on **committing constituent files to the parent BEFORE
the constituent `.git` exists**. Order matters:

1. Clone a constituent into `constituents/<name>/`.
2. **Delete its `.git`** so it is just files.
3. `git add` + commit those files to the parent. The parent index now holds
   real file blobs (mode `100644`), not a gitlink (`160000`).
4. **Only now** re-create the constituent's `.git`: `git init`, add the remote,
   `git fetch --all`, `git reset --hard origin/<branch>`.
5. Verify the parent working tree is **clean** — `reset --hard` restores
   byte-identical content, so there is no diff.

If you ever `git add` a directory while it already contains a `.git`, git turns
it into a gitlink/embedded-repo and the model breaks. Never do that. See
`references/git-model.md` for the empirical proof of why the order works.

## When to use this skill

- "Onboard these N repos into one integration repo."
- "Make a change across service-a, service-b, and the shared lib on ticket X."
- "I merged the integration change — push it out to the underlying repos."
- "Scaffold tla-spec-dev / test_graph / deploy support across all of them."
- "Refresh the integration repo from upstream."

## Repository markers

Every integration repo carries two markers at its root (scaffolded by this
skill's `assets/`):

- **`INTEGRATION.md`** — the human/agent-facing note: "this is an integration
  repository, here is how to manage worktrees and push the constituents." An
  agent that opens the repo reads this first.
- **`integration.toml`** — the machine-readable manifest: the list of
  constituents (path, remote, default branch), the git host (`gitlab`/`github`
  → `glab`/`gh`), and which compositions (`spec_double_compiler`, `test_graph`,
  `deploy_helm`) are enabled. Every script reads this.

The **ignore file lives at the parent root** (`assets/gitignore.scaffold` →
`.gitignore`), with path-scoped rules like `constituents/*/target/`. It must
never be placed inside a constituent directory, because `git reset --hard` on a
constituent would clobber it.

## Workflows

| Task | Read | Scripts |
|---|---|---|
| Create / onboard an integration repo | `references/onboarding.md` | `scripts/init-integration.sh`, `scripts/add-constituent.sh`, `scripts/finalize-constituents.sh`, `scripts/verify.sh` |
| Make a ticketed multi-repo change | `references/worktrees.md` | `scripts/new-change.sh` |
| Fan a merged change out to constituents | `references/propagation.md` | `scripts/propagate.sh` |
| Scaffold spec / test-graph / deploy | `references/composition.md` | (invokes the composed skills) |
| Refresh from upstream (destructive) | `references/git-model.md` | `scripts/refresh.sh` |
| Understand *why* the git model works | `references/git-model.md` | — |

## Quick reference

```bash
# scripts read integration.toml from the repo root; run them from anywhere in the repo
S=<this-skill>/scripts

# --- create ---
$S/init-integration.sh my-integration            # scaffold markers, .gitignore, git init
$S/add-constituent.sh service-a git@host:org/service-a.git main
git add -A && git commit -m "onboard constituents"   # commit BEFORE finalize
$S/finalize-constituents.sh                       # re-init .git + remote + fetch + reset --hard, all constituents
$S/verify.sh                                      # assert parent clean + every constituent wired

# --- change ---
$S/new-change.sh TICKET-123                        # parent worktree on feature/TICKET-123 (plain files)
#   ...edit across constituents in the worktree, commit to the parent feature branch...
git -C <repo-root> merge --no-ff feature/TICKET-123   # bring it back to the integration main tree

# --- fan out ---
$S/propagate.sh TICKET-123                          # per-constituent: branch, commit, push, MR + one tracking issue
```

Always finish an onboarding or a propagation by running `scripts/verify.sh` and
confirming the parent tree is clean.
