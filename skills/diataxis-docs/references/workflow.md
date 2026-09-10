# Documentation in the workflow — PRs, CI, and boundaries

Depth for the `diataxis-docs` skill: how documentation work integrates with
the rest of the fleet (dev-workflow, llm-wiki) and with CI.

## Documentation rides the same gates as code

Docs that live in the repo are code-adjacent assets and follow the same
branch-based workflow (dev-workflow): docs changes flow issue → branch → PR
→ green CI → merge. There are no doc sprints — a doc sprint is a batch of
unreviewed drift.

Typical triggers — when a PR changes user-facing surface, the **same PR**
carries the docs delta:

| PR changes… | Docs delta in the same PR |
| --- | --- |
| a public API / CLI / config surface | the **reference** page mirroring that surface (reference mirrors architecture — a surface change makes the mirror wrong) |
| how an existing task is performed | the **how-to guide** for that task |
| a concept or design | an **explanation** page (new or existing) |
| a first-run experience / onboarding path | the **tutorial** that walks it |

The review catches doc gaps via pr-review's pillars; `dd audit --strict`
catches the mechanical drift deterministically.

## Docs-driven development

For new user-facing features, draft the docs **with** the feature, not
after: writing the how-to guide or reference delta first exposes interface
rough edges while they are cheap to fix. If the how-to reads badly, the API
is wrong.

## Wiring docs checks into CI

Docs checks are CI logic — before adding any of them, apply the **purpose
audit** (dev-workflow CI discipline): map what the repo's CI already checks
and never duplicate a purpose.

| Purpose | Already covered by | This skill's check |
| --- | --- | --- |
| Markdown style/lint | markdownlint etc. (if present) | `dd check` deliberately does **not** re-check style — extend the existing one |
| Link validity (all links incl. external) | a link checker (if present) | `dd audit` checks **internal `.md`** links as part of classification; if a full link checker exists, rely on it and treat `dd`'s check as redundant |
| Quadrant form, placement, mixed types | nothing standard | `dd audit --strict` — **the** purpose of this skill's CI presence |
| Map freshness / orphans | nothing standard | `dd map --check` |

Fast-tier wiring (mirrors the repo's other fast checks):

```yaml
- run: python3 skills/diataxis-docs/scripts/dd.py audit --root docs --strict
- run: python3 skills/diataxis-docs/scripts/dd.py map --root docs --check
```

Both exit non-zero on findings; that is the contract. Never wire them into
a slow tier — they are cheap and guard every docs PR.

## Boundaries — what this skill is NOT for

- **Internal/agent architecture knowledge** → `llm-wiki`. The wiki serves
  agents and maintainers reasoning about the system's design (RIG, C4,
  ADRs); docs serve *users* of the product. A design decision appears in
  both only as: wiki page = full reasoning; docs explanation = the
  user-relevant consequence, linked from how-tos.
- **Code comments** → live in the code, serve the next reader of that code;
  no Diátaxis form applies.
- **UI copy and interface design** → `impeccable`.
- **Terminology** — when docs must use the project's domain language,
  source it from `CONTEXT.md`/AGENTS.md if present; docs are often the
  place terminology drift becomes user-visible.

## Repairing legacy documentation

**Diátaxis is a guide, not a plan.** Never tear down and rebuild, never
impose the structure top-down, never raise empty scaffolds — the structure
emerges from the inside as pages are repaired, one step at a time. The loop
(from diataxis.fr/workflow): **choose** any page in front of you → **assess**
it (`dd check` the page, `dd audit` the tree) → **decide the single next
action** that produces an immediate improvement → **do it and publish it**
(small steps are worth committing immediately). Repeat. The quadrants appear
when the improved content demands them — which is why `dd new` creates a
quadrant directory only when its first page needs it.

Run `dd audit`, then triage by finding type:

- **`page:misplaced`** — the content is one quadrant's form sitting in
  another's directory. **Move** it (`git mv`) to the suggested quadrant and
  adjust the frame; do not copy it. Update inbound links.
- **`page:mixed`** — the page serves two needs. **Split** it into two
  single-purpose pages (move each part to its quadrant) and cross-link
  them. Splitting is a move, not duplication: each fragment must end up in
  exactly one place.
- **`page:unclear`** — decide by the compass (references/quadrants.md); if
  genuinely valueless, deleting is a valid repair.
- **`map:orphan`** — link from the map (`dd map` after moving) or delete.
- **`link:broken`** — fix the target or the link.

Then `dd check` the touched pages, `dd map`, and land via PR.
