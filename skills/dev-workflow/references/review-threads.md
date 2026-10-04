# Review threads — the dev-agent protocol

Depth page for hard rule 0 and gate 12/13 close-out in
[`SKILL.md`](../SKILL.md). This file owns the **author side** of the thread
protocol — what the dev agent does across review rounds. The reviewer's
half (sweep-first verification, verdict sinks, same-head refusal) is owned
by the `pr-review` skill; both sides verify against the same contract.

## The currency — threads, not comments

When an adversarial review leaves inline comments (gh / fj / glab threads)
— blocking findings AND TODOs alike — the dev agent addresses EVERY open
thread, and each response lands **on that same anchored review comment**
(the host's reply mechanism: `in_reply_to` on GitHub, discussion notes on
GitLab, `fj review reply` on Forgejo — native since #115 shipped), never
in a separate comment — carrying the fix SHA plus a one-line rationale.

**Forgejo close-out order (standard):** as each fix lands, resolve the
threads it addresses — `fj review resolve <PR> <COMMENT-ID>` — the
resolved marker IS the close-out, the reviewer verifies the fix in the
diff; the **actual replies** (`fj review reply`) come only when everything
is done — one per thread, carrying `path:line → fix SHA + rationale`, as
the round record. A reply posted as a separate/new comment does NOT count
— the answer lives where the finding lives, so the thread reads as one
conversation.

**NEVER mint a duplicate thread** — a new anchored snippet comment per
finding starts a NEW thread instead of answering the finding's
(anti-pattern observed live, rhesadox#2241: five `reply_to=None`
comments, one per finding).

The REVIEWER — not the dev — closes threads it did not author: it verifies
each fix in the diff and resolves/counts the thread as addressed; it never
downgrades for host-UI thread state — it queries the threads (`fj review
comments <PR> <REVIEW>`, resolved markers) instead.

## The reconciliation sweep — ALL rounds, not just the latest (r40)

Mandatory before the pipeline resumes (live on rhesadox#2360: the reviewer
re-posted its canonical findings as NEW threads each round while old
review objects kept their stale threads — 3×5=15 unresolved duplicates
accumulated monotonically and the gate downgraded verdicts over a fixed
diff for eight rounds). For every open thread on **every prior review** —
findings AND TODOs alike — the dev responds on that same review thread,
carrying the fix SHA + one-line rationale, then resolves it natively —
**and resolves its own reply comments too**: the gate counts any comment
with `resolved=false`, so a reply left unresolved is a new open thread by
its accounting. Only what is NEW or re-raised enters the round's findings.

Then **request review from harmostes-bot natively** — the request is the
re-arm signal (#488; the `needs-review` label stays as the scope
contract). Post-review mechanically **downgrades an APPROVE issued over
unresolved threads on the newest prior round (#579) whose findings are not
addressed in the diff** — unaddressed findings block the pipeline and the
merge, no matter what the verdict text says.

## Transport failures register NOTHING (r17, live on rhesadox#2359)

The host silently accepts every wrong transport — a PR-conversation
comment, a standalone COMMENT-type review, a new anchored snippet — with
HTTP 201. Nothing errors, so "replied wrongly" and "replied and was
heard" are indistinguishable from your side, and the only signal is the
reviewer re-counting unresolved threads, which reads like rejection of
your ARGUMENT when it is rejection of your TRANSPORT. On #2359 the dev
spent five rounds posting "Thread resolution" COMMENT-reviews while thread
#40268 never moved. Before concluding a reviewer is ignoring you, verify
the state yourself: `fj review comments <PR> <REVIEW>` — resolved markers
and `in_reply_to` are the only registration. If you believe a finding is
WRONG, the registered path is an on-thread reply with evidence — never
re-arm-as-retry.

Exact per-host call shapes: `pr-review`'s
`references/thread-commands.md` (same skills root — sibling skill, no
cross-skill path link so each skill stays distributable standalone).

## Re-arm is refused over a standing verdict (#567, live on rhesadox#2359)

A head is reviewed exactly once: if a `pr-review:` verdict trailer stands
at the CURRENT head SHA, the gate will not dispatch again — re-arming
cannot change the verdict, it can only burn agent runs (six identical
reviews of one SHA on #2359). Re-arm is meaningful only after a PUSH (new
head) plus the thread close-out above. If you disagree with the verdict,
the new head carrying your fix (or your on-thread rebuttal, which the next
round's reviewer verifies) is the only lever. The kernel's gate enforces
the same rule before dispatch; dev-workflow's `dw_request_review` is the
client-side backstop (r18).
