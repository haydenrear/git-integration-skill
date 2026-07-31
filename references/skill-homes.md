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

### It is a convention, and it is enforced by tests rather than by the kernel

Say what that is plainly: **env vars and PATH order**. Nothing in it *stops* a
process writing to `~/.skill-manager`, to another project's home, or to
`~/.ssh`. A determined — or merely surprising — process can write anywhere the
operator can. Every leak this epic fixed was a process writing where nothing
stopped it.

What keeps the convention from regressing is not a boundary, it is that the
recipe is written down **once** and something fails when a second copy appears:

- `test_graph/sources/lib/SmEnv.java` in `skill-manager` is the only place that
  puts `SKILL_MANAGER_HOME`, `SKILL_MANAGER_INSTALL_DIR`, `CLAUDE_HOME`,
  `CLAUDE_CONFIG_DIR`, `CODEX_HOME` or `GEMINI_HOME` into a child environment.
  `sources/sandbox/SandboxEnvContract.java` is the oracle that keeps it the only
  one: it fails if any other file writes one of those, and it fails if a file
  that spawns the CLI does not reach `SmEnv` through its own `//SOURCES`
  closure. It plants five synthetic nodes every run and requires the detector to
  flag three and clear two, because a scan reporting "no violations" is worth
  nothing until it has been shown to report one. Before that existed the recipe
  lived in prose and four disagreeing copies, and **50 of 105** CLI env sites
  passed neither the agent variables nor `HOME` — one of those projections
  turned up in a live agent's available-skills list. It is 0 now.
- `LaunchEnv.requireClaudeRedirected()`, called by `ExecCommand` **before any
  child process is created**, refuses a launch whose Claude config directory
  resolves outside the home root. Skills load from that directory, so an
  unredirected one is not a warning, it is the wrong home.

A `sandbox-exec` (Seatbelt) layer was built to make this a real kernel boundary,
and it was **removed** (`skill-manager` #60, closed as not-planned; commit
`5f8d61e`). Three reasons, none of them a defect in the code: it is macOS-only,
so the guarantee existed on one platform and every other got the convention
anyway; it fought the harnesses it was protecting, because `claude` and `codex`
each spawn their own tooling and each met the profile somewhere different, so
the failure mode was a mid-session `EPERM` from a process skill-manager did not
write and could not explain; and its cache redirection gave every home a private
copy of stores the operator already had (`~/.cache/uv` alone is 51 GB here, and
this machine carries 35 homes). If you are looking for `SKILL_MANAGER_SANDBOX`,
`launch.sb` or `home shims --sandbox`: they do not exist. Nothing in this repo
offers a kernel boundary, and an earlier version of this page said otherwise.

### What a per-home clone actually costs

The three-tier model — a home per repository, a home per ticket worktree — is
affordable because a clone is **copy-on-write**, not a copy. `Files.copy` with
`COPY_ATTRIBUTES` takes the JDK's `clonefile(2)` path on APFS and the
destination shares the source's blocks. Measured on this host by free-space
delta on a dedicated volume: a `home clone` of a 189 MB home consumes **7.22 MB
— 3.8%**. Do not check this with `du`; it attributes shared blocks to both files
and reported 197.1 MB against 7.14 MB real.

`cache/`, `tmp/`, `logs/`, `venvs/`, `tools/` and `npm/` are skipped on top of
that (see the clone caveat further down).

### Package caches are shared; install targets are not

A home does **not** get a private package cache, and the distinction is not
read-only versus writable — nothing here is read-only, and an agent can still
`uv pip install` (`skill-manager` commit `8fddd6e`, `pm/PackageCaches.java`):

| | category | |
|---|---|---|
| `~/.cache/uv`, `~/.npm`, the pip wheel cache | content-addressed | **shared** — an entry is named by the hash of what it holds, so two homes racing to populate one key write the same bytes |
| `<home>/venvs`, `<home>/bin/cli`, `<home>/npm/<skill>`, `<home>/pm/<tool>`, `<home>/cache` | install target | **per-home** — mutable, and two homes pointed at one are a `--force` away from pulling the interpreter out from under each other |

Sharing the store only pays if materializing out of it is cheap, so `UV_LINK_MODE`
is chosen per filesystem: `clone` (reflink) when the store and the home can
share blocks, `hardlink` on a same-filesystem pair that cannot reflink, `copy`
across filesystems. Guessing wrong degrades rather than breaks — uv falls back
to copy and warns. Measured counter-example for why this matters: three
skill-script venvs in one home held 48,258 files across 48,258 distinct inodes,
1.6 GB with zero sharing.

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

## Which home a bootstrap clones FROM — and why it is not a choice

A worktree home and the project home it will be reconciled back into must be
**the same pair by construction**. `bootstrap-home.sh` and `close-change.sh`
both derive it from the checkout, through one function (`project_home` in
`lib.sh`):

| Checkout being bootstrapped | Cloned from | `close-change.sh --into` |
|---|---|---|
| A **linked worktree** | its project home — `<main working tree>/.skill-manager` | the same path |
| A **main working tree** | `$SKILL_MANAGER_HOME`, else `~/.skill-manager` | n/a — nothing closes it out |

`$SKILL_MANAGER_HOME` is **not** consulted for a worktree, deliberately. It used
to be the default for both tiers while `close-change.sh` defaulted `--into` to
`<repo-root>/.skill-manager`, and from a **bare shell** those name different
homes: measured, bootstrap cloned the operator's 845 MB global home into the
worktree and `home close-out` then blocked on **17 units before any work
existed**, printing a remedy that would have synced those global units *into*
the project home. The launch shims export `SKILL_MANAGER_HOME` and so never met
it; a human running the scripts by hand did (issue #50).

Two things therefore **refuse** rather than fall back:

- a worktree whose project has **no home yet** — bootstrap it at the project
  first, because a home cloned from anywhere else cannot be closed into the
  project;
- an explicit `--source` that is not the project home.

When the bootstrap refuses, `new-change.sh` **rolls the worktree and its branch
back**, so the operator's next command is the one the message names rather than
`worktree path already exists`.

`scripts/selftest.sh` proves both directions on a disposable fixture, from a
bare shell, against a decoy global home: it asserts by **unit name present /
absent** which home the worktree's copy came from, so a check that only looked
for the right unit could not pass a home that carried both. It also pins the
things that have no other coverage — that a ticket resolves to the same worktree
from a sibling worktree, that `--dry-run` from *inside* a worktree is answered
while a real removal from inside it refuses, that a refused bootstrap leaves no
worktree or branch behind, and that a remedy's conflicted-file list is not
mangled.

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
launchers read it and `HomeDescriptor.resolveCli` documents it as rule 3, and
since `skill-manager` issue #61 there is **no `PATH` fallback behind it** — the
launcher's last line is `exec "$cli" exec --home …` and the released 0.19.2 on
`PATH` has no `exec` subcommand, so a `PATH` branch could only ever produce
`Unmatched arguments: 'exec'`. A wrong or missing pin is therefore not a
downgrade, it is a home that cannot launch.

**`skill-manager home shims` writes it. `bootstrap-home.sh` does not.**

It used to, and that was right at the time: `home shims` wrote a
`PATH`-resolving shim, so homes bootstrapped through this script worked and
homes provisioned by `home shims` alone died at their last line — and because
this script masked the difference across a 24-repo onboarding fan-out, nobody
saw it. Commit `e65962e` fixed `home shims` to write the absolute pin itself,
derived from the build running it (`RunningCli`), and at that moment two writers
of one file stopped being a redundancy and became a race with one correct
answer.

This script's predicate lost that race. It decided whether to overwrite by
grepping the slot for the literal words `home shims` — which the **fixed**
generated file also contains. Measured: **17 of 25** homes had a correct pin
replaced by a pin to whatever `pick_cli` had chosen, and an 18th, written before
the script marked its own output, was not repaired at all. A predicate that keys
on prose cannot distinguish versions of the prose, which is why the fix
introduced a stable token — `skill-manager:cli-pin`, `LauncherShims.PIN_MARKER`,
on line 2 of the generated body.

So `ensure_cli_pin` **verifies, and delegates every repair to the one writer**:

| What is in the slot | What happens |
|---|---|
| The `skill-manager:cli-pin` marker | Read the pinned path, check it is executable, **stop**. The file is not this script's to rewrite. |
| Nothing | Re-run `home shims` |
| This script's own older pin (`git-integration-repo:cli-pin`, or the unmarked one before it) | Re-run `home shims` |
| A pre-#61 `PATH`-resolving shim (identified by its `command -v skill-manager`, since it carries no marker) | Re-run `home shims` |
| Anything else | Left alone — it could be a real CLI dep |

A pin whose target is **gone** is a refusal, not a repair: the script names the
missing path and the command that re-pins it (`home shims --home <store>`, run
from the build the home should use) and writes nothing. Substituting a CLI of
its own choosing is exactly what overwrote the 17.

This runs on an already-bootstrapped home without `--force`, because the
operator has no way to know the slot is wrong. A **frozen** home is never
written, here as everywhere else.

`home shims` itself **refuses rather than guessing**: `RunningCli` probes
`SKILL_MANAGER_CLI`, the running process's own command,
`SKILL_MANAGER_INSTALL_DIR` and the jar's location, and exits 127 having written
nothing when none answers. Every candidate `pick_cli` can return is a launcher
that exports `SKILL_MANAGER_INSTALL_DIR` before it execs the JVM, so the probe
succeeds — but `bootstrap-home.sh` prints that refusal verbatim rather than
reducing it to an exit code, because a `$CLI` that is not a launcher (a bare
`jbang SkillManager.java`) is a configuration mistake that deserves the CLI's
own diagnostic.

Pinning the slot does **not** retire `close-change.sh`'s help-**text** probe.
`pick_cli` still consults `PATH` when nothing else answers. From a bare shell
that is the released 0.19.2, so the exit-status trap is still reachable; from
inside an agent session it is *another home's pin*, because `skill-manager exec`
puts `<home>/bin/cli` first on the launch `PATH`.

#### The pin resolves itself through `$SKILL_MANAGER_CLI`, so do not point that at it

The generated body is `cli="${SKILL_MANAGER_CLI:-<absolute>}"` followed by
`exec "$cli" "$@"`. The variable is honoured **first** so a harness can redirect
the pin at a build of its own; the absolute default is what makes the pin a pin.
Naming the pin itself in that variable therefore throws away the target it
already knows and replaces it with a path to itself, and it re-execs **forever**
— no output, no exit, one process burning a core.

This is not hypothetical and it is not a corner: `pick_cli` in both
`bootstrap-home.sh` and `close-change.sh` *prefers* the home's own pin, and
`exec` puts a pin first on an agent session's `PATH`, so "the CLI I picked" and
"the CLI that must not be named in that variable" are usually the same file.
`close-change.sh` shipped exactly that pairing for one epic; see
[Teardown](#teardown-including-at-epic-close).

Rules for anything that invokes a chosen CLI:

- Decide **per candidate**. The variable is still what makes a remedy printed by
  a non-self-pinning launcher name a runnable path.
- **Scrub an inherited value**, do not merely refrain from setting one. The
  livelock does not care who exported it.
- Do not assume a candidate is safe because it came from `PATH`, and do not
  identify the hazard by path alone — inside an agent session the `PATH` answer
  is a pin belonging to a home the caller has never heard of. The reliable
  predicate is the candidate's own bytes: does it *expand*
  `$SKILL_MANAGER_CLI`?
- Do not rely on the CLI to defend itself. A guard added to the shim today is
  absent from every home already pinned by an older build, which is most of the
  homes a teardown will ever meet.

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

## The first launch is gated on change awareness (exit 8)

A bootstrapped home is not the same thing as a home you can launch from. There
is one more gate, it belongs to `skill-manager` rather than to these scripts,
and **it is the first thing an operator meets after `new-change.sh` returns**.

### What it is for

An agent reads a skill, then works for twenty minutes on the strength of it. A
sync, a pull, or a fresh clone replaces that skill underneath it. Nothing fails
and nothing warns, and the agent keeps following instructions that no longer
exist. The only boundary at which that can still be said out loud is between
"the home changed" and "something starts using the home" — which is a launch. So
a change to a home's units is recorded, and the next launch **refuses** until
somebody has read it.

### The operator-visible contract

- The refusal is **exit 8**, before anything is spawned, with a report of what
  moved. A gate that fired after the launch would have already failed to gate.
- Bare `home drift` prints the pending change; `home drift --ack` clears it and
  the next launch proceeds. `--ack-drift` on a single `skill-manager exec`
  acknowledges in passing. Run them through the home's own
  `bin/cli/skill-manager`, not a bare `skill-manager` — same reason every remedy
  on this page names a resolved path.
- Acknowledgement is the **only** thing that retires it. Re-recording a digest
  does not: the record is a fact about a change that happened, not a statement
  about whether the home is currently self-consistent.
- The launcher shims (`bin/launch/{claude,codex,gemini}`) take the gated path,
  deliberately. `bootstrap-home.sh`'s own internal `exec` calls pass
  `--ack-drift`, so **the bootstrap verifying a home cannot tell you whether the
  operator's next command will be refused**.

### When a freshly provisioned worktree hits it

Measured on a disposable fixture: a worktree cloned from a project home whose
content had moved since that home last recorded a digest comes up with a pending
record, and `skill-manager exec --home <wt>/.skill-manager -- …` exits 8 with
`refusing to launch: … changed and the change has not been read.` Cloned from a
home whose digest was current, the same sequence exits 0.

"Content moved since the last recorded digest" is the ordinary state of a home
anyone is working in, so **expect the gate on a new worktree and do not read it
as a broken bootstrap**. Do not, however, encode "always" into a checklist: the
gate is a function of the source home's recorded state, both outcomes are
correct, and the exact conditions are `skill-manager`'s to change. Read the
report, acknowledge it, launch.

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
                             --into <main-working-tree>/.skill-manager --json
```

`--into` is the project home the worktree's own home was **cloned from** — the
main working tree's, resolved by the same `project_home` helper
`bootstrap-home.sh` uses, so where the operator happens to be standing cannot
change the answer. It used to be `<checkout_root>/.skill-manager`, i.e. `$PWD`'s
nearest git toplevel, which from inside a sibling worktree named *that*
worktree's home.

Every remedy names a **resolved CLI path**, not a bare `skill-manager`. A bare
`skill-manager` on a machine with an older release first on PATH exits 2 for the
operator who copy-pastes it, and that is the machine this was found on.

The substitution happens in **one** place — `HomeCloseOut` builds the string and
names the CLI through `HomeDescriptor.resolveCli`, so `--json` and
`home close-out`'s own human output say the same thing. `close-change.sh`
renders the remedy verbatim and contributes only the *environment* that
resolution runs in.

It used to rewrite the string with a regex instead, and that was wrong twice: it
fixed only the `--json` consumer, and its token boundary matched inside
`skill-manager.toml` — the manifest every unit has, so the most likely conflicted
file there is — turning the operator's conflict list into a path in a different
repository. `scripts/selftest.sh` now asserts the remedy's **tail**, not just its
first token.

#### That environment is decided per candidate, and this is where it bit

`resolveCli`'s rules are, in order: `$SKILL_MANAGER_CLI`; the running process's
own command, when it looks like a launcher (a jbang/JVM process does not);
`<store>/bin/cli/skill-manager`; then a bare `skill-manager` off `PATH`. So when
`pick_cli` answers with a checkout's or the integration parent's launcher, the
export is what keeps a remedy off that last rule — and a bare `skill-manager`
here is the released 0.19.2, which exits 2 for whoever copy-pastes it.

For a while this page said the export *was* the script's contribution, full
stop. That stopped being true the moment `home shims` began writing a pin that
honours the same variable: `pick_cli`'s **preferred** candidate is the home's
own pin, and

```bash
SKILL_MANAGER_CLI="$CLI" "$CLI" home close-out …      # WRONG when $CLI is a pin
```

tells that pin to exec itself, forever. Measured on the epic #2 pilot: 7:03 of
CPU over 13:06 of wall clock from one teardown, silently — a teardown that hangs
is indistinguishable from a teardown that is slow, which on a fan-out means it
is indistinguishable from progress.

Neither change was wrong on its own. `home shims` was right to take ownership of
the pin; the script was simply still exporting from the era when it owned the
pin. They only met at the moment the pin started honouring the variable.

So `close-change.sh` now exports **only** to a candidate that does not resolve
itself through `$SKILL_MANAGER_CLI`, scrubs an inherited value for one that
does, and applies the same rule to its capability *probes* — with the variable
already set in an agent's environment, the hang landed inside `pick_cli`, before
the script had printed which CLI it was even trying. See
[the pin section](#the-pin-resolves-itself-through-skill_manager_cli-so-do-not-point-that-at-it)
for the predicate and why it reads the candidate's bytes rather than its path.

`selftest.sh` covers it under a hard time bound, because the regression's
signature is silence: an unbounded check against it does not go red, it goes
away. That section is also the only one that runs with `SKILL_MANAGER_CLI`
**unset** — with it set, `pick_cli` returns it from the first branch and a home's
own pin is never reached, which is how 26 green checks sat on top of this.

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
  until the snapshot was refreshed. Pin `SKILL_MANAGER_CLI` in the meantime — at
  a real `skill-manager` **launcher**, never at a home's `bin/cli/skill-manager`
  shim, which resolves itself through that same variable and would exec itself
  forever.
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
   remember and nothing to **export** — which is a statement about the
   environment, not a promise that the first launch will proceed. Expect the
   change-awareness gate (exit 8) on a new worktree and clear it with
   bare `skill-manager home drift`, then the same command plus `--ack`; see
   [the first launch is gated](#the-first-launch-is-gated-on-change-awareness-exit-8).
