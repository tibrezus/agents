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
> Never merge a PR whose CI is red. A change is not done until the PR is
> merged and CI is green on the default branch.

### CI discipline (quality gates)

"CI green" means the **test suite** passes, not merely that it builds. Two
gates hold for every change:

- **Tests cover the change.** Unit tests are **mandatory** for every behavior
  the change adds or alters. If the project already has an integration-test
  suite, the change **extends** it for the paths it touches (never shrinks it).
  Tests must run in CI, not only locally. Load the `tdd` skill to write them.
- **No undocumented coupling.** Avoid coupling between components unless it is
  part of the intended architecture. If coupling is unavoidable and not part
  of the documented design, record it in the wiki (`/skill:llm-wiki`) **before**
  the PR merges, per `COUPLING_POLICY` below.

Depth (what counts as coupling, detection heuristics, CI wiring) lives in the
skill's `references/ci-concepts.md`.

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
- **Merge method:** `{{MERGE_METHOD}}`

### Before every change

1. **Find the issue** — search open issues for the task. If none exists,
   create one with a clear title and acceptance criteria.
2. **Find the branch** tied to that issue (by number). If none, create it off
   the default branch and associate the issue with a milestone.
3. **Make the change** on the branch, **with its tests** (unit mandatory;
   extend integration tests if a suite exists). Reference the issue in commits
   (`Fixes #<n>` / `Refs #<n>`). If the change adds coupling that is not part
   of the design, document it in the wiki first.
4. **Push the branch** and open a PR against the default branch.
5. **Watch CI to green** — the test suite passes, not just the build. If red,
   fix on the branch and re-push — never merge red.
6. **Merge only when green**, then delete the branch and close the issue.

A direct commit to the default branch requires an explicit user instruction,
recorded on the issue.
<!-- END dev-workflow -->
