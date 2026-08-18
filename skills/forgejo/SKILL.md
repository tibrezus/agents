---
name: forgejo
description: Operate Forgejo instances — the REST API is the source of truth and the `fj` Go CLI is generated from it. Covers reading the swagger spec (origin), the generated `fj api` tree, the polished commands (issues/PRs/releases/CI), multi-instance auth, and Actions CI run/job status + logs. Use when the task touches Forgejo, `git.rezus.cloud`, codeberg.org, the Forgejo API/swagger, the `fj` CLI, CI status/logs, or opening/viewing/merging PRs and issues.
---

# Forgejo — the API is the origin, `fj` follows it

Every capability of a Forgejo instance is a **REST endpoint**. The instance
publishes its own machine-readable reference at
`https://<host>/swagger.v1.json` (basePath `/api/v1`). Everything else —
SDK, CLI — is *derived* from that spec:

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

Consequences that shape daily use:

- **The spec is the discovery tool.** Anything you can do has an operationId.
  Find it in the spec (or via `fj api <svc> | grep <keyword>`) — never guess.
- **`fj api` covers 100% of the API**; the polished top-level commands
  (`fj issue`, `fj pr`, `fj actions`…) are hand-written conveniences over the
  same generated SDK. Prefer polished, fall back to `fj api`.
- **Structure of a call is uniform**: `fj api <service> <subcommand> --<params>
  [--body '<json>']` — path params become required flags, the request body
  becomes `--body` JSON matching the swagger schema.

The full origin documentation — spec layout, the path→service table, the
operationId→command derivation, how to mine the spec with `jq`, and where the
generator lives in the fork — is in
[`references/api.md`](references/api.md). Read it before doing anything
non-trivial with `fj api` or when a polished command is missing.

## Instances & auth

| Host | Role |
|---|---|
| `git.rezus.cloud` | self-hosted (rezuscloud fork distribution) |
| `codeberg.org` | public Forgejo upstream instance |

Credentials live in **`~/.local/share/forgejo-cli/keys.json`** — one entry per
host, portable across machines (tokens are host-scoped API keys).

```bash
fj auth login <host>            # browser OAuth or token prompt
fj auth list                    # this machine's authenticated hosts
fj whoami -H <host>             # proves the token works
bash "$HOME/.agents/skills/forgejo/scripts/first-shot.sh"   # orientation
```

## Targeting — the #1 rule ⚠️

`fj` needs a host **and** a repo. Without `-H` (outside a git checkout) it
falls back to **github.com** → `not logged in to github.com`. That error means
you forgot `-H`.

```
-H <host>   always, unless just confirmed via `fj auth list`
-r o/n      repo by owner/name          -R origin   repo from a git remote
```

## Everyday surfaces (polished)

Issues / PRs — `<INDEX>` is the repo-local number from the URL (`#1330`):

```bash
fj issue list|view|create|comment|close …
fj issue view <N> -c              # -c adds the comment thread
fj pr list|view|create|merge|status …
fj pr status <N>                  # ★ CI check status for the PR
fj release list|view|create|delete … ; fj tag list|create|delete …
fj repo view|clone ; fj user … ; fj org … ; fj wiki list|view
```

CI (Actions) — reading order for a failing PR: **runs → jobs → logs**:

```bash
fj actions runs  -H <host> -r <repo>        # #ID (sha) STATE (event): title
fj actions jobs  <RUN> -H <host> -r <repo>  # which job failed
fj actions logs --job <JOB> -H <host> -r <repo>   # ★ that job's log → stdout
fj actions logs --run <RUN> …               # all jobs' logs → zip (--out)
```

Run states: `OK · FAIL · RUN · WAIT · BLOCKED`. List commands **exit 0 even
on failed runs** — parse `FAIL` / the `Overall:` line of `pr status`.

## The `fj api` tree — for everything else

Milestones, labels, branches, admin, runners, wiki CRUD, … have no polished
command; use the generated tree:

```bash
fj api repo | grep -i wiki        # discover the exact name — never guess
fj api repo get-wiki-pages --owner tibrez --repo rhesadox -H git.rezus.cloud
fj api repo issue-create-milestone --owner tibrez --repo rhesadox \
     --body '{"title":"v2"}' -H git.rezus.cloud
```

Discovery methods (either works, same data):
- client-side: `fj api <svc> | grep -i <keyword>`
- origin-side: `jq` against `swagger.v1.json` — see `references/api.md`

## Gotchas

- **No `-H` → github.com fallback.** See targeting above.
- **Wrong `fj api` subcommand name → empty stdout.** Cobra reports
  `unknown flag: --owner` to *stderr*; stdout looks empty. Grep first.
- **`--body` field names aren't in `--help`** — they come from the swagger
  request schema (e.g. `{title, description, state, due_on}` for milestones).
- **CI lists exit 0 on failures** — parse output, not the exit code.
- **Milestone `--id` is opaque** (from `get-milestones-list`), not a repo-local
  number like issue/PR indexes.
- **`fj auth list` reads local `keys.json`**, not env vars.
- **`go install` doesn't work** (module path `forgejo.org` is upstream's).
  Install prebuilt tarballs from the fork's GitHub Release (tag `forgejo-v*`):

```bash
OS=$(uname -s | tr A-Z a-z); ARCH=$([ "$(uname -m)" = aarch64 ] && echo arm64 || echo amd64)
curl -fsSL "https://github.com/rezuscloud/forgejo/releases/download/forgejo-v16.0.2/fj-${OS}-${ARCH}.tar.gz" | tar -xz -C /tmp
install -m 0755 "/tmp/fj-${OS}-${ARCH}" ~/.local/bin/fj
```

## See also

- [`references/api.md`](references/api.md) — **the origin**: spec layout,
  path→service grouping, operationId→command derivation, jq mining, the
  generator's home in the fork.
- [`references/command-reference.md`](references/command-reference.md) — full
  per-command `--help` + live example output (the drivethrough).
