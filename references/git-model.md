# The git model (why this works)

An integration repo puts many repos' files inside one parent repo **without
submodules**. This reference explains the mechanics, all of which are verifiable
with plain git, so you can trust and debug the scripts.

## The one rule

> Commit a constituent's files to the parent **while the constituent has no
> `.git`**. Restore its `.git` only afterward.

Git decides whether a subdirectory is "just files" or "an embedded repo
(gitlink)" **at `git add` time**, by looking for a `.git` inside it:

- `git add constituents/foo` when `foo/.git` **absent** → the parent stages each
  file as a normal blob (`100644`). The parent owns the content.
- `git add constituents/foo` when `foo/.git` **present** → the parent stages a
  single gitlink (`160000`) pointing at foo's commit. That is a submodule in all
  but name — the exact thing we must avoid.

Because onboarding deletes `.git` before committing, the parent index is full of
`100644` blobs. Restoring `.git` afterward does **not** rewrite those index
entries. Git now has per-file blobs for that path, so it keeps diffing the
files directly and never reinterprets the directory as a gitlink — even though a
`.git` is sitting right there.

## Verified behaviors

The following were confirmed empirically (git 2.50):

1. **Onboard order yields a clean tree.** clone → `rm -rf .git` → parent commit →
   `git init` + `remote add` + `fetch --all` + `reset --hard origin/<branch>` →
   `git status` in the parent is **clean**, because `reset --hard` restores
   byte-identical content to what the parent committed.

2. **Worktrees are pure files.** `git worktree add` from the parent checks out
   the parent's tracked blobs. Constituent directories in the worktree contain
   **no `.git`**. That is exactly "a worktree, it's just the files."

3. **Changes fan out as ordinary diffs.** After a worktree change merges into the
   parent main tree, each constituent's real `.git` reports its slice of the
   change as normal `M`/`??` status — ready to branch, commit, and push.

4. **New files stay files.** Creating a new file inside a constituent and running
   `git add -A` in the parent stages it as `100644`, not a gitlink. The parent
   remains the content owner.

5. **`reset --hard` is destructive and local to the constituent.** It only
   touches files under that constituent's directory, and it discards anything not
   on the upstream branch — including parent-injected files placed *inside* the
   constituent. This is why the integration `.gitignore` lives at the **parent
   root**, path-scoped (`constituents/*/target/`), never inside a constituent.

## Debugging checklist

- **A constituent shows as a submodule / a `160000` line appears.** Someone
  `git add`-ed the directory while `.git` existed. Fix: `git rm --cached
  constituents/<name>`, ensure `.git` is absent, re-add the files, commit, then
  restore `.git`. `scripts/verify.sh` flags stray gitlinks.
- **Parent won't go clean after finalize.** The constituent's upstream content
  differs from what was committed (wrong branch, or upstream moved between clone
  and finalize). Diff and re-onboard, or `reset --hard` to the intended ref.
- **A parent-root ignored file keeps reappearing inside a constituent.** Root
  `.gitignore` governs the *parent*; the constituent's own git still sees the
  file. Add it to the constituent's own `.gitignore` or `.git/info/exclude`.
