<!-- BEGIN dev-workflow (managed by the dev-workflow skill — re-run `adopt` to update) -->
## Development Workflow

This project uses **branch-based development**. No change lands on the
default branch directly.

> **Cardinal rule:** before making any change, load and follow the
> `dev-workflow` skill (`/skill:dev-workflow`). Every change flows:
>
> **issue → branch → green CI → merged PR**
>
> Never `git commit` or `git push` to the default branch (`{{DEFAULT_BRANCH}}`).
> Never force-push (`--force` / `--force-with-lease`) to the default branch —
> on Codeberg this is absolute: `main`/`master` must never be overwritten.
> Always rebase the feature branch onto the default before merging.
> Never change platform/repository rules (branch protection, force-push
> settings, merge-strategy constraints) to work around merge requirements.
> Never merge a PR whose CI is red. A change is not done until the PR is
> merged and CI is green on the default branch.
> Only optimal implementations are accepted — no workarounds at any level
> (code, tests, CI, tooling, configuration). If a proper fix is blocked,
> surface the blocker on the issue.
>
> The full pipeline and an adversarial review run **once, at merge time**,
> on the declared-ready head SHA — not on every push. `dw_merge_readiness`
> verifies the whole chain before any merge.

### CI discipline (quality gates)

"CI green" means the **test suite** passes, not merely that it builds. Two
gates hold for every change:

- **Tests cover the change.** Unit tests are **mandatory** for every behavior
  the change adds or alters. If the project already has an integration-test
  suite, the change **extends** it for the paths it touches (never shrinks it).
  Tests must run in CI, not only locally. Load the `tdd` skill to write them.
- **CI instrumentation evolves with the project.** Run the project's own test
  runner locally — the same command CI runs (`make test`, `npm test`,
  `scripts/test`) — never a throwaway script you discard after verifying.
  Consolidation is the default: before creating any component — a tool, a CI
  job, a wiki page — quickly check that an equivalent doesn't already exist
  (tooling folders: `scripts/`, `tools/`, `bench/`) and extend it; new tools
  are wired into CI. Every test, lint check, or harness is wired into CI and
  stays there: extend the existing suite, don't create a parallel one.
- **No undocumented coupling.** Avoid coupling between components unless it is
  part of the intended architecture. If coupling is unavoidable and not part
  of the documented design, record it in the wiki (`/skill:llm-wiki`) **before**
  the PR merges, per `COUPLING_POLICY` below.
- **Measurements live in CI, not on laptops.** A benchmark, A/B comparison, or
  quality eval relevant over time is wired into the slow tier as a **reusable**
  job (`workflow_dispatch`), not an ad-hoc script. One harness, many
  invocations — composite actions, reusable workflows — never copy-pasted jobs.
  Depth: the skill's `ci-concepts.md` §1.4.

Depth (what counts as coupling, detection heuristics, CI wiring) lives in the
skill's `references/ci-concepts.md`.

### Two-phase CI + review gate (merge-gated validation)

Every push runs the **fast tier** only. When the change is ready: rebase
onto the default branch, dispatch the **full pipeline** on that SHA
(`dw_dispatch_full_pipeline`), request the **adversarial review**
(`dw_request_review` — refused unless the pipeline is green at head), then
merge only when `dw_merge_readiness` verifies fast + full + review APPROVE
at one frozen head SHA. Any push after declaration re-opens the merge path.
Depth: the skill's `ci-concepts.md` §1.3.

### Project configuration

- **Platform:** `{{PLATFORM}}`
- **Default branch:** `{{DEFAULT_BRANCH}}`
- **Branch naming:** `{{BRANCH_NAMING}}` — the issue number MUST appear in the
  branch name so the branch and issue stay linked.
- **Milestone convention:** `{{MILESTONE_CONVENTION}}`
- **CI watch:** `{{CI_WATCH}}`
- **Test command:** `{{TEST_COMMAND}}` — the suite CI runs; verify locally with
  the same command before pushing. This is a best-effort *suggestion*; if wrong,
  commit `scripts/test` (preferred) or set `CI_TEST_COMMAND` rather than
  hand-editing — see the skill's `ci-concepts.md`.
- **Coupling policy:** `{{COUPLING_POLICY}}` — one of `strict` (default) /
  `documented-exceptions` / `legacy`; see the skill's `ci-concepts.md`.
- **Safety level:** `{{SAFETY_LEVEL}}` — one of `none` (default) / `mcdc`.
  When `mcdc`, every boolean decision in changed code must achieve Modified
  Condition/Decision Coverage. See the skill's `mcdc.md`.
- **Merge method:** `{{MERGE_METHOD}}`
- **Full pipeline:** `{{FULL_PIPELINE}}` — slow-tier workflow(s) dispatched
  at ready declaration. `none` = the fast tier is the whole pipeline. On
  Forgejo set the workflow *name* if it differs from the filename.

### Before every change

1. **Consult the wiki** (`/skill:llm-wiki` `consult`/`read`) for the
   project's documented design — entities, concepts, ADRs — before framing
   the change. This is what "no undocumented coupling" judges against.
2. **Find the issue** — search open issues for the task. If none exists,
   create one with a clear title and acceptance criteria.
3. **Find the branch** tied to that issue (by number). If none, create it off
   the default branch and associate the issue with a milestone.
4. **Make the change** on the branch, **with its tests** (unit mandatory;
   extend integration tests if a suite exists). Reference the issue in commits
   (`Fixes #<n>` / `Refs #<n>`). If the change adds coupling that is not part
   of the design, document it in the wiki first.
5. **Simplify** — re-read the diff. Can it be simpler? Remove dead code,
   collapse abstractions, eliminate speculative generality. A complex
   implementation is not optimal when a simpler alternative exists.
6. **Push the branch and open a PR** (draft is fine) — every push runs the
   fast tier; iterate to green and finish the simplification pass.
7. **Re-simplify, then declare ready:** rebase onto the default branch,
   dispatch the full pipeline on that SHA and watch it green; then request
   the adversarial review (`dw_request_review`) and wait for APPROVE.
8. **Merge only when merge-ready** — `dw_merge_readiness` verifies fast +
   full + review at the same head SHA — then delete the branch and close
   the issue.

A direct commit to the default branch requires an explicit user instruction,
recorded on the issue.
<!-- END dev-workflow -->
