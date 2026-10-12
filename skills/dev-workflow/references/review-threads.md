# Review threads — the dev-agent protocol

Depth page for hard rule 0 and gate 12/13 close-out in
[`SKILL.md`](../SKILL.md). This file owns the **author side** of the thread
protocol — what the dev agent does across review rounds. The reviewer's
half (sweep-first verification, verdict sinks, same-head refusal) is owned
by the `pr-review` skill; both sides verify against the same contract.

## The mandate — no merge over an open thread

A PR merges only when **every review-thread root on it is resolved** — any
round, any author (human reviewers' threads bind identically). This is
mechanically enforced on two independent layers:

- **The verdict gate** (the review pipeline): an APPROVE is composed only
  over a fully-resolved thread set; any open root downgrades the verdict
  to REQUEST_CHANGES listing the open threads.
- **The merge gate** (`dw_merge_readiness` → `dw_thread_check`): the
  workflow refuses to merge while any root is unresolved, on every host,
  with no platform configuration required. A project *may* additionally
  require the `pr-review/verdict` commit-status context in branch
  protection to block UI/manual merges — adoption data, not mechanism.

## Close-out — the reply is the record, the resolve is the close

Every response lands **on that same anchored review thread** (the host's
reply mechanism), carrying the fix SHA plus a one-line rationale. A reply
alone closes NOTHING — after replying, **resolve the thread**:

- **Forgejo**: `PUT $BASE/repos/$REPO/pulls/$N/comments/$ID/resolutions`
  (curl; `fj review reply` / `fj review resolve` wrap the same routes).
- **GitHub**: GraphQL `resolveReviewThread` (map the comment's
  `databaseId` to the thread id first).
- **GitLab**: `PUT …/merge_requests/$N/discussions/$ID` with
  `resolved=true`.

Close as each fix lands — do not batch resolutions to the end. A
disproven finding is closed the same way: reply why it is wrong, resolve;
never delete. **NEVER mint a duplicate thread** to answer a finding (the
answer lives where the finding lives — a new anchored comment starts a
NEW open thread and downgrades the verdict).

## The discharges — three lawful ways a thread ends

1. **Fixed in this PR** (Blocking findings, TODOs): reply fix SHA +
   rationale, resolve. This is the default for everything.
2. **Disproven**: reply the evidence, resolve.
3. **Carried** (architecture/design-scale items only): search the tracker
   for an open issue that already covers it — never duplicate; if none,
   mint ONE issue per finding (milestone: the repo's most recent open
   milestone), reply the issue reference on the thread, resolve. Carried
   issues are non-blocking by construction — they are tracked work, not
   merge conditions. A severe item (e.g. security) is never *only*
   carried: quick-fix it in the PR (Blocking) **and** carry the
   structural cure (Architecture-carry).

## The reconciliation sweep — ALL rounds

Before re-arming review, enumerate every thread on the PR (all rounds,
not just the latest) and close each open one per the discharges above.
The verdict gate counts every open root — a replied-but-unresolved thread
from round 1 blocks round 5's APPROVE exactly like a fresh finding.

Then **re-arm with the review label** — and verify the registration, not
the sentiment: on-thread replies and resolve markers are the only state
that counts. If you believe a finding is WRONG, the registered path is an
on-thread reply with evidence — never re-arm-as-retry, never a new
comment the reviewer will not see as an answer.
