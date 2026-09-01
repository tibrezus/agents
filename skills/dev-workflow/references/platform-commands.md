# Platform command reference

The [`scripts/host.sh`](../scripts/host.sh) helper abstracts the platform
differences. This page explains what those differences are, so you can adapt
when a helper function doesn't fit your case.

## Platform detection

`dw_detect_platform()` reads `git remote get-url origin`:

| Remote URL pattern | Platform | CLI |
|---|---|---|
| `github.com` | `github` | `gh` |
| `codeberg.org` | `codeberg` | `fj` + REST |
| anything else | `forgejo` | `fj` + REST |

Codeberg runs Forgejo, so it is treated as `forgejo` for API calls — only the
host (`codeberg.org`) and token env var differ.

## Where the platforms diverge

| Operation | GitHub | Forgejo/Codeberg |
|---|---|---|
| Create issue | `gh issue create` | `fj issue create` |
| **Milestones** | `gh issue edit --milestone`, `gh api .../milestones` | **REST only** — `fj` has no milestone flag |
| Open PR | `gh pr create --base --head` | `fj pr create --base --head` |
| **Watch CI** | `gh pr checks <n> --watch` (blocks) | **no `--watch`** — poll `fj actions tasks` or the commit status API |
| **Merge PR** | `gh pr merge --squash --delete-branch` | **REST only** — `POST .../pulls/<n>/merge` |
| **Trigger full pipeline (label)** | `gh issue edit <n> --add-label full-pipeline` | `POST .../issues/<pr>/labels` body `{"labels":["full-pipeline"]}` |

(Label name overridable via `DW_FULL_PIPELINE_LABEL`; `dw_trigger_full_pipeline`
creates it if missing and toggles it for re-triggers — same for `needs-review`
in `dw_request_review`.)
| **Dispatch full pipeline (fallback)** | `gh workflow run <wf> --ref <branch>` | `fj api repo dispatch-workflow ... --body '{"ref":"<branch>"}'` → `decode: EOF` = success (204) |
| **Resolve PR head SHA** | `gh pr view <n> --json headRefOid` | `GET .../pulls/<n>` → `.head.sha` |
| **Runs for a SHA** | `gh api .../actions/runs?head_sha=<sha>` | `GET .../actions/runs?limit=100` → filter `.commit_sha` + `.name` |

The bolded rows are why `host.sh` exists: milestones, CI watching, and merging
need different mechanisms and the agent should not have to remember them.

## Merge-gated dispatch mechanics (slow tier)

The slow tier runs `workflow_dispatch` + a **required status check** in
branch protection — the pending state until dispatch *is* the manual gate.
Platform notes:

- **GitHub** — do **not** combine with merge queues; they would re-run the
  full matrix on the merge group.
- **Forgejo/Gitea** — no merge queue exists (dispatch + required check is
  the pattern); `concurrency` is enforced at workflow level only, job-level
  is silently ignored.
- **GitLab** — heavy jobs `when: manual` (blocking by default) +
  "Pipelines must succeed"; merge trains (Premium) are the queued variant.

### The merge-queue-equivalent invariant (Forgejo/Gitea replication recipe)

Forgejo has no merge queue/merge train (GitHub merge queue, GitLab merge
trains — both test a temporary head+base ref before landing). The same
*correctness property* — **the CI-green tree is byte-identical to the
tree that lands** — is assembled from four generic ingredients:

1. **Required status checks** in branch protection, named for the slow-tier
   workflow's contexts — no failed-check waivers, ever (the Forgejo API has
   none; do not look for one).
2. **Behind-base rejection** — Forgejo protection answers
   `405 "The head branch is behind the base branch"` when the head is not a
   descendant of the default branch. This forces the rebase that makes the
   next ingredient true (client-side, the trigger helper refuses unrebased
   heads before the slow tier is even dispatched).
3. **Squash merge** — the squash of a rebased branch onto the default
   produces *exactly* the head tree. Combined with 1+2: the validated SHA's
   tree is the landing tree, so the merge race a queue exists to close is
   closed by construction — at merge time instead of pre-validated in a
   train.
4. **SHA-bound statuses** — required checks resolve against the head SHA;
   any push (source or docs) after declaration re-opens the path and
   re-quires the slow tier (see ci-concepts.md §1.3 two-phase readiness).

Operational corollaries on a shared runner (learned the hard way):

- **Concurrency groups are run management, not a queue.**
  `concurrency: group: <ref+cause>, cancel-in-progress: true` cancels every
  earlier pending/running member of the group when a new dispatch lands —
  for a PR, `github.ref` is `refs/pull/<n>/merge` (head-independent), so
  every re-dispatch of the same PR is in one group and the newest wins.
  A queued run is cancellable at any moment.
- **Dispatch last.** Under concurrent label-toggling bursts (multiple PRs
  racing one bare-metal runner), only the newest dispatch per group
  survives; the reliable pattern is to wait until the frontier has no
  non-terminal runs from any head, then dispatch. A solo run also avoids
  the co-tenancy false-failure class on perf gates (measured −8…−9% on
  shared-DDR AMD runners when decodes overlap).
- **Never re-toggle to fix a cancelled run** — the re-toggle is itself the
  newer dispatch and sends the PR to the back of the queue. First check
  whether a newer run for the same head is already waiting; if so, watch
  it.

## Tokens

`dw_token()` picks the right env var per platform:

| Platform | Env var tried (first set wins) |
|---|---|
| github | `GH_TOKEN`, then `GITHUB_TOKEN` |
| codeberg | `CODEBERG_TOKEN`, then `FJ_TOKEN` |
| forgejo | `RZC_TOKEN`, then `FJ_TOKEN`, then `FORGEJO_TOKEN` |

Ensure the relevant token is exported before sourcing `host.sh`.

## Milestone resolution conventions

`dw_resolve_milestone "<convention>"` returns `<id>:<title>` or empty:

| Convention | Meaning |
|---|---|
| `current` (default) | the most recent open milestone (sorted by due date desc) |
| `none` | do not set a milestone |
| `<exact title>` | match an open milestone by title |

Set a project's convention in its AGENTS.md mandate block (`Milestone
convention` line). If `current` finds no open milestone, the agent should ask
the user whether to create one.

## Forgejo REST API notes

Base: `https://<host>/api/v1/repos/<owner>/<repo>/...`

- List open milestones: `GET .../milestones?state=open&sort=due_date&direction=desc`
- Set issue milestone: `PATCH .../issues/<n>` body `{"milestone": <id>}`
- Merge PR: `POST .../pulls/<n>/merge` body `{"Do": "squash" | "merge" | "rebase"}`
- CI status for a commit: `GET .../commits/<sha>/status` → `.state` ∈ `success|failure|error|pending`
- Dispatch workflow: `POST .../actions/workflows/<filename>/dispatches`
  body `{"ref": "<branch>"}` (the `fj` wrapper is preferred). Run records
  expose the workflow **name**, not filename — configure the name in
  `Full pipeline:` when they differ.
- **Label-triggered full pipeline (primary)** — the workflow fires on
  `pull_request: types: [labeled]` guarded by
  `github.event.label.name == 'full-pipeline'`; `dw_trigger_full_pipeline`
  sets the label (agent path, auto-creates it, toggles on re-trigger) and a
  human ticking it in the UI is equivalent. Verified in Gitea ≥1.22:
  `HookIssueLabelUpdated` → `labeled`; without a `types` filter, label
  events do NOT fire; any label change converts to `labeled`, so the guard
  is mandatory; one run per label; the trigger must be defined on the base
  branch (default). The run lands on the PR head SHA and `dw_full_green`
  verifies it identically to a dispatch. Re-trigger after a push: remove →
  re-add (the helper does this automatically).
- Dispatch (`dw_dispatch_full_pipeline`) remains the fallback for workflows
  wired with `workflow_dispatch` only.
- PR comments (where the review verdict trailer lands):
  `GET .../issues/<pr>/comments` — PRs share the issues comment API.

All calls need `Authorization: token <TOKEN>`.

## Branch protection — hard rules

These apply on **every** platform, with no exceptions:

1. **Never force-push to the default branch.** `git push --force` or
   `--force-with-lease` to `main`/`master` is forbidden. On **Codeberg** this
   is absolute — the default branch must never be overwritten.
2. **Always rebase before merge.** Before merging a PR, rebase the feature
   branch onto the latest default branch so the merge is conflict-free and
   linear. Use `dw_rebase_onto_default` (which force-pushes the *feature*
   branch only, never the default).
3. **Never change platform/repository rules to work around these constraints.**
   Do not disable branch protection, enable `allow_force_push`, change
   merge-strategy settings, or alter any repository configuration to make a
   blocked merge go through. If a merge is blocked, the fix is on the branch.

The workflow's only force-push is to a *feature* branch after a rebase — never
the default.
