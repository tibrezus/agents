---
name: forgejo-cli
description: Operate Forgejo instances and their CI through the `fj` Go CLI — authenticate against multiple instances from one binary, manage issues/PRs/releases/milestones, and read Actions CI run/job status + logs. Use when the task touches Forgejo, `git.rezus.cloud`, codeberg.org repos, the `fj` CLI, CI status/logs, or opening/viewing/merging PRs and issues.
---

# Forgejo CLI (`fj`)

`fj` is a single Go binary that talks to **any number of Forgejo instances**. Every
host you log into is stored in one credentials file; each command targets exactly
one **instance + repo**. It is the rezuscloud-fork analogue of `kubectl` for
Forgejo — including the **Actions CI log access that the upstream Rust `fj` lacks**
(`fj actions jobs` / `fj actions logs` are fork-only).

This is the **Go** `fj`, shipped from the Forgejo fork (`github.com/rezuscloud/forgejo`),
not the third-party Rust `forgejo-cli`. It reuses the same config file, so switching
requires no re-login.

## First-shot targeting — read before any command  ⚠️

`fj` must resolve **which instance** and **which repo**. The #1 mistake is omitting
the host. Resolve in this order:

| Situation | Form | Example |
|---|---|---|
| Explicit instance + repo | `-H <host> -r owner/name` | `fj issue list -H git.rezus.cloud -r tibrez/rhesadox` |
| Inside the repo's git checkout | `-H <host> -R <remote>` | `fj pr list -H git.rezus.cloud -R origin` |
| Bare command, no host | (omit `-H`) | ⚠️ **falls back to `github.com`** — almost always wrong |

**Hard rule: always pass `-H <host>`** unless you have *just* confirmed `fj auth list`
shows your target. Without `-H`, outside a git repo `fj` targets **github.com** →
`not logged in to github.com`. When you see that error, you forgot `-H`.

The three global flags apply to **every** command:

```
-H, --host string     the forgejo instance to use          (git.rezus.cloud | codeberg.org | …)
-R, --remote string   git remote to use                    (origin | upstream | …)  [needs a git checkout]
-r, --repo string     repo to operate on (owner/name)      (tibrez/rhesadox)
```

Establish context first:
```bash
bash "$HOME/.agents/skills/forgejo-cli/scripts/first-shot.sh"
```

## Authenticate (the multi-instance model)

All credentials live in **`~/.local/share/forgejo-cli/keys.json`** — one entry per
host, portable across machines (copy the file to reuse auth; tokens are host-scoped
API keys, valid from any host).

```bash
fj auth login git.rezus.cloud   # interactive: browser OAuth OR token prompt
fj auth add-key -H git.rezus.cloud   # add an application token non-interactively
fj auth list                    # every authenticated host + token type
fj whoami -H git.rezus.cloud    # "currently signed in as <user> <email>" — proves the token works
fj auth logout git.rezus.cloud  # remove a host
```

`fj auth list` reads the **local** `keys.json`, not any env var — it reflects this
machine's login state. Token scopes needed (no `admin`): `write:repository`,
`write:issue`, `write:organization`, `write:user`.

## Issues

```bash
fj issue list  -H <host> -r <repo>                 # open issues  (-s open|closed|all)
fj issue view  <INDEX> -H <host> -r <repo>         # body only — ADD -c/--comments for the thread
fj issue view  <INDEX> -c -H <host> -r <repo>      # body + full comment thread
fj issue create -t "title" -b "body" -H <host> -r <repo>
fj issue comment <INDEX> -b "body" -H <host> -r <repo>
fj issue close <INDEX> -H <host> -r <repo>
```

`<INDEX>` is the repo-local number shown in `issue list` (the `#1330` in the URL),
**not** the internal DB id. `issue` and `issues` are both valid (alias).

## Pull requests

```bash
fj pr list  -H <host> -r <repo>                     # open PRs  (-s open|closed|all)
fj pr view  <INDEX> -H <host> -r <repo>
fj pr status <INDEX> -H <host> -r <repo>            # ★ CI check status for the PR (see below)
fj pr create -t "title" -b "body" --head feat --base main -H <host> -r <repo>
fj pr merge  <INDEX> -H <host> -r <repo>            # merge; add -s rebase|squash|… and/or -d (delete branch)
```

Merge styles: `merge` (default), `rebase`, `squash`, `rebase-merge`, `fast-forward-only`.
`-d/--delete-branch` deletes the head branch after merge.

**`fj pr status <INDEX>` is the CI health view** for a PR — every status check, its
state, duration, and a deep link to the run/job. See the example output below.

## Releases & tags

```bash
fj release list  -H <host> -r <repo>
fj release view  <TAG> -H <host> -r <repo>
fj release create --tag v1.2.3 -n "name" -b "notes" [--draft|--prerelease] -H <host> -r <repo>
fj release delete <TAG> -H <host> -r <repo>

fj tag list  -H <host> -r <repo>
fj tag create <TAG> -H <host> -r <repo>
fj tag delete <TAG> -H <host> -r <repo>
```

## CI status & logs — the main reason this CLI exists  ★

Forgejo Actions (CI). Workflow runs contain **jobs**, which contain task steps. The
flow to read CI is: **runs → jobs → logs**.

```bash
fj actions runs  -H <host> -r <repo>          # recent runs: #ID (sha) STATE (event): title
                                               #   STATE = OK | FAIL | RUN | WAIT | BLOCKED
fj actions jobs  <RUN> -H <host> -r <repo>    # jobs in a run: #ID name [status] runs_on:<label>
fj actions logs --run <RUN> -H <host> -r <repo>   # ★ all jobs' logs → run-<id>-logs.zip
fj actions logs --job <JOB> -H <host> -r <repo>   # ★ one job's logs → stdout (plain text)
fj actions tasks -H <host> -r <repo>          # per-task view across runs (first line = total count)
```

Reading order for a failing PR:
1. `fj pr status <PR>` — see which check failed and grab its run id.
2. `fj actions jobs <RUN>` — see which job in that run failed (status `[failure]`).
3. `fj actions logs --job <JOB>` — the failing job's log to stdout, ready to read/grep.
   (For a whole run, `--run <RUN>` downloads a zip; use `--out <path>` to name it.)

### What the output looks like (real, against rhesadox)

```
$ fj actions runs -H git.rezus.cloud -r tibrez/rhesadox
#6974 (1951b8a650) RUN (pull_request): fix(#1329): CI — vulkan build …
#6972 (3de7d2d591) FAIL (pull_request): feat(#1329): shared per-expert bookkeeping …
#6969 (531f82257b) OK (pull_request): feat(#1327): emit prefill performance …

$ fj actions jobs 6400 -H git.rezus.cloud -r tibrez/rhesadox
#12420 build-test [failure] runs_on:ubuntu-latest

$ fj pr status 1174 -H git.rezus.cloud -r tibrez/rhesadox
#1174 feat(#1113): COMPUTE-stage copy shader …
Head: 79084a7bff54…
Overall: OK success
  OK success   decode / decode (cuda) (pull_request)
      Successful in 8m28s
      /tibrez/rhesadox/actions/runs/6118/jobs/0
  FAIL failure  integration / integration (vulkan) (pull_request)
      …
```

### `fj actions runs` / `tasks` exit codes

These **list** commands return exit `0` even when runs have **failed** — the failure
is in the output text, not the exit code. Do not treat a green exit as "CI passed";
parse the `FAIL` token or use `fj pr status` and check the `Overall:` line.

## Milestones — raw API only (no polished command)

There is **no** `fj milestone` command. Milestones are reachable only through the
generated `fj api` tree, which takes a JSON `--body` and an opaque numeric `--id`:

```bash
fj api repo issue-get-milestones-list --owner tibrez --repo rhesadox -H git.rezus.cloud
fj api repo issue-create-milestone --owner tibrez --repo rhesadox --body '{"title":"v2"}' -H git.rezus.cloud
fj api repo issue-edit-milestone    --owner tibrez --repo rhesadox --id 12 --body '{"title":"v2","state":"closed"}' -H git.rezus.cloud
fj api repo issue-delete-milestone  --owner tibrez --repo rhesadox --id 12 -H git.rezus.cloud
```

(Find the exact name with `fj api repo | grep milestone` — see the `fj api` section.)
`--id` is the opaque milestone id from `get-milestones-list` (milestones have no
repo-local number like issues do). The create/edit body matches
`{title, description, state, due_on}`.

## Raw API escape hatch (`fj api`)

Every Forgejo REST endpoint (all ~265 under `repo`) is auto-generated under `fj api`.
Use it for anything the polished commands don't cover (milestones, labels, branches,
admin, runners, **wiki pages**).

### ⚠️ Discover the exact name — never guess

Command names are derived from swagger operationIds and are NOT always the obvious
word. **Before running a `fj api` endpoint, grep the listing for the keyword** so
you use the real name:

```bash
fj api repo                              # lists all repo endpoints with descriptions
fj api repo | grep -i wiki               # → get-wiki-pages, get-wiki-page, create-wiki-page…
fj api repo | grep -i milestone          # → issue-create-milestone, issue-get-milestone…
fj api repo | grep -iE 'branch|status'   # find branch / commit-status endpoints
```

If a `fj api repo <guess>` call returns **empty stdout**, you used a wrong
subcommand name — cobra couldn't match it, treated your flags as belonging to the
parent, and printed `Error: unknown flag: --owner` to **stderr** (so stdout looks
empty). Grep the listing for the real name and retry.

```bash
fj api repo get-wiki-pages --owner tibrez --repo rhesadox -H git.rezus.cloud
fj api repo issue-get-milestones-list --owner tibrez --repo rhesadox -H git.rezus.cloud
fj api repo get --owner tibrez --repo rhesadox -H git.rezus.cloud   # view a repo
fj api repo issue-edit-milestone --owner tibrez --repo rhesadox --id 12 \
     --body '{"title":"v2","state":"closed"}' -H git.rezus.cloud
```

Prefer the top-level polished commands where they exist (human-readable output);
reach for `fj api` only for gaps. Each endpoint takes `--help` showing its flags.

> **Naming history:** `fj` ≤ 16.0.2-rezuscloud.2 carried a redundant `repo-`
> prefix on 159 repo endpoints (`repo-get-wiki-pages`, `repo-get`…). Build
> `21fb276+` (16.0.2-rezuscloud.3) strips it. The `grep` discovery rule above is
> correct for **both** versions — it always shows the names your binary accepts.

## Other discovery

```bash
fj repo view  [OWNER/NAME] -H <host>           # repo info
fj repo clone <OWNER/NAME> [DIR] -H <host>      # clone
fj user view  <NAME> -H <host>                  # / fj user search / fj user repos <NAME>
fj org list  -H <host>                          # / fj org view <NAME>
fj wiki list  -H <host> -r <repo>               # / fj wiki view <PAGE>
fj version --client                             # client/api version (no server query)
```

## Gotchas

- **Default host is `github.com`.** Without `-H` (and outside a git repo), `fj`
  targets github.com → `not logged in to github.com`. Always pass `-H <host>`.
- **`fj api <guess>` returns empty stdout on a wrong name.** Cobra can't match the
  subcommand, so it reports `unknown flag: --owner` to **stderr** and stdout is
  empty. The `fj api` endpoints also **require `-H`** (`--host is required`) and
  **require path flags** (`required flag(s) "owner", "repo" not set`). Always
  `fj api <svc> | grep <keyword>` for the real name first.
- **`fj issue view <N>` shows the body only.** Add `-c/--comments` for the thread.
- **`issue`/`pr` list output uses the repo `Number`** (the `#1330` in the URL), not
  the internal DB id — pass that number to `view`/`comment`/`close`/`merge`.
- **CI list commands return exit 0 on failed runs.** Parse `FAIL`/`Overall:`; don't
  trust the exit code for pass/fail.
- **`fj pr status` needs the PR's head commit to have reported checks.** A freshly
  pushed PR may show no checks until CI schedules.
- **Milestones have no polished command** — use `fj api repo issue-*-milestone` with
  a JSON `--body` and the opaque `--id`.
- **`fj auth list` reads local `keys.json`**, not env vars. It reflects *this*
  machine's logins. In tests, assert exit-0, not the host list.
- **Build from source with `-o`**: `go build -o /tmp/fj ./cmd/fj` — a stray root
  `./fj` binary shadows the staging module and breaks the build.

## Install / upgrade

`fj` ships as a prebuilt tarball in the Forgejo fork's GitHub Release (tag
`forgejo-v*`). `go install` does **not** work (module path is `forgejo.org`,
owned by upstream — same constraint as `kubectl`/`k8s.io/kubernetes`).

```bash
OS=$(uname -s | tr A-Z a-z); ARCH=$([ "$(uname -m)" = aarch64 ] && echo arm64 || echo amd64)
REL=forgejo-v16.0.2
curl -fsSL "https://github.com/rezuscloud/forgejo/releases/download/${REL}/fj-${OS}-${ARCH}.tar.gz" | tar -xz -C /tmp
install -m 0755 "/tmp/fj-${OS}-${ARCH}" ~/.local/bin/fj
fj version --client    # → Client Version: fj 16.0.2-rezuscloud.2
```

Config (`keys.json`) is untouched on upgrade and is reusable across hosts.

## See also

- `references/command-reference.md` — full per-command help (verbatim `--help`) + live
  example output, the complete drivethrough.
