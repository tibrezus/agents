---
name: pr-review
description: "Review a pull request using a 2-adversary toolkit methodology: an Architect (does it fit the RIG/C4 architecture?) and an Adversary (what breaks?), then a Judge adjudicates. The reviewer has a SMALLER context than the author — it leverages deterministic proof (lint/tests/CI via bash), the architecture graph (RIG + C4), and selective web search for best practices. Two ingress points: manual (dev-workflow review subcommand) or automated (harmostes pr-review workflow)."
---

# PR Review — Adversarial Toolkit

This skill reviews a PR from **two adversarial stances**, then adjudicates.
Unlike a fixed checklist, the reviewer has a **toolkit** it uses **selectively**
based on what the change actually touches.

## The reviewer's advantage: smaller context

The **author** held the entire codebase in their head. The **reviewer** does not
need to. The reviewer answers two sharp questions about a **delta**:

1. Does this change fit the architecture? → RIG (component graph) + C4 (views)
2. Is this change correct and safe? → diff + deterministic proof + selective lookup

Keep the context small. Do not read the whole repo. Route to the minimal source.

## Context you have (already assembled by pr-fetch)

- **`/workspace/pr-context.json`** — PR metadata, CI status, files changed
- **`/workspace/pr-diff.patch`** — the full diff
- **`/workspace/repo`** — checked-out repo at the PR's head SHA
- **`/workspace/wiki`** — project wiki (if configured), including:
  - `wiki/raw/arch/<project>/rig.json` — component graph (if it exists)
  - `wiki/raw/arch/<project>/model.c4` — architecture views (if it exists)
  - `wiki/wiki/` — design decisions, entities, concepts

Read `pr-context.json` first to learn the project, then route selectively.

## Toolkit (use on demand, not all at once)

| Tool | When to use | What it gives you |
|------|------------|-------------------|
| `read` | Always — diff, changed files, RIG/C4, wiki pages | Code + architecture context |
| `grep` | To find patterns, usages, test files | Where things are used |
| `bash` | For **deterministic proof** — run lint, tests, build | Pass/fail, not opinion |
| `web_search` | **Selectively** — when the diff touches something that warrants external knowledge (crypto, concurrency, new dependency, unusual pattern) | Current best practices, CVEs, anti-patterns |

**Do not web_search everything.** Use it when the change touches a domain where
external knowledge adds value (security, concurrency, a new library, a language
feature you're unsure about). For most changes, the diff + RIG + lint/tests are
sufficient.

## The review process

### Phase 0: Orient (read the change)

1. `cat /workspace/pr-context.json` — what project, what CI status, what files?
2. Read the diff (`/workspace/pr-diff.patch`).
3. If a RIG exists (`wiki/raw/arch/<project>/rig.json`), read the components
   touched by the diff. If a C4 model exists, read the relevant view.
4. Run deterministic checks via `bash`:
   - Build: `cd /workspace/repo && go build ./...` (or the project's equivalent)
   - Lint: `go vet ./...` / `golangci-lint run` / `npm run lint` (if configured)
   - Tests: `go test ./...` / `npm test` (if the project has tests)
   - These give you **proof**, not opinion. A failing build/test is a
     REQUEST_CHANGES, no reasoning needed.

### Phase 1: Architect — "Does it fit?"

Take the stance of the system architect. You have the RIG (component graph)
and C4 model (architecture views). Ask:

- **Component boundaries**: does the change respect the boundaries in the RIG?
  If the diff adds an import/call from component A to B, is that edge in the
  RIG? If not, it's undocumented coupling.
- **Layering**: is the code in the right layer? (controller logic in a model?
  business logic in a view?)
- **Design intent**: does the change align with the wiki's documented decisions?
  Read the relevant entity/concept pages for the touched components.

**Evidence rule**: a coupling finding MUST cite the RIG or C4. "Component X
imports Y, but the RIG shows no X→Y edge" is evidence. "This feels coupled" is
not.

### Phase 2: Adversary — "What breaks?"

Take the stance of someone trying to break the change. Read the diff critically.

- **Correctness**: logic errors, unhandled errors, off-by-one, nil/null deref,
  race conditions, missing input validation.
- **Security**: injection, secret exposure, missing authz, unsafe deserialization.
  If the diff touches auth/crypto/network/SQL, `web_search` for known
  vulnerabilities in the specific functions/patterns used.
- **Language idioms**: does the code follow the project's conventions? (Go: error
  wrapping, context propagation. Python: type hints, context managers.) If
  unsure about a language pattern, `web_search` for the language's best practices.
- **Test quality**: are there tests? Do they test behavior (not implementation)?
  Do they cover the edge cases you found? If the project has a test pattern,
  do the new tests follow it?

**Be selective.** Not every change needs a security search. A docs-only change
doesn't. A 3-line formatting fix doesn't. Scale your investigation to the risk
of the change.

### Phase 3: Judge — adjudicate

1. Collect findings from both stances.
2. Verify each CRITICAL/MAJOR finding cites evidence (code line + RIG/C4/proof).
   Downgrade findings without evidence to NIT.
3. Weigh severity:
   - **CRITICAL** — security hole, data loss, broken architecture, build failure
   - **MAJOR** — logic error, missing tests for new behavior, undocumented coupling
   - **MINOR** — style issue, missing docstring, minor improvement
   - **NIT** — cosmetic, opinion, no evidence
4. Decide:

| Condition | Decision |
|-----------|----------|
| Any CRITICAL or verified MAJOR finding | REQUEST_CHANGES |
| Only MINOR/NIT | COMMENT |
| All pass + CI green + deterministic proof passes | APPROVE |

## Output contract

Write the review to `/workspace/review.json` using Python (NOT a bash heredoc —
heredocs break on Markdown backticks):

```bash
python3 -c "
import json
review = {
    'decision': 'COMMENT',
    'body': '## Adversarial Review\n\n**Architect:** ...\n**Adversary:** ...\n**Verdict:** ...',
    'comments': [
        {'path': 'internal/foo/bar.go', 'line': 42, 'body': 'Consider ...'}
    ]
}
json.dump(review, open('/workspace/review.json', 'w'), indent=2)
"
```

- `decision` — `APPROVE`, `REQUEST_CHANGES`, or `COMMENT`.
- `body` — Markdown. Structure as: Architect findings → Adversary findings →
  Verdict. Lead with the decision, then the reasoning. Reference specific files
  and lines.
- `comments` — inline review comments (optional, `[]` if none). Each has `path`
  (relative file path), `line` (line number), `body` (the comment).

## Do NOT

- Do not push, commit, or modify any repository. Review only.
- Do not read the entire repo. Route to the minimal source (RIG, C4, wiki pages
  for touched components, changed files).
- Do not run a fixed checklist. Investigate selectively based on what changed.
- Do not state findings without evidence. Cite the code line, the RIG edge, or
  the deterministic check that failed.

## Relationship to other skills

- **`dev-workflow`** — defines the gate chain (issue, branch, milestone, CI).
  The Architect stance subsumes the process gates (they're deterministic: check
  CI status, issue linkage from pr-context.json). This skill adds the
  engineering-quality review on top.
- **`llm-wiki`** — the wiki consulted for design intent. The RIG and C4 model
  are the deterministic architecture graph; the wiki pages are the reasoning.
