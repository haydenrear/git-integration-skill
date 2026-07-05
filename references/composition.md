# Composition: spec doubles, test graph, and deploy

When you scaffold an integration repo, you also scaffold the cross-cutting
tooling a multi-repo feature needs. These are **parent-managed workspaces at the
repo root** — tracked by the parent, never pushed into any constituent. The
`[compositions]` flags in `integration.toml` record which are enabled.

Each composition is delivered by an already-installed skill. This skill does not
reimplement them; it places them and tells you which skill to drive. Invoke the
named skill to do the actual scaffolding and generation.

## 1. spec-double-compiler (tla-spec-dev) — usually on

Features span constituents, so the specification that governs them is shared.
Scaffold tla-spec-dev spec doubles + spec unit tests at the parent root so a
worktree change can update the spec, the generated fakes, and the code together.

- Enabled by `[compositions].spec_double_compiler = true`.
- Suggested location: `specs/` at the repo root (add generated output dirs to the
  root `.gitignore`, e.g. `specs/**/_generated/`).
- **Drive the `spec-double-compiler` skill** to create the manifest, generate
  fakes/ports/validators, and wire spec unit tests. Point its generated Python
  doubles at the constituents that implement the ports.

Per-ticket: in the worktree, adjust the TLA+ spec and regenerate doubles
alongside the code change, so the spec and all constituents move together.

## 2. test-graph — usually on

Cross-repo behavior is validated with a `test_graph` project spanning
constituents (spec tests, and validation nodes that exercise several
constituents together).

- Enabled by `[compositions].test_graph = true`.
- Suggested location: `test_graph/` at the repo root (ignore `reports/`, `.runs/`
  via the root `.gitignore`).
- **Drive the `test-graph` skill** to scaffold the `test_graph` project, add
  JBang/uv nodes, compose graphs in `build.gradle.kts`, and run/aggregate. Add
  nodes that import from multiple `constituents/<name>` paths so a graph run
  covers the integrated behavior.

The tracking issue produced by `propagate.sh` asks the downstream agent to run
these `test_graph` graphs alongside each constituent's own tests.

## 3. deploy-helm (+ environment repo) — usually off

Only when this integration repo actually **deploys** its constituents together
to a test cluster (e.g. a set of apps released as a unit).

- Enabled by `[compositions].deploy_helm = true`.
- Add the environment repo as a constituent (`add-constituent.sh env
  git@host:org/environment.git main`) and/or scaffold deploy config under
  `deploy/` at the repo root (ignore `deploy/**/.rendered/`).
- **Drive the `deploy-helm` skill** for Helm charts, Kueue/ResourceFlavors, and
  cluster placement. Wire it so a `test_graph` validation node can deploy all
  constituents to the test cluster before exercising them.
- Skip this for most integration repos; leave the flag `false`.

## Where compositions live vs. constituents

| Thing | Location | Tracked by | Pushed to a constituent? |
|---|---|---|---|
| Constituent code | `constituents/<name>/` | parent **and** the constituent's own `.git` | yes, via `propagate.sh` |
| Spec doubles | `specs/` | parent only | no |
| test_graph project | `test_graph/` | parent only | no |
| deploy config | `deploy/` (+ env constituent) | parent only (env repo is a constituent) | env repo only |

Keeping compositions at the root means `propagate.sh` never tries to push them
into a code constituent — they are the integration layer, and they travel with
the parent repo.
