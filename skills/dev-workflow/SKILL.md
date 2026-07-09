---
name: dev-workflow
description: "Enforce branch-based development on a project — every change flows issue → branch → milestone → green CI → merged PR, never directly on the default branch. Treats \"CI green\" as a quality gate: unit tests are mandatory for every behavior change and integration tests are extended whenever the project already has a suite, and cross-component coupling must be part of the intended architecture or documented in the wiki before merge. Multi-platform (GitHub via gh, Forgejo/Codeberg via fj + REST). Includes an `adopt` command that injects or updates the workflow mandate into a project's AGENTS.md so the rule is always-on for every session. Use when about to implement a feature or fix in a project that follows this workflow, when creating issues/branches/PRs, when watching CI before merge, when deciding whether a change is covered by tests or introduces coupling, or when asked to set up / apply / propagate / change the development workflow in a repo's AGENTS.md."
---

# Dev Workflow — Issue → Branch → Green CI → Merge

This skill governs how changes are made in a project: **no change lands on the
default branch directly**. Every change is a disciplined flow that ties a
branch to an issue, proves itself in CI, and only then merges. The cardinal
invariant, non-negotiable:

> **The default branch is only ever changed by a merged PR whose CI is green.
> Every change starts as (or resolves to) an issue, lives on a branch whose
> name contains the issue number, and is associated with a milestone.**

The process is **universal** along two axes:

- **Multi-platform** — the project can live on GitHub, Forgejo, Gitea, or
  Codeberg. Issue/branch/PR/milestone/CI/merge calls dispatch to the right
  host via [`scripts/host.sh`](scripts/host.sh). Adding a host = one case arm.
- **Multi-project** — one workflow, applied everywhere. Per-project
  differences (default branch, milestone convention, CI command) are *data*
  in that project's AGENTS.md, not logic in the skill.

There is a clean **separation of enforcement vs. procedure**, and it matters:

- **The rule** ("never commit to the default branch") is *always-on* because it
  lives in each project's `AGENTS.md`, which is read at the start of every
  session. The `adopt` command (below) puts it there.
- **The procedure** (how to find issues, create branches, watch CI, merge)
  lives *once* in this skill, loaded on demand. It evolves without touching
  every repo.

This is the same stable-mandate + evolving-procedure split the llm-wiki module
uses. Do **not** duplicate the full procedure into every project's AGENTS.md —
that recreates drift. `adopt` injects a short, stable, marker-delimited section
that points back to this skill.

## When to use this skill

- About to implement a feature, fix, refactor, or docs change in a project
  that follows this workflow (you will see the `## Development Workflow`
  section in its `AGENTS.md`).
- Need to create an issue, branch, or PR tied to an issue/milestone.
- CI ran on a PR and you need to decide merge vs. fix.
- A change is about to be considered "done" and you must confirm it is covered
  by tests and introduces no undocumented coupling (see [CI discipline](#continuous-integration-discipline)).
- "Set up / apply the development workflow to repo X" → run `adopt`.
- "Update / change the development workflow in repo X" → run `adopt` again
  (it is idempotent — it replaces the marker-delimited section).
- "Propagate a workflow change to all my projects" → re-run `adopt` in each.

## The change lifecycle (gate chain)

A change may merge only after **all** gates pass, in order. Each gate is
independently falsifiable.

1. **Issue exists** — an open issue (found or created) describes the change.
2. **Branch tied to the issue** — a branch whose name contains the issue
   number, created off the default branch. No work on the default branch.
3. **Milestone assigned** — the issue is associated with a milestone (current
   by convention, or per the project config).
4. **Change made on the branch** — commits reference the issue
   (`Refs #<n>` / `Fixes #<n>`).
5. **Change covered by tests** — unit tests are written for every behavior
   the change adds or alters (mandatory); if the project already has an
   integration-test suite, the change extends it for the paths it touches and
   never shrinks it. (See [CI discipline](#continuous-integration-discipline).)
6. **No undocumented coupling** — any coupling the change introduces between
   components is part of the intended architecture; if it is not, the coupling
   is recorded in the wiki via the `llm-wiki` skill **before** the PR merges.
7. **PR open** against the default branch.
8. **CI green** — every check succeeds, and "green" means the test suite
   passes, not merely that the build compiles. Red CI is fixed on the branch
   and re-pushed; it is **never** merged red.
9. **Merged** — only now does the default branch move. Branch deleted, issue
   closed.

**The single most important rule** (it has shipped broken `main` branches): a
direct commit/push to the default branch is forbidden unless the user gave an
explicit instruction that is recorded on the issue. When in doubt, branch.

## Continuous integration discipline

"CI green" is a quality gate, not a build-status light. CI is where the change
proves itself: it must be **covered by tests that actually run in CI**, and it
must not smuggle in coupling the architecture did not ask for. The depth on
both policies — what counts as coupling, how to detect it, how to wire tests
into CI — lives in [`references/ci-concepts.md`](references/ci-concepts.md).
This section states the rules.

### Tests protect the change

- **Unit tests are mandatory** for every behavior the change adds or alters.
  A change with no new/updated unit test is incomplete — the behavior it adds
  is unverified and regresses silently on the next merge.
- **Integration tests are extended whenever the project already has a suite.**
  If a suite exists, a change to an integrated path extends it; never let the
  suite go stale by adding behavior it does not exercise. If the project has
  no integration suite yet, do not invent one unprompted — surface the gap on
  the issue instead.
- **Tests must run in CI, not only locally.** A test not executed by CI does
  not protect the change — the next contributor's environment is different.
  The local run (`dw_run_tests`, below) is a fast feedback loop; CI is the
  authoritative one, and both must run the **same** suite.
- **How** to write good tests (behavior over implementation, vertical
  red-green slices) is the `tdd` skill's job — load it. This skill only
  enforces that tests *exist and run*.

### Coupling is intentional or documented

- **Avoid coupling** between components unless it is part of the intended
  architecture. "Coupling" is broad — build-time, runtime, data, and temporal
  (defined with per-language detection heuristics in
  [`ci-concepts.md`](references/ci-concepts.md)). A clean change keeps
  components independently buildable and testable.
- **If coupling is unavoidable** and not already part of the documented
  design, it **must be recorded in the wiki before the PR merges** — load the
  `llm-wiki` skill and add or update a page/ADR describing the coupling, why
  it is required, and the boundary it creates. Undocumented coupling is debt
  that compounds; documenting it ASAP turns an accident into a decision.
- A project may set `COUPLING_POLICY` (`strict` default / `documented-exceptions` /
  `legacy`) in its AGENTS.md config block; see `ci-concepts.md`.

## Operating commands

All paths resolve relative to this skill directory.

### `adopt` — inject or update the workflow in a project's AGENTS.md

```bash
bash scripts/adopt.sh [repo-path]   # default: current directory
```

- Auto-detects platform, default branch, CI-watch command, and test command
  from the repo.
- Wraps the section in `<!-- BEGIN dev-workflow -->` / `<!-- END dev-workflow -->`
  markers, so re-running `adopt` **replaces** the section with the current
  skill version (idempotent — this is how "change the workflow to the one in
  the skill" works).
- If a legacy unmarked `## Development Workflow` header exists, it converts it
  to the marker-managed form.
- If there is no `AGENTS.md`, it creates one with a minimal frontmatter.
- Update the workflow once in [`templates/agents-workflow-section.md`](templates/agents-workflow-section.md),
  then re-run `adopt` in each project to propagate. Never hand-edit the
  marker-delimited block in a project's AGENTS.md — change the template and
  re-adopt.

### Make a change (the per-change procedure)

From the project repo:

```bash
source "$(dirname "$(readlink -f "$0")")/scripts/host.sh"   # or source the absolute skill path
```

1. **Resolve the issue.** Search, else create:
   ```bash
   ISSUE=$(dw_find_issue "<short task description>")
   [ -z "$ISSUE" ] && ISSUE=$(dw_create_issue "<Title>" "<Body with acceptance criteria>")
   ```
2. **Resolve the branch.** Find by issue number, else create off the default branch:
   ```bash
   BRANCH=$(dw_find_branch_for_issue "$ISSUE")
   if [ -z "$BRANCH" ]; then
     BRANCH="feat/${ISSUE}-<slug>"
     dw_create_branch "$BRANCH"
   else git switch "$BRANCH"; fi
   ```
3. **Assign a milestone** (convention from the project's AGENTS.md):
   ```bash
   M=$(dw_resolve_milestone current)        # → "<id>:<title>"
   dw_set_milestone "$ISSUE" "${M%%:*}"
   ```
4. **Make the change** on the branch, **including its tests** (unit tests
   mandatory; extend integration tests if a suite exists — see [CI discipline](#continuous-integration-discipline)).
   If the change introduces coupling that is not part of the documented
   design, document it in the wiki now (`/skill:llm-wiki`) — before the PR.
   Commit with `Refs #$ISSUE` (or `Fixes #$ISSUE`).
5. **Verify locally, then push and open the PR** (run the same suite CI will):
   ```bash
   dw_run_tests || { echo "local tests red — fix before pushing"; exit 1; }
   git push -u origin "$BRANCH"
   dw_open_pr "$BRANCH" "$(dw_default_branch)" "<title>" "Closes #$ISSUE"
   ```
6. **Watch CI to green:**
   ```bash
   PR=$(dw_pr_number_from_branch "$BRANCH")
   dw_watch_ci "$BRANCH" || { echo "CI red — fix on the branch and re-push"; exit 1; }
   ```
7. **Merge only when green**, then clean up:
   ```bash
   dw_merge_pr "$PR" squash    # refuses to merge unless CI is green
   ```

The agent is not bound to these exact commands — they illustrate the dispatch.
Load [`references/platform-commands.md`](references/platform-commands.md) for
the raw per-platform forms and token env vars when adapting.

## What `adopt` injects

A short, stable section in the project's `AGENTS.md`:

- The cardinal rule (no default-branch commits; issue → branch → green CI → merge),
  plus the CI-discipline mandates (tests cover the change; coupling is
  designed or wiki-documented).
- A pointer to load this skill (`/skill:dev-workflow`).
- A **Project configuration** block with detected values: platform, default
  branch, branch-naming convention, milestone convention, CI-watch command,
  **test command** (a best-effort suggestion — the project owns the real value;
  see `ci-concepts.md`), **coupling policy**, merge method.
- A numbered "before every change" checklist mirroring the gate chain.

It does **not** inject the procedure body — that stays here. See
[`templates/agents-workflow-section.md`](templates/agents-workflow-section.md)
for the exact content (edit there, then re-`adopt`).

## Milestone resolution

- `current` (default) — the most recent open milestone on the forge.
- `none` — skip milestone assignment.
- `<exact title>` — match an open milestone by title.

If `current` finds no open milestone, ask the user whether to create one rather
than silently proceeding without a milestone.

## Relationship to other skills

This skill owns **enforcement** (the gates). It deliberately does not own the
adjacent depth, and cross-references instead of duplicating it:

- **`tdd`** — *how* to write the tests this skill requires (behavior over
  implementation, vertical red-green slices, mocking). Load it when writing
  the unit/integration tests for a change.
- **`llm-wiki`** — *how* to document unavoidable coupling in the project's
  persistent wiki (pages, ADRs, cross-references). Load it when a change
  introduces coupling that is not part of the documented design.
- **`fork-maintenance`** — *external* change: upstream moved, keep the fork's
  release branch green. Two-branch mirror/release topology.
- **dev-workflow** (this skill) — *internal* change: you're making a feature or
  fix in your own project. Issue → branch → CI → merge.

For forked repos `dev-workflow` and `fork-maintenance` both apply: this skill
governs your own feature branches; fork-maintenance governs the upstream-sync
PRs. All three share the CI-watch pattern (`gh pr checks --watch` / commit
status polling).

## Checklist before declaring a change "done"

- [ ] Open issue exists describing the change
- [ ] Branch name contains the issue number; branched off the default branch
- [ ] Issue associated with a milestone
- [ ] Commits reference the issue (`Refs`/`Fixes #<n>`)
- [ ] **Unit tests written** for every behavior added or altered (mandatory)
- [ ] **Integration tests extended** for the paths touched (if a suite exists)
- [ ] **Tests run in CI**, not only locally; CI is green on the PR (watched)
- [ ] **No undocumented coupling** — any new coupling is part of the design,
      or recorded in the wiki (`llm-wiki`) before merge, per `COUPLING_POLICY`
- [ ] PR open against the default branch
- [ ] Merged (squash by default); branch deleted; issue closed
- [ ] Default branch moved **only** via the merged PR — no direct push
