# Drift-prevention contract — piece-by-piece

Load this when reviewing or making changes to the workflow machinery
(kernel PRs, k8s-config MRs, docs). The invariant and the everyday
reject-lens live in SKILL.md; this is the per-piece map.

## Kernel PRs (harmostes repo)

The UI-only path depends on six load-bearing pieces — changes must keep
all six intact:

| Piece | Where | Must remain |
|---|---|---|
| Creation routes | `internal/ui/server.go` (`GET /workflows/new`, `POST /workflows`, `POST /workflows/{name}/delete`) | Registered, templateRef-only, owner-stamping |
| Owner stamping | `internal/ui/workflows.go` (`StampOwnerLabel`) | Server-set from session, never client input |
| Template resolution | `api/v1alpha1/template.go` (`ApplyTemplateDefaults`) + worker fetch in `cmd/harmostes-worker/main.go` | Field-wise, instance wins, nil-safe; applied after CR fetch |
| Read-path resolution | `internal/ui` (`resolveWorkflow` in list/detail/graph) + creation RBAC in `chart/templates/ui-rbac.yaml` | Thin instances render merged shape; UI SA has workflow create/delete |
| Scope schema | `api/v1alpha1/workflowtemplate_types.go` (`ScopeParam`) + `scopeConfigJSON` in `internal/ui/workflows.go` | The template owns its config dialect: form renders from `spec.scope`, creation stores ONLY declared keys (defaults on empty) |
| One archetype registry | `internal/ui` (no gateCatalog — deleted; grouping by `templateRef`) | No hardcoded archetype catalogs anywhere; adding a template is YAML only |

**Also reject** any PR that reintroduces a Go-side gate/archetype catalog,
hardcodes instance-config keys in the creation form (the pr-review keys
are pr-review's declaration, not the form's business), or copies CRD YAML
into k8s-config (CRDs are single-sourced from the kernel repo via the
`harmostes-crds` Flux source).

## k8s-config MRs

- `platform/harmostes/workflows/` must **not exist** (and must not be
  re-created). Instance YAMLs live as `workflow-instances-*.yaml` files in
  `platform/harmostes/`, carry `harmostes.dev/owner` explicitly, and are
  sanctioned until harmostes#418 retires them.
- Templates do NOT live in k8s-config — they are **chart values** in the
  harmostes repo (`chart/values.yaml`, ADR-0011). Each template must carry
  **full executable defaults** — model, taskTemplate with `configMap` +
  `key`, plugin configMaps — **and a `spec.scope` declaration** for every
  instance-config key its prepare plugin consumes (the UI form is useless
  without it).
- CRDs: k8s-config holds **zero CRD bytes** — the `harmostes-crds`
  GitRepository + Kustomization source `chart/crds/` from the kernel repo
  (`prune: false`; fresh clusters: apply
  `platform/harmostes/gitrepository-crds.yaml` once directly).

## Documentation changes

- The wiki is the source of truth: [How-Harmostes-Works](https://github.com/tibrezus/harmostes/wiki/How-Harmostes-Works)
  (model), [Managing-Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows)
  (operations). Any procedure doc that teaches creating workflows outside
  the UI is drift — fix it, don't follow it.
- The wiki follows Diátaxis: this skill must never contradict
  [Managing-Workflows](https://github.com/tibrezus/harmostes/wiki/Managing-Workflows).

## Verification after any workflow-related change

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
