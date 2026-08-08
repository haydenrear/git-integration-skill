---
name: git-integration-repo
description: >-
  Create and operate "integration repositories" — a parent git repo that
  contains multiple constituent git repositories as ordinary tracked files
  (never submodules), so one cross-repo change can be fanned back out to each
  constituent as feature branches, MRs, and a tracking issue. Use when the user
  wants to onboard several repos into one integration repo, propagate a merged
  change out to the underlying repos, refresh the parent from upstream, or
  scaffold spec-double-compiler / test-graph / deploy-helm support across all of
  them. It does NOT create or tear down worktrees and does not own Skill Manager
  homes: `git-issue-workflow` ships `wt` and does that for every repo, with or
  without constituents. This skill is the specialization on top.
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
- "I merged the integration change — push it out to the underlying repos."
- "Scaffold tla-spec-dev / test_graph / deploy support across all of them."
- "Refresh the integration repo from upstream."

Not this skill: **"make a change across service-a, service-b and the shared lib
on ticket X."** That is a ticket, and a ticket is `git-issue-workflow` — the
worktree and its Skill Manager home are one `wt new` there, whatever shape the
repo is. Come back here for the fan-out afterwards.

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
| Make a ticketed change (multi-repo or not) | nothing — `git-issue-workflow` owns it; see below | *(not here)* |
| Give a checkout its own skill-manager home | `git-issue-workflow`'s `references/skill-homes.md` | *(not here)* |
| Fan a merged change out to constituents | `references/propagation.md` | `scripts/propagate.sh` |
| Scaffold spec / test-graph / deploy | `references/composition.md` | (invokes the composed skills) |
| Refresh from upstream (destructive) | `references/git-model.md` | `scripts/refresh.sh` |
| Understand *why* the git model works | `references/git-model.md` | — |

## Worktrees are not here: `git-issue-workflow` owns them

**`wt`, `new-change.sh`, `close-change.sh`, `bootstrap-home.sh`, `agent-home.sh`
and the shared `lib.sh` are shipped by `git-issue-workflow`, not by this skill.**
Nothing on this page creates or removes a worktree, and you do not need to read
this page to make one:

```bash
skt ticket new   TICKET-123   # preferred: on PATH in skt-carrying homes
skt ticket close TICKET-123

# fallback for a checkout without skt — same lifecycle underneath:
WT="${SKILL_MANAGER_HOME:-$HOME/.skill-manager}/skills/git-issue-workflow/scripts/wt"
"$WT" new   TICKET-123     # worktree + its own Skill Manager home, launchable
"$WT" close TICKET-123     # teardown, through the close-out gate
```

That is the same lifecycle in an integration repo, in a constituent of one, and
in an ordinary repo with no constituents at all — it detects which it is
standing in. Its contract, its one-line output, its refusals and the
per-checkout home mechanism are documented in git-issue-workflow's
`references/worktrees.md` and `references/skill-homes.md`; session orientation
(what is loaded, which tier, ticket/epic state) is `skt status`.

### Why they are there and not here

An integration repository is a **specialization**: it exists only when a repo has
constituents. A ticket and a worktree exist for **every** repo. So the general
machinery cannot live in the specialized skill, and the dependency has to run
specialized → general:

```
git-integration-repo  ->  git-issue-workflow  ->  git-issue
```

The failure that forced this was a **selection** failure, not a path failure. An
agent picks a skill by its `description`. This skill's says "onboard several
repos into one integration repo" — so an agent working a plain repo read it,
correctly concluded it was irrelevant, never opened it, never learned `wt`
existed, and wrote its own worktree script, which knew none of the rules those
files hold. Naming a resolvable path inside this page could not fix that: the
agent has to be *told* the command every time and can never *discover* the
capability. `git-issue-workflow`'s description is the one a ticket agent
already matches on, so that is where the capability is now announced.

Every script left here still uses `die`/`info`/`step`/`help_guard` and the
checkout predicates. They **source** them from the installed dependency —
`$SKILL_MANAGER_HOME/skills/git-issue-workflow/scripts/lib.sh` — through the
single resolver in `scripts/integration-lib.sh`. One definition, one home, one
resolved path to it; there is no second copy of `lib.sh` here and there must
never be one. `skill-manager.toml` declares the hard `skill_reference` that
guarantees the file, and `integration-lib.sh` refuses at source time — before
anything runs, with the `skill-manager sync` that fixes it — when the installed
copy is older than this skill needs.

### What this skill still contributes to a ticket

One key and one script: the constituent **fan-out**. `wt info TICKET-123` prints
a `PROPAGATE` key in an integration repo and only there, resolved to this
skill's `scripts/propagate.sh`; when the unit is not installed it prints the
install command instead of a dead path. `wt` decides that by looking for
`integration.toml` — an **artifact**, not an installed skill — which is
deliberate: the marker is already the thing every script here keys on, it costs
one `[ -f ]` per rung, and a plug-in mechanism for one boolean would be more
machinery than the question deserves.

## Quick reference

```bash
# scripts read integration.toml from the repo root; run them from anywhere in the repo
S="${SKILL_MANAGER_HOME:-$HOME/.skill-manager}/skills/git-integration-repo/scripts"

# --- create ---
$S/init-integration.sh my-integration            # scaffold markers, .gitignore, git init
$S/add-constituent.sh service-a git@host:org/service-a.git main
git add -A && git commit -m "onboard constituents"   # commit BEFORE finalize
$S/finalize-constituents.sh                       # re-init .git + remote + fetch + reset --hard, all constituents
$S/verify.sh                                      # assert parent clean + every constituent wired

# --- refresh (destructive) ---
$S/refresh.sh                                     # fetch + reset --hard every constituent to its default branch

# --- fan out ---
$S/propagate.sh TICKET-123                        # per-constituent: branch, commit, push, MR + one tracking issue
$S/propagate.sh TICKET-123 --push                 # also push feature/TICKET-123 to each origin
$S/propagate.sh TICKET-123 --push --mr            # also open a PR/MR each + one tracking issue

# --- prove the above (from a CHECKOUT of this skill, not the installed copy:
#     two of its checks sweep this unit's git index, which an install has none of) ---
bash <checkout-of-git-integration-skill>/scripts/selftest.sh   # needs no skill-manager CLI

# --- the worktree the change is MADE in: NOT here ---
skt ticket new TICKET-123                         # preferred where the skt plugin is installed
WT="${SKILL_MANAGER_HOME:-$HOME/.skill-manager}/skills/git-issue-workflow/scripts/wt"
$WT new TICKET-123                                # the same door where skt is absent
#   ...edit across constituent files in the one parent worktree, commit...
git -C <repo-root> merge --no-ff feature/TICKET-123   # bring it back to the integration main tree
$S/verify.sh                                      # then fan out with propagate.sh, above
skt ticket close TICKET-123                       # teardown through the close-out gate
$WT close TICKET-123                              #   (same gate where skt is absent)
```

Every entry point here answers `-h/--help` before doing anything, and refuses a
first positional beginning with `-`. That is not politeness: `propagate.sh
--help` once consumed `--help` as the TICKET and ran a real fan-out, and
`init-integration.sh --help` scaffolded an integration repo called `--help` into
the operator's own working directory. The guard is `help_guard` in
`git-issue-workflow`'s `lib.sh`, called first by every script here, and
`scripts/selftest.sh` sweeps this directory to keep it that way for scripts
added later.

`propagate.sh` fans a **parent** change out to constituents. Sending a **skill**
edit an agent made inside its own home back to that skill's repo is a different
flow (push-back) that `propagate.sh` cannot do, because the home is gitignored
and never in the parent diff. `git-issue-workflow`'s `references/skill-homes.md`
has the comparison; confusing the two silently loses the skill edit at worktree
teardown.

Always finish an onboarding or a propagation by running `scripts/verify.sh` and
confirming the parent tree is clean.
