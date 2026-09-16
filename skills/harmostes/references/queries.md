# Query cookbook — attempts, runs, jobs, pods, UI

Load this when inspecting run state or debugging execution.

## Model first

An attempt IS the run (ADR-0007): one graph execution = one Attempt CR;
each node execution inside it = one run = one K8s Job = one pod. The
Attempt CR is the durable spine; Jobs/pods are ephemeral. Query CRs for
state and history, pods only for live logs.

**Durable layer — Attempt CRs (`harmostes.dev/v1alpha1`):**

```bash
# Every attempt: phase + owner + workflow (owner = who may see it in the UI)
kubectl get attempts.harmostes.dev -n harmostes \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,OWNER:.metadata.labels.harmostes\.dev/owner,WF:.metadata.labels.harmostes\.dev/workflow

# All attempts of one workflow (attempt names embed workflow + head SHA:
# attempt-pr-review-rhesadox-0f034bedd3a0)
kubectl get attempts.harmostes.dev -n harmostes -l harmostes.dev/workflow=pr-review-rhesadox

# The run list: one row per node-execution; phase "running" = live position
kubectl get attempt <name> -n harmostes \
  -o jsonpath='{range .status.runs[*]}{.name}{"\t"}{.phase}{"\t"}{.startedAt}{"\t"}{.endedAt}{"\n"}{end}'

# The node-result ledger: per-node state + duration (ms) as the UI's graph
# and timing waterfall render it
kubectl get attempt <name> -n harmostes \
  -o jsonpath='{range .status.nodeResults[*]}{.nodeID}{"\t"}{.runID}{"\t"}{.status}{"\t"}{.durationMs}{"\t"}{.producedAt}{"\n"}{end}'
```

Phase vocabulary: attempt `reconciling` (in progress) → `validated` (a
deterministic claim confirmed the targeted state) / `failed` /
`superseded` (a newer targeted state replaced this one); runs are
`running` → `succeeded`/`failed`. Envelope status: `ok`/`failed`/`skipped`.

**Ephemeral layer — Jobs/pods, keyed by the attempt label:**

```bash
kubectl get jobs -n harmostes -l harmostes.dev/attempt=<attempt-name>
kubectl get pods -n harmostes -l harmostes.dev/attempt=<attempt-name> -o wide
kubectl logs -n harmostes -l harmostes.dev/attempt=<attempt-name> -c run --tail=100 -f
```

**Through the UI (owner-scoped reads; port-forward + session header):**

```bash
kubectl port-forward -n harmostes svc/harmostes-ui 18083:8083 &
U="-H X-Authentik-Username:<owner>"   # foreign names 404 — no existence leak
curl -s $U http://127.0.0.1:18083/                            # wall (live rollups)
curl -s $U http://127.0.0.1:18083/runs                        # attempt list
curl -s $U http://127.0.0.1:18083/runs/<attempt>              # detail: graph + claims + transcripts
curl -s $U http://127.0.0.1:18083/runs/<attempt>/runs/<run>/logs        # log fragment (HTML)
curl -s $U http://127.0.0.1:18083/runs/<attempt>/runs/<run>/session     # agent transcript
curl -s $U http://127.0.0.1:18083/runs/<attempt>/runs/<run>/pi-session  # raw pi session JSONL
curl -sN $U http://127.0.0.1:18083/runs/<attempt>/graph/events          # live graph SSE stream
curl -sN $U http://127.0.0.1:18083/api/wall/events                      # live wall SSE stream
```

A foreign or unknown attempt name under `/runs/...` returns the same 404 —
the multi-tenant gate; don't debug it as a routing bug.

## Verification curls (after any workflow-related change)

```bash
# The workflow is visible/operable in the UI (port-forward + session header):
curl -s -H "X-Authentik-Username: <owner>" http://127.0.0.1:18083/workflows | grep <workflow-name>

# Thin instance resolves (detail shows the template's nodes):
curl -s -H "X-Authentik-Username: <owner>" \
  http://127.0.0.1:18083/workflows/<workflow-name> | grep -E "pr-fetch|AGENT|post-review" # template-dependent
```

Plus the no-GitOps-drift check:
`kubectl get workflows.harmostes.dev -n harmostes -o custom-columns=NAME:.metadata.name,OWNER:.metadata.labels.harmostes\.dev/owner`
→ every row has an OWNER (UI-stamped); zero rows = also fine.

## Reading the session lineage (ADR-0010, #367)

PR-scoped pi session lineages: the session store is keyed
`pi-lineage/<repo>~<pr>` in Dapr state — fetch/materialize at run start,
stable `harmostes-<pr>` session id, publish back post-run; resumed runs
get a delta prompt, and the identical prefix gives provider KV-cache
hits across review rounds. The worker also persists a per-attempt copy
in Redis/valkey (`pr-review-rhesadox:<runId>:session` / `:pi-session`,
hash field `data`, double-JSON-encoded — read with
`redis-cli --raw HGET <key> data` + two `json.loads`).
