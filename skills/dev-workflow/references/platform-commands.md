# Platform command reference

The [`scripts/host.sh`](../scripts/host.sh) helper abstracts the platform
differences; this page explains what they are, so you can adapt when a
helper doesn't fit.

## Platform detection

`dw_detect_platform()` reads `git remote get-url origin`: `github.com` →
`github`/`gh`; `codeberg.org` → `codeberg`/`fj`+REST; anything else →
`forgejo`/`fj`+REST. Codeberg runs Forgejo, so only host and token env
differ.

## Where the platforms diverge

| Operation | GitHub | Forgejo/Codeberg |
|---|---|---|
| Create issue | `gh issue create` | `fj issue create` |
| **Milestones** | `gh issue edit --milestone`, `gh api .../milestones` | **REST only** — `fj` has no milestone flag |
| Open PR | `gh pr create --base --head` | `fj pr create --base --head` |
| **Watch CI** | `gh pr checks <n> --watch` (blocks) | **no `--watch`** — poll `fj actions tasks` or the commit status API |
| **Merge PR** | `gh pr merge --squash --delete-branch` | **REST only** — `POST .../pulls/<n>/merge` |
| **Trigger full pipeline (label)** | `gh issue edit <n> --add-label full-pipeline` | `POST .../issues/<pr>/labels` body `{"labels":["full-pipeline"]}` |
| **Dispatch full pipeline (fallback)** | `gh workflow run <wf> --ref <branch>` | `fj api repo dispatch-workflow ... --body '{"ref":"<branch>"}'` → `decode: EOF` = success (204) |
| **Resolve PR head SHA** | `gh pr view <n> --json headRefOid` | `GET .../pulls/<n>` → `.head.sha` |
| **Runs for a SHA** | `gh api .../actions/runs?head_sha=<sha>` | `GET .../actions/runs?limit=100` → filter `.commit_sha` + `.name` |

(Label overridable via `DW_FULL_PIPELINE_LABEL`; `dw_trigger_full_pipeline`
creates it if missing and toggles it for re-triggers — same for
`needs-review` in `dw_request_review`.) The bolded rows are why `host.sh`
exists: milestones, CI watching, and merging need different mechanisms.

## Merge-gated dispatch mechanics (slow tier)

The slow tier runs `workflow_dispatch` + a **required status check** in
branch protection — the pending state until dispatch *is* the manual gate.

- **GitHub** — do **not** combine with merge queues; they re-run the full
  matrix on the merge group.
- **Forgejo/Gitea** — no merge queue exists; `concurrency` is enforced at
  workflow level only, job-level is silently ignored.
- **GitLab** — heavy jobs `when: manual` (blocking by default) +
  "Pipelines must succeed"; merge trains (Premium) are the queued variant.

### The merge-queue-equivalent invariant (Forgejo/Gitea)

No merge queue/train exists there; the same property — **the CI-green
tree is byte-identical to the tree that lands** — is assembled from:

1. **Required status checks** in protection, named for the slow tier's
   contexts — no failed-check waivers (the Forgejo API has none).
2. **Behind-base rejection** — protection answers `405 "head branch is
   behind the base branch"` for non-descendant heads, forcing the rebase
   (client-side, the trigger helper refuses unrebased heads before
   dispatch).
3. **Squash merge** — a rebased branch squashed onto default produces
   exactly the head tree; with 1+2 the merge race closes by construction.
4. **SHA-bound statuses** — checks resolve against the head SHA; any push
   after declaration re-opens the path (two-phase readiness:
   [test-policy.md](test-policy.md)).

Operational corollaries on a shared runner (learned the hard way):

- **Concurrency groups are run management, not a queue.**
  `concurrency: group: <ref+cause>, cancel-in-progress: true` cancels
  earlier pending/running members when a new dispatch lands — for a PR,
  `github.ref` is `refs/pull/<n>/merge` (head-independent), so every
  re-dispatch of the PR is one group and the newest wins; a queued run is
  cancellable at any moment.
- **Dispatch last.** Under label-toggling bursts racing one bare-metal
  runner, only the newest dispatch per group survives; wait until the
  frontier has no non-terminal runs from any head, then dispatch. A solo
  run also avoids co-tenancy false failures on perf gates (measured
  −8…−9% on shared-DDR AMD runners when decodes overlap).
- **Never re-toggle to fix a cancelled run** — the re-toggle is itself the
  newer dispatch and sends the PR to the back. First check whether a newer
  run for the same head is already waiting; if so, watch it.

## Tokens

`dw_token()` picks the env var per platform (first set wins): github →
`GH_TOKEN`, `GITHUB_TOKEN`; codeberg → `CODEBERG_TOKEN`, `FJ_TOKEN`;
forgejo → `RZC_TOKEN`, `FJ_TOKEN`, `FORGEJO_TOKEN`. Export before
sourcing `host.sh`.

## Milestone resolution conventions

`dw_resolve_milestone "<convention>"` returns `<id>:<title>` or empty:
`current` (default) = most recent open milestone (due date desc); `none` =
skip; `<exact title>` = match by title. Set the project's convention in
its AGENTS.md mandate block (`Milestone convention` line). If `current`
finds no open milestone, ask the user whether to create one rather than
proceeding silently without.

## Forgejo REST API notes

Base `https://<host>/api/v1/repos/<owner>/<repo>/...`, all calls with
`Authorization: token <TOKEN>`:

- Milestones: `GET .../milestones?state=open&sort=due_date&direction=desc`;
  set via `PATCH .../issues/<n>` body `{"milestone": <id>}`.
- Merge: `POST .../pulls/<n>/merge` body `{"Do": "squash" | "merge" | "rebase"}`.
- CI status: `GET .../commits/<sha>/status` → `.state` ∈
  `success|failure|error|pending`.
- Dispatch: `POST .../actions/workflows/<filename>/dispatches` body
  `{"ref": "<branch>"}` (the `fj` wrapper is preferred). Run records
  expose the workflow **name**, not filename — configure the name in
  `Full pipeline:` when they differ.
- **Label-triggered full pipeline (primary)** — the workflow fires on
  `pull_request: types: [labeled]` guarded by
  `github.event.label.name == 'full-pipeline'`; `dw_trigger_full_pipeline`
  sets the label (auto-creates, toggles on re-trigger); a human ticking it
  in the UI is equivalent. Verified in Gitea ≥1.22: `HookIssueLabelUpdated`
  → `labeled`; **without a `types` filter label events do NOT fire**; any
  label change converts to `labeled` (the guard is mandatory); one run per
  label; the trigger must be defined on the base branch. The run lands on
  the PR head SHA and `dw_full_green` verifies it like a dispatch.
  Re-trigger after a push: remove → re-add (the helper does this).
- Dispatch (`dw_dispatch_full_pipeline`) remains the fallback for
  `workflow_dispatch`-only workflows.
- PR comments (where the review verdict trailer lands):
  `GET .../issues/<pr>/comments` — PRs share the issues comment API.

## Branch protection — hard rules

Restated from [`SKILL.md`](../SKILL.md) hard rules, with the mechanism:
never force-push the default branch (on **Codeberg** absolute — the
default must never be overwritten); always rebase before merge
(`dw_rebase_onto_default` force-pushes the *feature* branch only); never
change platform/repository rules (protection, `allow_force_push`,
merge-strategy settings) to unblock a merge — the fix is on the branch.
The workflow's only force-push is a *feature* branch after a rebase.
