# Per-checkout Skill Manager homes in an integration repo

An agent working in an integration repo installs, edits, syncs and binds skills.
By default all of that lands in the operator's global `~/.skill-manager`, which
every other agent and every other worktree is also using. Parallel tickets
collide there, and an improvement an agent makes to a skill has no defined route
back to that skill's own repo.

So each checkout gets its **own** home:

```
<checkout>/.skill-manager/        the home (a clone of an existing home)
<checkout>/.skill-manager/home.runtime.json    the launch descriptor
<checkout>/.skill-manager/home.policy.toml     live | frozen
<checkout>/.skill-manager/bin/launch/{claude,codex,gemini}   launcher shims
<checkout>/.claude  <checkout>/.codex  <checkout>/.gemini    agent homes
```

One script does this, for both the repo root and every worktree:

```bash
<this-skill>/scripts/bootstrap-home.sh --root <checkout>
```

A repo that has been onboarded also carries a two-line locator,
`scripts/agent-home.sh`, so a person or agent in the checkout does not have to
know where the skill lives.

## Where the isolation actually comes from

`SKILL_MANAGER_HOME` alone is **not** enough, and assuming it is has cost this
epic real time:

- Skills load from Claude's config dir, so `CLAUDE_CONFIG_DIR` (and
  `CLAUDE_HOME`, which carries the same value) must be redirected too. Both are
  emitted by the descriptor; `skill-manager exec` refuses a launch where they
  still resolve outside the home.
- `skill-script` CLI deps are generated shell scripts with a home's absolute
  path in the body. No variable redirects those, so the launch PATH puts this
  home's `bin/` first **and removes other homes' `bin/`**.

All of that lives in `skill-manager exec` / `LaunchEnv`. The generated shims are
thin wrappers over it. **Launch agents through the shims** (or through
`skill-manager exec`) and you inherit the whole contract; export variables by
hand and you get the part you remembered.

## When to bootstrap

| Checkout | When | How |
|---|---|---|
| Repo root (the main tree, where constituent `.git`s live) | Once, at onboarding, and again after the home is deleted | `scripts/agent-home.sh` |
| A ticket worktree | Automatically, by `new-change.sh`, before it returns | nothing to do |
| A worktree made by hand (`git worktree add`) | Immediately after creating it | `bootstrap-home.sh --root <wt>` |
| A **nested** integration repo (a constituent that is itself one) | At its own root, as its own checkout | `bootstrap-home.sh --root constituents/<nested>` |
| A constituent you are working in directly | Only if you run an agent from inside it rather than from the parent | `bootstrap-home.sh --root constituents/<name>` |

A nested integration repo is not special-cased: it bootstraps at its own root
because that is the checkout an agent works in. Leaf-first ordering still
applies to *content* — a change to a leaf that the nested parent also contains
starts in the leaf, not in the duplicated nested path — and having a home per
checkout does not change that ordering at all.

## Which `skill-manager` a home uses

`home clone`, `home shims`, `home policy`, `home describe` and `exec` are newer
than the released CLI, so `bootstrap-home.sh` probes for a build that has them:
`SKILL_MANAGER_CLI`, then `PATH`, then a `skill-manager` the checkout itself
ships. If none of them answers `home clone`, it refuses **before** creating
anything and tells you why — a half-bootstrapped worktree is worse than none.

It then writes `<home>/bin/cli/skill-manager` pointing at that build. Both the
generated shims and `HomeDescriptor.resolveCli` already look there before
`PATH`, but nothing in skill-manager writes it, and without it a shim falls
through to whatever `skill-manager` is installed globally. Measured on a
released 0.19.2: the shim's `skill-manager exec …` printed "Unmatched arguments"
and **exited 0**, so the launch silently did nothing. Filling that slot is what
makes a home's shims work with no environment help at all.

## The one ordering rule

```
clone the home  ->  point SKILL_MANAGER_HOME at the clone  ->  everything else
```

`install`, `sync`, `bind`, `upgrade` and `project resolve` all write into
whatever `SKILL_MANAGER_HOME` names, and `project resolve` additionally writes a
child-home record and a projection ledger into that store. Run any of them
before the local home exists and they mutate the operator's global home. That is
why `bootstrap-home.sh` clones as its first command, exports
`SKILL_MANAGER_HOME` as its second, and re-asserts the export before every
mutating step. Do not reproduce the sequence by hand.

Two consequences worth stating:

- **A cloned home is not a `project resolve` child home.** Both want the path
  `<root>/.skill-manager`. Resolving a root against that root's own home makes
  the home its own child: measured, it exits 0 and destroys nothing (unit
  materialization no-ops when source and destination are the same real path),
  but it records a child home whose parent and child are one directory and it
  isolates nothing. Pick the clone for a checkout an agent works in; use
  `project resolve` when the parent home lives somewhere else. Either way,
  never resolve before the local home exists — that is the case where the
  child-home record and the ledger land in the operator's global home.
- **A clone is not a full copy.** `cache/`, `tmp/`, `logs/`, `venvs/`, `tools/`
  and `npm/` are skipped (they are re-derivable, and copying `tools/` costs
  1.3 GB). Any CLI shim whose target was under one of those is reported by the
  clone and re-provisioned with
  `SKILL_MANAGER_HOME=<store> skill-manager sync --force-scripts`.

## `propagate.sh` and skill push-back are different flows

Confusing them loses work. They move different things in different directions.

| | `propagate.sh` | Skill push-back |
|---|---|---|
| What moves | A **parent** change: the diff you committed to the integration feature branch | A **skill** change: an edit an agent made to a unit inside its own home |
| From | The integration repo's merged feature branch | `<checkout>/.skill-manager/skills/<unit>/` |
| To | Each affected constituent's own repo: `feature/<TICKET>` + MR + one tracking issue | That skill's own repo, trunk-style, via `skill-manager project sync` (see the skill-manager and skill-publisher skills) |
| Trigger | You merged a cross-repo change | An agent improved a skill while using it |
| Ignores the other's state | Yes — it fans out the parent diff and knows nothing about homes | Yes — it pushes a unit and knows nothing about the parent branch |

A skill's files inside a home are **not** part of the parent diff: the home is
gitignored, so `git add -A` in the worktree never sees them and `propagate.sh`
can never carry them. If an agent edits a skill in its home and you only run
`propagate.sh`, the edit is not published anywhere — and `git worktree remove`
then deletes it. **Push back before teardown.**

The reverse mistake is just as bad: a skill lives in its own repo, so editing
its copy under `constituents/<skill>/` and propagating that is the *parent*
flow, and it is the right one when you are changing the skill as a constituent
of this repo. Decide which artifact you changed — a repo's files, or a unit
inside a home — and use the matching flow.

## Policy: `live` and `frozen`

`bootstrap-home.sh` declares `live` by default: the home may be synced,
upgraded, and pushed back from. `--policy frozen` declares the opposite, for a
home whose contents are evidence (an experiment run, a bisect checkpoint).

A home that is **already frozen is never modified** — not re-shimmed, not
re-described, not re-baselined — and `bootstrap-home.sh` reports the skip
instead of "repairing" it. Clone a frozen home to get a live copy; the original
stays as it was.

## Teardown, including at epic close

```bash
# 1. Push back anything the agent changed in the worktree's OWN home first.
#    (skill-manager project sync / the skill-publisher flow — not propagate.sh)
# 2. Then the ordinary worktree teardown; the home goes with the directory.
git -C <repo-root> worktree remove ../<repo>-TICKET-123
# 3. At epic close, list what is left and remove each one deliberately.
git -C <repo-root> worktree list
```

`git worktree remove` succeeds with a home inside it because the home is
ignored, not untracked — which is also why the ignore rules matter. It deletes
the home without asking, so step 1 is not optional.

The global `~/.skill-manager` is never a teardown target. Nothing in this flow
writes it; `bootstrap-home.sh` refuses outright if a target home would resolve
to it.

## Ignoring the homes (parent root only)

Add to the **parent root** `.gitignore` — never to a file inside a constituent
(`INTEGRATION.md` rule 2):

```gitignore
/.skill-manager/
/.claude/
/.codex/
/.gemini/
constituents/*/.skill-manager/
constituents/*/.claude/
constituents/*/.codex/
constituents/*/.gemini/
```

Then **prove it**, because a constituent's own `.gitignore` is more specific
than the root's and a negated rule in it wins:

```bash
git check-ignore -v .skill-manager/home.runtime.json
for d in constituents/*/; do git check-ignore -v "$d.skill-manager/x" || echo "NOT IGNORED: $d"; done
```

Every path must be reported as ignored. It is fine for the source to be a
constituent's own `.gitignore` — that means it already agrees. What must never
happen is a path reported as not ignored, or a home showing up in
`git status`: committing a home would put another machine's absolute paths, and
a copy of every installed unit, into the parent repo.

## Bootstrapping the repo that ships the bootstrap

An integration repo that contains the CLI or the skill implementing this
mechanism has a genuine circular dependency the first time: the worktree that
installs the hook must itself be created the old way (`git worktree add`) and
have its home bootstrapped by hand inside it. That is expected once, not a bug
to chase.

Two measured consequences worth knowing before you rely on the in-repo copy:

- **A parent worktree carries the parent's *committed snapshot* of a
  constituent**, not that constituent's current branch. On this repo the
  snapshot's `skill-manager` had no `home` command at all while the main tree's
  working copy did, so a worktree could not bootstrap from the repo's own CLI
  until the snapshot was refreshed. Pin `SKILL_MANAGER_CLI` in the meantime.
- **`new-change.sh` requires a clean parent tree**, and a parent mid-epic is
  often dirty with constituent drift. Then the worktree is created by hand and
  `bootstrap-home.sh --root <wt>` run against it — the same two steps the hook
  performs, in the same order.

## Onboarding any integration repo

1. Onboard the repo the ordinary way (`references/onboarding.md`).
2. Add the ignore rules above to the parent root `.gitignore`, then verify with
   `git check-ignore -v`.
3. Write a `skill-project.toml` at the root declaring the units this repo's
   agents need. It is portable intent — the realized state is the home.
4. Copy `scripts/agent-home.sh` (the locator) into the repo root.
5. Run `scripts/agent-home.sh` once for the main tree.
6. From then on, `new-change.sh` gives every worktree its own home. Nothing to
   remember and nothing to export.
