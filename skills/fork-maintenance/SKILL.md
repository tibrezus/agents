---
name: fork-maintenance
description: Maintain forks of upstream projects that carry added features — keep them continuously synced with upstream, automatically, across multiple git hosts (GitHub, Forgejo/Gitea/Codeberg) and multiple projects, while guaranteeing the deployed release branch is always functional. Everything lands via a PR with a safeguard chain (merge-clean, textual conflict-marker scan, post-merge codegen, patch signatures, real build + codegen-drift + integration validation) so only working code merges. Forks can opt into full auto-merge + auto-release (green PR → merged → tagged → image built → deployed by Flux image automation, no human in the loop). Use when setting up or operating fork sync, resolving a sync PR/conflict, debugging "why does our fork drift / fail to build / show another fork's errors", or designing automated/agentic upstream-sync for any forked repo.
---

# Fork Maintenance — Universal Upstream Sync with an Always-Functional Release Branch

This skill maintains **forks that add features on top of an upstream project** and must stay current with upstream — *without ever breaking the deployed release branch*. The cardinal invariant, non-negotiable:

> **The release branch (`rezus/<default>` / `main` / your default) is always buildable and deployable. Every change lands through a PR. Only PRs that pass every safeguard gate merge — and only then can an opt-in auto-merge/auto-release fire.**

The process is **universal** along two axes:

- **Multi-platform** — the fork repo can live on GitHub, Forgejo, Gitea, or Codeberg. Git push, labels, PR creation, **and PR merge** dispatch to the right host API (`gh` CLI vs Forgejo REST — no `tea` dep).
- **Multi-project** — one shared sync engine + validator serves every fork. Per-fork differences are *data* (a declarative fork definition), not code. New language? new host? new build system? — add a check type or a host routine, never fork the engine.

Conflicts are resolved **automatically** when mechanical (signature re-application, divergence re-stripping) and via an **agentic protocol** when semantic (upstream changed an API our patch depends on). Either way the resolution lands in the PR for review — never directly on the release branch.

**The canonical source of truth for this skill is co-located with the reference implementation** at `platform/fork-maintenance/skill/` in the GitOps repo that owns the maintenance system. The live scripts live one directory up (`scripts/`, `checks/`, `flux/`). `skill/scripts/check-drift.sh` verifies the skill's engine templates stay byte-identical to the live scripts, so what an agent reads always matches what the CronJob runs. The copy in `~/.agents/skills/fork-maintenance/` is a synced derivative for agents to load; change the canonical one and re-sync.

## The two-branch topology (load this into your head first)

Every fork has exactly two branches:

| Branch | Role | Mutability |
|--------|------|------------|
| `<upstream-default>` (mirror) | Clean 1:1 upstream mirror, read-only reference | Force-reset to upstream when needed |
| `rezus/<default>` (release) | Upstream + feature patches + additive code. **This is the GitHub default branch** so tag-triggered release workflows fire here. **Always functional.** | Only via merged, green PR |

There is no third branch. You never commit to the release branch directly.

## When to use this skill

- "Set up automatic upstream sync for our fork of X"
- "Our fork is behind upstream / drifted / fails to build after a sync"
- "A sync PR has conflicts / failed validation — resolve it"
- "One fork's PR shows another fork's validation errors" (cross-contamination bug — see [Safeguards](references/safeguards.md))
- "Add a new fork to the maintenance system"
- "Enable auto-merge / auto-release for a fork" (opt-in via `auto.merge`/`auto.release`)
- "Move a fork to a different git host" (GitHub → Codeberg or vice versa)
- "The skill drifted from the implementation" → run `skill/scripts/check-drift.sh`

## The invariant, restated as a gate chain

A sync PR may merge only after **all** gates pass, in order. Each gate is a separate, independently-falsifiable check. See [references/safeguards.md](references/safeguards.md) for the rationale and failure modes.

1. **Merge applied cleanly** — no unresolved conflict markers in file content (not just the git index — see gotcha below).
2. **Permanent divergences re-applied** — deleted upstream dirs re-deleted; additive paths preserved.
3. **Post-merge hook succeeded** — per-fork code generation (SDK regen, swagger, `go mod tidy`, ee-stripping) ran and produced the expected artifacts.
4. **Patch signatures intact** — every feature patch's grep-verifiable proof string is still present (a merge didn't silently drop it).
5. **Validation passed** — the checks *this fork* declares (go_build / clean_tree / integration), built with the **fork's declared toolchain**, all green, run in a real toolchain.
6. **(Agentic) conflict resolved & re-validated** — if a semantic conflict required agent resolution, the resolution itself was validated before the PR is marked auto-mergeable.
7. **(Opt-in) Auto-merge + auto-release** — if all above pass *and* `auto.merge: true`, the engine merges the PR immediately; if `auto.release: true` it also cuts the next release tag `<upstream-ver>-rezus.<N+1>` so the fork's tag-triggered workflow builds an image that Flux image automation deploys.

**The single most important gotcha** (it has shipped broken branches in production): after a conflicted merge, the divergence-cleanup step does `git add -A`, which **clears git's unmerged-path state** (`git diff --diff-filter=U` finds nothing) but **leaves `<<<<<<<` / `=======` / `>>>>>>>` markers in the file content**. The index-based conflict check passes and a non-building branch gets pushed. `sync-fork.sh` therefore *also* `git grep`s for textual markers regardless of index state. This is gate 1.

## Operating commands

These assume the reference implementation in `platform/fork-maintenance/` of the GitOps repo that owns the maintenance system. The skill's [`templates/`](templates/) are portable starting points; the live engine is `scripts/` + `checks/` + `flux/` (one directory up from this skill).

### Sync one fork now (manual)

```bash
# Run the sync engine for one fork, locally or via a one-off Job from the CronJob
FORK_NAME=<fork> bash scripts/sync-fork.sh <fork>
# exit 0 = up to date or PR opened (auto-merged if auto.merge); 2 = conflict; 3 = push failure
```

To trigger in-cluster from the CronJob template, extract its `jobTemplate` into a `Job` and set `FORK_NAME=<fork>`. Follow logs with `kubectl logs -n fork-maintenance job/<name> -f`.

### Validate a fork locally (the same engine the CronJob uses)

```bash
bash checks/validate-fork.sh <fork> <path-to-fork-checkout>
# exit 0 = all declared checks pass; stdout is a markdown block embedded in the PR body
```

Validate reads the fork's `validation:` block and runs **only** the checks that fork declares. A fork with no checks (e.g. a non-Go project) passes cleanly. It honors `validation.toolchain.go` (precedence: declared > `go.mod`) via `GOTOOLCHAIN` so the build uses the exact Go minor the fork pins.

### Verify patches independently

```bash
bash scripts/verify-patches.sh forks/<fork>.yaml <path-to-fork-checkout>
# exit 0 = all signatures present; 1 = some lost (needs re-application)
```

### Resolve a sync PR with conflicts

1. Pull the sync branch locally.
2. `git grep -l -E '^(<<<<<<<|>>>>>>>|=======) '` — list files with unresolved markers.
3. For each: decide **mechanical** (re-apply our patch) or **semantic** (upstream changed an API we depend on) → follow [references/conflict-resolution.md](references/conflict-resolution.md).
4. Resolve, `git grep` again (must be empty), rebuild, run `validate-fork.sh`.
5. Push to the sync branch. The PR re-runs validation and flips to `auto-merge` if green (and merges automatically if the fork opted in).

### Add a new fork

Edit only data + one hook. No engine changes. See [references/architecture.md](references/architecture.md#adding-a-new-fork) and [`templates/fork.yaml`](templates/fork.yaml):

1. `forks/<name>.yaml` — declarative definition (upstream, fork, host, patches, additive paths, deletions, validation, release, optional `auto:`).
2. `post-merge-hooks/<name>.sh` — per-fork logic (or a no-op).
3. Flux `GitRepository` (`flux/gitrepository-upstreams.yaml`) + `Alert` (`flux/alert-upstream-changes.yaml`) for the upstream.
4. Register both the hook + the def in `kustomization.yaml`'s `configMapGenerator`.
5. If forgejo-hosted: the PAT in your secret store + `fork.api_url`.
6. Commit the GitOps repo → Flux reconciles ConfigMaps → next sync run (cron or event) picks it up.

### Enable full automation for a fork

Add (or flip) the `auto:` block in `forks/<name>.yaml`:

```yaml
auto:
  merge: true      # merge the green PR immediately (no human review)
  release: true    # also tag <upstream-ver>-rezus.<N+1> → image build → Flux deploys
```

`release: true` requires `merge: true`. With both on, a green sync goes all the way to a deployed image with no human in the loop — the centralized gates **are** the CI (there is no per-PR GitHub Actions to wait for). Leave `merge: false` (the default) for forks that need review.

### Keep the skill in sync with the implementation

```bash
bash skill/scripts/check-drift.sh          # verify engine templates match live scripts (CI-gatable)
bash skill/scripts/check-drift.sh --sync   # regenerate verbatim templates after changing the impl
```

Then sync the canonical skill to where agents load it: `cp -r platform/fork-maintenance/skill/* ~/.agents/skills/fork-maintenance/`.

## The fork definition (single source of truth)

Every per-fork difference is data here. This is what makes the process multi-project. Full annotated template: [`templates/fork.yaml`](templates/fork.yaml).

```yaml
name: <fork>
upstream:  { url, branch }
fork:
  url: https://github.com/org/repo        # or codeberg.org/...
  default_branch: rezus/<default>         # always-functional release branch (GitHub default)
  mirror_branch: <default>                # clean upstream mirror
  platform: github                        # github | forgejo  ← multi-platform
  api_url: https://codeberg.org/api/v1    # forgejo only (REST base)
  token_env: GITHUB_TOKEN                 # env var holding the host PAT
versioning: { tag_pattern: "v*-rezus.*" }
auto: { merge: false, release: false }    # opt-in full automation (see above)
patches:                                  # feature patches, each grep-verifiable
  - { file, description, signature }
additive_paths: [...]                     # our code that never conflicts with upstream
deletions: [ee/]                          # permanent divergence (re-deleted each sync)
post_merge_hook: post-merge-hooks/<name>.sh
release: { dockerfiles, multi_arch, image_registry, chart_registry, build_cli, version_file }
validation:                               # ← multi-project: declare YOUR checks
  toolchain: { go: "1.25.7" }             # pin Go minor (precedence: declared > go.mod)
  go_build:   [{ module, packages }]
  clean_tree: { paths: [...] }
  integration: { kind: forgejo-live, image, module, env }
```

## How the engine stays universal

- **Host abstraction** (`scripts/git-host.sh` → [`templates/git-host.sh`](templates/git-host.sh)): each fork declares `platform`; `sync-fork.sh` sources it. Git push = credential helper (both hosts). Labels + PRs + **PR merge** = `gh` CLI (github) or REST API via `curl` (forgejo). Adding a host = one `case` arm in `host_setup`/`host_label_create`/`host_pr_create`/`host_pr_merge`.
- **Universal validator** (`checks/validate-fork.sh` → [`templates/validate-fork.sh`](templates/validate-fork.sh)): a generic dispatcher over the `validation:` block, with **per-fork toolchain** pinning. Adding a language = adding a check type (`go_build`, `cargo_build`, `cmake_build`, …). Never hardcode one fork's structure into the validator — that was the bug that made every non-reference fork's PR show the reference fork's errors (results leaked via a shared temp file).
- **Per-fork result files**: validation output goes to `/tmp/fork-validation-<name>.md`, never a shared path. One CronJob pod runs many forks — they must not read each other's results.
- **Patch verifier** (`scripts/verify-patches.sh` → [`templates/verify-patches.sh`](templates/verify-patches.sh)): standalone signature grep, usable outside a full sync.
- **Agentic escalation**: when validation fails on a *semantic* conflict (not a missing signature), the engine emits a structured `needs-fix` payload (conflicting files, both sides, our patch intent) consumable by an agent that resolves and re-pushes. See [references/conflict-resolution.md](references/conflict-resolution.md).

## Automation model

Sync is **automatic and regular**: a Flux `GitRepository` polls each upstream (event-driven artifact update); a `*/30 * * * *` CronJob is the execution engine; an `Alert` can trigger an immediate sync on upstream change. Scripts + definitions are delivered as **ConfigMaps** (`configMapGenerator` in `kustomization.yaml`) — Flux reconciles them on push, no image rebuild or git clone of the GitOps repo inside the job. The GitHub PAT comes from Bitwarden via `ExternalSecrets`.

Depending on the fork's `auto:` settings, a green sync PR either:

- **`auto.merge: false` (default)** — sits for human review/merge.
- **`auto.merge: true`** — merges immediately, and with `auto.release: true` cuts the next `<upstream-ver>-rezus.<N+1>` tag so the fork's tag-triggered release workflow builds an image that Flux image automation deploys. **Fully hands-off.**

The release branch is touched *only* by a merged PR, so a broken sync can never deploy.

## Deep references (load on demand)

- [**references/architecture.md**](references/architecture.md) — full design: what lives where (fork repo stays clean; maintenance logic centralised in GitOps), the sync chain sequence, branch topology, versioning, the ConfigMap delivery model.
- [**references/safeguards.md**](references/safeguards.md) — the gate chain in depth, each gate's failure mode and the production bugs it prevents (forgejo-hardcoded validator, shared-result-file leak, `git add -A` masking markers, the `ry`/`read_yaml` typo that silently disabled auto-merge).
- [**references/conflict-resolution.md**](references/conflict-resolution.md) — mechanical vs semantic conflicts, the agentic resolution protocol, the resolution-validation loop, when to escalate to a human.

## Templates (portable starting points)

Engine (verbatim copies of the live scripts — drift-guarded by `skill/scripts/check-drift.sh`):

- [`templates/sync-fork.sh`](templates/sync-fork.sh) — universal sync engine (merge → hook → validate → verify patches → PR → auto-merge/release)
- [`templates/git-host.sh`](templates/git-host.sh) — github | forgejo host abstraction incl. `host_pr_merge`
- [`templates/validate-fork.sh`](templates/validate-fork.sh) — universal validation dispatcher + per-fork toolchain
- [`templates/verify-patches.sh`](templates/verify-patches.sh) — standalone patch-signature verifier
- [`templates/generate-manifest.sh`](templates/generate-manifest.sh) — divergence manifest generator (audit trail)
- [`templates/cronjob-entrypoint.sh`](templates/cronjob-entrypoint.sh) — CronJob entrypoint (installs tools, runs syncs)
- [`templates/cronjob-sync-forks.yaml`](templates/cronjob-sync-forks.yaml) — the CronJob (ConfigMap-mounted scripts)
- [`templates/external-secret-github.yaml`](templates/external-secret-github.yaml) — GitHub PAT from Bitwarden

Generic (hand-maintained examples, not verbatim copies):

- [`templates/fork.yaml`](templates/fork.yaml) — annotated fork definition (with `auto:` + toolchain)
- [`templates/post-merge-hook.sh`](templates/post-merge-hook.sh) — per-fork hook skeleton
- [`templates/alert-upstream-changes.yaml`](templates/alert-upstream-changes.yaml) — Flux Alert + Provider (one per fork)
- [`templates/gitrepository-upstreams.yaml`](templates/gitrepository-upstreams.yaml) — Flux GitRepository (one per fork)

## Checklist before declaring a sync "done"

- [ ] Sync branch pushed; PR open against the **release** branch (not mirror)
- [ ] No `<<<<<<<`/`>>>>>>>` markers anywhere in the tree (gate 1)
- [ ] All declared patch signatures present (gate 4) — PR body says `all-intact`
- [ ] `validate-fork.sh` green for *this* fork, in a real toolchain, with the declared toolchain (gate 5)
- [ ] PR label is `auto-merge` (or `needs-fix`/`needs-conflict-resolution` with a clear reason if not)
- [ ] If `auto.merge: true`: PR merged by the engine; release branch still functional
- [ ] If `auto.release: true`: next `<upstream-ver>-rezus.<N+1>` tag pushed; image build triggered
- [ ] Release branch untouched by the sync run (only the PR — or the auto-merge — can change it)
- [ ] If agentic resolution was used: the resolution was re-validated, not trusted (gate 6)
