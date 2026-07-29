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

`bootstrap-home.sh` with no `--root` defaults to the **nearest enclosing git
toplevel**, which inside `constituents/deploy-helm` is deploy-helm — not the
integration parent. It used to walk up to `integration.toml` instead, so a bare
run from a constituent reported on (or created) the *parent's* home; usually the
parent's home already existed, so the run just said "already bootstrapped" and
the operator learned nothing.

A nested integration repo is not special-cased: it bootstraps at its own root
because that is the checkout an agent works in. Leaf-first ordering still
applies to *content* — a change to a leaf that the nested parent also contains
starts in the leaf, not in the duplicated nested path — and having a home per
checkout does not change that ordering at all.

## Which `skill-manager` a home uses

`home clone`, `home shims`, `home policy`, `home describe` and `exec` are newer
than the released CLI, so `bootstrap-home.sh` probes for a build that has them:
`SKILL_MANAGER_CLI`, then `PATH`, then a `skill-manager` the checkout itself
ships, then one the **enclosing integration repo** ships. That last entry is
what lets a constituent home find a capable build at all: bootstrapping
`constituents/deploy-helm` searched only deploy-helm, which ships no CLI, so it
either refused or ran on a `SKILL_MANAGER_CLI` the caller exported by hand and
that nothing recorded. The epic build lives in the parent. If nothing answers
`home clone`, it refuses **before** creating anything and tells you why — a
half-bootstrapped worktree is worse than none.

### The pin at `<home>/bin/cli/skill-manager`

That slot decides which build every launch from the home runs. The generated
launchers and `HomeDescriptor.resolveCli` both consult it before `PATH`, so
`bootstrap-home.sh` writes an **absolute pin** there naming the build it
resolved, and re-writes it on every run — including on an already-bootstrapped
home, without `--force`, because the operator has no way to know the slot is
wrong. A **frozen** home is never written, here as everywhere else.

Two ways the slot goes wrong, both measured on this repo:

- **Empty.** Every shim falls through to `PATH`, which here is the released
  0.19.2 — no `exec`, no `home`, no `home close-out`. The shim's
  `skill-manager exec …` printed "Unmatched arguments" and **exited 0**, so the
  launch silently did nothing.
- **Occupied by `home shims`' own generated shim.** That shim resolves via
  `PATH` by design (it is written to survive the home being copied elsewhere).
  Newer builds write it during the bootstrap, so a guard of "write the pin only
  if the slot is empty" saw an occupied slot and skipped — and the home pointed
  at the released CLI anyway. That is exactly the split observed here: the root
  home, bootstrapped before `home shims` filled the slot, carries the pin;
  every constituent home bootstrapped afterwards carried the generated shim.

So the pin is written when the slot is empty **and** in place of the generated
shim, which is not a tool anyone installed. Anything else in that slot is left
alone — it could be a real CLI dep. The pin deliberately has **no `PATH`
fallback**: falling through to an older CLI is the behaviour it exists to
remove, and that CLI answers unknown subcommands with top-level usage and exit
0, a downgrade that looks like success. If the pinned build disappears the shim
exits 127 and says how to re-pin.

Pinning the slot does **not** retire `close-change.sh`'s help-**text** probe.
`pick_cli` still falls through to `PATH` when the home's own slot cannot be
used, and `PATH` is still 0.19.2, so the exit-status trap is still reachable.

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
then deletes it. **Push back before teardown.** `close-change.sh` enforces the
first, weaker half of that (the edit reaches the *project home*) and will not
let a bare removal skip it; getting the edit to the skill's own repo is still
this push-back flow, and still yours to run.

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

Tear a worktree down with `close-change.sh`, never with a bare
`git worktree remove`:

```bash
# The gate runs BEFORE anything is deleted.
<this-skill>/scripts/close-change.sh TICKET-123

# At epic close, list what is left and close each one deliberately.
git -C <repo-root> worktree list
```

`close-change.sh` runs

```bash
skill-manager home close-out --home <wt>/.skill-manager \
                             --into <repo-root>/.skill-manager --json
```

and **refuses to remove the worktree** (exit 4) while that verdict is non-zero,
printing every blocking unit and the exact command that clears it. Run the
remedy, re-run the script, and the removal proceeds.

Why a script rather than a rule: `git worktree remove` succeeds with a home
inside it because the home is ignored, not untracked — which is also why the
ignore rules matter. It deletes the home **without asking**, and it succeeds
exactly as quietly whether the home held a week of skill edits or nothing.
Because the home is gitignored, the loss shows up in no diff, so "push back
before teardown" was a discipline that failed silently the first time anyone
forgot. The gate makes it a mechanism.

### The override, and why it exists

```bash
<this-skill>/scripts/close-change.sh TICKET-123 --force
```

`--force` still runs the gate and still prints the blockers; it only declines to
stop, and it says plainly that the work is being discarded. It exists because a
gate with no escape hatch does not stop the operator who genuinely wants to
throw a spike away — it routes them to `rm -rf` or `git worktree remove --force`
by hand, which skips this check *and* every other one. A named, loud override is
safer than an improvised one.

### How it degrades

The rule is: proceed only when the gate has actually established there is
nothing to lose.

| Situation | What close-change.sh does | Why |
|---|---|---|
| Worktree has **no home** (`--no-home`) | Removes it, saying the gate was skipped | Absence of a home really is proof there is no home-resident work |
| **No `skill-manager` with `close-out`** on `SKILL_MANAGER_CLI`, the home's `bin/cli`, the checkout, the enclosing integration repo, or PATH | **Refuses** | Absence of the tool is absence of *proof*, which is not the same thing. A gate that opens when it cannot check is not a gate |
| **Project home missing** (`--into` does not exist) | **Refuses** | The work has nowhere to go and there is nothing to compare against |
| Gate reports blockers | **Refuses**, printing each remedy | The case the gate exists for |

The capability probe reads the CLI's help **text**, not its exit status, for the
same measured reason `bootstrap-home.sh` does: the released 0.19.2 answers
`home close-out --help` by printing top-level usage and **exiting 0**. A
status-only probe would accept a CLI with no `close-out` at all and the teardown
would sail past a gate that never ran.

### Reconciling is not publishing

The gate's remedy (`home sync … --merge`) moves the work into the **project
home**, which is what stops the teardown destroying it. That is not the same as
getting the edit back to the skill's own repository — for that, see the
push-back flow in the table above. Clearing the gate makes the edit survive the
worktree; it does not make it survive the machine.

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

**These rules cover a home, not a worktree.** A ticket worktree of a nested
integration repo or of a constituent is a whole checkout, and no ignore rule in
the parent can safely name it: a glob matching
`constituents/meta-orchestrator-CO2` also matches `constituents/deploy-helm`.
Worse, the worktree's `.git` is a file, so a parent `git add -A` stages it as a
gitlink rather than as files. That is why `new-change.sh` puts such worktrees
**outside** the outermost integration repo instead — see
`references/worktrees.md`. Nothing needs adding to the parent's `.gitignore`
for it.

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
