# Ticketed multi-repo changes with worktrees

A cross-repo change is made once, in one parent worktree, against one ticket,
then fanned out. This is the composition idea: **multi-repo changes need a
ticket and a worktree, but no submodules** — the worktree is just files.

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

```bash
S=<this-skill>/scripts

# 1. Start the change. Requires a clean parent tree.
$S/new-change.sh TICKET-123
#    -> creates ../<repo>-TICKET-123 on branch feature/TICKET-123 (plain files)

WT=../<repo>-TICKET-123

# 2. Make the change across constituents in the worktree. Use the composed
#    skills here: write/adjust tla-spec-dev specs, spec unit tests, and
#    test_graph nodes alongside the code (see references/composition.md).

# 3. Commit once to the parent feature branch.
git -C "$WT" add -A
git -C "$WT" commit -m "TICKET-123: <cross-repo change summary>"

# 4. Bring it back into the integration main tree.
git merge --no-ff feature/TICKET-123
git worktree remove "$WT"

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

- **Keep the parent tree clean between changes.** `new-change.sh` refuses to
  start if it is dirty — commit or stash first.
- **One ticket per worktree.** Parallel tickets get separate worktrees and
  separate branches; they never share a worktree.
- **Do not run git inside the worktree's constituent directories** — there is no
  `.git` there, and you do not want one. Constituent-level git happens later in
  the main tree during propagation.
