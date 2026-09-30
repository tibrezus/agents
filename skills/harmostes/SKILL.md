---
name: harmostes
description: "Operate harmostes — a Kubernetes-native workflow orchestration platform that combines deterministic operations with agentic reasoning — and ENFORCE its single supported implementation path. Use when creating, deploying, triggering, monitoring, or removing workflows; debugging workflow failures; reviewing changes that touch workflow machinery (kernel, chart, k8s-config, docs); or any question about how harmostes works. This skill's core job is drift prevention: workflows are implemented exactly one way."
---

# Harmostes — Workflow Orchestration Platform

Harmostes is a **Kubernetes-native orchestration platform** for workflows
that combine deterministic operations and agentic reasoning. Workflows are
CRs (`Workflow`, `harmostes.dev/v1alpha1`) that the controller triggers via
Dapr pub/sub and the worker pool executes as typed graphs
(`prepare → agent → gate → deploy`).

**Read the model first:** [How Harmostes Works](https://github.com/tibrezus/harmostes/wiki/How-Harmostes-Works)
— the complete one-page narrative this skill enforces.

---

## THE single supported way (memorize this)

There is exactly **one** implementation path for workflows. Every layer has
one job and lives in one place (ADR-0012, shipped harmostes#414):

```
TEMPLATE (pipeline shape)      INSTANCE (scope)              SURFACE (creation)
chart values (harmostes PR     UI form → thin CR             harmostes UI
→ chart release → Flux)        {templateRef, config}         /workflows/new
                               or k8s-config MR (GitOps)
```

1. **Templates** (`WorkflowTemplate` CRs) hold the reusable pipeline shape:
   gate, prepare/agent/deploy plugins, skill, task template, model. They
   are **chart values** (ADR-0011) — changed only via a harmostes PR to
   `chart/values.yaml`, never mutated in-cluster by anything.
2. **Instances** are created in the harmostes UI (`/workflows/new`): pick
   a template, supply a name + the template's **declared scope fields**
   (the form renders from `spec.scope`; only declared keys are stored in
   `spec.config`, per-key overlaying the template's `prepare.config`). The
   CR is thin — it duplicates nothing. **Creation is inert**: instances
   are born `spec.disabled: true` — a form submit never arms an unattended
   agent loop. Arming is a separate deliberate act (#418 ships the run
   controls; until then an operator flips `spec.disabled` deliberately).
   GitOps instances in k8s-config remain sanctioned (owner label carried
   explicitly); #418 retires them when UI lifecycle ships.
3. The UI stamps `harmostes.dev/owner` from the authenticated session
   (`v1alpha1.StampOwnerLabel` — server-set, never client input). Writes
   require an Authentik-authoritative identity; dev identities
   (`X-Harmostes-Dev-User`) write only on servers started with
   `ui.devWrite` (dev/fixture) and stamp into the reserved `dev-<user>`
   owner namespace — they can never occupy a real user's label. All reads
   are owner-scoped: **a workflow created in the UI is visible to its
   creator by construction**.
4. Resolution happens at every point of use: the worker merges
   `templateRef` at run start (`ApplyTemplateDefaults` — instance-set
   fields win, `spec.config` overlays `prepare.config` per key); the UI
   resolves for rendering (list grouping, detail pipeline, graph API).
   `GET /api/schema` serves the CRDs' OpenAPI schema live — the CRD is the
   only hand-maintained schema in the stack.

### The invariant

> **Everything visible in the UI, everything in the UI visible — and owner
> attribution everywhere.**
> Every workflow carries `harmostes.dev/owner`: the UI stamps it from the
> session, GitOps carries it explicitly. A workflow invisible to its owner
> under the owning identity must not exist. Ad-hoc `kubectl apply` of an
> owner-less Workflow CR is drift — it bypasses review, the origin check,
> scope filtering, and inert-by-default creation.

History: the original GitOps creation path was dismantled (#291) after it
produced a workflow invisible in the UI; ADR-0012 rebuilt the write path
with owner stamping as the load-bearing invariant (harmostes#414).

---

## Drift-prevention lens (reviewing or making changes)

The UI-only path depends on six load-bearing kernel pieces (creation
routes, owner stamping, template resolution, read-path resolution, scope
schema, one archetype registry) and on placement rules for k8s-config and
docs. The piece-by-piece map with file paths, must-remain clauses, and
the post-change verification recipes:
**[references/drift-contract.md](references/drift-contract.md)**.

**Reject any PR/MR that:** re-adds example Workflow CR YAML (`examples/`)
or any YAML/GitOps creation flow (docs or code); creates Workflow CRs
from any component other than the UI; lets an instance carry a duplicated
pipeline shape (fat instance); re-creates `platform/harmostes/workflows/`;
puts templates or CRD bytes into k8s-config; reintroduces a Go-side
gate/archetype catalog; hardcodes instance-config keys in the creation
form (the pr-review keys are pr-review's declaration, not the form's
business).

A change that passes tests but leaves any verification check red is
**not done**.

## Canonical documentation

Model: **[How-Harmostes-Works](https://github.com/tibrezus/harmostes/wiki/How-Harmostes-Works)** (always first).
Operations: **[Managing-Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows)** (create/deploy/trigger/monitor/remove).
Depth on wiki: Architecture, Execution-Model, Gate-Catalog,
Workflow-CRD-Reference (every spec field), Workflow-Catalog,
Fork-Maintenance, Observability-Views (Map/Flows/Sessions/Attempts),
Credential-Management, Event-Driven-Worker-Pool, Webhook-Triggers.
Glossary: repo `CONTEXT.md`. ADRs 0001–0010 on the wiki Home — incl.
ADR-0006 event-armed gates, ADR-0007 Job-per-attempt, ADR-0008
attempt-scoped resumption, ADR-0009 graph-first navigation,
**ADR-0010 PR-scoped agent session lineages**.

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

| Artifact | Location |
|----------|----------|
| **Workflow instances** | harmostes UI (`/workflows/new`, inert by default) or `k8s-config/platform/harmostes/workflow-instances-*.yaml` (sanctioned until #418) |
| **WorkflowTemplates** | `harmostes/chart/values.yaml` (chart values, ADR-0011) — must carry full executable defaults + `spec.scope` for every instance-config key |
| **Platform / chart / docs** | `harmostes/` repo (+ `.wiki`); credentials in chart `values.yaml` `credentials:` block (chart-rendered ExternalSecrets) |

Cluster: namespace `harmostes` @ `admin@talosoci`; chart
`oci://ghcr.io/tibrezus/harmostes` (Flux `HelmRepository`); Flux
Kustomization `platform` watches k8s-config; UI `harmostes.rezus.cloud`
(behind Authentik SSO); Dapr topic `harmostes-triggers`
(`pubsub.redis` on Valkey).

## Common operations

### Create a workflow (the only way)

1. UI → **Workflows → New Workflow** (`/workflows/new`)
2. Pick a WorkflowTemplate; supply name (`{gate}-{targetSlug}`), schedule,
   scope (label/repos/wiki)
3. Create — owner is stamped from your session; verify it appears in your list
4. If no template fits: add/change a **template** via a harmostes PR to
   `chart/values.yaml` — never a fat instance, never YAML

### Trigger / toggle / delete

UI actions on the workflow detail page (**Trigger** / **Toggle** /
**Delete**). Fallback for scripted triggering only:
```bash
kubectl annotate workflow.harmostes.dev <name> -n harmostes \
  harmostes.dev/trigger-revision="$(date +%s)" --overwrite
```

### Monitor

```bash
kubectl get workflow.harmostes.dev <name> -n harmostes
kubectl logs -n harmostes deploy/harmostes-worker-pool -c worker --tail=50
kubectl logs -n harmostes deploy/harmostes-controller -c controller --tail=50
# Gate holds at a glance (#512): red/pending-CI holds are healthy — only
# "ingress may be lost" rows deserve a second look:
kubectl logs -n harmostes deploy/harmostes-worker-pool -c worker | grep -E "armed .*\(waiting: (ci |label absent)"
```
The UI is **observe-only**; nav: **Live** (`/` wall), **Runs** (attempt
history → detail: timeline graph + logs + transcripts), **Workflows**
(templates + instances; page-tabs Workflows | Templates).

### Query attempt / run state

An attempt IS the run (ADR-0007): one graph execution = one Attempt CR;
each node inside = one run = one Job = one pod. Attempt CRs are the
durable spine (query those for state/history); Jobs/pods are ephemeral
(logs only). Phase vocabulary: attempt `reconciling` → `validated` /
`failed` / `superseded`; runs `running` → `succeeded`/`failed`; envelope
`ok`/`failed`/`skipped`. Full cookbook — Attempt-CR custom-columns/
jsonpath queries, attempt-labeled Job/pod queries, owner-scoped UI curls
(`X-Authentik-Username`; foreign names 404 — no existence leak), live SSE
streams, session-lineage reads:
**[references/queries.md](references/queries.md)**.

```bash
kubectl get attempts.harmostes.dev -n harmostes -l harmostes.dev/workflow=<name>
kubectl get attempt <attempt> -n harmostes -o jsonpath='{range .status.runs[*]}{.name}{"\t"}{.phase}{"\n"}{end}'
```

## Execution model (summary)

```
Controller detects workflow is due
  → publishes TriggerEvent to Dapr pub/sub (harmostes-triggers)
    → worker pool consumer fetches Workflow CR + resolves templateRef
      → execs one-shot worker: prepare → agent (LLM) → gate → deploy
      → ACK on success / NACK on failure (at-least-once via Redis Streams)
```

Key properties: single-flight per pod; at-least-once delivery; `detect:
changed` skips no-op runs; Node Result Envelopes + Attempt CRs record
history (ADR-0005). Reviews run attempt-scoped Jobs (ADR-0007) with a
**dead-dispatch breaker** (N dispatches dying verdictless ⇒ re-arm
refused; override by re-applying the `needs-review` label) and
**PR-scoped pi session lineages** (ADR-0010, #367): keyed
`pi-lineage/<repo>~<pr>` in Dapr state, stable `harmostes-<pr>` session
id, delta prompt on resume, identical prefix ⇒ provider KV-cache hits
across review rounds. The claim's live marker is SUBTRACTIVE (#512):
`harmostes.dev/review-claim=released` marks RELEASED, ABSENCE means live —
never "repair" a live claim by adding a label; a stranded marker is
invisible (holds no slot) and the next candidate arm heals it. Gate hold
logs discriminate CI (#512, release 1.2.0-215+): `ci red/pending at head
(…) — dispatch on green` is the benign armed hold; `ingress may be lost`
(green or unreadable head, no verdict) is the only class worth a second
look — one grep separates them.

## Relationship to other skills

- **`dev-workflow`** — governs changes to the harmostes codebase itself
- **`pr-review`** / **`wiki`** / **`fork-maintenance`** — the skills the
  agents inside workflows run
