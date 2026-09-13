---
name: pr-review
description: "Review a pull request using a pillar-driven adversarial methodology. Two adversaries cover nine CI quality pillars: the Architect (structural fit: coupling & architecture decay, design intent & DRY, interface stability, CI economy) and the Adversary (behavioral soundness: correctness, security, performance, observability, test quality). A Judge adjudicates. The reviewer scans the diff to determine which pillars apply, investigates those selectively, and marks the rest N/A — making coverage visible without bloating every review. Leverages deterministic proof (lint/tests/CI via bash), the architecture graph (RIG + C4), and selective web search. Two ingress points: manual (dev-workflow review subcommand) or automated (harmostes pr-review workflow)."
---

# PR Review — Pillar-Driven Adversarial Toolkit

This skill reviews a PR from **two adversarial stances** across **nine CI
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
| Deterministic proof | 3 min | ONE warm build + tests for the TOUCHED packages only — never the full battery (pipeline CI is green by ingress). Mutation probes batch into one edit→test→revert cycle, and only for load-bearing claims. |
| Judge + write | 2 min | The verdict is the payload. Write it, post it, done. |

If the budget runs out mid-investigation, post what the evidence already
supports at the highest remaining severity — an honest APPROVE-with-note
or REQUEST_CHANGES on partial coverage beats a perfect review that dies
unposted. Never spend budget re-deriving what the diff itself shows.

## Ingress contract — validated SHAs only

**This skill owns the review process**: the two-stance methodology, the
verdict vocabulary (APPROVE / REQUEST_CHANGES), the `reviewed_sha`
currency rule, and the label lifecycle (set by the requester; consumed
only by a verdict at the exact reviewed SHA). The output contract's
canonical home is `verdictTrailer` in the harmostes tree
(internal/review/review.go); `dev-workflow` requests and consumes
verdicts — it never re-states these rules.

Two ingress points, one contract: the **harmostes Review-Ready Gate**
(ADR-0006, armed per PR by the `needs-review` label) proceeds only when
the label is present ∧ the merge-rule context is green at the head SHA;
or **manual** via `dw_request_review`, which refuses unvalidated heads.
Invoked **only on a pipeline-green SHA** — red CI is fixed on the branch,
never reviewed; this pass exists for what CI cannot see. Phase-0
deterministic proof remains: it catches nondeterminism and drift, not CI
status.

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

## The 9 pillars

The review vocabulary. Scan the diff against the **Trigger** column to decide
which pillars are relevant. Investigate those; mark the rest N/A.

### Architect — structural fit (4 pillars)

| Pillar | Question | Proof | Trigger (investigate when…) |
|--------|----------|-------|-----------------------------|
| **Coupling** | Does it respect component boundaries in the RIG — and keep the graph's shape scalable (no cycles, hubs, god-components)? | RIG edge check + `rig overview` shape + the brief's risk lines (blast radius) | the diff adds imports/calls across components, or grows a component's footprint |
| **Design Intent** | Aligned with documented decisions / ADRs? **Does the diff duplicate existing functionality?** | `rig search` (whole graph) + `rig clones` near-dup edges + `rig dead` + wiki pages + model.c4 `// Exports:` | the change touches documented architecture, **or adds new functions/types** |
| **Interface Stability** | Breaking changes to exported symbols / API contracts? | grep exports + diff | the change modifies public/exported API |
| **CI Economy** | Is CI treated as the expensive asset it is — is each new check **necessary** (no existing check already achieves the same purpose in a different way), and is it **efficient and in the right place** (tier, trigger, single home)? | Read the full CI surface (all workflow files + Makefile/`scripts/test` runners) and purpose-map it against the diff | the diff touches workflow/CI files or test runners, adds/moves checks between tiers, or adds tests that run in CI |

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
3. **One graph call, the whole orientation:** when `rig_path` is set and the
   diff touches code, run `rig brief diff=$(git diff
   origin/<default>...HEAD) expectSha=$HEAD_SHA` — provenance (stale graph
   → re-emit, never review one), touched files → components, risk-ranked
   touched symbols with fan-in and cross-component hops, orphaned new
   exports, near-clone edges, and the drill-down menu. **Orientation is one
   call; drill down only where the brief flags.** The drill-downs (`rig
   impact`, `rig dead <component>`, `rig clones <symbol>`, `rig trace <a>
   <b>`, `rig component`) exist for the follow-up a finding names — not as
   a second orientation pass. If `c4_path` is set, read the relevant C4
   view for design intent beyond what the brief flags.
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

- **Coupling**: does the diff add imports/calls across components? Each new
  dependency must be a graph edge or documented in the wiki/ADR —
  undocumented cross-component edges are findings. Then check **architecture
  decay** against a deterministic baseline, not by eyeball: run
  `rig-fitness.py <db> --json` on the base graph (merge-base SHA or the kb's
  `raw/arch/<proj>/rig.db`) and the head graph, and diff — new cycles,
  fan-in growth on touched components, size growth in the largest component.
  Scalability is a graph *shape* property; findings stand even when each
  edge is individually documented. The Phase-0 `brief` risk lines are the
  fine-grained complement — cite a HIGH line rather than re-deriving it.
  **Evidence**: the delta (`fan-in 3→9 on decode`), the RIG edge, or the
  `rig impact` risk line.
- **Design Intent**: aligned with the wiki's documented decisions (read the
  entity/concept/ADR pages for the touched components)? **And DRY**: for
  every new exported symbol, `rig search` its name and capability keywords —
  a matching export anywhere is a finding (extend, don't duplicate);
  `rig clones <symbol>` catches paraphrased copies; `rig dead` flags new
  exports zero callers reach (dead API surface is a finding, not a neutral
  fact). Without a rig.db: model.c4 `// Exports:` + `grep`. **Evidence**:
  the search hit, the `rig clones` edge, the `rig dead` line, or the ADR.
- **Interface Stability**: does the diff modify exported/public symbols, API
  contracts, or schema? `grep` for usages of changed symbols across the repo.
  Breaking changes without versioning/migration are findings. **Evidence**:
  cite the symbol and its usages.
- **CI Economy**: every check is paid on every future push, forever. When the
  diff adds or moves CI work, re-run the author's purpose audit
  independently: enumerate the entire CI surface (workflow files plus what
  CI invokes — Makefile targets, `scripts/test`, reusable actions), reduce
  each check to its **purpose** (the defect it catches, not its commands),
  and compare the diff's additions against that map. Findings:
  - a new check whose purpose an existing check already achieves —
    **MAJOR**: the logic moves (extend or re-home), never clones.
  - a purpose re-homed by copy-paste (two homes) → **MAJOR**.
  - a new purpose in the wrong tier/trigger → **MAJOR** if the waste
    recurs on every push, **MINOR** otherwise.
  - inefficiency inside a legitimate check (no caching, unbounded matrix,
    missing `concurrency` cancellation) → **MINOR**.
  Test Quality hunts *missing* coverage; CI Economy hunts *redundant*
  coverage — together they bound the test delta from both sides. When
  workflow files changed, run `dw_ci_conformance "origin/<default>"`; its
  findings are findings here too. **Evidence**: the colliding check
  (file:line), the duplicated purpose, or the tier/trigger mismatch.

### Phase 2: Adversary — behavioral soundness

Investigate the relevant behavioral pillars:

- **Correctness**: logic errors, unhandled errors, off-by-one, nil/null deref,
  race conditions, missing input validation. Verify invariants hold on edge
  cases (empty, max, concurrent). When the tests cannot answer a call-chain
  question (who reaches this path, what breaks if this invariant flips),
  `rig trace '<a> <b>'` returns the shortest call paths — escalation only,
  never a substitute for running the tests. **Evidence**: cite the code
  line, or the trace path with the broken link in it.
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
     coupling, breaking interface change, resource leak, duplicated CI
     purpose (a check CI already achieves elsewhere) or a check in the
     wrong tier/trigger
   - **MINOR** — style issue, missing docstring, minor improvement, CI
     efficiency polish
   - **NIT** — cosmetic, opinion, no evidence
4. Decide:

| Condition | Decision |
|-----------|----------|
| Any CRITICAL or verified MAJOR finding | REQUEST_CHANGES (each becomes a thread) |
| Only MINOR/NIT, or all clean + CI green + deterministic proof passes | APPROVE (MINOR/NIT are dropped, not posted) |

5. **Completely missing, not wrong?** A missing piece — absent test scope,
   an unwired tool, a doc that should exist — that is not a defect in what
   the diff contains is a **TODO**, not a finding: record it in
   `todos[]` (same shape as `comments[]`). TODOs anchor as non-blocking
   threads the dev must address (reply with the follow-up, then resolve);
   they never change THIS decision, but unresolved TODO threads downgrade
   the NEXT round's APPROVE. Anything that makes the change incorrect or
   unmergeable is a finding, never a TODO.

"Deterministic proof" here is the reviewer's independent local run of the
checked-out delta — pipeline CI is green by ingress contract.

## The inline review protocol — threads are the merge currency

A bullet list is not a review — but under the r7 output contract the
threads are NOT yours to post. **Every NEW blocking finding rides
`review.json`'s `comments[]`** (path, line, body); the deploy node
publishes them as native anchored threads and composes the one-line
verdict. NEVER post NEW findings via the forge CLI yourself — a
self-post duplicates the deploy's publish and the verdict line lies
about the count. The CLI protocol below is for the AUTHOR-side replies
and resolutions that close a thread:

- **GitHub (`gh`)**: `gh api repos/{o}/{r}/pulls/$N/comments -f commit_id=$SHA -f path=F -F line=N -f body="…"`.
  Reply: `gh api repos/{o}/{r}/pulls/$N/comments -f body="…" -F
  in_reply_to=$ID` (the `/replies` subpath 404s — verified live; use
  `in_reply_to`). Resolve via GraphQL `resolveReviewThread`
  (map the comment's databaseId → thread id with a `reviewThreads` query).
- **Forgejo / Codeberg (`fj`, native since v16.0.3-rezus.2)**: findings post
  as a real anchored review — one create-pull-review per round carrying ALL
  findings. THE LINE FIELD IS `new_position` (`new_line` 500s server-side).
  Reply/resolve: the REST shape has no
  in_reply_to yet (fork gap, rezuscloud/forgejo#… follow-up) — until it
  ships, a thread is addressed by a follow-up create-pull-review whose
  comment body leads with `path:line` + the resolution and the original
  comment id; native reply/resolve lands with the fork API extension.
- **Verdict sink — identity decides.** The deploy posts the verdict as a
  native review event under the runtime identity. On repos where the
  adversarial review is armed in branch protection (rhesadox `main`:
  `required_approvals=1` + `block_on_rejected_reviews` +
  `dismiss_stale_approvals` + `apply_to_admins`, whitelist
  `[harmostes-bot, tibrez]`), that native APPROVED/REQUEST_CHANGES **is**
  the binding approval: a reject physically blocks merge, a newer verdict
  from the same identity auto-dismisses the prior one, fresh pushes
  invalidate stale approvals. When the runtime identity IS the PR author,
  Forgejo rejects self-verdicts server-side → the deploy falls back to
  COMMENT; enforcement rides gate-12's trailer alone. Still post the
  trailer comment — gate-12 consumes it as merge currency (defense in
  depth).
- **GitLab (`glab`)**: positioned discussions —
  `glab api projects/:id/merge_requests/$N/discussions -X POST …`;
  reply via `…/discussions/$ID/notes`; resolve via `PUT … {"resolved":true}`.

One thread per finding (and per TODO); the verdict is a deploy-composed
ONE-LINE comment (decision + SHA + blocking count + trailer) — review.json
has NO body field and you write no prose. On a later round: verify each fix
in the diff, **reply on the thread with the fixing SHA**, then **resolve
it**.

**Author side (dev agent) — mandatory before the pipeline resumes:** reply
to every open thread — findings AND TODOs — with the fix SHA + one-line
rationale, resolve it (native where the host has it, a closing reply on
Forgejo), and only then re-arm. post-review mechanically **downgrades an
APPROVE issued over open prior-round threads** — unresolved threads block
the full pipeline and the merge, no matter what the verdict text says.

## Output contract — threads are the review; the comment is one line

The posted output is SMALL by design. The pillar analysis (Phases 0-3)
happens in your head and in your tool calls — it is never posted as prose.
Exactly three things leave this review:

1. **Blocking findings** — each CRITICAL or verified MAJOR finding becomes
   ONE entry in `comments[]`. The deploy posts them as native inline
   review threads anchored to the code; each must be independently
   resolved by the dev before the PR can merge. MINOR and NIT findings are
   NOT posted — they do not block merges and a review is not the place for
   style notes.
2. **TODOs** — each completely-missing piece becomes ONE entry in
   `todos[]`, anchored as a non-blocking thread the dev must address.
   TODOs never change the decision; unresolved ones downgrade the next
   round.
3. **A one-line verdict** — written by the deploy step, not by you. It
   states the decision, the SHA, and the blocking-finding count. Nothing
   else. There is no pillar-structured body, no summary section, no
   coverage essay.

Write the review to `/workspace/review.json` using Python (NOT a bash
heredoc — heredocs break on Markdown backticks and special chars):

```python
import json
review = {
    "decision": "REQUEST_CHANGES",
    "reviewed_sha": "<head SHA of /workspace/repo>",
    "comments": [
        {"path": "src/foo.zig", "line": 42,
         "body": "Blocking: <what is wrong> <evidence> <what to do>."}
    ],
    "todos": [
        {"path": "src/bar.zig", "line": 7,
         "body": "<what is completely missing> <where it belongs>."}
    ]
}
json.dump(review, open("/workspace/review.json", "w"), indent=2)
```

- `decision` — `APPROVE` (no blocking findings) or `REQUEST_CHANGES`
  (≥1 blocking finding). There is no COMMENT middle ground: MINOR/NIT
  findings are dropped, not posted. TODOs do not affect the decision.
- `reviewed_sha` — the head SHA of `/workspace/repo` (full 40 hex). The
  deploy embeds it in the verdict line and anchors every thread to it.
- `comments` — ONLY blocking findings (empty `[]` when approving). Each
  is one self-contained thread: what is wrong, the evidence, what to do.
  The deploy deduplicates and publishes them; do not post them yourself.
- `todos` — optional; ONLY completely-missing pieces (empty `[]` or omit
  the key). Same self-contained-thread rule: what is missing, where it
  belongs.

**Coverage** stays your discipline: every pillar investigated per the
phases above. But coverage is reported by the deploy's one-line verdict
("pillars clean" vs "N blocking"), not by an N/A essay — a pillar with no
blocking finding simply produces nothing.

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
  to dev-workflow gates: Coupling → Gate 7, Design Intent → Gate 1, CI
  Economy → the CI-discipline purpose audit (`ci-concepts.md` §3 — CI as a
  fundamental yet expensive asset: necessary checks only, no duplicated
  purposes, efficient and correctly placed). The verdict trailer is what
  `dw_merge_readiness` consumes as merge currency.
- **`llm-wiki`** — the wiki consulted for Design Intent. The RIG and C4 model
  are the deterministic architecture graph; the wiki pages are the reasoning.

## Divergence ledger — carried across rounds (never re-litigate, never forget)

Empirical source: rounds r18–r20 of the model-role flip + #367's blocker. Multi-round loops were never *disagreements about the implementation* — they were **unverified claims about the implementation**. Each round must check the *class*, not just the finding:

1. **Tests pin mechanism, not intent.** Mutation-probe the load-bearing test: swap the guarded value for nonsense (`BOGUS/primary`), run the suite — red required. A test that survives nonsense is decoration. (r18: 19/19 passed with a BOGUS default.)
2. **One fact, one home.** When a fix updates a stated fact (constant, chain, clamp, limit), grep for EVERY home of that fact (docblocks, canonical comments, ADRs) — fix the class, not the instance. (r19: third stale vintage in `applyChains` docblock.)
3. **Deployment claims are manifest-grounded.** Any claim about durability, env, volumes, or topology must be falsified against `job.go`, the chart, and the ops repo — never accepted from an ADR's prose. (r20: "the directory IS the association" died on `/tmp` being per-pod ephemeral.)
4. **Self-authored spec = suspect premise.** When the PR's author also authored the ADR/spec it implements, the load-bearing assumption gets an adversarial pass *first*.

**Session continuity:** a PR's review rounds are ONE lineage. If a prior verdict exists at an earlier head, resume its context (ADR-0010): previously-verified findings stay verified, previously-addressed fixes are acknowledged as addressed, and the review examines the delta between heads. The findings ledger above is the compaction seed — what survives between rounds.
