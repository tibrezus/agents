---
name: dev-workflow
description: "Enforce branch-based development — every change flows issue → branch → green CI → merged PR, never a direct commit to the default branch. Grounds changes in the project's documented design (wiki/llm-wiki); treats CI green as a quality gate (unit tests mandatory, integration suite extended); requires coupling to be intentional or wiki-documented. Multi-platform (GitHub via gh, Forgejo/Codeberg via fj). Ships `adopt` to inject the mandate into a repo's AGENTS.md. Use when implementing features/fixes, creating issues/branches/PRs, watching CI, or setting up the workflow in a repo."
---

# Dev Workflow — Issue → Branch → Green CI → Merge

This skill enforces one invariant: **the default branch only ever moves via a
merged PR whose CI is green — never a direct commit.** The gate chain below is
that invariant in operational, falsifiable form; every change must pass all
gates in order.

It is **universal**: multi-platform (issue/branch/PR/CI/merge calls dispatch to
the right host via [`scripts/host.sh`](scripts/host.sh)) and multi-project
(per-project differences — default branch, milestone/test/CI commands — are
*data* in that project's AGENTS.md, not logic here).

## When to use this skill

- About to implement a feature, fix, refactor, or docs change in a project
  that follows this workflow (you will see the `## Development Workflow`
  section in its `AGENTS.md`).
- Need to create an issue, branch, or PR tied to an issue/milestone.
- CI ran on a PR and you must decide merge vs. fix.
- A change is about to be considered "done" — confirm it is grounded in the
  documented design, covered by tests, and free of undocumented coupling.
- "Set up / change / propagate the workflow in repo X" → run `adopt`
  (idempotent; re-run in each project to propagate).

## The change lifecycle (gate chain)

A change may merge only after **all** gates pass, in order. Each gate is
independently falsifiable.

1. **Grounded in documented design — read before implementing.** Pull the
   llm-wiki repo, then read in this order (mandatory if the file exists):

   - `raw/arch/<project>/model.c4` — **architecture views + exported API surface**
     (every `// Exports:` line lists the functions/types each file provides).
     Read this BEFORE writing any code. If a capability you need is already
     exported, extend it — do not duplicate.
   - `raw/arch/<project>/rig.json` — component graph, dependencies, source files
   - relevant `wiki/` pages — decisions, trade-offs

   Implementation without this context is invalid. The model.c4 API surface
   is the primary tool against code duplication — use it.
2. **Issue exists** — an open issue (found or created) describes the change.
3. **Branch tied to the issue** — a branch whose name contains the issue
   number, created off the default branch. No work on the default branch;
   rebase an existing branch onto the default before starting.
4. **Milestone assigned** — the issue is associated with a milestone (current
   by convention, or per the project config).
5. **Change made on the branch** — commits reference the issue
   (`Refs #<n>` / `Fixes #<n>`). **No unnecessary duplication** — before
   writing a new function/type, verify it does not already exist in model.c4's
   `// Exports:` lines. Extend existing code when possible; only create new
   code when no existing export can be extended. If you create a near-duplicate,
   the PR must explain why reuse is not possible.

6. **Change covered by tests** — unit tests for every behavior added or
   altered (fast tier). Extend the integration suite where one exists.
   Performance/A-B tooling goes in the slow tier. (See
   [CI discipline](#continuous-integration-discipline).)
7. **No undocumented coupling** — any coupling the change introduces between
   components is part of the intended architecture; if it is not, record it in
   the wiki (`/skill:llm-wiki`) **before** the PR merges.
8. **PR open** against the default branch.
9. **CI green** — both tiers pass (fast: every push; slow: pre-merge or
   manual). Red is fixed on the branch, never merged red.
10. **Comment The Issue** — with the complete implementation.
11. **Merged** — only now does the default branch move. Branch deleted, issue
    closed.

**Hard rules** (they have shipped broken `main` branches):

1. A direct commit/push to the default branch is forbidden unless the user
   gave an explicit instruction that is recorded on the issue. When in doubt,
   branch.
2. Never force-push (`--force` / `--force-with-lease`) to the default branch
   on **any** platform — and on **Codeberg** this is absolute: the default
   branch (`main`/`master`) must never be overwritten. The only force-push
   the workflow ever performs is to a *feature* branch after rebasing it onto
   the default.
3. Always rebase the feature branch onto the default branch before merging,
   so the merge is conflict-free and linear.
4. Never change platform/repository rules (branch protection, force-push
   settings, merge-strategy constraints) to work around these rules. If a
   merge is blocked, the fix is on the branch, never in the platform config.

## Continuous integration discipline

"CI green" is a quality gate, not a build-status light. The change must be
**covered by tests that actually run in CI** and must not smuggle in coupling
the architecture did not ask for. Depth on both — what counts as coupling, how
to detect it, how to wire tests into CI — lives in
[`references/ci-concepts.md`](references/ci-concepts.md).

**Tests run in CI, on the right tier.** Unit tests are mandatory for every
behavior added or altered (fast tier, every push). Extend the integration
suite where one exists; if none exists, surface the gap — don't invent one
unprompted. Performance benchmarks, integration A/B, and long evaluations go
in the slow tier (pre-merge or `workflow_dispatch`). Tests that only run
locally are dead weight; tooling added in a PR must be wired into the matching
tier. *How* to write tests is the `tdd` skill's job. Depth:
[`references/ci-concepts.md`](references/ci-concepts.md).

**Coupling is intentional or documented.** Avoid coupling between components
unless it is part of the intended architecture (build-time, runtime, data,
temporal — heuristics in `ci-concepts.md`); a clean change keeps components
independently buildable and testable. If coupling is unavoidable and not part
of the documented design, record it in the wiki (`/skill:llm-wiki`) before the
PR merges — describing the coupling, why it is required, and the boundary it
creates. A project may set `COUPLING_POLICY` (`strict` default /
`documented-exceptions` / `legacy`); see `ci-concepts.md`.

## How this stays one workflow

The rule is split across two places so it is always-on without drifting:

- **Enforcement** ("never commit to the default branch", the gates, the
  CI-discipline mandates) lives in each project's `AGENTS.md`, read at the
  start of every session. The `adopt` command puts it there as a short,
  marker-delimited section that points back to this skill.
- **Procedure** (how to find issues, create branches, watch CI, merge) lives
  once here, loaded on demand. It evolves without touching every repo.

Do **not** duplicate the procedure into every project's AGENTS.md — that
recreates drift. Update it here, then re-run `adopt` to propagate.

## Operating commands

All paths resolve relative to this skill directory.

### `adopt` — inject or update the workflow in a project's AGENTS.md

```bash
bash scripts/adopt.sh [repo-path]   # default: current directory
```

Auto-detects platform, default branch, CI-watch command, and test command. It
wraps the section in `<!-- BEGIN dev-workflow -->` / `<!-- END dev-workflow -->`
markers, so re-running `adopt` **replaces** it (idempotent — this is how "change
the workflow to the one in the skill" propagates). It converts a legacy
unmarked `## Development Workflow` header to the marker form, and creates a
minimal `AGENTS.md` if none exists. It injects the gate chain + CI-discipline
mandates + a pointer to this skill + a **Project configuration** block (see
[`templates/agents-workflow-section.md`](templates/agents-workflow-section.md)
for the exact content — edit there, then re-`adopt`). Never hand-edit the
marker block; change the template and re-adopt.

### `review` — request automated PR review

```bash
dw_request_review "<pr-number>" [label]
```

Adds the `needs-review` label (default; override with the second arg) to a PR,
triggering the harmostes pr-review workflow on monitored repos. The workflow
clones the PR, evaluates it against this skill's gate chain, and posts a review
within ~5 min. Not part of the mandatory procedure — use it when you want an
automated review pass before merging. The label must exist on the repo
(one-time setup: `gh label create needs-review --color fbca04`).

### Make a change (the per-change procedure)

From the project repo:

```bash
source "$(dirname "$(readlink -f "$0")")/scripts/host.sh"   # or source the absolute skill path
```

1. **Consult the wiki** for the project's documented design
   (`/skill:llm-wiki` `consult`/`read`) — entities, concepts, ADRs.
2. **Resolve the issue.** Search, else create:
   ```bash
   ISSUE=$(dw_find_issue "<short task description>")
   [ -z "$ISSUE" ] && ISSUE=$(dw_create_issue "<Title>" "<Body with acceptance criteria>")
   ```
3. **Resolve the branch.** Find by issue number, else create off the default branch:
   ```bash
   BRANCH=$(dw_find_branch_for_issue "$ISSUE")
   if [ -z "$BRANCH" ]; then
     BRANCH="feat/${ISSUE}-<slug>"
     dw_create_branch "$BRANCH"
   else git switch "$BRANCH"; fi
   ```
4. **Assign a milestone** (convention from the project's AGENTS.md):
   ```bash
   M=$(dw_resolve_milestone current)        # → "<id>:<title>"
   dw_set_milestone "$ISSUE" "${M%%:*}"
   ```
5. **Make the change** on the branch, **including its tests** (unit mandatory;
   extend integration tests if a suite exists — see [CI discipline](#continuous-integration-discipline)).
   If the change introduces coupling that is not part of the documented design,
   document it in the wiki now (`/skill:llm-wiki`) — before the PR. Commit with
   `Refs #$ISSUE` (or `Fixes #$ISSUE`).
6. **Verify locally, then push and open the PR** (run the same suite CI will):
   ```bash
   dw_run_tests || { echo "local tests red — fix before pushing"; exit 1; }
   git push -u origin "$BRANCH"
   dw_open_pr "$BRANCH" "$(dw_default_branch)" "<title>" "Closes #$ISSUE"
   ```
7. **Watch CI to green:**
   ```bash
   PR=$(dw_pr_number_from_branch "$BRANCH")
   dw_watch_ci "$BRANCH" || { echo "CI red — fix on the branch and re-push"; exit 1; }
   ```
8. **Rebase onto the default branch, then merge only when green**:
   ```bash
   dw_rebase_onto_default            # rebase feature branch onto latest default
   dw_merge_pr "$PR" squash          # refuses to merge unless CI is green
   ```

The agent is not bound to these exact commands — they illustrate the dispatch.
Load [`references/platform-commands.md`](references/platform-commands.md) for
the raw per-platform forms and token env vars when adapting.

## Milestone resolution

- `current` (default) — the most recent open milestone on the forge.
- `none` — skip milestone assignment.
- `<exact title>` — match an open milestone by title.

If `current` finds no open milestone, ask the user whether to create one rather
than silently proceeding without a milestone.

## Relationship to other skills

This skill owns **enforcement** (the gates). It deliberately does not own the
adjacent depth, and cross-references instead of duplicating it:

- **`llm-wiki`** — the project's persistent knowledge base. Consult it
  **at the start** (`consult`/`read`) to ground a change in documented design;
  write to it **before merge** when a change adds coupling that is not part of
  that design (pages, ADRs, cross-references).
- **`tdd`** — *how* to write the tests this skill requires (behavior over
  implementation, vertical red-green slices, mocking). Load it when writing the
  unit/integration tests for a change.
- **`fork-maintenance`** — *external* change: upstream moved, keep the fork's
  release branch green (two-branch mirror/release topology).
- **`pr-review`** — *reviewer* counterpart to this skill's *initiator* role.
  When the `review` subcommand triggers the harmostes pr-review workflow, that
  workflow loads `pr-review` (not this skill) to evaluate the PR against the
  same gate chain from the reviewer's perspective.

For forked repos `dev-workflow` and `fork-maintenance` both apply: this skill
governs your own feature branches; fork-maintenance governs the upstream-sync
PRs. All three share the CI-watch pattern (`gh pr checks --watch` / commit
status polling).

The gate chain above is the done-checklist — a change is "done" only when every
gate has passed and the default branch has moved via the merged PR.
