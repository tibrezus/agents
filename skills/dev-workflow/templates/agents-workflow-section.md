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

### Project configuration

- **Platform:** `{{PLATFORM}}`
- **Default branch:** `{{DEFAULT_BRANCH}}`
- **Branch naming:** `{{BRANCH_NAMING}}` — the issue number MUST appear in the
  branch name so the branch and issue stay linked.
- **Milestone convention:** `{{MILESTONE_CONVENTION}}`
- **CI watch:** `{{CI_WATCH}}`
- **Merge method:** `{{MERGE_METHOD}}`

### Before every change

1. **Find the issue** — search open issues for the task. If none exists,
   create one with a clear title and acceptance criteria.
2. **Find the branch** tied to that issue (by number). If none, create it off
   the default branch and associate the issue with a milestone.
3. **Make the change** on the branch. Reference the issue in commits
   (`Fixes #<n>` / `Refs #<n>`).
4. **Push the branch** and open a PR against the default branch.
5. **Watch CI to green.** If red, fix on the branch and re-push — never merge
   red.
6. **Merge only when green**, then delete the branch and close the issue.

A direct commit to the default branch requires an explicit user instruction,
recorded on the issue.
<!-- END dev-workflow -->
