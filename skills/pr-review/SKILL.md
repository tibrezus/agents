---
name: pr-review
description: "Review a pull request against the project's documented design and the dev-workflow gate chain. Produces a structured decision (APPROVE / REQUEST_CHANGES / COMMENT) with gate-by-gate findings and inline comments. Two ingress points: manual (via dev-workflow's review subcommand, which adds the needs-review label) or automated (via the harmostes pr-review workflow, which clones the PR + wiki and triggers on schedule). Use when asked to review a PR, when the harmostes pr-review workflow runs, or when evaluating whether a change is ready to merge."
---

# PR Review — Evaluate Against the Gate Chain

This skill is the **reviewer** counterpart to `dev-workflow`. Where
`dev-workflow` is the initiator (how to *structure* your work), this skill is
how to *evaluate* someone else's work. Both share the same gate chain — the
developer follows the gates, the reviewer checks them.

## Ingress points

Two entry paths, same methodology, same output:

1. **Manual (via dev-workflow)** — a developer finishes work and calls
   dev-workflow's `review` subcommand (`dw_request_review`), which adds the
   `needs-review` label. The harmostes pr-review workflow detects the label
   and loads this skill. The developer is the initiator; the review is
   automated.

2. **Automated (via harmostes)** — the harmostes pr-review workflow detects a
   labeled PR, prepares the context (PR metadata, diff, checked-out repo,
   project wiki), and loads this skill directly. No developer in the loop for
   the review itself.

## Review criteria (the dev-workflow gates)

These are the same gates defined in `dev-workflow` — this skill is their
reviewer-side application. Evaluate the PR against **each** gate. A failing
gate does NOT automatically mean REQUEST_CHANGES — weigh severity.

| Gate | What to check | Where to look |
|------|--------------|---------------|
| 1. Grounded in design | Does the change align with the documented architecture? | wiki |
| 2. Issue exists | Is there a linked issue describing the change? | PR body / issue |
| 3. Branch tied to issue | Does the branch name contain the issue number? | branch name |
| 4. Milestone assigned | Is the issue/PR associated with a milestone? | issue metadata |
| 5. Commits reference issue | Do commit messages reference the issue? | git log |
| 6. Tests cover the change | Are there unit tests for new/changed behavior? | the diff |
| 7. No undocumented coupling | Is new cross-component coupling part of the design? | wiki + code |
| 9. CI green | Are all checks passing? | CI status |

If the gate chain changes in `dev-workflow`, update this table to match.

## How to review

1. **Understand WHAT and WHY** — read the PR context (title, body, linked
   issue). What problem does this solve? What is the stated intent?

2. **Understand the actual change** — read the diff. What files changed, what
   was added/removed, what is the shape of the change?

3. **Read changed files in full context** — do not review the diff in
   isolation. Open the files around the changed lines to understand the
   surrounding code and how the change fits.

4. **Consult the project wiki** (if available) — read the entities and
   concepts relevant to the change. Does the change align with the documented
   architecture? Is new coupling part of the intended design?

5. **Check commit hygiene** — do commit messages reference the issue? Are the
   commits clean and atomic?

6. **Look for tests** — are new functions/behaviors covered? Is the
   integration suite extended if one exists? Are the tests meaningful (testing
   behavior, not implementation)?

7. **Evaluate each gate** — go through the table. Note pass/fail/warning with
   evidence. Lead with the most significant findings.

## Decision framework

- **APPROVE** — all important gates pass (minor gates may fail with low
  impact). The change is sound, tested, aligned with the design.

- **REQUEST_CHANGES** — a significant gate fails:
  - Missing tests for new behavior (Gate 6).
  - Undocumented coupling not part of the design (Gate 7).
  - CI is red (Gate 9).
  - No issue linkage at all (Gate 2).
  - The change contradicts the documented architecture (Gate 1).

- **COMMENT** — the review needs human judgment:
  - Ambiguous design decisions (could go either way).
  - Insufficient context to decide.
  - Informational observations (nits, suggestions, praise).

## Output contract

Write the review as a JSON object:

```json
{
  "decision": "APPROVE",
  "body": "## Review\n\nSummary + gate-by-gate findings.\n\n**Gates:**\n- ✅ Issue linked\n- ✅ Tests added\n- ⚠️ Milestone not set (minor)",
  "comments": [
    {
      "path": "internal/foo/bar.go",
      "line": 42,
      "body": "Consider extracting this into a helper."
    }
  ]
}
```

- `decision` — one of `APPROVE`, `REQUEST_CHANGES`, `COMMENT`.
- `body` — the review summary in Markdown. Reference specific gates. Be
  constructive and specific. Lead with the decision, then the reasoning.
- `comments` — inline review comments (optional, `[]` if none). Each has
  `path` (relative file path), `line` (line number in the file), and `body`
  (the comment text).

## Relationship to other skills

- **`dev-workflow`** — defines the gate chain that this skill checks. This
  skill is the reviewer-side application of those gates; `dev-workflow` is the
  initiator-side. Both must stay in sync.
- **`llm-wiki`** — the project wiki consulted for Gate 1 (design alignment)
  and Gate 7 (coupling). The wiki may be checked out alongside the repo
  during an automated review.
