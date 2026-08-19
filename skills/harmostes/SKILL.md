---
name: harmostes
description: "Operate harmostes — a Kubernetes-native workflow orchestration platform that combines deterministic operations with agentic reasoning — and ENFORCE its single supported implementation path. Use when creating, deploying, triggering, monitoring, or removing workflows; debugging workflow failures; reviewing changes that touch workflow machinery (kernel, chart, k8s-config, docs); or any question about how harmostes works. This skill's core job is drift prevention: workflows are implemented exactly one way."
---

# Harmostes — Workflow Orchestration Platform

Harmostes is a **Kubernetes-native orchestration platform** for workflows that
combine deterministic operations with agentic reasoning. Workflows are CRs
(`Workflow`, `harmostes.dev/v1alpha1`) that the controller triggers via Dapr
pub/sub and the worker pool executes as typed graphs
(`prepare → agent → gate → deploy`).

**Read the model first:** [How Harmostes Works](https://github.com/tibrezus/harmostes/wiki/How-Harmostes-Works)
— the complete one-page narrative this skill enforces.

---

## THE single supported way (memorize this)

There is exactly **one** implementation path for workflows. Every layer has
one job and lives in one place:

```
TEMPLATE (pipeline shape)     INSTANCE (scope)           SURFACE (creation)
k8s-config MR → Flux    →     UI form → thin CR     →     harmostes UI only
workflow-templates.yaml       {templateRef, source,       /workflows/new
                               config}
```

1. **Templates** (`WorkflowTemplate` CRs) hold the reusable pipeline shape:
   gate, prepare/agent/deploy plugins, skill, task template, model.
   Changed **only** via k8s-config MR (Flux-managed). One place per shape.
2. **Instances** are created **only** in the harmostes UI
   (`/workflows/new`): pick a template, supply name + schedule + scope
   (label/repos/wiki). The stored CR is thin — it duplicates nothing.
3. The UI stamps `harmostes.dev/owner` from the authenticated session
   (`StampOwnerLabel`). All UI reads are owner-scoped, so **a workflow
   created in the UI is visible to its creator by construction**.
4. Resolution happens at every point of use: the worker merges
   `templateRef` at run start (`ApplyTemplateDefaults` — instance-set fields
   win, `spec.config` overlays `prepare.config`); the UI resolves for
   rendering (list grouping, detail pipeline, graph API).

### The invariant

> **Everything visible in the UI, everything in the UI visible.**
> If a workflow cannot be seen (and triggered/toggled/deleted) in the harmostes
> UI under the owning identity, it must not exist. Any mechanism that can
> create workflows outside the UI must be dismantled, not documented.

This is not a preference — the GitOps/YAML creation path was dismantled after
it produced a workflow invisible in the UI. `kubectl apply` of a Workflow CR,
a `workflows/` directory in GitOps, example Workflow CRs in docs: all
forbidden, all drift.

---

## Drift-prevention contract (apply when reviewing or making changes)

### Kernel PRs (harmostes repo)

The UI-only path depends on four load-bearing pieces — changes must keep all
four intact:

| Piece | Where | Must remain |
|---|---|---|
| Creation routes | `internal/ui/server.go` (`GET /workflows/new`, `POST /workflows`, `POST /workflows/{name}/delete`) | Registered and owner-stamping |
| Owner stamping | `internal/ui/workflows.go` (`StampOwnerLabel`) | Server-set from session, never client input |
| Template resolution | `api/v1alpha1/template.go` (`ApplyTemplateDefaults`) + worker fetch in `cmd/harmostes-worker/main.go` | Field-wise, instance wins, nil-safe; applied after CR fetch |
| Read-path resolution | `internal/ui` (`resolveWorkflow` in list/detail/graph) + creation RBAC in `chart/templates/ui-rbac.yaml` | Thin instances render merged shape; UI SA has workflow create/delete |

**Reject** any PR that: re-adds example Workflow CR YAML (`examples/`),
re-introduces a YAML/GitOps creation flow in docs or code, lets an instance
carry a duplicated pipeline shape (fat instance), or creates Workflow CRs
from any component other than the UI.

### k8s-config MRs

- `platform/harmostes/workflows/` must **not exist** (and must not be
  re-created; the kustomization carries the warning comment).
- Templates in `workflow-templates.yaml` must carry **full executable
  defaults** — model, taskTemplate with `configMap` + `key`, plugin
  configMaps — because instances inherit everything they don't override.
- CRD copies (`crd.yaml`) must include `spec.templateRef` + `spec.config`
  and stay in sync with `chart/crds/`.

### Documentation changes

- The wiki is the source of truth: [How-Harmostes-Works](https://github.com/tibrezus/harmostes/wiki/How-Harmostes-Works)
  (model), [Managing-Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows)
  (operations). Any procedure doc that teaches creating workflows outside the
  UI is drift — fix it, don't follow it.
- The wiki follows Diátaxis: this skill must never contradict
  [Managing-Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows).

### Verification after any workflow-related change

```bash
# 1. Only the UI path created workflows (no GitOps drift):
kubectl get workflows.harmostes.dev -n harmostes \
  -o custom-columns=NAME:.metadata.name,OWNER:.metadata.labels.harmostes\.dev/owner
# → every row has an OWNER (UI-stamped); zero rows = also fine

# 2. The workflow is visible/operable in the UI (port-forward + session header):
kubectl port-forward -n harmostes svc/harmostes-ui 18083:8083 &
curl -s -H "X-Authentik-Username: <owner>" http://127.0.0.1:18083/workflows | grep <workflow-name>

# 3. Thin instance resolves (detail shows the template's nodes):
curl -s -H "X-Authentik-Username: <owner>" \
  http://127.0.0.1:18083/workflows/<workflow-name> | grep -E "pr-fetch|AGENT|post-review" # template-dependent
```

A change that passes tests but leaves any check red is **not done**.

---

## Canonical documentation

| Resource | URL | When to read |
|----------|-----|--------------|
| **How Harmostes Works** | [wiki/How-Harmostes-Works](https://github.com/tibrezus/harmostes/wiki/How-Harmostes-Works) | **Always first** — the complete model |
| **Managing Workflows** | [wiki/Managing-Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows) | Create, deploy, trigger, monitor, remove |
| Architecture | [wiki/Architecture](https://github.com/tibrezus/harmostes/wiki/Architecture) | Components, execution model, data flow |
| Execution Model | [wiki/Execution-Model](https://github.com/tibrezus/harmostes/wiki/Execution-Model) | trigger→worker→pipeline flow |
| Gate Catalog | [wiki/Gate-Catalog](https://github.com/tibrezus/harmostes/wiki/Gate-Catalog) | The gates and their structure |
| Workflow CRD Reference | [wiki/Workflow-CRD-Reference](https://github.com/tibrezus/harmostes/wiki/Workflow-CRD-Reference) | Every spec field |
| Workflow Catalog | [wiki/Workflow-Catalog](https://github.com/tibrezus/harmostes/wiki/Workflow-Catalog) | What exists, where it lives, how it fires |
| Fork Maintenance | [wiki/Fork-Maintenance](https://github.com/tibrezus/harmostes/wiki/Fork-Maintenance) | Fork sync model (self-hosted transport) |
| Observability Views | [wiki/Observability-Views](https://github.com/tibrezus/harmostes/wiki/Observability-Views) | UI views (Map, Flows, Sessions, Attempts) |
| Credential Management | [wiki/Credential-Management](https://github.com/tibrezus/harmostes/wiki/Credential-Management) | Secrets, tokens, ExternalSecrets |
| Event-Driven Worker Pool | [wiki/Event-Driven-Worker-Pool](https://github.com/tibrezus/harmostes/wiki/Event-Driven-Worker-Pool) | Execution/pod debugging |
| Webhook Triggers | [wiki/Webhook-Triggers](https://github.com/tibrezus/harmostes/wiki/Webhook-Triggers) | Instant triggers |
| CONTEXT.md (glossary) | [repo/CONTEXT.md](https://github.com/tibrezus/harmostes/blob/main/CONTEXT.md) | Domain language |
| ADRs (0001–0005) | [wiki Home → ADRs](https://github.com/tibrezus/harmostes/wiki/Home#adrs-architecture-decisions) | Design decisions |

## The gate-centric model

A workflow's **gate** determines its structure — templates encode this:

| Gate | Purpose | Prepare | Deploy |
|------|---------|---------|--------|
| `wiki-lint` | Documentation sync (code → C4 docs → wiki) | `rig-emit` | `git-push` |
| `pr-review` | PR review (fetch → agent → validate → post) | `pr-fetch` | `post-review` |
| `fork-maintenance` | Fork maintenance (mostly self-hosted now) | `merge-sync` | `fork-merge-deploy` |
| `noop` | Passthrough (deterministic only) | `rig-emit` | `git-push` |

**Naming convention:** `{gate}-{targetSlug}` (e.g., `pr-review-harmostes`).

## Where things live

| Artifact | Location | Git remote |
|----------|----------|------------|
| **Workflow instances** | created in the harmostes UI (`/workflows/new`) — no YAML path exists | in-cluster only |
| **WorkflowTemplates** (pipeline shapes) | `k8s-config/platform/harmostes/workflow-templates.yaml` | `gitlab.com:rezusnet/operations/k8s-config` |
| **Harmostes platform** (controller, worker, UI) | `harmostes/` | `github.com:tibrezus/harmostes` |
| **Chart** (Helm) | `harmostes/chart/` | `github.com:tibrezus/harmostes` |
| **Documentation** | `harmostes.wiki/` | `github.com:tibrezus/harmostes.wiki` |
| **Credentials** | `k8s-config/platform/harmostes/externalsecret-*.yaml` | BSM → ExternalSecrets |

## Cluster details

| Detail | Value |
|--------|-------|
| Namespace | `harmostes` |
| Cluster | `admin@talosoci` |
| Chart source | `oci://ghcr.io/tibrezus/harmostes` (Flux `HelmRepository`) |
| Flux Kustomization | `platform` (watches `k8s-config`) |
| UI | `harmostes.rezus.cloud` (behind Authentik SSO) |
| Dapr pub/sub topic | `harmostes-triggers` (`pubsub.redis` on Valkey) |

## Common operations

### Create a workflow (the only way)

1. Open the UI → **Workflows → New Workflow** (`/workflows/new`)
2. Pick a WorkflowTemplate; supply name (`{gate}-{targetSlug}`), schedule,
   scope (label/repos/wiki)
3. Create — owner is stamped from your session; verify it appears in your list
4. If no template fits: add/change a **template** via k8s-config MR — never a
   fat instance, never YAML

### Trigger / toggle / delete

UI actions on the workflow detail page (**Trigger** / **Toggle** / **Delete**).
Fallback for scripted triggering only:
```bash
kubectl annotate workflow.harmostes.dev <name> -n harmostes \
  harmostes.dev/trigger-revision="$(date +%s)" --overwrite
```

### Monitor

```bash
kubectl get workflow.harmostes.dev <name> -n harmostes
kubectl logs -n harmostes deploy/harmostes-worker-pool -c worker --tail=50
kubectl logs -n harmostes deploy/harmostes-controller -c controller --tail=50
```
Or the UI (`harmostes.rezus.cloud`): Map for topology, Flows for the timeline,
Attempts for history, Sessions for agent transcripts.

## Execution model (summary)

```
Controller detects workflow is due
  → publishes TriggerEvent to Dapr pub/sub (harmostes-triggers)
    → worker pool consumer receives event
      → fetches Workflow CR + resolves templateRef (ApplyTemplateDefaults)
      → execs one-shot worker
        → prepare → agent (LLM) → gate → deploy
      → ACK on success / NACK on failure (at-least-once via Redis Streams)
```

Key properties: single-flight per pod, at-least-once delivery, no batchv1
Jobs, `detect: changed` skips no-op runs, Node Result Envelopes + Attempt CRs
record history (ADR-0005).

## Relationship to other skills

- **`dev-workflow`** — governs changes to the harmostes codebase itself
- **`pr-review`** / **`wiki`** / **`fork-maintenance`** — the skills the
  agents inside workflows run
