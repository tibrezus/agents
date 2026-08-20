# The Forgejo REST API — origin reference

The API is the single source of truth. The `fj` CLI (and its Go SDK) are
*generated* from the instance's own swagger spec, so the API's structure is
the CLI's structure. This page documents that structure once; command details
live in `command-reference.md`.

## Where the spec lives

Every instance serves its spec (auth not required):

```
https://git.rezus.cloud/swagger.v1.json      # self-hosted
https://codeberg.org/swagger.v1.json         # upstream public
```

Key metadata: `basePath: /api/v1`, `info.version` (the API/SDK level),
`paths` (326), operations (507) on v16.0.2. The API level is also what
`fj version` reports as **API Version** — keep CLI and server on the same
release line (CLI version == Forgejo release version by convention).

## How the spec is organized → how the CLI groups it

Swagger declares ~10 tags (`repository`, `issue`, `admin`…), but the generator
**does not use tags** — it groups by the **first URL path segment**, which is
what actually predicts where a command lands:

| URL first segment | `fj api` service | ops (v16.0.2) | covers |
|---|---|---|---|
| `/repos/…` | `repo` | 265 | repos, issues, PRs, releases, branches, labels, milestones, wiki, actions, … |
| `/users/…` | `user` | 80 | user profiles, emails, keys, tokens, settings |
| `/orgs/…` | `org` | 69 | orgs, members, teams, hooks |
| `/admin/…` | `admin` | 51 | instance administration, runners, quotas, cron |
| `/notifications/…` | `notify` | 7 | notification feed |
| `/activitypub/…` | `activitypub` | 11 | federated actor endpoints |
| *everything else* | `misc` | ~25 | version, signing, misc endpoints |

So an *issue* endpoint like `/repos/{owner}/{repo}/milestones` is a **`repo`**
service command (`fj api repo issue-create-milestone`) — the path decides, not
the domain word. Rule of thumb: **the service is the first path segment, plural
→ singular** (`repos→repo`, `orgs→org`, `notifications→notify`).

## operationId → command name

Each operation has an `operationId` (e.g. `repoGetWikiPages`,
`issueCreateMilestone`, `acceptRepoTransfer`). The generator derives the
subcommand as:

```
command = kebab-case(operationId), minus a redundant leading service prefix
   repoGetWikiPages      → repo  get-wiki-pages
   issueCreateMilestone  → repo  issue-create-milestone   (no prefix to strip)
   acceptRepoTransfer    → repo  accept-repo-transfer
```

Forgejo's operationIds are inconsistent — some carry the service word, some
don't — so the strip step exists to keep names guessable (fixed in the fork,
commit `21fb276`; ≤ `.2` builds kept a redundant `repo-` prefix on 159
commands). Collision-free by construction (operationIds are unique).

**Invoking**: `fj api <service> <command> --<param flags> [--body '<json>'] -H <host>`

- **Path parameters** (`{owner}`, `{repo}`, `{id}`…) → **required flags**
  (`--owner`, `--repo`, `--id`). Missing ones: `required flag(s) "owner" not set`.
- **Query parameters** → optional flags (`--state`, `--page`, …).
- **List-typed query params** (swagger `type: array`, e.g. `status`, `event`
  of list-action-runs) take a **comma-separated flag value** but travel on the
  wire as **repeated query params** (`?status=a&status=b`) — the server reads
  them via `FormStrings` (`url.Values[key]`); a joined or bracketed value is
  a 400. The SDK serializes them with `qry.Add` per element; the CLI splits
  the flag with `parseStringSlice` (same helper for polished and generated
  commands — reuse it, never hand-roll).
- **Request body** → `--body` taking JSON that must match the operation's
  schema `$ref` (e.g. `CreateMilestoneOption`: `{title, description, state, due_on}`).
- **Responses** print as JSON on stdout; errors print to stderr with non-zero exit.

## Mining the spec (origin-side discovery)

When you don't know the operation, query the spec — this is the same data
`fj api <svc>` lists, but with full schemas:

```bash
# all operationIds matching a keyword, with method+path
curl -s https://git.rezus.cloud/swagger.v1.json | jq -r '
  .paths | to_entries[] | .key as $p | .value | to_entries[]
  | select(.value.operationId != null)
  | select(.value.operationId | test("(?i)milestone"))
  | "\(.value.operationId)  \(.key|ascii_upcase)  \($p)"'
# → issueGetMilestonesList  GET  /repos/{owner}/{repo}/milestones
#   issueCreateMilestone    POST /repos/{owner}/{repo}/milestones …

# the request-body schema for a POST/PUT/PATCH operation
curl -s https://git.rezus.cloud/swagger.v1.json | jq '.components.schemas.CreateMilestoneOption | .properties | keys'
```

Client-side equivalent: `fj api repo | grep -i milestone` (names + one-line
summaries, what the binary actually accepts). Either way — **discover, don't
guess**: a wrong name yields empty stdout (cobra flags the *next* flag as
unknown, on stderr).

## Where the generator lives (fork side)

The whole chain is in the fork monorepo `github.com/rezuscloud/forgejo`
(default branch `rezus/forgejo-16`, managed by the **fork-maintenance**
workflow — changes go through that system, never direct):

```
staging/src/forgejo.org/client-go/gen/main.go   # reads swagger.json →
                                                #   SDK services + fj api cobra tree
  groupByService() / classify(path)             # path-first-segment → service
  cmdNameFor(svc, opID)                         # kebab + strip redundant prefix
```

- The spec input is vendored next to the generator (`swagger.json`); regenerate
  when re-baselining on a new Forgejo release (v17+ changes the op set).
- The polished commands (`fj issue`, `fj pr`, `fj actions`…) are **hand-written**
  in `staging/src/forgejo.org/fj/pkg/cmd/` on top of the same generated SDK —
  they add human-readable output and CI-log access (upstream Rust `fj` lacks
  job logs). A new polished command = thin wrapper over one SDK method.
- `fj` ships prebuilt in the fork's GitHub Release (`fj-<os>-<arch>.tar.gz`,
  tag `forgejo-v*`); the release version equals the Forgejo release it targets.

## Versioning contract

| Layer | Version | Where |
|---|---|---|
| Server | e.g. `16.0.2-rezuscloud.3` | `fj whoami`-adjacent; `GET /version`; `swagger.v1.json` `info.version` |
| SDK / `fj api` tree | generated from the server's spec | `fj version` → *API Version* |
| `fj` binary | matches the Forgejo release | `fj version --client` |

Mismatch is tolerated within a minor line, but new endpoints exist only from
the version that introduced them — check the spec of *your target instance*
when in doubt (self-hosted runs a fork distribution; codeberg.org may lag).
