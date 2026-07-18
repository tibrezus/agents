---
name: pr-review
description: "Review a pull request using a pillar-driven adversarial methodology. Two adversaries cover eight CI quality pillars: the Architect (structural fit: coupling, design intent, interface stability) and the Adversary (behavioral soundness: correctness, security, performance, observability, test quality). A Judge adjudicates. The reviewer scans the diff to determine which pillars apply, investigates those selectively, and marks the rest N/A — making coverage visible without bloating every review. Leverages deterministic proof (lint/tests/CI via bash), the architecture graph (RIG + C4), and selective web search. Two ingress points: manual (dev-workflow review subcommand) or automated (harmostes pr-review workflow)."
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
| **Coupling** | Does it respect component boundaries in the RIG? | RIG edge check | the diff adds imports/calls across components |
| **Design Intent** | Aligned with documented decisions / ADRs? **Does the diff duplicate existing functionality?** | wiki pages + model.c4 `// Exports:` | the change touches documented architecture, **or adds new functions/types** |
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
4. Run deterministic proof via `bash` — detect the build system from the repo
   (Makefile `make test`, `scripts/test`, `go.mod`→`go`, `build.zig`→`zig`,
   `package.json`→`npm`, `Cargo.toml`→`cargo`):
   - Build: `cd /workspace/repo && <build cmd>`
   - Lint: `<lint cmd>` (if configured)
   - Tests: `<test cmd>`
   - A failing build or test is an automatic REQUEST_CHANGES — no debate.
5. **Scan the diff against the pillar triggers.** Note which pillars are
   relevant before investigating.

### Phase 1: Architect — structural fit

Investigate the relevant structural pillars:

- **Coupling**: does the diff add imports/calls across components? If a RIG
  exists, check whether each new dependency is an edge in the graph. If not,
  is the coupling documented in the wiki/ADR? Undocumented cross-component
  edges are findings. **Evidence**: cite the RIG or the import line.
- **Design Intent**: does the change align with the wiki's documented
  decisions? Read the relevant entity/concept/ADR pages for the touched
  components. **Also**: does the diff add new functions/types that duplicate
  capabilities already in the codebase? Check model.c4's `// Exports:` lines
  for the touched components — if a new function mirrors an existing export,
  that's a finding. **Evidence**: cite the wiki page/ADR or the model.c4
  export line that is being duplicated.
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

## Output contract

Write the review to `/workspace/review.json` using Python (NOT a bash heredoc —
heredocs break on Markdown backticks and special chars):

```python
import json
review = {
    "decision": "COMMENT",
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
        "### Verdict\n(decision + weighted reasoning)"
    ),
    "comments": [
        {"path": "src/foo.zig", "line": 42, "body": "Consider ..."}
    ]
}
json.dump(review, open("/workspace/review.json", "w"), indent=2)
```

- `decision` — `APPROVE`, `REQUEST_CHANGES`, or `COMMENT`.
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

## Relationship to other skills

- **`dev-workflow`** — defines the gate chain (issue, branch, milestone, CI).
  The Architect pillars map to dev-workflow gates: Coupling → Gate 7, Design
  Intent → Gate 1. This skill adds the engineering-quality review (the five
  Adversary pillars + Interface Stability) on top of the process gates.
- **`llm-wiki`** — the wiki consulted for Design Intent. The RIG and C4 model
  are the deterministic architecture graph; the wiki pages are the reasoning.
