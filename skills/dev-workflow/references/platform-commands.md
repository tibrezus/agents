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

The bolded rows are why `host.sh` exists: milestones, CI watching, and merging
need different mechanisms and the agent should not have to remember them.

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

All calls need `Authorization: token <TOKEN>`.
