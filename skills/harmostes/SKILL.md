---
name: harmostes
description: "Operate harmostes — a Kubernetes-native workflow orchestration platform that combines deterministic operations with agentic reasoning. Use when creating, deploying, triggering, monitoring, or removing workflows; debugging workflow failures; managing credentials; or understanding the gate-centric model. Points to the canonical wiki documentation for every operation."
---

# Harmostes — Workflow Orchestration Platform

Harmostes is a **Kubernetes-native orchestration platform** for workflows that
combine deterministic operations with agentic reasoning. Workflows are
declarative Kubernetes CRs (`Workflow` kind, `harmostes.dev/v1alpha1` API) that
the harmostes controller reconciles and the worker pool executes via Dapr
pub/sub.

## When to use this skill

- Creating, deploying, or removing a workflow
- Triggering a workflow (schedule, webhook, manual)
- Monitoring workflow runs or debugging failures
- Understanding the gate-centric model
- Managing credentials (git tokens, LiteLLM)
- Any question about how harmostes works

## Canonical documentation

**Read these before acting.** They are the source of truth.

| Resource | URL | When to read |
|----------|-----|--------------|
| **Managing Workflows** (primary guide) | [wiki/Managing-Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows) | **Always** — create, deploy, trigger, monitor, remove |
| Workflow CRD Reference | [wiki/Workflow-CRD-Reference](https://github.com/tibrezus/harmostes/wiki/Workflow-CRD-Reference) | When writing workflow YAML — every field documented |
| Architecture | [wiki/Architecture](https://github.com/tibrezus/harmostes/wiki/Architecture) | When understanding components, execution model, data flow |
| Event-Driven Worker Pool | [wiki/Event-Driven-Worker-Pool](https://github.com/tibrezus/harmostes/wiki/Event-Driven-Worker-Pool) | When debugging execution / pod issues |
| Webhook Triggers | [wiki/Webhook-Triggers](https://github.com/tibrezus/harmostes/wiki/Webhook-Triggers) | When setting up instant triggers |
| CONTEXT.md (glossary) | [repo/CONTEXT.md](https://github.com/tibrezus/harmostes/blob/main/CONTEXT.md) | When domain language is unclear |
| ADRs (0001–0005) | [wiki Home → ADRs](https://github.com/tibrezus/harmostes/wiki/Home#adrs-current-architecture) | When understanding design decisions |

## The gate-centric model

A workflow's **gate** determines its entire structure. You don't assemble a
workflow from parts — you pick a gate, and the gate dictates the plugins.

| Gate | Purpose | Prepare | Deploy |
|------|---------|---------|--------|
| `wiki-lint` | Documentation sync (code → C4 docs → wiki) | `rig-emit` | `git-push` |
| `pr-review` | PR review (fetch → agent → validate → post) | `pr-fetch` | `post-review` |
| `fork-maintenance` | Fork maintenance (sync → resolve → build → deploy) | `merge-sync` | `fork-merge-deploy` |
| `noop` | Passthrough (deterministic only, no LLM) | `rig-emit` | `git-push` |

**Naming convention:** `{gate}-{targetSlug}` (e.g., `wiki-lint-harmostes`).

## Where things live

| Artifact | Location | Git remote |
|----------|----------|------------|
| **Workflow CRs** (the YAMLs you create) | `k8s-config/platform/harmostes/workflows/` | `gitlab.com:rezusnet/operations/k8s-config` |
| **Harmostes platform** (controller, worker, UI code) | `harmostes/` | `github.com:tibrezus/harmostes` |
| **Chart** (Helm) | `harmostes/chart/` | `github.com:tibrezus/harmostes` |
| **Documentation** | `harmostes.wiki/` (GitHub wiki) | `github.com:tibrezus/harmostes.wiki` |
| **Glossary** | `harmostes/CONTEXT.md` | `github.com:tibrezus/harmostes` |
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

### Create a workflow

1. Read [Managing Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows)
2. Choose a gate
3. Write the YAML: `k8s-config/platform/harmostes/workflows/{gate}-{target}.yaml`
4. Add to `k8s-config/platform/harmostes/kustomization.yaml`
5. Commit → MR → merge → Flux applies
6. Verify: `kubectl get workflows.harmostes.dev -n harmostes`

### Trigger a workflow manually

```bash
kubectl annotate workflow.harmostes.dev <name> -n harmostes \
  harmostes.dev/trigger-revision="$(date +%s)" --overwrite
```

### Monitor a workflow

```bash
# Status
kubectl get workflow.harmostes.dev <name> -n harmostes

# Worker pool logs (trigger events + execution)
kubectl logs -n harmostes deploy/harmostes-worker-pool -c worker --tail=50

# Controller logs
kubectl logs -n harmostes deploy/harmostes-controller -c controller --tail=50
```

Or use the UI at `harmostes.rezus.cloud`.

### Disable a workflow

Set `spec.disabled: true` in the k8s-config YAML. Commit → push → Flux applies.

### Remove a workflow

1. Delete the YAML from `k8s-config/platform/harmostes/workflows/`
2. Remove from `kustomization.yaml`
3. Commit → push → Flux prunes

## Execution model (summary)

```
Controller detects workflow is due
  → publishes TriggerEvent to Dapr pub/sub (harmostes-triggers topic)
    → worker pool consumer receives event
      → execs one-shot worker (/proc/self/exe)
        → prepare plugin → agent (LLM) → gate plugin → deploy plugin
      → ACK on success / NACK on failure (at-least-once via Redis Streams)
```

Key properties:
- **Single-flight per pod**: one concurrent run per worker pod (mutex)
- **At-least-once delivery**: unacked messages are re-delivered
- **Zero pod bloat**: no batchv1.Jobs — the pool pod persists, execs workers as processes
- **Deterministic skip**: `detect: changed` skips if the prepare output hash is unchanged

## Relationship to other skills

- **`dev-workflow`** — governs changes to the harmostes codebase itself (issue → branch → PR)
- **`wiki`** (llm-wiki skill) — the wiki workflows use this skill to sync docs
- **`pr-review`** — the pr-review workflows use this skill to review PRs
- **`fork-maintenance`** — the fork-maintenance workflows use this skill to maintain forks

## See Also

- [Managing Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows) — **start here**
- [Architecture](https://github.com/tibrezus/harmostes/wiki/Architecture)
- [Event-Driven Worker Pool](https://github.com/tibrezus/harmostes/wiki/Event-Driven-Worker-Pool)
- [Deployment](https://github.com/tibrezus/harmostes/wiki/Deployment)
