# `fj` command reference

Syntax + flags per group with the live output shapes that matter for
parsing, against `git.rezus.cloud` / `tibrez/rhesadox` (fj
`16.0.2-rezuscloud.x`). Targeting rules and workflow: parent `SKILL.md`;
API origin and operationId→command derivation: [`api.md`](api.md).
Per-command `--help` renders client-side — no host/auth needed — so this
page stays compact; exact help text is one `--help` away.

Global flags (every command): `-H, --host` (git.rezus.cloud |
codeberg.org | …) · `-r, --repo owner/name` · `-R, --remote`
(origin | upstream | …).

## Top level

`actions` · `api` (auto-generated from swagger) · `auth` · `completion` ·
`help` · `issue` (alias `issues`) · `org` · `pr` (alias `prs`) ·
`release` · `repo` · `tag` · `user` · `version` · `whoami` · `wiki`

`fj version [--client|--short]` — client + API (spec level) + server
versions (`--client` skips the server query).
`fj whoami -H <host>` — signed-in identity.

## `auth` — multi-instance credentials

`fj auth login <host>` (browser OAuth or token prompt) · `add-key` ·
`list` (hosts) · `logout <host>`. Credentials live in
`~/.local/share/forgejo-cli/keys.json` (portable). Live:

```
$ fj auth list                          $ fj whoami -H git.rezus.cloud
  codeberg.org (type: Application)        currently signed in as tibrez <tiberiu@rezus.net>
  git.rezus.cloud (type: Application)
```

## `issue`

`<INDEX>` = repo-local **Number** (the URL id, `#1330`), not the DB id.

```
fj issue list  [-s open|closed|all]     # rows: #1330 OK [open] title …
fj issue view  <INDEX> [-c]             # -c, --comments → full thread
fj issue create -t <title> [-b <body>]
fj issue comment <INDEX> -b <body>
fj issue close <INDEX>
```

## `pr`

```
fj pr list [-s open|closed|all]
fj pr view <INDEX>
fj pr create --head <branch> [--base main] -t <title> -b <body>
fj pr status <INDEX>     # ★ CI health: per-check state, duration, deep link
fj pr merge <INDEX> [-s merge|rebase|squash|rebase-merge|fast-forward-only] [-d]
```

`pr status` (needs checks reported on the head commit; fresh PRs may be
empty until CI schedules):

```
#1174 feat(#1113): COMPUTE-stage copy shader …
Head: 79084a7bff54d31aa07ed16f9802f5c1d6527184
Overall: OK success

  OK success   decode / decode (cuda) (pull_request)
      Successful in 8m28s
      /tibrez/rhesadox/actions/runs/6118/jobs/0
```

## `release` / `tag`

```
fj release create --tag <T> [-n <name>] [-b <body>] [--draft] [--prerelease]
fj release list | view <TAG> | delete <TAG>
fj tag list | create <TAG> | delete <TAG>
```

## `actions` — CI status & logs ★

Runs contain **jobs**, which contain the steps. Reading order for a
failing PR: **`pr status` → `actions jobs <RUN>` → `actions logs --job
<JOB>`** (or `runs → jobs → logs`).

```
fj actions runs              # rows: #6974 (1951b8a650) RUN (pull_request): title
                             #   filters (PR #75): --limit --page --status --event
                             #   --head-sha --ref --workflow-id --run-number
fj actions jobs <RUN>        # rows: #12420 build-test [failure] runs_on:ubuntu-latest
fj actions tasks [-p <page>] # flat list; col 1 = run id
fj actions logs --job <JOB>  # single job's log → stdout (grep it)
fj actions logs --run <RUN> [--out f.zip]   # all jobs' logs → zip
fj actions dispatch | secrets | variables …
```

**Run states:** `OK` · `FAIL` · `RUN` (running) · `WAIT` (queued) ·
`BLOCKED`. **`runs`/`tasks` exit 0 even on failed runs** — parse the
`FAIL` token / `pr status`'s `Overall:` line, never the exit code.

## `repo` / `user` / `org` / `wiki`

```
fj repo view [OWNER/NAME] ; fj repo clone <OWNER/NAME> [DIR]
fj user view <NAME> | repos <NAME> | search <QUERY>
fj org list | view <NAME>
fj wiki list ; fj wiki view <PAGE>          # wiki needs -H + -r
```

## `api` — the generated tree (everything else)

One subcommand per operationId; services: `activitypub admin misc notify
org repo user`. Prefer polished commands; reach for `fj api` only for
gaps (milestones, labels, branches, admin, runners).

```
fj api repo                     # lists all 265 repo endpoints, one line each
fj api repo | grep -i wiki      # → get-wiki-pages, get-wiki-page, …
fj api repo issue-edit-milestone --help     # flags: --body --id --owner --repo
```

**Discover, don't guess.** Names come from swagger operationIds and
aren't always the obvious word — grep the listing first; a wrong name
gives **empty stdout** (cobra reports `unknown flag: --owner` to stderr;
help/listings render client-side, cobra handles help before RunE).
Examples:

```
fj api repo issue-get-milestones-list --owner tibrez --repo rhesadox -H git.rezus.cloud
fj api repo issue-create-milestone  --owner tibrez --repo rhesadox --body '{"title":"v2"}' -H git.rezus.cloud
fj api repo get-wiki-pages --owner tibrez --repo rhesadox -H git.rezus.cloud
```

## `milestone` — descriptor-generated (since #78; first `polish.json` group)

```
fj milestone list [-s open|closed|all] [--name <title-substring>]
                  # rows: #ID ✅/✗ [state] title
fj milestone view <ID>          # title, state, due, open/closed counts, description
fj milestone create -t <title> [-d <desc>] [--due 2026-09-30T00:00:00Z]
fj milestone edit <ID> [-t] [-d] [--state open|closed] [--due]   # partial: only provided flags change
fj milestone close <ID> | delete <ID>
```

`--due` RFC3339, validated. `--id` is the **opaque** milestone id from
`get-milestones-list` (milestones have no repo-local number like
issues). `--body` field names are not in `--help`; the JSON must match
the Option struct: `{title, description, state, due_on}`. Escape hatch:
`fj api repo issue-*-milestone` for anything the group lacks.
