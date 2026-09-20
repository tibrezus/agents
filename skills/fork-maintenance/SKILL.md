---
name: fork-maintenance
description: Maintain forks of upstream projects that carry added features — keep them continuously synced with upstream, automatically, across multiple git hosts (GitHub, Forgejo/Gitea/Codeberg) and multiple projects, while guaranteeing the deployed release branch is always functional. Everything lands via a PR with a safeguard chain (merge-clean, textual conflict-marker scan, post-merge codegen, patch signatures, real build + codegen-drift + integration validation) so only working code merges. Forks can opt into full auto-merge + auto-release (green PR → merged → tagged → image built → deployed by Flux image automation, no human in the loop). Use when setting up or operating fork sync, resolving a sync PR/conflict, debugging "why does our fork drift / fail to build / show another fork's errors", or designing automated/agentic upstream-sync for any forked repo.
---

# Fork Maintenance — Universal Upstream Sync with an Always-Functional Release Branch

This skill maintains **forks that add features on top of an upstream
project** and must stay current with upstream — *without ever breaking the
deployed release branch*. Cardinal invariant, non-negotiable:

> **The release branch (`rezus/<default>` / `main`) is always buildable and
> deployable. Every change lands through a PR. Only PRs that pass every
> safeguard gate merge — and only then can an opt-in auto-merge/auto-release
> fire.**

Universal along two axes: **multi-platform** (GitHub, Forgejo, Gitea,
Codeberg — push/labels/PR/merge dispatch to the right host API) and
**multi-project** (one shared sync implementation; per-fork differences
are *data* in a declarative definition, never code). Sync uses the
**merge model**: conflicts are localized 3-way regions, resolved
mechanically when possible, via the agentic protocol when semantic —
either way the resolution lands in the PR, never on the release branch.

**Canonical source of truth:** co-located with the reference
implementation at `platform/harmostes/fork-maintenance/skill/` in the
GitOps repo (live scripts one directory up).
`skill/scripts/check-drift.sh` keeps the script templates byte-identical
to the live scripts; the `~/.agents/` copy is a synced derivative.

## The two-branch topology (load this into your head first)

| Branch | Role | Mutability |
|--------|------|------------|
| `<upstream-release>` (mirror) | clean 1:1 upstream mirror, read-only reference | force-reset to upstream when needed |
| `rezus/<default>` (release) | upstream + feature patches + additive code; **the default branch** so tag-triggered release fires here; **always functional** | only via merged, green PR |

No third branch; you never commit to the release branch directly.
**Branch-per-major:** the release branch is named for the upstream major
it tracks (`rezus/forgejo-16`); each major is its own release line,
synced independently — a bad sync on the staging major cannot touch
production. A new upstream major spawns a NEW branch; it never rebases
the old one (runbook: [`references/operations.md`](references/operations.md)).

## The generic model (read this first)

Fork maintenance is a **mapping table**: rows map `theirs → ours`
(e.g. `v16.0/forgejo → rezus/forgejo-16`). Invariant per row:
`ours ⊇ theirs`. Sync restores it; release derives identities across it
(theirs = identity, ours = ordinal). Operations are ROW operations: add
(major upgrade = new row + one merge of the old ours + green proof),
edit, delete. The registry defs in `forks/` state the table; transports
execute it. **forgejo** is self-hosted (`.github/workflows/sync.yml`
walks the table daily; the engine politely declines mapping defs);
**dapr / signoz / llama-cpp** use the plugin transport (phase mode below).

## Version identity (upstream-identity versioning)

**The fork mints no version of its own; identity is the upstream version,
everything else is provenance.** The binary reports the upstream version
it is based on (`16.0.2`) — no fork-branded versions, no hand-bumped
counters. `v*-rezus.N` tags are release **triggers**, cut machine-computed
(`<upstream-ver>-rezus.<N+1>` from `git describe`); the release workflow
derives identity `16.0.2` + provenance `+rezus.N` (semver build metadata)
+ docker-hyphen form + a `<shortsha>` fingerprint tag from them.
"What's different vs upstream?" is answered by provenance, not version:
`git log v16.0.2..rezus/forgejo-16 --grep '^RZ/'` plus the structural
tools (additive paths, patch signatures).

## Commit convention (RZ/)

| Prefix | Who | Meaning |
|--------|-----|---------|
| `RZ/sync:` | sync plugin | an upstream merge appended to the release line |
| `RZ/bp:` | `backport.sh` / agent | an upstream commit cherry-picked ahead of the next release — carries `(cherry picked from commit …)` |
| `RZ/resolve:` | conflict-resolver agent | conflict resolution on a sync/backport branch |
| `RZ/feat:` / `RZ/fix:` | humans | new fork customizations |

Applies to NEW commits (existing history is immutable — merge model). It
makes the fork's delta machine-queryable (`--grep '^RZ/'`) and
self-explaining in `git log`.

## Sync model: merge + an LLM maintainer

The plugin **merges** the upstream release branch into the fork's release
branch — it does **not** cherry-pick / replay customizations onto fresh
upstream. Why merge: **immutable customizations** (patches keep stable
SHAs — append-only, bisectable, citable); **localized conflicts** (only
where upstream *and* our patch changed the same region — small 3-way
`base`/`ours`/`theirs` regions, vs per-commit resolution against a moving
base); **isolated mistakes** (a bad resolution is one `git revert -m 1`,
not a smeared rebuild); **no accumulation** (commit reachability answers
"is this custom already applied?" structurally). Ideal for an LLM
maintainer: small stable conflict surface, concrete 3-way context, a
wrong call is one revert — and because we track release branches, most
merges are clean, so the LLM is invoked only on the rare real conflict.
On conflict the resolver re-creates the exact merge, resolves from the
fork's wiki chapter, and re-runs the gates as **proof** before merge.

**Track release branches, not main; one release line per major.** Point
`upstream.branch` at the upstream release/maintenance branch
(`v16.0/forgejo`), not dev `main` — slow-moving branches → smaller
deltas → fewer conflicts → fewer LLM chances to err. (A fork that must
track `main` can; the safety properties hold regardless.)

## Vendored-tree mode (subtree sources)

Some upstreams aren't forked — they're **vendored** inside a monorepo at
a pinned version (`runner/`, `charts/forgejo/`). Same plugin, `mode:
subtree` in the fork def; the sync unit is *(target repo, vendored path,
pin file)* and the plugin never edits vendored content itself. Decision
model (patch-class auto-merges on CI green; minor = manual merge +
validation contract; major = advisory only), the pristine vs
patch-accounting gate flavors, the operations table, and the onboarding
recipe: **[`references/vendored.md`](references/vendored.md)**.
`DRY_RUN=1` runs the full decision path with zero writes.

## When to use this skill

Setting up automatic upstream sync; a fork behind upstream / drifted /
failing to build after a sync; a sync PR with conflicts or failed
validation; backporting an upstream security fix; a new upstream major
(transition runbook); one fork's PR showing another fork's validation
errors (cross-contamination — [safeguards](references/safeguards.md));
adding a fork; enabling auto-merge/auto-release; moving a fork between
hosts; skill-vs-implementation drift (`skill/scripts/check-drift.sh`).

## The invariant, restated as a gate chain

A sync PR may merge only after **all** gates pass, in order (rationale and
failure modes: [references/safeguards.md](references/safeguards.md)).

1. **Merge applied cleanly** — no unresolved conflict markers in file
   content (not just the git index — see gotcha below).
2. **Permanent divergences re-applied** — deleted upstream dirs
   re-deleted; additive paths preserved.
3. **Post-merge hook succeeded** — per-fork codegen (SDK regen, swagger,
   `go mod tidy`, ee-stripping) ran and produced expected artifacts.
4. **Patch signatures intact** — every feature patch's grep-verifiable
   proof string still present (a merge didn't silently drop it).
5. **Validation passed** — the checks *this fork* declares (go_build /
   go_test / clean_tree / integration), built with the **fork's declared
   toolchain**, all green in a real toolchain.
6. **(Agentic) conflict resolved & re-validated** — the resolution itself
   was validated before the PR is marked auto-mergeable.
7. **(Opt-in) Auto-merge + auto-release** — if all above pass *and*
   `auto.merge: true`, the plugin merges immediately; `auto.release: true`
   also cuts the next machine tag `<upstream-ver>-rezus.<N+1>` so the
   tag-triggered workflow builds an image Flux deploys (identity =
   upstream version).

**The single most important gotcha** (it has shipped broken branches in
production): after a conflicted merge, the divergence-cleanup step does
`git add -A`, which **clears git's unmerged-path state**
(`git diff --diff-filter=U` finds nothing) but **leaves `<<<<<<<` /
`=======` / `>>>>>>>` markers in the file content**. The index-based
check passes and a non-building branch gets pushed. `sync-fork.sh`
therefore *also* `git grep`s for textual markers regardless of index
state. This is gate 1.

## Operating commands

### Sync one fork now (manual)

```bash
FORK_NAME=<fork> bash scripts/sync-fork.sh <fork>          # all phases (legacy single-shot)
FORK_NAME=<fork> bash scripts/sync-fork.sh <fork> <phase> # one phase (see below)
# all-mode exit codes: 0 = up to date or PR opened (auto-merged if auto.merge); 2 = conflict; 3 = push failure
```

**Phase mode (graph-native workflows):** the plugin is phase-addressable —
`merge | hook | gates | validate | pr | tag` — with each phase its own
harmostes node (`plugin fork-sync <fork> <phase>`). Phases share the
clone via `HARMOSTES_WORKDIR/fork-<name>` and pass state through
`.git/harmostes-state.env`:

| Phase | green | red |
|---|---|---|
| `merge` | `changed:true` merged / `changed:false` no-op (node skipped) | exit 2 conflict → `when:failed` edge → external resolver node |
| `hook` | codegen complete | failed node |
| `gates` | divergence + patches intact | pushes needs-fix PR, then fails honestly |
| `validate` | declared checks green | failed node |
| `pr` | `changed:true` merged / `changed:false` left for review | push failure |
| `tag` | machine-cuts `v<upstream>-rezus.<N+1>` (`describe` output must be pure `vX.Y.Z`) | no release |

Phased `merge` reads the **local mirror branch** (the alias remote), never
the upstream host — the mirror action + webhook are the only upstream
conduit. To trigger in-cluster: annotate the Workflow
(`harmostes.dev/trigger-revision`) or push to the fork's mirror branch;
watch nodes in the UI (Map/Attempts).

### Validate a fork locally (the same plugin the CronJob uses)

```bash
bash checks/validate-fork.sh <fork> <path-to-fork-checkout>
# exit 0 = all declared checks pass; stdout is a markdown block embedded in the PR body
```

Runs **only** the checks the fork declares (no checks = clean pass, e.g.
non-Go projects). Honors `validation.toolchain.go` (precedence: declared
> `go.mod`) via `GOTOOLCHAIN` so the build uses the exact pinned Go minor.

### Verify patches independently

```bash
bash scripts/verify-patches.sh forks/<fork>.yaml <path-to-fork-checkout>
# exit 0 = all signatures present; 1 = some lost (needs re-application)
```

### Rare procedures → [`references/operations.md`](references/operations.md)

Conflict resolution (`resolve-conflict.sh`), backports (`backport.sh`),
the major-version transition runbook, resolving a sync PR manually,
adding a new fork, enabling full automation, keeping the skill in sync
with the implementation.

## The fork definition (single source of truth)

Every per-fork difference is data here — this is what makes the process
multi-project. Full annotated template:
[`templates/fork.yaml`](templates/fork.yaml).

```yaml
name: <fork>
upstream:  { url, branch }
fork:
  url: https://github.com/org/repo        # or codeberg.org/...
  default_branch: rezus/<default>-<major> # branch-per-major; the host's default branch
  mirror_branch: <release-branch>         # clean upstream mirror
  platform: github                        # github | forgejo  ← multi-platform
  api_url: https://codeberg.org/api/v1    # forgejo only (REST base)
  token_env: GITHUB_TOKEN                 # env var holding the host PAT
versioning: { tag_pattern: "v*-rezus.*" } # machine-cut release TRIGGERS (identity = upstream version)
auto: { merge: false, release: false }    # opt-in full automation
patches:                                  # feature patches, each grep-verifiable
  - { file, description, signature }
additive_paths: [...]                     # our code that never conflicts with upstream
deletions: [ee/]                          # permanent divergence (re-deleted each sync)
post_merge_hook: post-merge-hooks/<name>.sh
release: { dockerfiles, multi_arch, image_registry, chart_registry, build_cli, version_file }
validation:                               # ← multi-project: declare YOUR checks
  toolchain: { go: "1.25.7" }             # pin Go minor (declared > go.mod)
  go_build:   [{ module, packages }]
  go_test:    [{ module, packages }]   # behavioral gate (#564): declare TARGETED
                                       # feature packages, never upstream's suite
                                       # (fast + deterministic — runs every sync)
  clean_tree: { paths: [...] }
  integration: { kind: forgejo-live, image, module, env }
```

## How the plugin stays universal

**Host abstraction** (`git-host.sh`): each fork declares `platform`;
push = credential helper on both hosts; labels/PRs/**PR merge** = `gh`
CLI or Forgejo REST. Adding a host = one `case` arm per operation.
**Universal validator** (`validate-fork.sh`): a generic dispatcher over
the `validation:` block; adding a language = adding a check type — never
hardcode one fork's structure into the validator (that bug made every
fork's PR show the reference fork's errors). **Per-fork result files**
(`/tmp/fork-validation-<name>.md`, never a shared path — one CronJob pod
runs many forks). **Agentic escalation**: conflicts emit
`fork.conflict.needs-resolution` (Dapr pub/sub or
`manifests/<fork>-needs-fix.json`), consumed by `resolve-conflict.sh`.
Depth: [references/architecture.md](references/architecture.md).

## Automation model

Sync is **automatic and regular**: a Flux `GitRepository` polls each
upstream; a `*/30 * * * *` CronJob executes; an `Alert` can trigger an
immediate sync on upstream change. Scripts + definitions ship as
**ConfigMaps** (`configMapGenerator` — Flux reconciles on push, no image
rebuild, no GitOps clone inside the job); the GitHub PAT comes from
Bitwarden via `ExternalSecrets`. A green sync PR then either sits for
human review (`auto.merge: false`, the default) or — with
`auto.merge: true` (+ `auto.release: true`) — merges, cuts the next
machine tag, and deploys via Flux image automation: **fully hands-off,
no human ever types a version**. The release branch is touched *only* by
a merged PR, so a broken sync can never deploy.

## Deep references (load on demand)

- [**references/architecture.md**](references/architecture.md) — full design: what lives where, the four sync shapes, the sync-chain sequence, host abstraction, validation-as-data.
- [**references/safeguards.md**](references/safeguards.md) — each gate's failure mode and the production bugs it prevents.
- [**references/conflict-resolution.md**](references/conflict-resolution.md) — mechanical vs semantic conflicts, the agentic protocol, the validation loop, escalation.
- [**references/operations.md**](references/operations.md) — the rare procedures (see Operating commands).

## Templates (portable starting points)

Engine (verbatim copies of the live scripts, drift-guarded by
`skill/scripts/check-drift.sh`): `sync-fork.sh` (the universal plugin),
`git-host.sh`, `validate-fork.sh`, `verify-patches.sh`,
`generate-manifest.sh`, `cronjob-entrypoint.sh`,
`cronjob-sync-forks.yaml`, `external-secret-github.yaml` — all under
[`templates/`](templates/). Generic (hand-maintained examples):
`fork.yaml` (annotated definition with `auto:` + toolchain),
`post-merge-hook.sh`, `alert-upstream-changes.yaml`,
`gitrepository-upstreams.yaml`.

## Checklist before declaring a sync "done"

- [ ] Sync branch pushed; PR open against the **release** branch (not mirror)
- [ ] No `<<<<<<<`/`>>>>>>>` markers anywhere in the tree (gate 1)
- [ ] All declared patch signatures present (gate 4) — PR body says `all-intact`
- [ ] `validate-fork.sh` green for *this* fork, in a real toolchain, with the declared toolchain (gate 5)
- [ ] Engine commits carry their `RZ/` prefix (`RZ/sync:` / `RZ/bp:` / `RZ/resolve:`)
- [ ] PR label is `auto-merge` (or `needs-fix`/`needs-conflict-resolution` with a clear reason)
- [ ] If `auto.merge: true`: PR merged by the plugin; release branch still functional
- [ ] If `auto.release: true`: next machine tag `<upstream-ver>-rezus.<N+1>` pushed; release derives pure-upstream VERSION; image build triggered
- [ ] Release branch untouched by the sync run (only the PR — or the auto-merge — can change it)
- [ ] If agentic resolution was used: the resolution was re-validated, not trusted (gate 6)
- [ ] No hand-edited version anywhere (identity = upstream version; counters are machine-cut)
