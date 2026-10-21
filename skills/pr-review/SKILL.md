---
name: pr-review
description: "Adversarial review of a pull request or merge request on any forge (GitHub, Forgejo/Gitea, GitLab). Reviews the delta across nine quality pillars from two stances — an Architect judging structural fit (boundaries, design intent, interface stability, CI cost) and an Adversary probing behavior (correctness, security, performance, observability, test quality). Every pillar is examined on every review; depth scales with risk. Use when asked to review, critique, or vet a PR/MR before merge, or to re-review after fixes. Posts each verified finding as an anchored thread on the platform immediately, then a single verdict. Works on any project; uses an architecture map when the project provides one, derives structure from the code when it does not."
compatibility: "Requires a git checkout of the reviewed head SHA and access to the forge host (host CLI or HTTP API with a token)."
---

# PR Review — Adversarial, Pillar-Driven

Review a change from two adversarial stances and post what survives. The
**Architect** asks whether the change fits the codebase's structure; the
**Adversary** tries to break its behavior. A **Judge** decides what is
blocking. You review the **delta** — the diff is the artifact — reading the
smallest amount of surrounding context each finding needs. Never read the
whole repository.

All nine pillars are examined on every review. Most get a quick pass; the
risky ones get depth. Depth comes from risk, not habit.

## Ground rules

- Evidence or it didn't happen: every finding cites a code line, a failing
  check, a documented decision, or an external advisory.
- Never modify the reviewed repository. Review only.
- The platform is the state: threads on the PR are the durable record;
  your working notes are not.
- The pipeline guarantees CI was green at the reviewed head. If your
  context shows a failed check instead, say so and stop — red CI is fixed
  on the branch, not reviewed.
- If no pre-assembled context exists, build it: checkout the head SHA,
  fetch the diff and PR metadata via the host (see
  [references/hosts.md](references/hosts.md)).

## Orientation

Read, in order: the PR context (metadata, CI state, files touched), the
full diff, and the project's architecture map or design docs if they
exist. Note which components the diff touches and who depends on them —
from the map if there is one, from imports and symbol searches if not.
Pillars whose surface the diff barely touches get their quick pass and
move on; note where depth is warranted.

## The nine pillars

| Pillar | The question | Evidence that settles it | Dig deeper when |
|---|---|---|---|
| Boundaries | Does it respect the project's component seams — no new cycles, hubs, or god-modules? | the architecture map; import graph | cross-component calls or new dependencies appear |
| Design intent | Aligned with documented decisions? Duplicating an existing capability? | design docs; a search for the same capability elsewhere | new functions/types/commands are added |
| Interface stability | Breaking changes to exported symbols, APIs, schemas, or stored data? | usages of changed symbols across the repo | public surface changes |
| CI cost | Is every new or moved check necessary, and in the right place? | a purpose-map of the whole CI surface | CI files, runners, or check wiring change |
| Correctness | Logic right? Errors handled? Edge and concurrent cases safe? | the project's own tests on changed parts | any logic changes |
| Security | Injection, authz gaps, secrets, unsafe deserialization, supply chain? | pattern knowledge + external advisories | auth, crypto, network, SQL, or input parsing changes |
| Performance | Complexity, hot paths, resource leaks, unbounded growth? | benchmarks if they exist | loops, allocations, I/O, or hot paths change |
| Observability | Are new error paths logged or surfaced? Debuggable in production? | error paths in the diff | new error or async paths |
| Test quality | Do tests pin behavior through public interfaces, edges included? | the tests that changed with the code | behavior is added or altered |

## Investigate

Work the pillars where depth is warranted. For each hypothesis: find the
seam, read the minimal code, and try to **falsify** it — a suspicion that
survives an attempt to break it is a finding; one that doesn't was noise.
Depth recipes per pillar (with and without an architecture map) are in
[references/playbook.md](references/playbook.md) — load it when a pillar
needs more than its quick pass.

## Deterministic proof

Run the project's own checks on the changed parts — its build, its tests,
touched packages only. One warm build first. A failing build or test is an
automatic REQUEST_CHANGES; no debate, no further pillars needed. If a
load-bearing claim depends on a test really guarding something, make that
test fail on purpose once (feed it nonsense) and watch it go red — a test
that cannot fail guards nothing.

## Judge

Severity, with the evidence bar:

- **CRITICAL** — security hole, data loss, broken architecture, build failure.
- **MAJOR** — logic error, missing tests for new behavior, undocumented
  coupling, breaking interface change, resource leak, duplicated CI purpose.
- **MINOR / NIT** — style, polish, opinion. Recorded in your notes only.

Rules: a CRITICAL or MAJOR without cited evidence is a NIT. A *completely
missing* piece (a test scope that should exist, an unwired tool) is a
**todo**, not a finding — but it still blocks: every open thread counts
against the verdict, todos included. Decision: any verified CRITICAL or
MAJOR, or any todo left open → REQUEST_CHANGES; otherwise APPROVE.

## Posting protocol — threads are the review

If your environment carries a **posting credential** (a comment-scoped
token), post each verified blocking finding **immediately** as a native
anchored thread on the PR — do not batch. If no posting credential is
present, record findings in the ledger only; the pipeline publishes them.

Before posting, list the existing threads; **never post a finding that
already has an open thread** — reply on that thread instead. Threads are
append-only: a finding you later disprove is closed by a reply saying so,
never deleted. Exact verbs per host are in
[references/hosts.md](references/hosts.md).

Every thread you raise opens with its **class prefix** — the verdict gate
and the merge gate read it, and the class fixes the lawful way to close:

- `**Blocking**` — a defect in this diff. Close: fixed in this PR; reply
  the fix SHA, then **resolve**. Never carried.
- `**TODO**` — a missing complement. Close: fixed in this PR, same way.
- `**Architecture-carry**` — a design/architecture-scale flaw that
  outlives this diff. Close: **reply + resolve — a tracker issue is the
  EXCEPTION, not the default** (#71: the advisory "never duplicate"
  flooded rhesadox with ~20 re-mints of the same few findings). Mint one
  issue ONLY when BOTH hold: (a) the finding is **severe/structural**
  (security, data loss, outage, corruption — or you wrote an explicit
  `mint:` marker in the todo body) AND (b) **no existing issue covers
  it** — search OPEN and CLOSED issues with several keyword probes;
  titles drift between rounds, so probe the finding's stable nouns, not
  your last wording. A recurrence never mints: if you are writing
  "(Nth round…)" or "still open" in the body, an issue already exists —
  find it and reference it. Everything else resolves as a review-record
  carry: reply "carried in the review record" + **resolve**, no issue.
  Findings whose subject is deterministically GENERATED content
  (arch-sync artifacts: `raw/arch/`, `rig.json`, `model.c4`, `.mmd`,
  arch-graph commits and pages) never mint — they belong to the
  generator's owner; raise a TODO thread on the PR at most. Severe items
  (e.g. security) get *two* threads: a Blocking quick fix in this PR
  **and** an Architecture-carry for the structural cure.

A reply alone never closes a thread: the reply is the record, the
**resolve is the close-out**.

Record what you posted in the round ledger (the review file in your
workspace, if one was assembled; otherwise alongside your notes):

```json
{
  "decision": "REQUEST_CHANGES",
  "reviewed_sha": "<full head SHA>",
  "findings": [
    {"path": "src/foo.zig", "line": 42, "body": "Blocking: <what> <evidence> <fix>",
     "thread_ref": "<platform thread reference, once posted>"}
  ],
  "todos": [
    {"path": "src/bar.zig", "line": 7, "body": "<what is missing> <where it belongs>",
     "disposition": "fix-in-pr"}
  ]
}
```

`disposition` is `fix-in-pr` (default) or `architecture-carry`; a carry
entry SHOULD carry an `issue` reference (`"#431"` or a URL) whenever the
tracker already covers it, and MUST contain `mint:` (or a severity word:
severe/security/data loss/outage/corruption) when you want a NEW issue —
the pipeline's dedup and exception gates read the same signals (#71):
deduped (fuzzy, open+closed) and unmarked carries resolve as
review-record carries with no tracker issue. The pipeline publishes
uncarried todos as threads and carries marked ones — it never carries a
`Blocking` entry.

The verdict line (decision, SHA, blocking count) is composed from the
threads actually on the PR — not from the ledger — by whatever pipeline
assembled the review. If none did, post it yourself as one line.

## Later rounds on the same PR

Sweep **first**: list every thread on the PR from all rounds; a thread is
closed only by its **resolve** state. Verify each open one against the
current diff: fixed → reply (fix SHA + one line) and **resolve**;
disproven → reply why, and **resolve**; architecture-scale → carry it
(issue reference + **resolve** — reference the ORIGINAL issue, never a
re-mint: a recurring finding that cannot find its issue resolves as a
review-record carry and says so). Only findings that are new or still
unaddressed become new threads. Do not trust a UI's resolved markers over
the API — query the threads; the UI can lag.

## Coverage — rounds accumulate, never restart (#704)

A re-review does not re-read the surface: the workspace carries the
**coverage ledger** (`/workspace/coverage-ledger.json`) — files prior
rounds fully reviewed and at which SHA, plus the declared **frontier**
(files seen but not examined) — and `review-delta.patch`, the diff since
the last-reviewed SHA. Spend the budget **frontier-first**:

1. Open threads (the sweep above).
2. The delta: `review-delta.patch` — fix verification and every ledger
   entry stamped `touched: true` (their file changed since they were
   covered; the coverage claim does not survive an untouched-file
   assumption across a change).
3. The frontier: the files prior rounds named but never examined — this
   is where saturation comes from; a surface read once, not 28 times.
4. Whatever budget remains goes to the full surface, as today.

Close the round by writing the `coverage` block into review.json — the
round's honest statement, and the next round's starting point:

    "coverage": {
      "covered":  [{"path": "internal/x.go", "note": "full read + mechanical checks"}],
      "frontier": [{"path": "internal/y.go", "reason": "wall reached before examination"}]
    }

`covered` = fully reviewed at this round's head. `frontier` = named but
not examined — an APPROVE with a declared frontier is refused (an
approval over unexamined files is a lie about coverage); a frontier-only
round is a legitimate REQUEST_CHANGES whose blocking statement IS the
frontier. Never pad covered: a file you skimmed is frontier, not
coverage — the frontier is how the next round finds what you didn't.

## Hardened rules

Learned the hard way; apply without exception:

1. **A test that cannot fail guards nothing.** When a finding hinges on a
   test's protection, break the test once and watch it go red.
2. **One fact, one home.** When a fix changes a stated fact (a limit, a
   name, a chain), find *every* home of that fact — comments, docs, sibling
   constants — and fix all of them.
3. **Claims about deployment are verified against manifests**, not prose:
   the actual config, the actual runtime wiring.
4. **When the PR's author also wrote the spec it implements**, give that
   spec's load-bearing assumptions an extra adversarial pass.

## Do not

- Do not push, commit, or modify any repository under review.
- Do not read the entire repository — route to the minimal context.
- Do not post findings without evidence, or MINOR/NITs at all.
- Do not watch or re-trigger CI — review the delta you were given.

## References

- [references/hosts.md](references/hosts.md) — talking to the forge:
  host detection, fetching diff and metadata, posting/replying/resolving
  threads, token and curl fallbacks. Load when you first touch the platform.
- [references/playbook.md](references/playbook.md) — per-pillar depth
  recipes. Load when a pillar needs more than its quick pass.
