---
name: forgejo
description: Operate Forgejo instances via the REST API and the `fj` Go CLI — the swagger spec is the origin, `fj` follows it. Covers the full subcommand surface (issues, PRs, releases, CI/Actions, wiki), multi-instance auth, and the fj coverage contract (every Forgejo operation must be doable via `fj`; gaps are filed as issues on rezuscloud/forgejo and implemented through this same skill). Use when the task touches Forgejo, `git.rezus.cloud`, codeberg.org, the Forgejo API/swagger, the `fj` CLI, CI status/logs, or opening/viewing/merging PRs and issues.
---

# Forgejo — the API is the origin, `fj` must cover it

Every capability of a Forgejo instance is a **REST endpoint**. The instance
publishes its own reference at `https://<host>/swagger.v1.json` (basePath
`/api/v1`). Everything else — SDK, CLI — is *derived* from that spec:

```
GET /swagger.v1.json                    326 paths · 507 operations (v16.0.2)
   │
   ├─ group by first URL segment  →  7 services: repo · user · org · admin
   │                                 notify · activitypub · misc
   │
   └─ operationId → kebab-case,
      minus redundant service prefix →  one `fj api` subcommand each
                 repoGetWikiPages  ─▶  fj api repo get-wiki-pages
```

`fj api` therefore covers **100% of the API**; the polished top-level commands
are hand-written conveniences over the same generated SDK. Structure of every
generated call: `fj api <service> <command> --<params> [--body '<json>']` —
path params become required flags, request bodies become `--body` JSON
matching the swagger schema. Full origin detail (path→service table,
derivation, `jq` mining, generator location): [`references/api.md`](references/api.md).

## Coverage contract — no operation without `fj`

**If something can be done on the instance (web UI, curl, git), it must be
doable with `fj`.** This is the contract between the API and the CLI. When a
task hits a missing surface:

1. **Confirm the gap** — find the operation in the spec (`jq`, see
   `references/api.md`) or `fj api <svc> | grep <keyword>`; check whether a
   polished command already exists (`fj --help`, `fj <group> --help`).
2. **Check known gaps below** and `gh issue list -R rezuscloud/forgejo` —
   don't file duplicates.
3. **No issue? Open one** on `rezuscloud/forgejo`: title
   `fj <surface>: <lack>`; body = operationId + endpoint, current workaround
   (`fj api …` if it exists), desired command shape, use case.
4. **Close the gap from the issue** — implementation guide below.
5. **Update the Known gaps table** in this skill with the issue link/state.

### Known gaps

| Gap | Workaround | Issue | State |
|---|---|---|---|
| `fj milestone` — no polished group; opaque `--id` + JSON `--body` | `fj api repo issue-*-milestone` | [rezuscloud/forgejo#73](https://github.com/rezuscloud/forgejo/issues/73) | open |

(Resolved gaps: drop the row when the release ships; note it in the release.)

### Implementing a gap (fork side, issue-triggered)

Work happens in `github.com/rezuscloud/forgejo` (default branch
`rezus/forgejo-16`) under the dev-workflow rules: **issue → branch → green CI
→ PR** (the repo is managed by the fork-maintenance workflow — never hack
directly on the deployed branch).

| What | Where |
|---|---|
| Generated SDK + `fj api` tree | `staging/src/forgejo.org/client-go/gen/main.go` (`classify()`, `cmdNameFor()`) |
| Polished commands | `staging/src/forgejo.org/fj/pkg/cmd/<group>.go` — thin wrapper over one SDK method + readable output |
| CLI tests | `staging/src/forgejo.org/fj/tests/integration/` |
| Build locally | `go build -o /tmp/fj ./cmd/fj` (never leave a root `./fj` — it shadows the staging module) |
| Ship | prebuilt tarball in the fork's GitHub Release (tag `forgejo-v*`); CLI version == Forgejo release |

A polished command never talks HTTP directly — it wraps the generated SDK
method. If the *SDK method itself* is missing, the fix is in the generator /
spec re-baseline, not in the command.

## Targeting — the #1 rule ⚠️

`fj` needs a host **and** a repo. Without `-H` (outside a git checkout) it
falls back to **github.com** → `not logged in to github.com` — that error
means you forgot `-H`.

```
-H <host>   always, unless just confirmed via `fj auth list`
-r o/n      repo by owner/name          -R origin   repo from a git remote
```

## Command surface — by subcommand

The three global flags apply everywhere. Per-command `--help` verbatim + live
examples: [`references/command-reference.md`](references/command-reference.md).

### `auth` — multi-instance credentials
Credentials live in `~/.local/share/forgejo-cli/keys.json` (portable across
machines). `fj auth login <host>` (OAuth/token) · `add-key` · `list` ·
`logout <host>` · `fj whoami -H <host>` proves the token. Token scopes (no
admin): `write:repository`, `write:issue`, `write:organization`, `write:user`.

### `actions` — CI status & logs ★
Runs contain **jobs**, which contain the steps. Reading order for a failing
PR: **`pr status` → `actions jobs <RUN>` → `actions logs --job <JOB>`**.

```bash
fj actions runs  -H <host> -r <repo>        # #ID (sha) STATE (event): title
fj actions jobs  <RUN> -H <host> -r <repo>  # which job failed, runs_on label
fj actions logs --job <JOB> …               # that job's log → stdout (grep it)
fj actions logs --run <RUN> --out f.zip …   # all jobs' logs → zip
fj actions tasks -H <host> -r <repo>        # flat task list (col 1 = run id)
fj actions dispatch|secrets|variables …
```
States: `OK · FAIL · RUN · WAIT · BLOCKED`. **`runs`/`tasks` exit 0 even on
failed runs** — parse `FAIL` / `pr status`'s `Overall:` line, never the exit code.

### `issue` — issues (alias `issues`)
`<INDEX>` = repo-local number from the URL (`#1330`), not the DB id.
```bash
fj issue list  [-s open|closed|all] ; fj issue view <N> [-c]   # -c = comments
fj issue create -t <title> -b <body> ; fj issue comment <N> -b <body> ; fj issue close <N>
```

### `pr` — pull requests (alias `prs`)
```bash
fj pr list [-s …] ; fj pr view <N> ; fj pr create --head <b> --base main -t … -b …
fj pr status <N>            # ★ CI checks: state, duration, run/job deep link
fj pr merge <N> [-s merge|rebase|squash|rebase-merge|fast-forward-only] [-d]
```
`pr status` needs the head commit to have reported checks (fresh PRs may be
empty until CI schedules).

### `release` / `tag`
`fj release list|view <TAG>|create --tag v1 [--draft|--prerelease]|delete <TAG>`
`fj tag list|create <TAG>|delete <TAG>`

### `repo` / `user` / `org` / `wiki`
`fj repo view [o/n]` · `fj repo clone <o/n> [dir]` · `fj user view|search|repos` ·
`fj org list|view` · `fj wiki list|view <PAGE>` (wiki needs `-r`)

### `api` — the generated tree (everything else)
Milestones, labels, branches, admin, runners, wiki CRUD, … — one subcommand
per operationId. **Discover, never guess** (a wrong name = empty stdout,
`unknown flag: --owner` on stderr):

```bash
fj api repo | grep -i milestone     # client-side discovery
fj api repo issue-get-milestones-list --owner tibrez --repo rhesadox -H git.rezus.cloud
fj api repo issue-create-milestone  --owner tibrez --repo rhesadox \
     --body '{"title":"v2"}' -H git.rezus.cloud
```

### `version` / `whoami`
`fj version [--client|--short]` — client + API (spec) + server versions.
`fj whoami -H <host>` — signed-in identity.

## Gotchas

- **No `-H` → github.com fallback** (see Targeting).
- **Wrong `fj api` name → empty stdout** — the error is on stderr. Grep first.
- **`--body` field names aren't in `--help`** — they come from the swagger
  request schema; mine the spec when unsure.
- **Milestone `--id` is opaque** (from `get-milestones-list`) — see gap #73.
- **`fj auth list` reads local `keys.json`**, not env vars.
- **CI lists exit 0 on failures** — parse output, not the exit code.

## Install

`go install` doesn't work (module path `forgejo.org` is upstream's). Prebuilt:

```bash
OS=$(uname -s | tr A-Z a-z); ARCH=$([ "$(uname -m)" = aarch64 ] && echo arm64 || echo amd64)
curl -fsSL "https://github.com/rezuscloud/forgejo/releases/download/forgejo-v16.0.2/fj-${OS}-${ARCH}.tar.gz" | tar -xz -C /tmp
install -m 0755 "/tmp/fj-${OS}-${ARCH}" ~/.local/bin/fj
```

## See also

- [`references/api.md`](references/api.md) — the origin: spec layout,
  path→service table, operationId→command derivation, jq mining, generator.
- [`references/command-reference.md`](references/command-reference.md) — every
  command's `--help` + live output (the drivethrough).
