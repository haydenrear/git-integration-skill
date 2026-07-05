# Propagation: fanning a merged change out to constituents

After a ticketed change is merged back into the integration **main** tree, each
constituent's real `.git` sees its slice of the diff. Propagation turns those
slices into per-constituent feature branches, MRs, and one tracking issue for a
downstream agent.

## Preconditions

- The change is **merged into the integration main tree** (not still in the
  worktree). Propagation reads each constituent's working-tree status in the main
  tree.
- Each constituent has been finalized (has its own `.git` + `origin`). Run
  `scripts/verify.sh` if unsure.

## Command

```bash
$S/propagate.sh TICKET-123            # DRY RUN: branch + commit per constituent, no network
$S/propagate.sh TICKET-123 --push     # also push feature branches
$S/propagate.sh TICKET-123 --push --mr  # also open MRs + file the tracking issue
```

Default is a dry run on purpose: it creates the `feature/TICKET-123` branch and
commit locally in each changed constituent but touches no remote, so you can
inspect before pushing.

## What it does, per changed constituent

1. Detects change via `git -C constituents/<name> status --porcelain` (skips
   unchanged constituents).
2. Creates or switches to `feature/TICKET-123`.
3. `git add -A` + commit the constituent's slice.
4. With `--push`: `git push -u origin feature/TICKET-123`.
5. With `--mr`: opens an MR against the constituent's default branch using the
   host CLI (`glab` for GitLab, `gh` for GitHub, chosen by `[integration].host`).

## The tracking issue

After the per-constituent MRs, propagation composes **one** issue for a
downstream agent:

- Title: `[TICKET-123] Integration change: run tests and manage merges`.
- Body: the list of constituents, their `feature/TICKET-123` branches, and MR
  links, plus instructions to run each constituent's tests together with the
  shared `test_graph` / `tla-spec-dev` checks and merge when green.
- Filed in `[integration].tracker` (e.g. `org/coordination-repo`) when set and
  `--mr` is used; otherwise written to `.integration/tmp/TICKET-123-issue.md`
  with instructions.

This is the handoff: your job ends at "branches pushed, MRs open, issue filed";
another agent picks up testing and merging.

## Idempotency and re-runs

- Re-running on the same ticket switches to the existing `feature/TICKET-123`
  branch and commits any further changes on top — safe to iterate.
- A constituent with no changes is skipped, so partial fan-outs converge.

## Host CLI setup

- GitLab: `glab auth login`; MRs/issues use the constituent's `origin`.
- GitHub: `gh auth login`; PRs/issues use the constituent's `origin`.
- Neither installed: propagation still branches/commits/pushes (if `--push`) and
  writes the issue body to a file with manual next steps.
