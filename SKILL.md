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
| Give a checkout its own skill-manager home | `references/skill-homes.md` | `scripts/bootstrap-home.sh`, `scripts/selftest.sh` |
| Make a ticketed multi-repo change | nothing — run `scripts/wt` and act on its output; `references/worktrees.md` is the explanation | `scripts/wt`, `scripts/new-change.sh`, `scripts/close-change.sh` |
| Fan a merged change out to constituents | `references/propagation.md` | `scripts/propagate.sh` |
| Scaffold spec / test-graph / deploy | `references/composition.md` | (invokes the composed skills) |
| Refresh from upstream (destructive) | `references/git-model.md` | `scripts/refresh.sh` |
| Understand *why* the git model works | `references/git-model.md` | — |

## The cheap path: `scripts/wt`

Creating and closing worktrees is the thing this repo does all day, so it must
cost an agent two commands and no reading. It does:

```bash
<this-skill>/scripts/wt new   TICKET-123     # worktree + its own home, launchable
<this-skill>/scripts/wt close TICKET-123     # teardown, through the close-out gate
```

**Stdout is the contract and carries nothing else.** Act on it directly; there
is nothing to look up.

```
WORKTREE   /path/to/repo-TICKET-123
BRANCH     feature/TICKET-123 (from main, constituent repo deploy-helm)
LAUNCH     /path/to/repo-TICKET-123/.skill-manager/bin/launch/claude
IF-EXIT-8  /path/to/repo-TICKET-123/.skill-manager/bin/cli/skill-manager home drift --ack
CLOSE      <this-skill>/scripts/wt close TICKET-123
PROPAGATE  <this-skill>/scripts/propagate.sh TICKET-123   # integration repos only
```

A failure is two lines, and the second one runs:

```
FAILED     the project home /path/to/repo/.skill-manager holds no skills, ...
FIX        <this-skill>/scripts/bootstrap-home.sh --root /path/to/repo --onboard
```

`wt` holds no policy of its own — it picks a verb, suppresses the prose, and
forwards the contract that `new-change.sh` and `close-change.sh` emit. Those two
remain the implementation and remain a matched pair (issue #50). Add `--verbose`
to see everything they say. The rest of this page and `references/worktrees.md`
explain *why* each line is what it is; the happy path does not need them.

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

# --- agent homes ---
$S/bootstrap-home.sh --root <repo-root>            # this checkout's own skill-manager home (idempotent)
#   --root defaults to the nearest git toplevel — inside a constituent that is
#   the CONSTITUENT, not the integration parent. Re-running CHECKS
#   <home>/bin/cli/skill-manager (written by `skill-manager home shims`, which
#   pins the build that ran it) and re-runs `home shims` when the slot is
#   absent, stale or a pre-#61 PATH-resolving shim. It never writes that file
#   itself, and it refuses rather than re-pointing a pin whose build is gone.
#   A WORKTREE clones from its project home (<main working tree>/.skill-manager),
#   never from $SKILL_MANAGER_HOME, because that is the home close-change.sh
#   reconciles it back into. No project home yet -> it refuses.
#   A home that comes out with ZERO SKILLS is REFUSED (exit 5), never reported
#   as verified: cloning copies units, it never installs any, so an empty source
#   yields a perfectly wired home an agent gets no skills from. The refusal names
#   `skill-manager onboard`. --onboard runs it (--skip-gateway by default, since
#   the gateway is a contended singleton); for a worktree the remedy is always
#   the PROJECT home, because units installed into the copy block teardown (#50).
#   --allow-empty accepts an empty home deliberately.
$S/selftest.sh                                     # prove that pair on a disposable fixture, bare shell

# --- change (the cheap path; see above) ---
$S/wt new TICKET-123                               # worktree + home; stdout IS the next move
$S/wt close TICKET-123                             # teardown through the gate

# --- change (the same thing, with the prose) ---
$S/new-change.sh TICKET-123                        # worktree on feature/TICKET-123
#   ...acts on the NEAREST enclosing git repo and prints which one and of what
#      kind (integration | constituent | standalone). From a constituent it
#      branches the CONSTITUENT; add --integration for the parent instead.
#   ...places the worktree BESIDE the outermost enclosing integration repo, so
#      a nested repo's worktree never lands in the parent's constituents/.
#   ...also bootstraps the worktree's OWN home; launch agents via
#      ../<repo>-TICKET-123/.skill-manager/bin/launch/claude
#      That first launch may be REFUSED with exit 8 — skill-manager gates a
#      launch from a home whose units changed until the change has been read.
#      Read it with `<that home>/bin/cli/skill-manager home drift`, then clear
#      it with the same command plus `--ack`. See references/skill-homes.md.
#   ...edit in the worktree, commit to the feature branch...
git -C <repo-root> merge --no-ff feature/TICKET-123   # bring it back to the integration main tree

# --- close ---
$S/close-change.sh TICKET-123                      # gate on `home close-out`, THEN remove the worktree
#   refuses (exit 4) while the worktree's home still holds unit work, naming
#   each blocker and the command that clears it. HomeCloseOut names a resolved
#   CLI path in every remedy (never a bare `skill-manager`, which on a machine
#   with an older release on PATH exits 2); this script supplies the environment
#   that resolution runs in — and NEVER names a home's own `bin/cli` pin in
#   $SKILL_MANAGER_CLI, which would tell that pin to exec itself forever.
#   --force discards deliberately. --dry-run works from inside the
#   worktree; a real removal from inside it refuses.
#   --into defaults to the project home the worktree was cloned FROM, wherever
#   you are standing when you run it.
#   Use this instead of a bare `git worktree remove`, which deletes the home
#   and any unpushed skill edit in it without a word.

# --- fan out ---
$S/propagate.sh TICKET-123                          # per-constituent: branch, commit, push, MR + one tracking issue
```

`propagate.sh` fans a **parent** change out to constituents. Sending a **skill**
edit an agent made inside its own home back to that skill's repo is a different
flow (push-back) that `propagate.sh` cannot do, because the home is gitignored
and never in the parent diff. `references/skill-homes.md` has the comparison;
confusing the two silently loses the skill edit at worktree teardown.

Always finish an onboarding or a propagation by running `scripts/verify.sh` and
confirming the parent tree is clean.
