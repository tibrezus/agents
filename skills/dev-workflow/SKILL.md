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

1. **Grounded in documented design — load architectural context before
   implementing.** The purpose: insert the most compressed, accurate picture
   of the project's architecture into context so the implementation follows
   the project's structure and best practice. If the project has an
   architecture graph (`rig.db` — via the [llm-wiki](/skill:llm-wiki)
   pipeline, a wiki checkout, or committed in-repo), load in this order
   (each item: mandatory if it exists):

   1. **`rig overview`** — the whole graph in ~400 tokens: every build-target
      component, its type, file count, dependency edges, symbol counts.
      (pi `rig` tool, auto-discovers `raw/arch/<project>/rig.db`;
      elsewhere: `python3 .llm-wiki/.github/actions/repo-map/rig-query.py
      <rig.db> overview`.)
   2. **Targeted drill-down into the area you're touching** —
      `rig component <name>` (deps + files + doc comments),
      `rig search '<term>*'` (FTS5 symbol search → exact `file:line`),
      `rig deps <name> --reverse` (blast radius). Hundreds of tokens, not
      thousands.
   3. **project's own wiki `Architecture.md`** — the merged human page
      (rendered views, source map, LikeC4 model, CI registry),
      CI-regenerated on every push: **authoritative** for architecture.
   4. relevant llm-wiki `wiki/` pages — decisions, trade-offs, the *why*.

   Implementation without this context is invalid. **The graph is the
   primary tool against code duplication**: before writing a new
   function/type, `rig search` for the name/capability — if it already
   exists as an export, extend it instead of duplicating.
2. **Issue exists** — an open issue (found or created) describes the change.
3. **Branch tied to the issue** — a branch whose name contains the issue
   number, created off the default branch. No work on the default branch.
4. **Milestone assigned** — the issue is associated with a milestone (current
   by convention, or per the project config).
5. **Change made on the branch** — commits reference the issue
   (`Refs #<n>` / `Fixes #<n>`). The implementation is **optimal** (hard
   rule 5): root cause, right abstraction, no workarounds. **No unnecessary
   duplication** — before writing a new function/type, `rig search` the
   graph for the capability; extend what exists, and justify a near-duplicate
   on the PR if reuse is impossible.

6. **Change covered by tests** — unit tests for every behavior added or
   altered (fast tier); extend the integration suite where one exists. Every
   test and tool is **wired into CI** — never a throwaway script (see [CI
   discipline](#continuous-integration-discipline)). For
   `SAFETY_LEVEL: mcdc` projects, also achieve MC/DC
   ([`references/mcdc.md`](references/mcdc.md)).
7. **No undocumented coupling** — any coupling the change introduces between
   components is part of the intended architecture; if it is not, record it in
   the wiki (`/skill:llm-wiki`) **before** the PR merges.
8. **Simplification pass** — re-read the full diff and ask "can this be
   simpler?" Remove dead code, redundant abstractions, speculative
   generality. A complex implementation is not optimal when a simpler one
   exists (hard rule 5). Runs **before pushing to CI** and is re-checked
   **before merging**.
9. **PR open — only after the local CI mirror is green.** The project's
    fast-tier workloads run locally first (build, lint, unit/targeted tests
    — `dw_run_tests` + the project's lint) and the PR opens **once**, when
    all of it passes. Opening a PR is the expensive step: it triggers CI on
    the forge, so early scaffolding stays on the branch with the local
    loop.
10. **Fast CI green on every push** — lint/build/unit/targeted tests. Red
    is fixed on the branch, never merged red.
11. **Full pipeline green on the head SHA** — at ready declaration: rebase
    onto the default branch, then set the `full-pipeline` label on the PR
    (`dw_trigger_full_pipeline`; a human ticking the label in the UI is
    equivalent), which runs the full pipeline on that head SHA; watch it
    green. Any later push invalidates it — re-trigger (the helper toggles
    the label). Skipped when no full workflow is configured (the fast tier
    *is* the pipeline).
12. **Adversarial review APPROVE on the head SHA** — `dw_request_review`
    (guarded ingress: refuses heads without a green pipeline) triggers the
    `pr-review` skill; APPROVE must land at the same head SHA.
13. **Merge-ready, then merged** — `dw_merge_readiness` verifies fast +
    full + review + rebase at one frozen head SHA; only then `dw_merge_pr`.
    Branch deleted; the merged PR (`Closes #n`) closes the issue and is the
    implementation record — no separate issue comment required.

**Two-phase readiness:** development pushes run the fast tier only; the
full pipeline + adversarial review run **once, at ready declaration, on the
final head SHA** (rebase *before* triggering). Statuses bind to SHAs, so any
push after declaration — source or docs — re-opens the path; a red pipeline
means back to developing, never into review. Depth:
[`references/ci-concepts.md`](references/ci-concepts.md) §1.3.

## Hard rules

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
5. Only optimal implementations are accepted. Workarounds at any level
   (code, tests, CI, tooling, configuration) are forbidden — they defer
   problems, they don't solve them. A complex implementation is not optimal
   when a simpler alternative exists — simplicity is a requirement, not a
   preference. If a proper fix is genuinely blocked, surface the blocker on
   the issue rather than routing around it silently. "It works" is not the
   bar; "it is correct and well-structured" is.

## Continuous integration discipline

"CI green" is a quality gate, not a build-status light. The change must be
**covered by tests that actually run in CI** and must not smuggle in coupling
the architecture did not ask for. Depth on both — what counts as coupling, how
to detect it, how to wire tests into CI — lives in
[`references/ci-concepts.md`](references/ci-concepts.md).

**CI instrumentation evolves with the project — there is no throwaway test.**
Run the project's own runner locally (`make test`, `npm test`, `scripts/test`
— whatever CI runs) and wire every new test or tool into CI; before creating
a component (tool, CI job, wiki page), check that an equivalent doesn't
already exist and extend it instead. Unit tests are mandatory (fast tier,
every push); benchmarks and long evaluations go in the slow tier (dispatched
once at ready declaration — gate 11) as reusable jobs. A throwaway script
leaves CI frozen while the code moves on — it looks like coverage but
protects nothing. Depth: [`references/ci-concepts.md`](references/ci-concepts.md) §1.

**Safety-critical boolean logic requires MC/DC.** When the project declares
`SAFETY_LEVEL: mcdc`, every boolean decision in changed code must achieve
Modified Condition/Decision Coverage — each condition proven to independently
affect the outcome. This is a deterministic pipeline (spec-driven, not LLM
reasoning). Load [`references/mcdc.md`](references/mcdc.md) when
`SAFETY_LEVEL: mcdc` is set or when a change touches complex boolean
decisions.

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

### `review` — request the adversarial review (gate 12)

```bash
dw_request_review "<pr-number>" [label]
```

**Guarded ingress:** refuses unless the pipeline is green at the PR's head
SHA (full pipeline, or fast tier when none is configured). On success it
adds the `needs-review` label (created if missing — no per-repo setup).

The label is the single portable trigger: the harmostes **Review-Ready
Gate** (event-armed, ADR-0006) wakes on the label webhook and re-verifies
label ∧ merge-rule greenness itself — verdicts land within minutes, not a
10-minute poll. **The review methodology and the verdict contract are
owned by the `pr-review` skill** (stances, pillars, trailer format, label
lifecycle) — this skill only requests and consumes; it never duplicates
those rules. The verdict lands as a comment ending in the trailer
`<!-- pr-review: <DECISION> @ <sha> -->` — `dw_wait_review` polls for it,
`dw_merge_readiness` binds it to the head SHA.

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
5. **Make the change** on the branch, **including its tests** — consolidate:
   extend existing tooling, CI jobs, and wiki pages instead of creating
   duplicates (see [CI discipline](#continuous-integration-discipline)). If
   the change introduces coupling not part of the documented design, document
   it in the wiki now (`/skill:llm-wiki`). Commit with `Refs #$ISSUE`.
6. **Simplification pass** — re-read the full diff (`git diff` against the
   default branch). Ask: "can this be simpler?" Remove dead code, collapse
   redundant abstractions, eliminate speculative generality. If you change
   code, re-verify locally before proceeding. (Gate 8; hard rule 5.)
7. **Green locally first — the PR is the expensive step:**
   ```bash
   dw_run_tests || { echo "local tests red — fix before pushing"; exit 1; }
   ```
   Run the project's fast-tier workloads locally (build + lint +
   `dw_run_tests`) until green and the simplification pass (gate 8) is
   done. Opening a PR consumes CI on the forge — push and open it **once**,
   when the local mirror is green:
   ```bash
   git push -u origin "$BRANCH"
   dw_open_pr "$BRANCH" "$(dw_default_branch)" "<title>" "Closes #$ISSUE"
   ```
8. **Fast CI confirms on a clean runner** (it re-runs what you ran
   locally):
   ```bash
   dw_watch_ci "$BRANCH" || { echo "fast CI red — fix on the branch and re-push"; exit 1; }
   ```
9. **Declare ready — full pipeline, review, merge:**
   ```bash
   PR=$(dw_pr_number_from_branch "$BRANCH")
   dw_rebase_onto_default "$BRANCH"        # hard rule 3 — BEFORE triggering
   dw_trigger_full_pipeline "$PR"          # gate 11: sets the full-pipeline label (no-op if none configured)
   dw_watch_full_pipeline "$BRANCH" || { echo "full pipeline red — fix, re-push, re-declare"; exit 1; }
   dw_request_review "$PR"                 # gate 12 — refuses unvalidated heads
   dw_wait_review "$PR"                    # blocks for the verdict trailer
   dw_merge_pr "$PR" squash                # gate 13 — refuses unless merge-ready
   ```
   A REQUEST_CHANGES verdict means: address the findings, then re-run this
   step — the new head SHA re-opens gates 11 and 12.

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

- **`llm-wiki`** — the project's persistent knowledge base **and the
  architecture-context provider** (its `rig` tool is how gate 1 loads a
  project's graph into context in ~400 tokens). Consult it **at the start**
  (`rig overview` / `read`) to ground a change in documented design; write to
  it **before merge** when a change adds coupling that is not part of that
  design (pages, ADRs, cross-references).
- **`tdd`** — *how* to write the tests this skill requires (behavior over
  implementation, vertical red-green slices, mocking). Load it when writing the
  unit/integration tests for a change.
- **`fork-maintenance`** — *external* change: upstream moved, keep the fork's
  release branch green (two-branch mirror/release topology).
- **`pr-review`** — **gate 12**, the reviewer counterpart: adversarial
  review APPROVE on the head SHA is required for merge-ready. It is
  SHA-guarded at ingress, so it only ever evaluates pipeline-green code.

For forked repos `dev-workflow` and `fork-maintenance` both apply: this skill
governs your own feature branches; fork-maintenance governs the upstream-sync
PRs. CI-watching is one pattern everywhere (`gh pr checks --watch` on GitHub,
commit-status polling on Forgejo).

The gate chain above is the done-checklist — a change is "done" only when every
gate has passed and the default branch has moved via the merged PR.
