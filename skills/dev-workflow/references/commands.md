# Operating commands — full reference

Summaries and the gate mapping live in [`SKILL.md`](../SKILL.md); this page
carries the full usage of each command. All paths resolve relative to the
skill directory.

## `adopt` — inject or update the workflow in a project's AGENTS.md

```bash
bash scripts/adopt.sh [repo-path]   # default: current directory
```

Auto-detects platform, default branch, CI-watch command, and test command.
It wraps the section in `<!-- BEGIN dev-workflow -->` / `<!-- END
dev-workflow -->` markers, so re-running `adopt` **replaces** it
(idempotent — this is how "change the workflow to the one in the skill"
propagates). It converts a legacy unmarked `## Development Workflow` header
to the marker form, and creates a minimal `AGENTS.md` if none exists. It
injects the gate chain + CI-discipline mandates + a pointer to this skill +
a **Project configuration** block (see
[`templates/agents-workflow-section.md`](../templates/agents-workflow-section.md)
for the exact content — edit there, then re-`adopt`). Never hand-edit the
marker block; change the template and re-adopt.

## `review` — request the adversarial review (gate 12)

```bash
dw_request_review "<pr-number>" [label]
```

**Guarded ingress:** refuses unless the pipeline is green at the PR's head
SHA (full pipeline, or fast tier when none is configured). On success it
adds the `needs-review` label (created if missing — no per-repo setup).

The label is the single portable trigger: the harmostes **Review-Ready
Gate** (event-armed, ADR-0006) wakes on the label webhook and re-verifies
label ∧ merge-rule greenness itself — verdicts land within minutes, not a
10-minute poll. **The review methodology and the verdict contract are
owned by the `pr-review` skill** (stances, pillars, trailer format, label
lifecycle) — this skill only requests and consumes; it never duplicates
those rules. The verdict lands as a comment ending in the trailer
`<!-- pr-review: <DECISION> @ <sha> -->` — `dw_wait_review` polls for it,
`dw_merge_readiness` binds it to the head SHA.

**Checking review progress — two surfaces:** (1) **the PR itself** —
verdicts land as comments identified by the trailer `<!-- pr-review:
<DECISION> @ <sha> -->` (format owned by `pr-review`): read the latest
verdict at a SHA, or a PR's review history; (2) **the harmostes runtime** —
whether the pr-review workflow is armed, queued, running, or failed, and at
which stage. To read the runtime, load the **`harmostes`** skill: it owns
the pr-review workflow end to end (Review-Ready Gate, attempts, event
history) and provides the exact progress/query commands — never
reconstruct them by hand.

## `ci-conformance` — validate CI against the five invariants

```bash
dw_ci_conformance                 # advisory scan of this repo's CI files
dw_ci_conformance "origin/main"   # + checks-preservation diff vs base
dw_ci_conformance --fleet /path/a /path/b   # cross-repo vocabulary report
```

Deterministic static validation of native CI files (GitHub/Forgejo/Gitea
Actions + GitLab) against the conceptual framework: **I1** check
equivalence, **I2** matrix coherence, **I3** justified non-suitability
(`not-suitable:` markers), **I4** no silent divergence, **I5** naming
consistency — plus the checks-preservation policy (checks are shifted,
never removed). Advisory by default; strict when the repo carries a
`.ci-conformance` file with `strict`. Gate rule: run after any commit
touching workflow files — the same rule as markdownlint for docs. Backed by
`scripts/ci-conformance.py`; depth in
[`invariants.md`](invariants.md).
