---
name: diataxis-docs
description: "Create, structure, audit, and maintain user-facing documentation following the Diátaxis framework (diataxis.fr): four quadrants — tutorials (learning), how-to guides (tasks), reference (information), explanation (understanding) — plus the docs map. Use when creating or writing any documentation, docs pages, guides, tutorials, API/CLI reference, explainers or design discussions for users, organizing or restructuring a docs tree, deciding where a doc belongs, auditing existing docs for mixed/misplaced/orphaned content, or wiring docs checks into CI. Automates scaffolding, page creation from quadrant templates, map generation, classification audit, and per-quadrant lint (dd init/new/map/audit/check/stats). Not for internal agent-architecture knowledge (llm-wiki), code comments, or UI design (impeccable)."
---

# Diátaxis Documentation

Source of truth: **[diataxis.fr](https://diataxis.fr/)** (Daniele Procida) —
when this skill and the website disagree, the website wins; when following
it reveals a gap in this skill's automation, close the gap here.

Documentation is a service to a reader with a need at a moment in time.
**Form follows function**: there are exactly four kinds of docs, each
serving a different need, each with its own form. Write the kind the reader
needs — in the form that kind demands — and nothing else.

## The compass — always the first move

Before writing a word, ask two questions about the *reader*:

1. Are they **doing** (action) or **understanding** (cognition)?
2. Are they **acquiring** skill (study) or **applying** skill (work)?

|                          | **action** (doing)    | **cognition** (knowing) |
| ------------------------ | --------------------- | ----------------------- |
| **acquisition** (study)  | **tutorial**          | **explanation**         |
| **application** (work)   | **how-to guide**      | **reference**           |

If the answer isn't clean, the content mixes needs — split it. Depth:
[`references/quadrants.md`](references/quadrants.md).

## Hard rules

1. **One page, one quadrant.** Never mix forms on a page. Mixing is the
   root cause of most documentation failure (diataxis.fr).
2. **Form follows function.** A tutorial guarantees success and teaches by
   doing; a how-to gets a competent user's task done; reference is neutral,
   complete, and mirrors the architecture of its subject; explanation holds
   the why and the only permitted opinions.
3. **The map is law.** Every page is reachable from the docs map
   (`index.md`); the map is *generated* (`dd map`), never hand-maintained.
4. **Minimal explanation inside action pages** — one line plus a link;
   depth lives in its own quadrant.
5. **Docs ride the same PR gates as code.** A PR that changes user-facing
   surface carries its docs delta; there are no doc sprints.
6. **Content moves, never duplicates.** Misplaced or mixed pages are moved
   and split into single-purpose homes; a piece of documentation exists in
   exactly one quadrant.
7. **Docs are tested.** Tutorials are executed after surface changes; the
   mechanical layer is verified where other fast checks run.

## Command surface (`dd`)

All automation is `scripts/dd.py` (stdlib-only Python; run with
`python3 .../dd.py <subcommand>`, all subcommands accept `--root <dir>`,
default `docs`). Exit codes: 0 clean · 1 findings · 2 usage error —
non-zero exits are the CI contract.

| Command | Does | Use when |
| ------- | ---- | -------- |
| `dd init` | create the docs map (`index.md`); `--full` also scaffolds all four quadrants | starting a docs tree — default creates the map only: quadrants materialize via `dd new` as each type is first needed (empty scaffolds are an anti-pattern, diataxis.fr/workflow) |
| `dd new <type> <slug> [--title]` | create a page from its quadrant's template (type: `tutorial` \| `howto` \| `reference` \| `explanation`, aliases ok) | every new page — the template enforces the quadrant's form at birth |
| `dd map [--check]` | regenerate the map section in `index.md`; `--check` exits 1 if stale | after adding/moving/renaming pages; `--check` in CI |
| `dd audit [--strict] [--json]` | classify every page → misplacement, mixed types, orphans, broken internal links, empty quadrants | first move on an existing docs tree; pre-PR; CI |
| `dd check <files...> [--type auto]` | per-page lint against the quadrant's craft rules (outcome/prereq/steps for tutorials; "How to" title + no teaching for how-tos; no narrative/steps/why for reference; why-present/no-steps for explanation) | before opening a docs PR |
| `dd stats` | quadrant coverage table + last-commit age | spotting rot, planning docs work |

## Workflows

**Creating a page:** diagnose with the compass → `dd new` → write (the
template's embedded comments are the craft rules; delete them as you go) →
`dd check` → `dd map` → PR.

**Repairing legacy docs:** one step at a time, structure emerges from the
inside — never tear down, never impose top-down. `dd audit` → triage by
finding type — misplaced = **move**; mixed = **split** into two
single-purpose pages and cross-link; orphan = map or delete; broken link =
fix. Then `dd check` the touched pages, `dd map`, land via PR. Detail:
[`references/workflow.md`](references/workflow.md).

**Wiring into CI:** docs checks are CI logic — run the **purpose audit**
first (dev-workflow CI discipline): markdownlint owns style, an existing
link checker owns links; this skill's unique purposes are quadrant form,
placement, and map freshness. Wire exactly those into the fast tier:

```
dd audit --root docs --strict
dd map  --root docs --check
```

## Boundaries

- **Internal/agent-facing architecture knowledge → `llm-wiki`** (RIG, C4,
  ADRs). This skill is for user-facing product documentation. A design
  decision appears in the wiki as full reasoning and in docs as the
  user-relevant consequence.
- **UI copy / interface design → `impeccable`.** **Code comments** stay in
  code. **Terminology** comes from `CONTEXT.md`/AGENTS.md when present —
  user-facing docs are where terminology drift becomes visible.

## Depth

- [`references/quadrants.md`](references/quadrants.md) — per-quadrant craft
  rules, failure modes, testing docs.
- [`references/workflow.md`](references/workflow.md) — docs-in-PR triggers,
  docs-driven development, CI wiring, legacy repair.
