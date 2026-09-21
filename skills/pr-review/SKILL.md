---
name: pr-review
description: "Review a pull request using a pillar-driven adversarial methodology. Two adversaries cover nine CI quality pillars: the Architect (structural fit: coupling & architecture decay, design intent & DRY, interface stability, CI economy) and the Adversary (behavioral soundness: correctness, security, performance, observability, test quality). A Judge adjudicates. The reviewer scans the diff to determine which pillars apply, investigates those selectively, and marks the rest N/A — making coverage visible without bloating every review. Leverages deterministic proof (lint/tests/CI via bash), the architecture graph (RIG + C4), and selective web search. Two ingress points: manual (dev-workflow review subcommand) or automated (harmostes pr-review workflow)."
---

# PR Review — Pillar-Driven Adversarial Toolkit

Review a PR from **two adversarial stances** across **nine CI quality
pillars**, then adjudicate: scan the diff against pillar triggers,
investigate the ones that fire, mark the rest N/A — coverage is visible
without investigating every pillar on every PR. The author held the whole
codebase in their head; the reviewer does not need to. Answer sharp
questions about the **delta** from minimal context — the diff, the
architecture graph (RIG + C4), selective tools. Never read the whole repo.

## The 15-minute contract

A review that has not posted its verdict within the run bound is a FAILED
review, however good — the platform kills the run and the next one starts
over (live: #357 r14 — a focused 5-file PR burned 65 min of wall on
unbounded verification theater: watching CI the ingress already guarantees,
a cold full-battery run, per-finding mutation probes each rebuilding from
scratch, a verdict written as an essay; the verdict itself took 5 min).
Budget the review at **15 minutes**, spent where findings come from:

| Phase | Cap | Rule |
|---|---|---|
| Orient (context + diff + RIG brief of touched nodes) | 3 min | Read the diff — it is the artifact. Follow a symbol out of the diff only when the finding hinges on it. |
| Investigate (pillars the diff's triggers select) | 7 min | Targeted source reads. A cross-package trace earns its keep only when a finding names the seam. |
| Deterministic proof | 3 min | ONE warm build + tests for TOUCHED packages only — never the full battery (pipeline CI is green by ingress). Mutation probes batch into one edit→test→revert cycle, load-bearing claims only. |
| Judge + write | 2 min | The verdict is the payload. Write it, post it, done. |

Budget exhausted mid-investigation → post what the evidence already
supports at the highest remaining severity; an honest partial verdict beats
a perfect review that dies unposted. Never re-derive what the diff shows.

## Ingress contract — validated SHAs only

**This skill owns the review process**: the two-stance methodology, the
verdict vocabulary (APPROVE / REQUEST_CHANGES), the `reviewed_sha` currency
rule, the label lifecycle (set by the requester; consumed only by a verdict
at the exact reviewed SHA). The output contract's canonical home is
`verdictTrailer` in the harmostes tree (internal/review/review.go);
`dev-workflow` requests and consumes verdicts — it never re-states them.

Two ingress points, one contract: the **harmostes Review-Ready Gate**
(ADR-0006, armed per PR by the `needs-review` label) proceeds only when
label ∧ merge-rule context is green at the head SHA; or **manual** via
`dw_request_review`, which refuses unvalidated heads. Invoked **only on a
pipeline-green SHA** — red CI is fixed on the branch, never reviewed; this
pass exists for what CI cannot see. Phase-0 deterministic proof remains:
it catches nondeterminism and drift, not CI status.

## Context and toolkit

Workspace (assembled by pr-fetch): `/workspace/pr-context.json` (PR
metadata, CI status, files changed; `rig_path` set → RIG graph exists,
`c4_path` set → C4 model exists) — read it FIRST; `/workspace/pr-diff.patch`
(the full diff); `/workspace/repo` (checkout at the head SHA);
`/workspace/wiki` (project wiki if configured). Route selectively.

| Tool | When | Gives |
|------|------|-------|
| `read` | always — diff, changed files, RIG/C4, wiki | code + architecture context |
| `grep` | usages, test files, exported symbols, log/metric calls | where things are used |
| `bash` | **deterministic proof** — build, lint, tests, benchmarks | pass/fail, not opinion |
| `web_search` | **selectively** — crypto, concurrency, new dependency, CVEs | current practice, advisories |

Do not web_search everything: for most changes the diff + RIG + lint/tests
suffice.

## The 9 pillars

Scan the diff against the **Trigger** column; investigate pillars that
fire, mark the rest N/A. Scale to the risk of the change, not the pillar
count — docs-only touches ~0 pillars; a GPU kernel touches performance,
correctness, observability, test quality; an auth handler touches
security, correctness, interface stability.

### Architect — structural fit (4 pillars)

| Pillar | Question | Proof | Trigger (investigate when…) |
|--------|----------|-------|-----------------------------|
| **Coupling** | Does it respect component boundaries in the RIG — and keep the graph's shape scalable (no cycles, hubs, god-components)? | RIG edge check + `rig overview` shape + the brief's risk lines (blast radius) | the diff adds imports/calls across components, or grows a component's footprint |
| **Design Intent** | Aligned with documented decisions / ADRs? **Does the diff duplicate existing functionality?** | `rig search` (whole graph) + `rig clones` near-dup edges + `rig dead` + wiki pages + model.c4 `// Exports:` | the change touches documented architecture, **or adds new functions/types** |
| **Interface Stability** | Breaking changes to exported symbols / API contracts? | grep exports + diff | the change modifies public/exported API |
| **CI Economy** | Is CI treated as the expensive asset it is — each new check **necessary** (no existing check already achieves the purpose) and **efficient, in the right place** (tier, trigger, single home)? | Read the full CI surface (all workflow files + Makefile/`scripts/test` runners) and purpose-map it against the diff | the diff touches workflow/CI files or test runners, adds/moves checks between tiers, or adds tests that run in CI |

### Adversary — behavioral soundness (5 pillars)

| Pillar | Question | Proof | Trigger (investigate when…) |
|--------|----------|-------|-----------------------------|
| **Correctness** | Logic right? Edge cases, invariants, error handling? | test suite pass | any logic change |
| **Security** | Injection, authz, secrets, supply chain? | web_search CVEs | auth, crypto, network, SQL, deserialization |
| **Performance** | Complexity, hot paths, resource leaks, allocation patterns? | benchmarks (if exist) | loops, allocations, I/O, hot paths |
| **Observability** | Logging, metrics, traceability, error messages? | grep log/metric | error paths, async work, production paths |
| **Test Quality** | Tests exist? Test behavior (not implementation)? Cover edges? | coverage gap on changed files | new behavior added or altered |

## The review process

### Phase 0: Orient (read the change)

1. `cat /workspace/pr-context.json` — project, CI status, files.
2. Read the diff (`/workspace/pr-diff.patch`).
3. **One graph call, the whole orientation:** when `rig_path` is set and
   the diff touches code, run `rig brief diff=$(git diff
   origin/<default>...HEAD) expectSha=$HEAD_SHA` — provenance (stale graph
   → re-emit, never review one), touched files → components, risk-ranked
   symbols with fan-in and cross-component hops, orphaned new exports,
   near-clone edges, and the drill-down menu. **Orientation is one call;
   drill down (`rig impact` / `dead` / `clones` / `trace` / `component`)
   only where the brief flags** — they are follow-ups a finding names, not
   a second orientation pass. If `c4_path` is set, read the relevant C4
   view for design intent beyond what the brief flags.
4. Run deterministic proof via `bash`, CHEAPLY (15-minute contract): detect
   the build system (Makefile `make test`, `scripts/test`, `go.mod`→`go`,
   `build.zig`→`zig`, `package.json`→`npm`, `Cargo.toml`→`cargo`).
   - Build once — it warms every later test invocation.
   - Tests: **touched packages only** — the battery ran in pipeline CI on
     this exact SHA and is green by ingress.
   - A failing build or test is an automatic REQUEST_CHANGES — no debate.
   - CI status is a FIELD in `pr-context.json`. Read it; never poll or
     watch a pipeline — that is the dispatcher's spent budget, not yours.
5. Scan the diff against the pillar triggers; note relevant pillars.

### Phase 1: Architect — structural fit

- **Coupling** — each new cross-component import/call must be a graph edge
  or documented (wiki/ADR); undocumented edges are findings. Check
  **architecture decay against a deterministic baseline**, not by eyeball:
  `rig-fitness.py <db> --json` on base (merge-base SHA or the kb's
  `raw/arch/<proj>/rig.db`) vs head, diff for new cycles, fan-in growth on
  touched components, growth in the largest component — scalability is a
  graph *shape* property; findings stand even when each edge is
  individually documented. Cite a HIGH `brief` risk line rather than
  re-deriving it; evidence reads like `fan-in 3→9 on decode`.
- **Design Intent** — read the entity/concept/ADR pages for touched
  components. **DRY:** for every new exported symbol, `rig search` its name
  and capability keywords — a matching export anywhere is a finding
  (extend, don't duplicate); `rig clones` catches paraphrased copies;
  `rig dead` flags new exports zero callers reach (dead API surface is a
  finding, not a neutral fact). Without a rig.db: model.c4
  `// Exports:` + `grep`.
- **Interface Stability** — does the diff modify exported/public symbols,
  API contracts, schema? `grep` usages of changed symbols across the repo;
  breaking changes without versioning/migration are findings. Evidence:
  the symbol and its usages.
- **CI Economy** — every check is paid on every future push, forever. When
  the diff adds or moves CI work, re-run the author's purpose audit
  independently: enumerate the entire CI surface (workflow files plus what
  CI invokes — Makefile targets, `scripts/test`, reusable actions), reduce
  each check to its **purpose** (the defect it catches, not its commands),
  compare the diff's additions against that map. Findings (cite the
  colliding check file:line):
  - new check whose purpose an existing check already achieves — **MAJOR**:
    the logic moves (extend or re-home), never clones;
  - a purpose re-homed by copy-paste (two homes) → **MAJOR**;
  - new purpose in the wrong tier/trigger → **MAJOR** if the waste recurs
    on every push, **MINOR** otherwise;
  - inefficiency inside a legitimate check (no caching, unbounded matrix,
    missing `concurrency` cancellation) → **MINOR**.

  Test Quality hunts *missing* coverage; CI Economy hunts *redundant*
  coverage — together they bound the test delta from both sides. When
  workflow files changed, run `dw_ci_conformance "origin/<default>"`; its
  findings are findings here too.

### Phase 2: Adversary — behavioral soundness

- **Correctness** — logic errors, unhandled errors, off-by-one, nil/null
  deref, races, missing input validation; verify invariants on edge cases
  (empty, max, concurrent). When tests cannot answer a call-chain question
  (who reaches this path, what breaks if the invariant flips), `rig trace
  '<a> <b>'` returns the shortest call paths — escalation only, never a
  substitute for running the tests. Evidence: the code line, or the trace
  path with the broken link in it.
- **Security** — injection, secret exposure, missing authz, unsafe
  deserialization; for auth/crypto/network/SQL diffs, `web_search` known
  vulnerabilities in the specific functions/patterns. Evidence: the
  pattern + advisory.
- **Performance** — algorithmic complexity, hot-path allocations, resource
  leaks (file handles, connections, goroutines, GPU memory), unbounded
  growth; run benchmarks if they exist. Evidence: the hot path or
  allocation site.
- **Observability** — are errors logged/surfaced, metrics for the new
  behavior, debuggable in production? `grep` log/metric calls in changed
  files; missing logging on error paths is a finding (cite the silent
  error path).
- **Test Quality** — tests for new behavior, through public interfaces
  (not implementation), covering the edge cases found; missing tests for
  new behavior is a MAJOR finding (cite the untested function/behavior).

Be selective: if the diff doesn't touch a pillar's trigger, mark it N/A
and move on. Do not force an investigation where there is no risk.

### Phase 3: Judge — adjudicate

1. Collect findings across investigated pillars.
2. Verify each CRITICAL/MAJOR finding cites evidence (code line +
   proof/RIG/wiki/advisory). Findings without evidence downgrade to NIT.
3. Weigh severity:
   - **CRITICAL** — security hole, data loss, broken architecture, build failure
   - **MAJOR** — logic error, missing tests for new behavior, undocumented
     coupling, breaking interface change, resource leak, duplicated CI
     purpose or a check in the wrong tier/trigger
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
   the diff contains is a **TODO**, not a finding: record it in `todos[]`
   (same shape as `comments[]`). TODOs anchor as non-blocking threads the
   dev must address; they never change THIS decision, but unresolved TODO
   threads downgrade the NEXT round's APPROVE. Anything that makes the
   change incorrect or unmergeable is a finding, never a TODO.

"Deterministic proof" = the reviewer's independent local run of the
checked-out delta — pipeline CI is green by ingress contract.

## The inline review protocol — threads are the merge currency

Under the r7 output contract the threads are **NOT yours to post**: every
NEW blocking finding rides `review.json`'s `comments[]` (path, line, body);
the deploy node publishes them as native anchored threads and composes the
one-line verdict. NEVER post NEW findings via the forge CLI yourself — a
self-post duplicates the deploy's publish and the verdict line lies about
the count. One thread per finding (and per TODO); the verdict is a
deploy-composed ONE-LINE comment (decision + SHA + blocking count +
trailer) — you write no prose.

**Exact per-host call shapes** (gh/fj/glab post/reply/resolve, the Forgejo
`new_position` field, `fj review reply|resolve|comments` — native since
#115 shipped, verdict-sink identity mechanics) live in
[`references/thread-commands.md`](references/thread-commands.md) — load it
when replying to or closing threads, or debugging where a verdict landed.

**Verdict sink — identity decides.** The deploy posts the verdict as a
native review event under the runtime identity. **Doctrine (r18): the
verdict is a testing signal, not merge authority — anywhere.** Its value
is the FINDINGS it delivers and the corroboration it offers; the
non-determinism of an LLM reviewer (a re-review of an unchanged diff can
disagree — the rhesadox#2359 class) means no merge, in any repo, may
stand on a verdict alone. Deterministic gates (CI, conformance,
signatures) are the enforcement layer; a merge that must proceed without
a guaranteed verdict carries a recorded owner-bypass with the
deterministic evidence instead. Where branch protection arms on the
review event, treat the native APPROVED/REQUEST_CHANGES as one input to
the owner's judgment — never as a guarantee to lean on.

**Later rounds — YOU (the reviewer) resolve prior threads by
verification.** For every prior-round thread: locate the fix in the diff;
when the solution is valid, the thread is CLOSED by your verification —
post the verification **on that same thread** (the host's reply mechanism;
`fj review reply` on Forgejo) and resolve it natively (`fj review resolve
<PR> <COMMENT-ID>`).
Do NOT downgrade an APPROVE because a thread shows unresolved in the host
UI — UI state can lie both ways; query the threads instead (`fj review
comments <PR> <REVIEW>`, resolved markers) — trusting the UI burns a full
review round on findings already fixed (r12, live on #483). A downgrade is
for exactly one thing: a prior finding NOT addressed in the diff.

**Same head, same verdict — refuse in one line (r17, #567).** If the PR
head equals the head an existing verdict was posted at, and the diff is
unchanged since, do NOT run the phases: every phase re-derives a conclusion
that already exists (the rhesadox#2359 class — six full reviews, one diff).
Emit the verdict line stating the standing decision, SHA, and unresolved
count, with the directive (push a fix, reply + resolve on the threads,
re-arm), and stop. The kernel's gate enforces the same rule before
dispatch; this is the reviewer-side backstop for older gates and manual
dispatches. Determinism is the point: re-arm at an unchanged head must
NEVER produce a different verdict — that non-determinism is exactly what
made re-arm-as-retry rational for the dev.

**Author side (dev agent) — mandatory before the pipeline resumes:** for
every open thread — findings AND TODOs alike — the dev responds **on that
same review thread** (the anchored code comment itself, via the host's
reply mechanism: `in_reply_to` on GitHub, discussion notes on GitLab,
`fj review reply` on Forgejo), carrying the fix SHA + one-line rationale,
then resolves it natively. **Forgejo close-out order (the standard):**
as each fix lands, resolve the threads it addresses — `fj review resolve
<PR> <COMMENT-ID>` — resolution IS the close-out, the fix is verified in
the diff; the **actual replies** (`fj review reply`) come only when
everything is done — one per thread, `path:line → fix SHA + rationale`,
the round record. A reply posted as a separate/new comment does NOT
count — the answer lives where the finding lives, so the thread reads as
one conversation. New anchored snippet comments per finding are
FORBIDDEN — each starts a new thread instead of answering the finding's
(anti-pattern observed live, rhesadox#2241: five `reply_to=None`
comments, one per finding).

**Transport failures register NOTHING (r17, live on rhesadox#2359).** The
host silently accepts every wrong transport — a PR-conversation comment,
a standalone COMMENT-type review, a new anchored snippet — with HTTP 201.
Nothing errors, so "replied wrongly" and "replied and was heard" are
indistinguishable from your side, and the only signal is the reviewer
re-counting unresolved threads, which reads like rejection of your
ARGUMENT when it is rejection of your TRANSPORT. On #2359 the dev spent
five rounds posting "Thread resolution" COMMENT-reviews while thread
#40268 never moved. Before concluding a reviewer is ignoring you, verify
the state yourself: `fj review comments <PR> <REVIEW>` — resolved markers
and `in_reply_to` are the only registration. If you believe a finding is
WRONG, the registered path is an on-thread reply with evidence — never
re-arm-as-retry.

**Re-arm is refused over a standing verdict (#567, live on rhesadox
#2359).** A head is reviewed exactly once: if a `pr-review:` verdict
trailer stands at the CURRENT head SHA, the gate will not dispatch again —
re-arming cannot change the verdict, it can only burn agent runs (six
identical reviews of one SHA on #2359). Re-arm is meaningful only after a
PUSH (new head) plus the thread close-out above. If you disagree with the
verdict, the new head carrying your fix (or your on-thread rebuttal, which
the next round's reviewer verifies) is the only lever.

Then
**request review from harmostes-bot
natively** — the request is the re-arm signal (#488; the label stays the
scope contract). post-review mechanically **downgrades an APPROVE issued
over prior-round threads whose findings are not addressed in the diff** —
unaddressed findings block the pipeline and the merge, whatever the
verdict text says.

## Output contract — threads are the review; the comment is one line

The pillar analysis (Phases 0–3) happens in your head and your tool calls
— never posted as prose. Exactly three things leave this review:

1. **Blocking findings** — each CRITICAL or verified MAJOR finding is ONE
   `comments[]` entry, posted by the deploy as a native inline thread each
   dev must independently resolve before merge. MINOR/NIT are NOT posted.
2. **TODOs** — each completely-missing piece is ONE `todos[]` entry,
   anchored non-blocking; never change the decision, unresolved ones
   downgrade the next round.
3. **A one-line verdict** — by the deploy, not you: decision, SHA, blocking
   count. No pillar-structured body, no summary, no coverage essay.

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

- `decision` — `APPROVE` (no blocking findings) or `REQUEST_CHANGES` (≥1).
  No COMMENT middle ground; MINOR/NIT dropped; TODOs never affect it.
- `reviewed_sha` — head SHA of `/workspace/repo` (full 40 hex); the deploy
  embeds it in the verdict and anchors every thread to it.
- `comments` — ONLY blocking findings (`[]` when approving); each a
  self-contained thread — what is wrong, the evidence, what to do. The
  deploy deduplicates and publishes; do not post them yourself.
- `todos` — optional; ONLY completely-missing pieces (`[]` or omit); same
  self-contained rule.

**Coverage** stays your discipline — every pillar investigated per the
phases — but it is reported by the deploy's one-line verdict ("pillars
clean" vs "N blocking"), not by an N/A essay.

## Do NOT

- Do not push, commit, or modify any repository. Review only.
- Do not read the entire repo. Route to the minimal source (RIG, C4, wiki
  pages for touched components, changed files).
- Do not investigate pillars whose triggers the diff doesn't touch. Mark N/A.
- Do not state findings without evidence. Cite the code line, the RIG edge,
  the wiki page, or the deterministic check that failed.
- Do not re-dispatch CI or wait for pipelines — ingress guarantees a green
  SHA; review the delta.

## Relationship to other skills

- **`dev-workflow`** — owns the gate chain; this skill **is gate 12**.
  Pillar→gate map: Coupling → Gate 7, Design Intent → Gate 1, CI Economy →
  the CI-discipline purpose audit ([`ci-wiring.md`](dev-workflow/references/ci-wiring.md) purpose audit). The verdict
  trailer is what `dw_merge_readiness` consumes as merge currency.
- **`llm-wiki`** — consulted for Design Intent: RIG/C4 are the
  deterministic architecture graph; wiki pages are the reasoning.

## Divergence ledger — carried across rounds (never re-litigate, never forget)

Empirical source: rounds r18–r20 of the model-role flip + #367's blocker.
Multi-round loops were never *disagreements about the implementation* —
they were **unverified claims about the implementation**. Each round checks
the *class*, not just the finding:

1. **Tests pin mechanism, not intent.** Mutation-probe the load-bearing
   test: swap the guarded value for nonsense (`BOGUS/primary`), run the
   suite — red required. A test that survives nonsense is decoration (r18:
   19/19 passed with a BOGUS default).
2. **One fact, one home.** When a fix updates a stated fact (constant,
   chain, clamp, limit), grep for EVERY home of that fact (docblocks,
   canonical comments, ADRs) — fix the class, not the instance (r19: third
   stale vintage in `applyChains` docblock).
3. **Deployment claims are manifest-grounded.** Any claim about durability,
   env, volumes, or topology must be falsified against `job.go`, the
   chart, and the ops repo — never accepted from an ADR's prose (r20: "the
   directory IS the association" died on `/tmp` being per-pod ephemeral).
4. **Self-authored spec = suspect premise.** When the PR's author also
   authored the ADR/spec it implements, the load-bearing assumption gets an
   adversarial pass *first*.

**Session continuity:** a PR's review rounds are ONE lineage (ADR-0010). If
a prior verdict exists at an earlier head, resume its context: verified
findings stay verified, addressed fixes are acknowledged, the review
examines the delta between heads. This ledger is the compaction seed — what
survives between rounds.
