# git-integration-repo

A skill-manager skill for **integration repositories**: one parent git repo that
tracks the files of several other repositories directly — **no submodules, no
gitlinks** — so a cross-repo feature can be made in a single worktree and then
fanned back out to each underlying repo as feature branches, MRs, and a tracking
issue.

## Install

```bash
skill-manager install git+https://<host>/<org>/git-integration-skill.git --yes
# or, locally during development:
skill-manager install file:///Users/hayde/IdeaProjects/git-integration-skill --yes
skill-manager sync git-integration-repo
```

## What it gives you

- **Onboarding** — clone repos in, strip their `.git`, commit to the parent,
  restore `.git` + remotes, verify clean. (`scripts/init-integration.sh`,
  `add-constituent.sh`, `finalize-constituents.sh`, `verify.sh`)
- **Ticketed changes** — parent worktrees that are pure files.
  (`scripts/new-change.sh`)
- **Propagation** — per-constituent branch/commit/push, MRs, one tracking issue.
  (`scripts/propagate.sh`)
- **Refresh** — destructive upstream sync. (`scripts/refresh.sh`)
- **Composition** — scaffold tla-spec-dev, test_graph, and optional deploy-helm
  across all constituents. (`references/composition.md`)

## The core idea

Commit constituent files to the parent **before** restoring each constituent's
`.git`. Then the parent tracks real file blobs, never gitlinks, and each
constituent stays its own pushable repo inside the parent working tree. See
`references/git-model.md` for the empirically-verified mechanics.

## Layout

```
SKILL.md                     # agent-facing router
skill-manager.toml           # unit manifest
assets/                      # scaffolded into each new integration repo
  INTEGRATION.md.scaffold    #   the "this is an integration repo" marker + how-to
  integration.toml.scaffold  #   machine-readable constituent/compositions manifest
  gitignore.scaffold         #   root-level, path-scoped ignores
scripts/                     # the workflow (see SKILL.md quick reference)
references/                  # onboarding, worktrees, propagation, composition, git-model
```
