---
name: dev-workflow
description: "Enforce branch-based development — every change flows issue → branch → green CI → merged PR, never a direct commit to the default branch. Grounds changes in the project's documented design (wiki/llm-wiki); treats CI green as a quality gate (unit tests mandatory, integration suite extended); requires coupling to be intentional or wiki-documented. Multi-platform (GitHub via gh, Forgejo/Codeberg via fj). Ships `adopt` to inject the mandate into a repo's AGENTS.md. Use when implementing features/fixes, creating issues/branches/PRs, watching CI, or setting up the workflow in a repo."
---

# Dev Workflow — Issue → Branch → Green CI → Merge

One invariant: **the default branch only ever moves via a merged PR whose
CI is green — never a direct commit.** The gate chain below is that
invariant in operational, falsifiable form. It is **universal**:
multi-platform (issue/branch/PR/CI/merge dispatch via
[`scripts/host.sh`](scripts/host.sh)) and multi-project (per-project
differences are *data* in the project's AGENTS.md, not logic here).

Use when: implementing a feature/fix/refactor/docs change in a project
with the `## Development Workflow` section in its AGENTS.md; creating
issues/branches/PRs tied to an issue/milestone; deciding merge vs. fix on
a red PR; declaring a change "done"; setting up or propagating the
workflow in a repo (`adopt` — idempotent, re-run per project).

## The change lifecycle (gate chain)

A change may merge only after **all** gates pass, in order; each is
independently falsifiable. (Numbers are stable identifiers —
`references/*` and other skills cite them.)

1. **Grounded in documented design** — before implementing, load context
   in order (each mandatory if it exists): `rig overview` (whole graph,
   ~400 tokens), targeted drill-down (`rig component`, `rig search`,
   `rig deps --reverse`), the project wiki's `Architecture.md`
   (CI-regenerated, authoritative), relevant llm-wiki pages (decisions,
   the why). Implementation without this context is invalid. **The graph
   is the primary tool against duplication**: before writing a new
   function/type, `rig search` the capability — extend what exists.
2. **Issue exists** — an open issue (found or created) describes the change.
3. **Branch tied to the issue** — name contains the issue number, created
   off the default branch. No work on the default branch.
4. **Milestone assigned** — per the project's convention.
5. **Change made on the branch** — commits reference the issue
   (`Refs #<n>` / `Fixes #<n>`). The implementation is **optimal** (hard
   rule 5): root cause, right abstraction, no workarounds, **no
   unnecessary duplication** (gate 1's `rig search` rule; justify a
   near-duplicate on the PR if reuse is impossible).
6. **Change covered by tests** — unit tests for every behavior added or
   altered (fast tier); extend the integration suite where one exists
   (what counts: [`test-policy.md`](references/test-policy.md)). Every new
   or altered test is **mutation-probed before push**: break the behavior,
   confirm red, restore — green tests that survive nonsense are not
   coverage (r18: a BOGUS constant passed 19/19). Before any new test,
   job, or step goes into CI, audit the whole CI surface for a check that
   already achieves the purpose ([`ci-wiring.md`](references/ci-wiring.md)).
   Every test and tool is **wired into CI** — never a throwaway script.
   `SAFETY_LEVEL: mcdc` projects also achieve MC/DC
   ([`mcdc.md`](references/mcdc.md)).
7. **No undocumented coupling** — coupling the change introduces must be
   part of the intended architecture or recorded in the wiki
   (`/skill:llm-wiki`) **before** merge ([`coupling.md`](references/coupling.md)).
8. **Simplification pass** — re-read the full diff, ask "can this be
   simpler?", remove dead code / redundant abstractions / speculative
   generality (hard rule 5). Before pushing to CI, re-checked before merge.
9. **PR open — only after the local CI mirror is green.** Fast-tier
   workloads run locally first (build, lint, `dw_run_tests`); the PR opens
   **once** — it triggers CI on the forge, so scaffolding stays on the
   branch. Probe conflicts BEFORE pushing: a DIRTY PR gets no runs at all
   (procedure step 7).
10. **Fast CI green on every push** — lint/build/unit/targeted tests; red
    fixed on the branch. Silence is not green: "no checks" is a rebase
    signal (procedure step 8).
11. **Full pipeline green on the head SHA** — at ready declaration: rebase
    onto default, then `dw_trigger_full_pipeline` (the helper **refuses
    unrebased heads** — first trigger and re-triggers alike; the full
    tier is expensive: benchmarks, GPU/infra matrices, long evals). Any
    later push or default-branch move invalidates the run — re-rebase,
    re-trigger. Skipped when no full workflow is configured.
12. **Adversarial review APPROVE on the head SHA — when armed.** Opt-in
    per PR: `dw_request_review` (guarded ingress: refuses heads without a
    green pipeline) arms it via the `needs-review` label, which wakes the
    harmostes Review-Ready Gate; the `pr-review` skill runs as
    `harmostes-bot`. The bot's native APPROVED/REQUEST_CHANGES satisfies
    branch-protection approvals where armed; APPROVE lands only when every
    review thread — findings AND TODOs — is resolved by the dev. When not
    required, skip: the dev (admin) merges independently after gate 11.
13. **Merge-ready, then merged** — `dw_merge_readiness` verifies fast +
    full + rebase at one frozen head SHA (plus the review verdict when
    armed); then `dw_merge_pr`. Branch deleted; the merged PR
    (`Closes #n`) closes the issue and is the implementation record.

**Two-phase readiness:** development pushes run the fast tier only; the
full pipeline + adversarial review run **once, at ready declaration, on
the final head SHA** (rebase *before* triggering). Statuses bind to SHAs,
so any push after declaration — source or docs — re-opens the path; red
pipeline means back to developing, never into review (depth:
[`test-policy.md`](references/test-policy.md)).

## Hard rules

0. **Review threads are the merge currency.** When an adversarial review
   leaves inline comments (gh / fj / glab threads) — blocking findings AND
   TODOs alike — the dev agent replies on EVERY open thread, and the reply
   lands **on that same anchored review comment** (the host's reply
   mechanism: `in_reply_to` on GitHub, discussion notes on GitLab), never
   in a separate comment — carrying the fix SHA plus a one-line rationale,
   then resolving it natively where the host has resolve. Sole exception:
   Forgejo, where the thread API has no reply/resolve yet
   (github.com/rezuscloud/forgejo#115) — there post ONE `create-pull-review`
   (`event: COMMENT`) whose **body** enumerates `path:line → fix SHA +
   rationale` for every open thread, with **`comments[]` empty**. NEVER
   create new anchored snippet comments per finding — each starts a NEW
   thread instead of answering the finding's (anti-pattern observed live,
   rhesadox#2241: five `reply_to=None` comments, one per finding). The dev
   then **requests review from harmostes-bot natively** — the request is
   the re-arm signal (#488; the `needs-review` label stays as the scope
   contract). The REVIEWER — not the dev — closes threads on the next
   round: it verifies each fix in the diff and resolves/counts the thread
   as addressed; it never downgrades for host-UI thread state on Forgejo
   (the resolve API does not exist there). The full pipeline resumes and a
   re-review can APPROVE only when every finding is verifiably addressed
   in the diff; post-review downgrades APPROVEs issued over findings that
   are not.
1. A direct commit/push to the default branch is forbidden unless the user
   gave an explicit instruction that is recorded on the issue. When in
   doubt, branch.
2. Never force-push to the default branch on **any** platform — on
   **Codeberg** absolute. The only force-push the workflow performs is to
   a *feature* branch after rebasing it onto the default.
3. Always rebase the feature branch onto the default branch before
   merging, so the merge is conflict-free and linear.
4. Never change platform/repository rules (branch protection, force-push
   settings, merge-strategy constraints) to work around these rules. If a
   merge is blocked, the fix is on the branch, never in the platform
   config.
5. Only optimal implementations are accepted. Workarounds at any level
   (code, tests, CI, tooling, configuration) are forbidden — they defer
   problems, they don't solve them. Simplicity is a requirement, not a
   preference; a complex implementation is not optimal when a simpler one
   exists. If a proper fix is genuinely blocked, surface the blocker on
   the issue rather than routing around it silently. "It works" is not the
   bar; "it is correct and well-structured" is.
6. **A finding cites one instance; the dev fixes the class.** Review
   findings name a single occurrence (`path:line`) — before fixing,
   determine whether the same mistake repeats elsewhere: sweep for it
   (grep the pattern, `rig search` the capability, `rig clones` for
   paraphrased copies). Isolated → fix the instance. Repeated → the fix
   is **structural**: correct every instance AND the root cause that
   invites the mistake — a component refactor within the change, or,
   when the architecture's shape itself is the cause, an
   architectural-change proposal (ADR / wiki page + issue) enumerating
   the instances. A reply that fixes only the cited instance of a
   repeated pattern re-opens the finding next round.

## Continuous integration discipline

"CI green" is a quality gate, not a build-status light. The mandates; each
rule's depth lives in its reference page:

- **CI instrumentation evolves with the project — there is no throwaway
  test.** Run the project's own runner locally (`make test`, `npm test`,
  `scripts/test`) and wire every new test or tool into CI; before creating
  a component (tool, CI job, wiki page), check that an equivalent doesn't
  already exist and extend it. A throwaway script leaves CI frozen while
  the code moves on — it looks like coverage but protects nothing.
  Depth: [`test-policy.md`](references/test-policy.md).
- **CI code is expensive — a check's purpose is never duplicated.** Before
  adding any CI logic, audit the entire CI surface and map each existing
  check to its **purpose**; if the purpose exists anywhere, the logic
  moves into the right form — never added twice. The audit runs before the
  first line of CI code and its result is stated on the PR. **A purpose
  has exactly one home in CI; checks move between homes, never cloned,
  never orphaned.** Depth: [`ci-wiring.md`](references/ci-wiring.md).
- **Safety-critical boolean logic requires MC/DC** when the project
  declares `SAFETY_LEVEL: mcdc` — deterministic pipeline, spec-driven.
  Load [`mcdc.md`](references/mcdc.md) when set or when touching complex
  boolean decisions.
- **CI checks are never removed — they shift, they don't vanish.** Every
  check that existed must still exist somewhere after a pipeline reshape
  (different job/file/tier, but present); `dw_ci_conformance "origin/main"`
  enforces this against a base ref; a removal is fixed by re-homing or
  justified as genuinely obsolete.
- **CI conformance — the five invariants.** Native CI files must hold:
  **I1** check equivalence, **I2** matrix coherence, **I3** justified
  non-suitability (`not-suitable: runner=<token> — <capability reason>`
  markers), **I4** no silent divergence, **I5** naming consistency
  (kebab job ids, runner tokens, decomposable contexts). Conceptual, not a
  schema; validation is deterministic (`dw_ci_conformance`, run after any
  commit touching workflow files). Advisory until a `.ci-conformance`
  file opts into `strict`. Depth: [`invariants.md`](references/invariants.md).
- **Coupling is intentional or documented.** Clean changes keep components
  independently buildable and testable; unavoidable-but-undocumented
  coupling is recorded in the wiki before merge. `COUPLING_POLICY` knob:
  `strict` (default) / `documented-exceptions` / `legacy`. Depth:
  [`coupling.md`](references/coupling.md).

## How this stays one workflow

- **Enforcement** (never commit to the default branch, the gates, the
  CI-discipline mandates) lives in each project's `AGENTS.md` — injected
  by `adopt` as a short marker-delimited section pointing back to this
  skill.
- **Procedure** lives once here, loaded on demand, evolving without
  touching every repo.

Do **not** duplicate the procedure into every project's AGENTS.md — that
recreates drift. Update it here, then re-run `adopt` to propagate.

## Operating commands

| Command | Purpose | Full usage |
|---|---|---|
| `adopt` | inject/update the workflow section in a project's AGENTS.md (idempotent; marker-delimited; template: [`templates/agents-workflow-section.md`](templates/agents-workflow-section.md) — never hand-edit the block) | [`references/commands.md`](references/commands.md) |
| `review` | `dw_request_review "<pr>"` — guarded ingress, adds `needs-review`; verdict = comment with `<!-- pr-review: <DECISION> @ <sha> -->`; runtime progress via the `harmostes` skill | [`references/commands.md`](references/commands.md) |
| `ci-conformance` | `dw_ci_conformance ["origin/main"] [--fleet a b]` — I1–I5 + checks-preservation; run after any workflow-file commit | [`references/commands.md`](references/commands.md) |
| Make a change | the per-change procedure, full bash | [`references/procedure.md`](references/procedure.md) |

### Make a change — the skeleton

1. Consult the wiki (`/skill:llm-wiki` consult/read) — gate 1.
2. Resolve the issue: `dw_find_issue` → else `dw_create_issue`.
3. Resolve the branch: `dw_find_branch_for_issue` → else create
   `feat/${ISSUE}-<slug>` off default.
4. Assign milestone: `dw_resolve_milestone current` → `dw_set_milestone`.
5. Make the change **including its tests**; document new coupling in the
   wiki now; commit with `Refs #$ISSUE`.
6. Simplification pass on the full diff (gate 8).
7. Green locally (`dw_run_tests` + build + lint), probe conflicts
   (`git merge-tree`), then push and open the PR **once**
   (`dw_open_pr "$BRANCH" "$(dw_default_branch)" "<title>" "Closes #$ISSUE"`).
8. Watch fast CI (`dw_watch_ci`); if workflow files changed, CI
   conformance must hold (`dw_ci_conformance "origin/<default>"`).
9. Declare ready: `dw_rebase_onto_default` → `dw_trigger_full_pipeline`
   → `dw_watch_full_pipeline` → (when armed) `dw_request_review` →
   `dw_wait_review` → `dw_merge_pr squash`. REQUEST_CHANGES → address the
   findings (hard rule 6: sweep for the class), resolve every thread,
   re-run this step.

The agent is not bound to these exact commands — they illustrate the
dispatch. Raw per-platform forms and token env vars:
[`references/platform-commands.md`](references/platform-commands.md).

## Milestone resolution

`current` (default) = most recent open milestone; `none` = skip; `<exact
title>` = match by title. If `current` finds none, ask the user whether to
create one rather than silently proceeding without.

## Relationship to other skills

- **`llm-wiki`** — the knowledge base **and the architecture-context
  provider** (gate 1 loads the graph via its `rig` tool). Consult at the
  start; write to it before merge when a change adds undocumented coupling.
- **`tdd`** — *how* to write the tests gate 6 requires.
- **`pr-review`** — gate 12's reviewer counterpart: adversarial APPROVE on
  the head SHA; SHA-guarded at ingress.
- **`harmostes`** — the pr-review runtime (Review-Ready Gate, attempts,
  event history) and its query commands; load it when checking
  adversarial-review progress.
- **`fork-maintenance`** — *external* change (upstream moved, keep the
  fork's release branch green); governs upstream-sync PRs where this skill
  governs your own feature branches. CI-watching is one pattern
  everywhere.

The gate chain is the done-checklist — a change is "done" only when every
gate has passed and the default branch has moved via the merged PR.
