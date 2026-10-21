---
name: agentskills-spec
description: The agentskills.io Agent Skills specification adapted to this repo — SKILL.md format, frontmatter field rules, directory layout, progressive disclosure, and this repo's validation gates (pi-mirror validator, line budget). Use when creating a new skill, writing or editing a SKILL.md, adding scripts/references/assets to a skill, fixing a skill that fails validation or will not load, or maintaining vendored skills.
---

# Agent Skills Specification (repo adaptation)

This is the format contract for every skill in `skills/`. It adapts the
[agentskills.io specification](https://agentskills.io/specification.md) to this
repo's distribution (skills.sh → `npx skills@latest add tibrezus/agents`) and
its validation (`scripts/validate-skills.mjs`, mirrored in CI). The full
field-by-field reference with examples lives in
[references/specification.md](references/specification.md) — load it when you
need exact constraints or examples beyond the quick contract below.

## The quick contract

A skill is a directory under `skills/` containing at minimum a `SKILL.md`:

```
skills/<name>/
├── SKILL.md          # required: YAML frontmatter + instructions
├── scripts/          # optional: executable code the agent can run
├── references/       # optional: documentation loaded on demand
└── assets/           # optional: templates, images, data files
```

The frontmatter has exactly two required fields:

| Field | Required | Constraints |
|---|---|---|
| `name` | yes | 1–64 chars; lowercase `a-z`, `0-9`, hyphens only; no leading, trailing, or consecutive hyphens; must equal the directory name |
| `description` | yes | 1–1024 chars, non-empty; states what the skill does AND when to use it |

Optional fields: `license`, `compatibility` (≤500 chars; only for real
environment requirements), `metadata` (string→string map),
`allowed-tools` (experimental). The pi harness also accepts its own fields —
this repo uses `disable-model-invocation: true` (see `zoom-out`).

The description decides whether agents find the skill — front-load capability
and trigger keywords: "Extracts text and tables from PDFs, fills forms,
merges files. Use when working with PDF documents…" — never "Helps with PDFs."

## Progressive disclosure

Agents load skills in widening rings; structure for it:

1. **Metadata** (~100 tokens): `name` + `description` load for every skill at startup.
2. **Instructions** (<5k tokens recommended): the full `SKILL.md` body, loaded on activation.
3. **Resources** (as needed): `references/`, `scripts/`, `assets/` load only when required.

Keep `SKILL.md` lean and push depth into `references/`. Reference files with
relative paths from the skill root, one level deep
(`references/specification.md`, not a chain of links through nested files).

## This repo's gates

CI (`.github/workflows/validate-skills.yml`) and the local mirror validate
every `SKILL.md` the way pi loads it, in strict mode:

```bash
cd scripts && npm ci --silent && npm run validate-skills && npm test
```

The validator mirrors pi's loader exactly:

- **HARD** (skill will not load): unparseable frontmatter YAML; missing or
  empty `description`; duplicate `name` across skills.
- **WARNING** (loads, but strict CI fails): `name` over 64 chars, invalid
  characters, or bad hyphen shape; `description` over 1024 chars.
- **Line budget** (this repo, issue #33): every `.md` inside a non-vendored
  skill root stays ≤150 lines (clean); >250 is a HARD error. Depth belongs in
  `references/` — each reference file is budget-checked too. Vendored skills
  (`impeccable`, `bailian-*`) are exempt: they are refreshed wholesale from
  upstream, never hand-densified. Reviewed exceptions live in
  `LINE_BUDGET_EXCEPTIONS` in `scripts/validate-skills.mjs` — that header is
  the source of truth for budget mechanics; do not restate them here.

YAML gotcha: a colon inside a plain scalar (`description: Use when: X`) is a
HARD parse error — quote the value.

## Creating a skill here

1. Check the quick contract above; load
   [references/specification.md](references/specification.md) for field
   details, body guidance, and examples.
2. `mkdir skills/<name>` — the directory name must equal the `name` field.
3. Write the frontmatter (both required fields), then the body:
   step-by-step instructions, input/output examples, common edge cases.
4. Keep `SKILL.md` ≤150 lines; move depth to `references/` files (relative
   links, one level deep).
5. Run the gates (command above) — strict-clean is the merge bar.
6. Add a row to the README skills table; land the change through the
   `dev-workflow` (issue → branch → green CI → merged PR).

## Maintaining a skill

- Any edit re-runs the same gates. A skill drifting past 150 lines gets
  densified or split into `references/` — not exempted.
- Vendored skills (`impeccable`, `bailian-*`): update wholesale from upstream;
  never hand-edit them against the budget.
- Distribution is automatic: skills.sh serves the repo as-is; nothing to
  register. Users pick skills at install time
  (`npx skills@latest add tibrezus/agents`).

## Reference

- [references/specification.md](references/specification.md) — the full
  adapted specification: every frontmatter field with constraints and
  examples, body content guidance, optional directories, progressive
  disclosure, and skills-ref validation.
