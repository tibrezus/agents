---
name: pr-review
description: "Review a pull request using a pillar-driven adversarial methodology. Two adversaries cover eight CI quality pillars: the Architect (structural fit: coupling & architecture decay, design intent & DRY, interface stability) and the Adversary (behavioral soundness: correctness, security, performance, observability, test quality). A Judge adjudicates. The reviewer scans the diff to determine which pillars apply, investigates those selectively, and marks the rest N/A — making coverage visible without bloating every review. Leverages deterministic proof (lint/tests/CI via bash), the architecture graph (RIG + C4), and selective web search. Two ingress points: manual (dev-workflow review subcommand) or automated (harmostes pr-review workflow)."
---

# PR Review — Pillar-Driven Adversarial Toolkit

This skill reviews a PR from **two adversarial stances** across **eight CI
quality pillars**, then adjudicates. Unlike a fixed checklist, the reviewer
scans the diff to determine which pillars apply, investigates those
**selectively**, and acknowledges the rest — making coverage **visible**
without investigating every pillar on every PR.

## The reviewer's advantage: smaller context

The **author** held the entire codebase in their head. The **reviewer** does
not need to. It answers sharp questions about a **delta** using the minimal
context: the diff, the architecture graph (RIG + C4), and selective tools.

Keep the context small. Do not read the whole repo. Route to the minimal source.

## The 15-minute contract

A review that has not posted its verdict within the run bound is a FAILED
review, no matter how good it would have been — the platform kills the run
and the next one starts over. Observed live (#357 r14): a focused 5-file
PR spent run 1 dying at the 30-minute bound mid-trace and run 2 re-deriving
it, 65 minutes wall for a diff whose verdict took 5 minutes to earn. The
failure was not hard thinking — it was unbounded verification theater:
watching CI the ingress contract already guarantees, a cold full-battery
test run, per-finding mutation probes each rebuilding from scratch, and a
verdict written as an essay. Budget the whole review at **15 minutes** and
spend it where findings come from:

| Phase | Cap | Rule |
|---|---|---|
| Orient (context + diff + RIG component of touched nodes) | 3 min | The diff is the artifact under review — read IT, not the codebase around it. Follow a symbol out of the diff only when the finding hinges on it. |
| Investigate (the pillars the diff's triggers select) | 7 min | Targeted source reads. A trace across packages earns its keep only when a finding names the seam. |
| Deterministic proof | 3 min | ONE warm build (`go build ./...` or equivalent) + tests for the TOUCHED packages only (`go test ./internal/worker/ ./api/...`) — never the full battery; pipeline CI owns that and it is green by ingress. Mutation probes: batch ALL candidate edits into ONE edit→test→revert cycle. Probes are for load-bearing pin claims, not decoration — a probe that cannot change a verdict is skipped. |
| Judge + write | 2 min | The verdict is the payload. Write it, post it, done. |

If the budget runs out mid-investigation, post what the evidence already
supports at the highest remaining severity — an honest APPROVE-with-note
or REQUEST_CHANGES on partial coverage beats a perfect review that dies
unposted. Never spend budget re-deriving what the diff itself shows.

## Ingress contract — validated SHAs only

**This skill owns the review contract**: the two-stance methodology below,
the verdict vocabulary (APPROVE / REQUEST_CHANGES / COMMENT), the trailer
format `<!-- pr-review: DECISION @ sha -->`, the `reviewed_sha` currency
rule, and the label lifecycle (set by the requester; consumed ONLY by a
verdict posted at the exact reviewed SHA). `dev-workflow` requests and
consumes verdicts; it never re-states these rules.

Two ingress points, one contract:
- **harmostes (automated):** the event-armed Review-Ready Gate (ADR-0006)
  proceeds only when the label is present ∧ every merge-rule required
  context is green at the head SHA; the workspace plugin provisions the
  knowns (clone at head, PR context, tools); the agent runs this skill.
- **manual:** `dw_request_review` guards greenness requester-side, then
  sets the same label — human-ticking the label in the UI is equivalent.

Invoked **only on a pipeline-green SHA**: the harmostes gate pins the
validated SHA, or `dw_request_review` refuses
unvalidated heads. CI evidence in `pr-context.json` is green by contract —
red CI is fixed on the branch, never reviewed; this pass exists for what CI
*cannot* see. Phase-0 deterministic proof (local build/test of the delta)
remains — it catches nondeterminism and drift, not CI status.

## Context you have (assembled by pr-fetch)

- **`/workspace/pr-context.json`** — PR metadata, CI status, files changed.
  If `rig_path` is set, a RIG (component graph) exists. If `c4_path` is set, a
  C4 model exists.
- **`/workspace/pr-diff.patch`** — the full diff
- **`/workspace/repo`** — checked-out repo at the PR's head SHA
- **`/workspace/wiki`** — project wiki (if configured): RIG, C4 model, design pages

Read `pr-context.json` first, then route selectively.

## Toolkit (use on demand, not all at once)

| Tool | When to use | What it gives you |
|------|------------|-------------------|
| `read` | Always — diff, changed files, RIG/C4, wiki | Code + architecture context |
| `grep` | Find usages, test files, exported symbols, log/metric calls | Where things are used |
| `bash` | **Deterministic proof** — build, lint, tests, benchmarks | Pass/fail, not opinion |
| `web_search` | **Selectively** — crypto, concurrency, new dependency, CVEs | Current best practices, advisories |

**Do not web_search everything.** Use it when the change touches a domain where
external knowledge adds value. For most changes, the diff + RIG + lint/tests
are sufficient.

## The eight pillars

The review vocabulary. Scan the diff against the **Trigger** column to decide
which pillars are relevant. Investigate those; mark the rest N/A.

### Architect — structural fit (3 pillars)

| Pillar | Question | Proof | Trigger (investigate when…) |
|--------|----------|-------|-----------------------------|
| **Coupling** | Does it respect component boundaries in the RIG — and keep the graph's shape scalable (no cycles, hubs, god-components)? | RIG edge check + `rig overview` shape | the diff adds imports/calls across components, or grows a component's footprint |
| **Design Intent** | Aligned with documented decisions / ADRs? **Does the diff duplicate existing functionality?** | `rig search` (whole graph) + wiki pages + model.c4 `// Exports:` | the change touches documented architecture, **or adds new functions/types** |
| **Interface Stability** | Breaking changes to exported symbols / API contracts? | grep exports + diff | the change modifies public/exported API |

### Adversary — behavioral soundness (5 pillars)

| Pillar | Question | Proof | Trigger (investigate when…) |
|--------|----------|-------|-----------------------------|
| **Correctness** | Logic right? Edge cases, invariants, error handling? | test suite pass | any logic change |
| **Security** | Injection, authz, secrets, supply chain? | web_search CVEs | auth, crypto, network, SQL, deserialization |
| **Performance** | Complexity, hot paths, resource leaks, allocation patterns? | benchmarks (if exist) | loops, allocations, I/O, hot paths |
| **Observability** | Logging, metrics, traceability, error messages? | grep log/metric | error paths, async work, production paths |
| **Test Quality** | Tests exist? Test behavior (not implementation)? Cover edges? | coverage gap on changed files | new behavior added or altered |

**Selective investigation is the key.** A docs-only change touches ~0 pillars.
A GPU kernel touches performance, correctness, observability, test quality. An
auth handler touches security, correctness, interface stability. Scale your
investigation to the risk of the change, not to the number of pillars.

## The review process

### Phase 0: Orient (read the change)

1. `cat /workspace/pr-context.json` — what project, what CI status, what files?
2. Read the diff (`/workspace/pr-diff.patch`).
3. If `rig_path` is set, read the RIG components touched by the diff. If
   `c4_path` is set, read the relevant C4 view.
4. Run deterministic proof via `bash`, CHEAPLY (see the 15-minute contract):
   detect the build system from the repo (Makefile `make test`,
   `scripts/test`, `go.mod`→`go`, `build.zig`→`zig`, `package.json`→`npm`,
   `Cargo.toml`→`cargo`):
   - Build: `cd /workspace/repo && <build cmd>` — once; this warms every
     later test invocation.
   - Tests: **touched packages only** (`go test ./pkg/under/test/...`), not
     the repo battery — pipeline CI ran the battery on this exact SHA and
     it is green by the ingress contract.
   - A failing build or test is an automatic REQUEST_CHANGES — no debate.
   - CI status is a FIELD in `pr-context.json`. Read it; never poll, never
     watch a pipeline — that is the dispatcher's spent budget, not yours.
5. **Scan the diff against the pillar triggers.** Note which pillars are
   relevant before investigating.

### Phase 1: Architect — structural fit

Investigate the relevant structural pillars:

- **Coupling**: does the diff add imports/calls across components? If a RIG
  exists, check whether each new dependency is an edge in the graph. If not,
  is the coupling documented in the wiki/ADR? Undocumented cross-component
  edges are findings. Then check **architecture decay** against a
  deterministic baseline, not by eyeball: fetch the base graph — the
  project's arch package at the merge-base SHA (package versions are the
  SHA series; `fj`/token auth) or the kb `raw/arch/<proj>/rig.db` at the
  base commit — run `rig-fitness.py <db> --json` (module repo-map) on base
  and head, and diff: new cycles, fan-in growth on touched components,
  size growth concentrated in the largest component, new duplicated
  symbols. Findings even when each edge is individually documented —
  scalability is a graph *shape* property, not an edge property.
  **Evidence**: cite the delta (e.g. `fan-in 3→9 on decode`), the RIG edge,
  or the import line.
- **Design Intent**: does the change align with the wiki's documented
  decisions? Read the relevant entity/concept/ADR pages for the touched
  components. **Also (DRY)**: for every new exported function/type, `rig
  search` the graph for its name and capability keywords — a matching export
  in **any** component (not only the touched ones) is a finding: extend the
  existing symbol instead of adding a near-duplicate. Without a rig.db,
  fall back to model.c4 `// Exports:` + `grep`. **Evidence**: cite the rig
  search hit (symbol + file:line), the wiki page/ADR, or the export line
  being duplicated.
- **Interface Stability**: does the diff modify exported/public symbols, API
  contracts, or schema? `grep` for usages of changed symbols across the repo.
  Breaking changes without versioning/migration are findings. **Evidence**:
  cite the symbol and its usages.

### Phase 2: Adversary — behavioral soundness

Investigate the relevant behavioral pillars:

- **Correctness**: logic errors, unhandled errors, off-by-one, nil/null deref,
  race conditions, missing input validation. Verify invariants hold on edge
  cases (empty, max, concurrent). **Evidence**: cite the code line.
- **Security**: injection, secret exposure, missing authz, unsafe
  deserialization. If the diff touches auth/crypto/network/SQL, `web_search`
  for known vulnerabilities in the specific functions/patterns.
  **Evidence**: cite the pattern + advisory.
- **Performance**: algorithmic complexity, hot-path allocations, resource
  leaks (file handles, connections, goroutines, GPU memory), unbounded
  growth. If benchmarks exist, run them. **Evidence**: cite the hot path or
  allocation site.
- **Observability**: are errors logged or surfaced? Are there metrics for the
  new behavior? Can you debug this in production? `grep` for log/metric calls
  in the changed files. Missing logging on error paths is a finding.
  **Evidence**: cite the silent error path.
- **Test Quality**: are there tests for the new behavior? Do they test behavior
  through public interfaces (not implementation)? Do they cover the edge cases
  you found? Missing tests for new behavior is a MAJOR finding.
  **Evidence**: cite the untested function/behavior.

**Be selective.** Scan the trigger column — if the diff doesn't touch the
trigger, mark the pillar N/A and move on. Do not force an investigation where
there is no risk.

### Phase 3: Judge — adjudicate

1. Collect findings across all investigated pillars.
2. Verify each CRITICAL/MAJOR finding cites evidence (code line + proof/RIG/
   wiki/advisory). Downgrade findings without evidence to NIT.
3. Weigh severity:
   - **CRITICAL** — security hole, data loss, broken architecture, build failure
   - **MAJOR** — logic error, missing tests for new behavior, undocumented
     coupling, breaking interface change, resource leak
   - **MINOR** — style issue, missing docstring, minor improvement
   - **NIT** — cosmetic, opinion, no evidence
4. Decide:

| Condition | Decision |
|-----------|----------|
| Any CRITICAL or verified MAJOR finding | REQUEST_CHANGES |
| Only MINOR/NIT | COMMENT |
| All investigated pillars pass + CI green + deterministic proof passes | APPROVE |

"Deterministic proof" here is the reviewer's independent local run of the
checked-out delta — pipeline CI is green by ingress contract.

## Output contract

Write the review to `/workspace/review.json` using Python (NOT a bash heredoc —
heredocs break on Markdown backticks and special chars):

```python
import json
review = {
    "decision": "APPROVE",
    "reviewed_sha": "<head SHA of /workspace/repo>",
    "body": (
        "## Adversarial Review\n\n"
        "### Architectural Fit\n"
        "- **Coupling:** (finding, or N/A + reason)\n"
        "- **Design Intent:** (finding, or N/A)\n"
        "- **Interface Stability:** (finding, or N/A)\n\n"
        "### Adversary Findings\n"
        "- **Correctness:** (finding, or N/A)\n"
        "- **Security:** (finding, or N/A)\n"
        "- **Performance:** (finding, or N/A)\n"
        "- **Observability:** (finding, or N/A)\n"
        "- **Test Quality:** (finding, or N/A)\n\n"
        "### Verdict\n(decision + weighted reasoning)\n\n"
        "<!-- pr-review: APPROVE @ <reviewed_sha> -->"
    ),
    "comments": [
        {"path": "src/foo.zig", "line": 42, "body": "Consider ..."}
    ]
}
json.dump(review, open("/workspace/review.json", "w"), indent=2)
```

**Length contract** (the verdict is read by a human and a merge gate — both
want the finding, not the essay): focused scope ≤ **500 words** total, with
PASSING pillars as a single line each (`**Coupling:** PASS — edges match the
RIG graph`). Reserve full prose for `huge` scope, and even there findings
lead; narration of what the diff obviously says is banned — the author wrote
it, the reader can read it. Cite, don't summarize.

- `decision` — `APPROVE`, `REQUEST_CHANGES`, or `COMMENT`.
- `reviewed_sha` — the head SHA of `/workspace/repo`. The body must **end**
  with the trailer `<!-- pr-review: <DECISION> @ <reviewed_sha> -->` (exact
  decision keyword, full SHA) — `dw_wait_review` polls for it,
  `dw_merge_readiness` binds it to the merge SHA.
- `body` — Markdown, structured by pillar (see above).
- `comments` — inline review comments (optional, `[]` if none). Each has
  `path`, `line`, `body`.

**Coverage rule**: every pillar appears in the body — either a finding or
"N/A — (brief reason)". Pillars can be grouped if multiple are N/A:
"N/A: Security (no auth/crypto surface), Observability (no prod paths)".
This makes coverage auditable — a reader sees what was checked at a glance.

## Do NOT

- Do not push, commit, or modify any repository. Review only.
- Do not read the entire repo. Route to the minimal source (RIG, C4, wiki pages
  for touched components, changed files).
- Do not investigate pillars whose triggers the diff doesn't touch. Mark N/A.
- Do not state findings without evidence. Cite the code line, the RIG edge, the
  wiki page, or the deterministic check that failed.
- Do not re-dispatch CI or wait for pipelines — ingress guarantees a green
  SHA; review the delta.

## Relationship to other skills

- **`dev-workflow`** — defines the gate chain; this skill **is gate 12**
  (adversarial review APPROVE on the merge SHA). The Architect pillars map
  to dev-workflow gates: Coupling → Gate 7, Design Intent → Gate 1. The
  verdict trailer is what `dw_merge_readiness` consumes as merge currency.
- **`llm-wiki`** — the wiki consulted for Design Intent. The RIG and C4 model
  are the deterministic architecture graph; the wiki pages are the reasoning.

## Divergence ledger — carried across rounds (never re-litigate, never forget)

Empirical source: rounds r18–r20 of the model-role flip + #367's blocker. Multi-round loops were never *disagreements about the implementation* — they were **unverified claims about the implementation**. Each round must check the *class*, not just the finding:

1. **Tests pin mechanism, not intent.** Mutation-probe the load-bearing test: swap the guarded value for nonsense (`BOGUS/primary`), run the suite — red required. A test that survives nonsense is decoration. (r18: 19/19 passed with a BOGUS default.)
2. **One fact, one home.** When a fix updates a stated fact (constant, chain, clamp, limit), grep for EVERY home of that fact (docblocks, canonical comments, ADRs) — fix the class, not the instance. (r19: third stale vintage in `applyChains` docblock.)
3. **Deployment claims are manifest-grounded.** Any claim about durability, env, volumes, or topology must be falsified against `job.go`, the chart, and the ops repo — never accepted from an ADR's prose. (r20: "the directory IS the association" died on `/tmp` being per-pod ephemeral.)
4. **Self-authored spec = suspect premise.** When the PR's author also authored the ADR/spec it implements, the load-bearing assumption gets an adversarial pass *first*.

**Session continuity:** a PR's review rounds are ONE lineage. If a prior verdict exists at an earlier head, resume its context (ADR-0010): previously-verified findings stay verified, previously-addressed fixes are acknowledged as addressed, and the review examines the delta between heads. The findings ledger above is the compaction seed — what survives between rounds.
