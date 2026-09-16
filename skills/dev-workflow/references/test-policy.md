# Test policy — "CI green" means tests pass, not "it compiled"

Depth page for gates 6/10 and the CI-discipline mandates in
[`SKILL.md`](../SKILL.md). `tdd` owns *how* to write good tests; this page
owns *what counts as covered* and *where tests run*.

> A test that is not executed by CI does not protect the change. The next
> contributor's laptop is not CI.

> CI instrumentation is cumulative. The local test command and the CI
> command are the same thing: run the project's own runner (`make test`,
> `npm test`, `scripts/test`) locally, never a throwaway script.
> Consolidation is the default: before creating any component — tool, CI
> job, wiki page — check that an equivalent doesn't already exist
> (`scripts/`, `tools/`, `bench/`) and extend it. A one-off script
> discarded after local verification leaves CI frozen while the code moves
> on — it looks like coverage but protects nothing.

CI is authoritative; the local run is the fast loop, valid only when it
runs the same suite CI does — otherwise it lies.

## Test-kind requirements

| Kind | Requirement | Rationale |
|---|---|---|
| **Unit** | **Mandatory** for every behavior added or altered. | Unverified behavior regresses silently on the next merge. |
| **Integration** | **Extended whenever the project has a suite.** Never shrink it. | A suite that stops tracking the code looks green while lying. |
| **No suite yet** | Do **not** invent one unprompted; surface the gap on the issue. | A forced harness couples to a tool nobody maintains. |

A change is **not covered** if: it adds/alters observable behavior without
a new/updated unit test; it touches an integration-tested path without
extending it; its tests exist but CI doesn't discover them (new file CI
misses, `*.skip`, excluded dir); or its validation was a **throwaway
script**. Writing style: load **`tdd`** — behavior through public
interfaces, vertical red-green slices; refuse horizontal slicing
(batch tests against imagined behavior) and implementation coupling
(mocks/asserts on private structure).

## Stratification — and merge-gated dispatch

| Tier | When | What | Gate |
|---|---|---|---|
| **Fast** | Every push, every PR | unit, lint, type-check | Gate 10 floor |
| **Full (slow)** | **Dispatched once at ready declaration** — a merge gate, not a push gate | benchmarks, GPU/infra matrices, integration A/B, long evals, MC/DC | Gates 11–12 input |

The bors/merge-queue lineage, inverted for agent workflows: the guarantee
lives at **merge time**, not PR-open time. Development iterates locally;
the PR opens **once**, locally green (gate 9 — an open PR consumes forge CI
on every push). After it opens, pushes re-run the fast tier only, with
superseded runs cancelled via `concurrency`. At ready declaration: rebase
first, trigger the full pipeline on that SHA (the `full-pipeline` label —
the trigger helper refuses heads not rebased onto current default, first
run and re-triggers alike), then adversarial review on the same SHA. Red
full pipeline → back to developing, never into review — the review exists
for what CI cannot see. The rebase-before-trigger order is resource logic:
a full run on a head behind default is wasted by construction — the
mandatory rebase moves the head, old-SHA statuses are void, the run must
repeat regardless of result. Rebased first, one green run is
merge-eligible.

**SHA binding + invalidation** — statuses attach to SHAs. Merge-ready =
fast green + full green + review APPROVE at the *same* SHA that is the
branch head at merge:

| Event after ready declaration | Fast | Full pipeline | Review |
|---|---|---|---|
| Any push (source **or** docs-only) | rerun | re-dispatch | re-review |
| Default branch moved | rerun | re-dispatch after re-rebase | re-review |
| REQUEST_CHANGES → fixes | rerun | re-dispatch | re-review |

No push-kind distinction: even a docs-only push after declaration re-opens
the path — fold such edits in **before** declaring ready. Platform
mechanics (dispatch quirks, merge-queue guidance):
[`platform-commands.md`](platform-commands.md).

**Boundary rule:** a job belongs in the slow tier only if running it on
every push harms the feedback loop (rule of thumb: > 30s beyond the fast
tier). If it's fast, keep it in the fast tier — don't fragment the suite.

## Measurements as reproducible CI artifacts

A measurement whose value is comparing across runs — benchmark, perf trace,
A/B, resource profile, model-quality eval — is a **CI artifact**, not a
script someone runs once: the same harness on the same runner class with
the same inputs produces comparable data points over time. A one-off run
is an anecdote; a CI run is a measurement. Wire it into the slow tier,
manually triggered (`workflow_dispatch`) — manual is the **correct**
trigger for work too expensive for every push whose reproducibility is the
point. Each run is a queryable data point with known runner/inputs/harness.

**Reusability prevents bloat** — one harness, many invocations:

| Mechanism | When |
|---|---|
| **Composite action** (`.github/actions/`, `.forgejo/actions/`) | shared setup + one measurement step, reused across workflows |
| **Reusable workflow** (`on: workflow_call`) | a full slow-tier harness called from multiple workflows |
| **Committed harness script** (`scripts/bench`, `scripts/ab-test`) | measurement logic versioned in the repo, called by CI — not inlined in YAML |

Anti-patterns: **ad-hoc script** (no CI wiring, result lost); **copy-pasted
job** (duplicated checkout/setup/build — one harness takes the measurement
name as a parameter instead); **non-deterministic harness** (unpinned deps,
floating runner images, no fixed seed — "regression" is noise). Pin what
you can (runner image, dep versions, input data, RNG seeds); record what
you cannot as known noise. **Results are artifacts, not stdout** — upload
as a CI artifact or commit to a results branch, so each run is queryable,
not a log line that expires.

## MC/DC for safety-critical boolean logic

When a project declares `SAFETY_LEVEL: mcdc`, every boolean decision in
changed code must achieve Modified Condition/Decision Coverage — each
atomic condition proven to independently affect the outcome (catches the
masked-condition bug class). It is a **deterministic pipeline** (AST → BDD
→ independence pairs → minimal test set → compiler measurement), not LLM
reasoning: a pre-computed spec (`mcdc-spec.json`) defines the test vectors;
the agent translates, the compiler verifies. Slow tier, pre-merge for
safety-critical paths. Full playbook: [`mcdc.md`](mcdc.md).
