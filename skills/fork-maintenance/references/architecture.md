# Architecture — Centralised GitOps Fork Maintenance

The design goal: maintain N forks of N upstreams, each carrying added features, each continuously synced, each on a different git host, with **one** shared plugin and **zero** per-fork duplication of sync logic. The release branch of every fork stays functional at all times.

## What lives where

### Fork repos — clean, minimal

Each fork repo contains **only**: upstream code + feature patches +
additive code + **one** CI file (`.github/workflows/release.yml`,
tag-triggered build). No maintenance scripts, sync workflows, manifests,
or per-PR CI — those artifacts duplicated across forks and drifted; they
belong in the GitOps repo.

### GitOps repo — all maintenance logic, version-controlled, GitOps-reconciled

```text
<gitops-repo>/platform/harmostes/fork-maintenance/
├── kustomization.yaml          # ConfigMap generators → scripts delivered GitOps-native
├── forks/<name>.yaml           # declarative fork definitions (the "what")
├── scripts/                    # shared sync logic (the "how") — universal
│   ├── sync-fork.sh            #   merge + hook + validate + open PR
│   ├── git-host.sh             #   github | forgejo host abstraction
│   ├── generate-manifest.sh    #   diff → divergence manifest (audit)
│   ├── verify-patches.sh       #   signature grep verification
│   └── cronjob-entrypoint.sh   #   runtime tool installer
├── checks/validate-fork.sh     # universal validation dispatcher (per-fork checks)
├── post-merge-hooks/<name>.sh  # per-fork post-merge logic (codegen etc.)
├── manifests/<name>-rezus.yaml # generated divergence manifests (audit trail)
├── skill/                      # ← CANONICAL skill (source of truth for agents;
│   ├── SKILL.md                #   references/, templates/, scripts/check-drift.sh —
│   └── …                       #   synced to ~/.agents/skills/fork-maintenance/)
└── flux/                       # upstream monitors + sync trigger (GitRepository,
    └── …                       #   Alert, cronjob, external-secret-<host>-token)
```

Scripts and definitions ship as **ConfigMaps** (kustomize
`configMapGenerator`): reconciling the GitOps repo updates them and the
CronJob picks up the latest at runtime — no image rebuild, no GitOps
clone inside the job.

## The four shapes of "keep ours current with theirs"

| Shape | Example | Merges / gate | Release |
|-------|---------|---------------|---------|
| **merge fork** | dapr, signoz, llama-cpp | upstream branch → release branch (immutable patches); centralized checks + signatures | plugin tags `v*-rezus.*` (opt-in auto) |
| **subtree** (pristine) | `runner/` (forgejo monorepo) | delegate re-vendors at the new pin; byte-diff vs upstream archive | target repo's cycle (plugin reports unreleased-pending) |
| **subtree + patches** | `charts/forgejo/` | re-vendor + re-apply the declared contract; diff must be exactly `preserve:` + signed `patches:` (contract read by plugin AND the target's CI guard) | target repo's cycle |
| **merge into monorepo** (mapping table) | forgejo itself (codeberg `v16.0/forgejo` → `rezus/forgejo-16`) | upstream release branch → monorepo release branch; regen + repo-local validation before push (`sync-validate.sh`, regen committed) | deliberate tags only — a sync never mints a version |

One plugin, one severity model across all shapes: RED = automation should
already have fixed it; WARN = policy-gated human action.

## The sync chain (sequence)

```text
Flux GitRepository artifact updates ── or ── Alert → immediate sync
   ▼
CronJob fork-sync (in-cluster, reads ConfigMaps) — for each fork definition:
sync-fork.sh <fork>
   ├── clone fork (shallow) + add upstream remote + fetch
   ├── if upstream unchanged since merge-base → exit (nothing to do)
   ├── create rezus/sync-<date> branch off the release branch
   ├── merge upstream/<branch>
   ├── re-apply permanent divergences (deletions)         [gate 2]
   ├── run post-merge hook (codegen / tidy / strip)        [gate 3]
   ├── scan for textual conflict markers → abort if any    [gate 1]
   ├── verify patch signatures (grep)                      [gate 4]
   ├── run validate-fork.sh (this fork's declared checks)  [gate 5]
   ├── generate divergence manifest → manifests/<fork>-rezus.yaml (audit)
   ├── push sync branch
   ├── open PR (host-routed) with validation results in body
   │            label = auto-merge | needs-fix | needs-conflict-resolution
   └── if label=auto-merge AND auto.merge:                 [gate 7, opt-in]
        ├── host_pr_merge (squash + delete branch)
        └── if auto.release: tag <upstream-ver>-rezus.<N+1>
             → fork release.yml builds image → Flux image automation deploys
```

Downstream of the PR: human review (`auto.merge:false`) / plugin merge
(`true`) / agent resolves → PR merges → release branch advances (still
functional, by construction).

## Branch topology

| Branch | Purpose | Content | How it changes |
|--------|---------|---------|----------------|
| `<upstream-default>` (mirror) | Clean upstream mirror | 1:1 with upstream | force-reset to upstream when stale |
| `rezus/<default>` (release) | **The deployed branch** | upstream + patches + additive | **only via merged green PR** — the GitHub/forgejo default branch so tag-triggered release fires |

The mirror exists so `git merge` has a clean upstream ref and `git describe` reaches upstream tags for versioning; it is never the merge target. One release line per major (slow-moving release branches → small deltas → most merges clean); the mirror tracks whichever upstream branch the fork line follows. Topology and rationale: [`SKILL.md`](../SKILL.md).

## Versioning

`v<upstream-version>-rezus.<build-number>` — e.g. `v0.127.0-rezus.2`. SemVer-compatible; the `-rezus.N` suffix sorts correctly and `git describe` works because upstream `v*` tags are reachable through the mirror. Identity is the upstream version (see [`SKILL.md`](../SKILL.md), Version identity).

## Multi-platform: host abstraction

`git-host.sh` is sourced by `sync-fork.sh`. Each fork declares:

```yaml
fork:
  url: <host>/org/repo
  platform: github | forgejo      # default github
  api_url: <forgejo REST base>    # forgejo only
  token_env: <env var name>       # default per platform
```

- **Git push** (identical on both): credential helper
  (`https://x-access-token:<token>@<host>`).
- **Labels**: `gh label create` | REST `POST …/labels`. **PR**:
  `gh pr create` | REST `POST …/pulls` + `POST …/issues/{n}/labels`
  (body JSON with `jq`). **PR merge** (opt-in auto-merge):
  `gh pr merge --squash --delete-branch` | REST `POST …/pulls/{n}/merge`
  `{"Do":"squash",…}`.

Adding a host (GitLab, Bitbucket…): add a `case` arm to `host_setup` / `host_label_create` / `host_pr_create` / `host_pr_merge`. One place each.

## Multi-project: validation as data

`validate-fork.sh` is a **generic dispatcher**. It reads the fork's `validation:` block and runs only the declared checks:

| Check type | Key | What it verifies |
|------------|-----|------------------|
| Toolchain | `validation.toolchain.go` | pins the exact Go minor via `GOTOOLCHAIN` (precedence: declared > `go.mod`) |
| Go build | `validation.go_build[]` | declared packages compile, per module, with the declared toolchain |
| Go test | `validation.go_test[]` | declared packages' tests pass — the BEHAVIORAL gate (#564): a signature proves the patch text survived the merge, a test proves the feature works. Declare targeted feature packages, never upstream's full suite (the gate runs per sync: fast + deterministic) |
| Clean tree | `validation.clean_tree.paths` | generated code committed matches freshly-regenerated (no codegen drift) |
| Integration | `validation.integration.kind` | opt-in harness routine (e.g. `forgejo-live`) |

Adding a language/ecosystem = adding a check type (`cargo_build`, `cmake_build`, `npm_build`, `dotnet_test`…). The dispatcher stays generic; one fork's checks never leak into another's.

**Critical**: validation output goes to a **per-fork** file (`/tmp/fork-validation-<name>.md`), never a shared path. One CronJob pod syncs many forks — a shared file is how fork A's results end up in fork B's PR body.

## Adding a new fork

Edit only data + one hook — no plugin changes. Steps (definition yaml,
post-merge hook, Flux GitRepository + Alert, kustomize registration,
forgejo PAT if needed, commit → reconcile): see
[operations.md](operations.md#add-a-new-fork). No change to
`sync-fork.sh`, `git-host.sh`, or `validate-fork.sh`, and none to the
fork repo beyond its existing patches + one `release.yml`.

## Automation model

Trigger: Flux `GitRepository` polls upstream; a `*/N m` CronJob executes;
an `Alert` triggers immediate sync on upstream change. Human action:
review + merge green PRs — **unless** the fork opts into `auto.merge:
true` (green PR self-merges; `auto.release: true` also cuts the tag; the
centralized gates are the CI — no per-PR Actions to wait for).
Escalation: mechanical conflicts auto-resolve; semantic ones are labelled
`needs-fix` for a human or agent
([conflict-resolution.md](conflict-resolution.md)). Safety: the release
branch is modified **only** by a merged PR — a broken sync cannot deploy.

## Reference implementation

`k8s-config/platform/harmostes/fork-maintenance/` is the production instance (forks: forgejo, signoz, dapr, llama.cpp). It demonstrates all four cases: a Go monorepo with codegen + integration (forgejo), a Go single-module with permanent divergence (signoz — strips `ee/`), a Go single-module (dapr), and a non-Go project with no validation (llama.cpp).
