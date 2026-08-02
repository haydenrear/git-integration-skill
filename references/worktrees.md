# Ticketed multi-repo changes with worktrees

A cross-repo change is made once, in one parent worktree, against one ticket,
then fanned out. This is the composition idea: **multi-repo changes need a
ticket and a worktree, but no submodules** — the worktree is just files.

## If you are here to create a worktree, you do not need this page

```bash
<this-skill>/scripts/wt new   TICKET-123
<this-skill>/scripts/wt close TICKET-123
```

Run it from anywhere inside the repo you want branched. It resolves the repo,
creates the worktree, gives it its own Skill Manager home, and prints the
contract. **Everything an agent needs next is on stdout**, one key per line,
every value a path or a command that runs:

| Key | What it is |
|---|---|
| `WORKTREE` | where to edit |
| `BRANCH` | what was branched, from what, in which repo and of what kind |
| `LAUNCH` | starts an agent bound to **this worktree's** home |
| `IF-EXIT-8` | clears the first-launch drift gate (see below) — run it only if `LAUNCH` refuses with exit 8 |
| `CLOSE` | tears the worktree down through the close-out gate |
| `PROPAGATE` | the constituent fan-out; printed only for an `integration` repo |

A refusal is two lines — `FAILED` (what) and `FIX` (one command that runs) —
with the full explanation on stderr. `--verbose` shows that explanation on a
successful run too.

**The keys are the interface, not the path.** git-issue-skill#4 asks whether
worktree provisioning should live in `git-issue` or in `skill-manager` rather
than here; a caller that reads these keys keeps working across such a move, and
one that parses the prose never could. If you add a key, add it to this table.

The rest of this page is the *explanation*: which repo gets branched and why,
where the worktree may live, and what the gates are for. It is worth reading
once. It is not worth reading before every ticket, and the whole point of `wt`
is that you do not have to.

## Which repo `new-change.sh` acts on, and where the worktree goes

Both of these were wrong in ways that produced no error message, so they are
stated before the flow rather than after it.

**The repo is the nearest enclosing git toplevel**, and the script prints it.
A constituent has its own real `.git`, so run from `constituents/deploy-helm`
the answer is deploy-helm — not the integration parent that tracks its files.
Three shapes, all supported:

| Where you run it | `kind` | What is branched | `propagate.sh` after? |
|---|---|---|---|
| A checkout holding `integration.toml` | `integration` | that repo; constituent files are plain files in the worktree | yes |
| A **nested** integration repo (`constituents/meta-orchestrator`) | `integration` | the nested repo — it is one in its own right | yes, within it |
| An ordinary constituent (`constituents/deploy-helm`) | `constituent` | the constituent | **no** — nothing beneath it to fan out to |
| A repo outside any integration repo | `standalone` | that repo | no |

Standing in a constituent and wanting the *parent* is a real case:
`new-change.sh TICKET --integration` targets the enclosing integration repo
without a `cd`.

**The worktree is placed beside the OUTERMOST enclosing integration repo**,
never inside one. For a top-level repo that is its own parent directory, which
is where worktrees have always gone. For anything living inside an integration
repo it is the difference between a clean parent and a broken one:

```
constituents/meta-orchestrator  ->  ../meta-orchestrator-TICKET-123
constituents/deploy-helm        ->  ../deploy-helm-TICKET-123
```

A worktree under `constituents/` is not merely untracked noise in the parent's
`git status`. A worktree's `.git` is a **file**, so a parent `git add -A` stages
the whole directory as a gitlink (mode `160000`) — exactly the submodule
`INTEGRATION.md` rule 1 forbids. Nor can the parent's `.gitignore` fix it: any
glob wide enough to match `constituents/meta-orchestrator-CO2` also matches real
constituents named `deploy-helm` or `hyper-experiments`. So the worktree goes
where the parent cannot see it, and `new-change.sh` refuses outright if a
worktree path would land inside an integration repo's working tree.

`close-change.sh` derives the path from the same helper, so it closes exactly
what `new-change.sh` opened, from either repo.

## Why a worktree

- The parent worktree checks out constituent files as **plain files** — no
  constituent `.git` inside it (verified; see `references/git-model.md`). You can
  edit `constituents/service-a/...` and `constituents/shared-lib/...` in one
  place and commit them together.
- It isolates the change on `feature/<TICKET>` without disturbing the main
  integration tree (where each constituent's real `.git` lives).
- It maps cleanly to the fan-out: one parent feature branch → one feature branch
  per affected constituent, all named `feature/<TICKET>`.

## Flow

Written out in full, with the prose kept. `wt new TICKET-123` is steps 1 and 1b
in one command with the narration suppressed, and `wt close TICKET-123` is 4b.

```bash
S=<this-skill>/scripts

# 1. Start the change. Requires a clean tree in the repo it picks — and it
#    prints which repo that is, and of what kind, before doing anything.
$S/new-change.sh TICKET-123
#    -> creates <repo>-TICKET-123 on branch feature/TICKET-123, beside the
#       outermost enclosing integration repo (plain files)
#    -> and gives it its OWN skill-manager home before returning
#    -> add --integration to target the parent from inside a constituent

WT=../<repo>-TICKET-123

# 1b. Launch agents through the worktree's own home, not the global one:
$WT/.skill-manager/bin/launch/claude
#    See references/skill-homes.md. Nothing to export; the shim applies the
#    whole launch contract.
#
#    That first launch may still be REFUSED with exit 8: a home whose units
#    changed gates the next launch until the change has been read. It is a
#    working home, not a broken one. Read and clear it, then launch again —
#    through the home's OWN cli entrypoint, since a bare `skill-manager` may be
#    an older release:
$WT/.skill-manager/bin/cli/skill-manager home drift
$WT/.skill-manager/bin/cli/skill-manager home drift --ack

# 2. Make the change across constituents in the worktree. Use the composed
#    skills here: write/adjust tla-spec-dev specs, spec unit tests, and
#    test_graph nodes alongside the code (see references/composition.md).

# 3. Commit once to the parent feature branch.
git -C "$WT" add -A
git -C "$WT" commit -m "TICKET-123: <cross-repo change summary>"

# 4. Bring it back into the integration main tree.
git merge --no-ff feature/TICKET-123

# 4b. Close the worktree THROUGH THE GATE, not with a bare `git worktree remove`.
#     close-change.sh runs `skill-manager home close-out` first and refuses
#     (exit 4) while the worktree's own home still holds unit work, printing
#     each blocking unit and the command that clears it.
$S/close-change.sh TICKET-123
#     -> blocked? run the remedy it prints, then re-run.
#     -> really want to throw the work away? $S/close-change.sh TICKET-123 --force

# 5. Fan out to the constituents.
$S/propagate.sh TICKET-123 --push --mr
```

## Tickets

Every change is tied to a ticket id (`TICKET-123`), which becomes:

- the parent branch `feature/TICKET-123`,
- each constituent branch `feature/TICKET-123`,
- the MR title prefix, and
- the tracking issue title.

This keeps a single change traceable across the parent and every constituent.
Create the ticket in your tracker first; `[integration].tracker` in
`integration.toml` is where `propagate.sh` files the coordinating issue.

## Notes

- **Keep the tree clean between changes.** `new-change.sh` refuses to start if
  the repo it picked is dirty — commit or stash first. The refusal names that
  repo, because "not clean" printed against files you did not expect is the
  first sign it picked one you did not mean.
- **Read the `repo:`/`kind:` lines it prints.** They are the whole defence
  against a wrong target: the failure this replaced was silent and exited 0.
- **One ticket per worktree.** Parallel tickets get separate worktrees and
  separate branches; they never share a worktree.
- **Do not run git inside an integration worktree's constituent directories** —
  there is no `.git` there, and you do not want one. Constituent-level git
  happens later in the main tree during propagation. (A `constituent` worktree
  is an ordinary checkout of one repo and has no such rule.)
- **The worktree's home dies with the worktree.** `git worktree remove` deletes
  `<wt>/.skill-manager` too, including any skill edit an agent made in it that
  was never pushed back. `close-change.sh` is the reason you no longer have to
  remember this: it asks `home close-out` first and refuses while there is
  anything to lose. Reconciling into the project home is a different flow from
  `propagate.sh`; see `references/skill-homes.md`.
- **`--no-home` exists but costs you the isolation.** A worktree created with it
  runs agents against the global home, which is what the per-worktree home is
  there to prevent. Use it only for a worktree no agent will run in.
