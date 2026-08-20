# `fj` command reference — the full drivethrough

Verbatim `--help` output for every command, plus live example output against
`git.rezus.cloud` / `tibrez/rhesadox`. This is the complete command surface of the
Go `fj` (rezuscloud Forgejo fork, `16.0.2-rezuscloud.x`). For targeting rules and
workflow, see the parent `SKILL.md`; for the API origin and the
operationId→command derivation, see [`api.md`](api.md).

Every command accepts the three global flags:

```
Global Flags:
  -H, --host string     the forgejo instance to use          (git.rezus.cloud | codeberg.org | …)
  -R, --remote string   git remote to use                    (origin | upstream | …)
  -r, --repo string     repo to operate on (owner/name)      (tibrez/rhesadox)
```

---

## Top level

```
$ fj
fj is a command-line client for Forgejo (https://forgejo.org).

Available Commands:
  actions     Manage repository actions
  api         Raw API access (auto-generated from swagger spec)
  auth        Manage authentication
  completion  Generate the autocompletion script for the specified shell
  help        Help about any command
  issue       Manage issues
  org         Manage organizations
  pr          Manage pull requests
  release     Manage releases
  repo        Manage repositories
  tag         Manage tags
  user        Manage users
  version     Print the fj, client API, and server versions
  whoami      Show the currently authenticated user
  wiki        Manage wiki pages
```

### `fj version`
```
Print version information, mirroring `kubectl version`:
  Client Version:  the fj binary version
  API Version:     the Forgejo REST API level this CLI's SDK was generated from
  Server Version:  the live Forgejo server version (queried from GET /version)
Flags:  --client   client version only (skip the server query)
        --short    print a single compact line
```
Live:
```
$ fj version --client
Client Version: fj 16.0.2-rezuscloud.2
API Version:    16.0.0-dev
```

---

## Authentication — multi-instance management

```
$ fj auth
Manage authentication
Available Commands:
  add-key     Add an application token for the current --host
  list        List all authenticated hosts
  login       Log in to a Forgejo instance (browser OAuth or token prompt)
  logout      Log out of a Forgejo instance
```

Live:
```
$ fj auth list
  codeberg.org (type: Application)
  git.rezus.cloud (type: Application)

$ fj whoami -H git.rezus.cloud
currently signed in as tibrez <tiberiu@rezus.net>
```

---

## Issues

```
$ fj issue            (alias: issues)
Manage issues
Available Commands:  close  comment  create  list  view

fj issue view <INDEX>   flags: -c, --comments   show the comment thread
fj issue list           flags: -s, --state string   open|closed|all (default "open")
fj issue create         flags: -t, --title (required)  -b, --body
fj issue comment <INDEX> flags: -b, --body (required)
fj issue close <INDEX>
```

Live (open issues):
```
$ fj issue list -H git.rezus.cloud -r tibrez/rhesadox
#1330 OK [open] refactor(#1329): shared per-expert bookkeeping substrate …
#1329 OK [open] Per-expert bookkeeping substrate — unify the CUDA + Vulkan …
#1328 OK [open] feat(#1327): emit prefill performance through the observability layer
...
```
`#1330` is the repo-local **Number** (the URL id), passed to `view`/`comment`/`close`.

---

## Pull requests

```
$ fj pr              (alias: prs)
Manage pull requests
Available Commands:  create  list  merge  status  view

fj pr view <INDEX>
fj pr list           flags: -s, --state string   open|closed|all (default "open")
fj pr create         flags: --head (required)  --base (default "main")
                          -t, --title (required)  -b, --body
fj pr status <INDEX>      ★ CI check status for the PR
fj pr merge <INDEX>  flags: -s, --style  merge|rebase|squash|rebase-merge|fast-forward-only (default "merge")
                          -d, --delete-branch   delete the head branch after merging
```

Live — `pr status` is the CI health view (per-check state, duration, deep link):
```
$ fj pr status 1174 -H git.rezus.cloud -r tibrez/rhesadox
#1174 feat(#1113): COMPUTE-stage copy shader for expert-cache promotion
Head: 79084a7bff54d31aa07ed16f9802f5c1d6527184
Overall: OK success

  OK success   decode / decode (cuda) (pull_request)
      Successful in 8m28s
      /tibrez/rhesadox/actions/runs/6118/jobs/0
  OK success   integration / integration (vulkan) (pull_request)
      Successful in 59s
      /tibrez/rhesadox/actions/runs/6119/jobs/2
  ...
```

---

## Releases & tags

```
$ fj release         Available: create  delete  list  view
fj release create    flags: --tag (required)  -n, --name  -b, --body  --draft  --prerelease
fj release view <TAG>
fj release delete <TAG>

$ fj tag             Available: create  delete  list
fj tag create <TAG>
fj tag delete <TAG>
```

---

## CI status & logs — Actions  ★

```
$ fj actions
Manage repository actions
Available Commands:  dispatch  jobs  logs  runs  secrets  tasks  variables

fj actions runs            # recent runs: #ID (sha) STATE (event): title
                            # filters (PR #75): --limit --page --status --event
                            #   --head-sha --ref --workflow-id --run-number
                            #   --status/--event comma-separated lists
fj actions jobs <RUN>      # jobs in a run: #ID name [status] runs_on:<label>
fj actions tasks           flags: -p, --page int (default 1)
fj actions logs            flags: --run int    download all jobs' logs (zip)
                                    --job int    print a single job's logs (plain text)
                                    --out string output file for --run (default run-<id>-logs.zip)
fj actions dispatch        # dispatch a workflow
fj actions secrets         # manage action secrets
fj actions variables       # manage action variables
```

Reading order for a failing PR: **runs → jobs → logs**, or start from `pr status`.

Live:
```
$ fj actions runs -H git.rezus.cloud -r tibrez/rhesadox
#6974 (1951b8a650) RUN (pull_request): fix(#1329): CI — vulkan build …
#6972 (3de7d2d591) FAIL (pull_request): feat(#1329): shared per-expert bookkeeping …
#6969 (531f82257b) OK (pull_request): feat(#1327): emit prefill performance …

$ fj actions jobs 6400 -H git.rezus.cloud -r tibrez/rhesadox
#12420 build-test [failure] runs_on:ubuntu-latest

$ fj actions tasks -H git.rezus.cloud -r tibrez/rhesadox
12765 tasks
#6974 (1951b8a650) RUN decode (cuda) (pull_request): fix(#1329): …
#6972 (3de7d2d591) FAIL integration (vulkan) (pull_request): feat(#1329): …
...
```

**Run states:** `OK` (success) · `FAIL` · `RUN` (running) · `WAIT` (queued) · `BLOCKED`.
`runs`/`tasks` return **exit 0** even on failed runs — parse the `FAIL` token.

`logs`:
- `--job <JOB>` → single job's log to **stdout** (read/grep directly).
- `--run <RUN>` → **zip** of all jobs' logs (`--out <path>` to name it).

---

## Repos / users / orgs / wiki

```
$ fj repo             Available: clone  view
fj repo view  [OWNER/NAME]
fj repo clone <OWNER/NAME> [DIRECTORY]

$ fj user             Available: repos  search  view
fj user view <USERNAME>
fj user repos <USERNAME>
fj user search <QUERY>

$ fj org              Available: list  view
fj org list
fj org view <NAME>

$ fj wiki             Available: list  view
fj wiki list          # needs -H <host> -r <repo>
fj wiki view <PAGE>
```

---

## Raw API escape hatch — `fj api`

Auto-generated from the swagger spec; one subcommand per SDK method — see
[`api.md`](api.md) for the origin and naming rules. Prefer the polished
commands above; reach for `fj api` only for gaps (milestones, labels,
branches, admin, runners).

```
$ fj api
Raw API access to every Forgejo REST endpoint. Each subcommand corresponds to an
SDK method generated from the swagger spec. For polished commands with
human-readable output, use the top-level commands (issue, pr, actions, etc.) instead.

Available Commands:
  activitypub activitypub service (auto-generated)
  admin       admin service (auto-generated)
  misc        misc service (auto-generated)
  notify      notify service (auto-generated)
  org         org service (auto-generated)
  repo        repo service (auto-generated)
  user        user service (auto-generated)
```

```
$ fj api repo             # lists all 265 repo endpoints with one-line descriptions
$ fj api repo | grep -i wiki    # → get-wiki-pages, get-wiki-page, create-wiki-page…
$ fj api repo issue-edit-milestone --help
Update a milestone
Flags:
      --body string    body
      --id int         id
      --owner string   owner
      --repo string    repo
```

**Discover, don't guess.** Command names come from swagger operationIds and
aren't always the obvious word. Always `fj api repo | grep <keyword>` for the
real name first — a wrong name gives **empty stdout** (cobra reports
`unknown flag: --owner` to stderr). Wiki example: `fj api repo get-wiki-pages
--owner tibrez --repo rhesadox -H git.rezus.cloud`.

### Milestones (fj milestone — PR #76)

```bash
fj milestone list [-s open|closed|all] [--name <title-substring>] -H <host> -r <o>/<r>
                            # rows: #ID ✅/✗ [state] title (ids for view/edit/close/delete)
fj milestone view <ID>      # title, state, due, open/closed issue counts, description
fj milestone create -t <title> [-d <desc>] [--due 2026-09-30T00:00:00Z]
fj milestone edit <ID> [-t] [-d] [--state open|closed] [--due]   # partial: only provided flags change
fj milestone close <ID>     # ≡ edit --state closed
fj milestone delete <ID>
```

`--due` is RFC3339 and validated; edit is a partial PATCH (unset flags leave
fields untouched — verified live). Generate-a-gap escape hatch stays available:
`fj api repo issue-*-milestone` for anything the group lacks.
`--id` is the opaque milestone id from `get-milestones-list` (milestones have no
repo-local number like issues). Body schema: `{title, description, state, due_on}`.

`--body`'s field names are not shown in `--help`; the JSON must match the Option
struct (`{title, description, state, due_on}` for milestones).
