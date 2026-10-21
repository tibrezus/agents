# The Agent Skills Specification (adapted)

Adapted from [agentskills.io/specification.md](https://agentskills.io/specification.md)
for this repo. Adaptations: pi-specific frontmatter fields and load
classification, this repo's line budget, and repo paths. Everything else is
the upstream contract, condensed. The quick version lives in the parent
[SKILL.md](../SKILL.md).

## `SKILL.md` format

YAML frontmatter, then Markdown content (the body). Minimal valid example:

```markdown
---
name: skill-name
description: What this skill does and when to use it.
---
```

With optional fields:

```markdown
---
name: pdf-processing
description: Extract PDF text, fill forms, merge files. Use when handling PDFs.
license: Apache-2.0
metadata:
  author: example-org
  version: "1.0"
---
```

### Frontmatter fields

| Field | Required | Constraints |
| - | - | - |
| `name` | yes | ≤64 chars; lowercase `a-z`, `0-9`, hyphens; no leading/trailing/consecutive hyphens; must match the parent directory name |
| `description` | yes | 1–1024 chars, non-empty; what the skill does and when to use it |
| `license` | no | Short license name or reference to a bundled license file |
| `compatibility` | no | 1–500 chars; environment requirements (product, system packages, network). Most skills do not need it |
| `metadata` | no | Map of string keys to string values; keep keys reasonably unique |
| `allowed-tools` | no | Space-separated pre-approved tools (experimental; support varies) |

### `name` — invalid examples

```yaml
PDF-Processing    # uppercase not allowed
-pdf              # cannot start with a hyphen
pdf--processing   # consecutive hyphens not allowed
```

### `description` — quality bar

Include the keywords an agent will match against the task:

- Good: "Extracts text and tables from PDF files, fills PDF forms, and merges
  multiple PDFs. Use when working with PDF documents or when the user mentions
  PDFs, forms, or document extraction."
- Poor: "Helps with PDFs."

### pi-harness fields (repo note)

pi accepts additional frontmatter beyond the spec. This repo uses
`disable-model-invocation: true` (skill is user-invocable only — see
`skills/zoom-out/SKILL.md`). Prefer spec fields; add harness fields only with
a real need.

### Repo gotcha (YAML)

The frontmatter is parsed with the `yaml` package in default (no-core-schema)
mode: a colon inside a **plain** scalar is a hard parse error
(`description: Use when: X` → skill fails to load). Quote such values.

## Body content

No format restrictions — write what helps the agent perform the task:

- Step-by-step instructions
- Examples of inputs and outputs
- Common edge cases

The agent loads the whole body on activation; consider splitting longer
content into referenced files (this repo hard-caps the split point at 150
lines — see [Line budget](#line-budget-repo)).

## Optional directories

- `scripts/` — executable code. Self-contained or documented dependencies;
  helpful error messages; graceful edge cases. Python, Bash, JavaScript are
  common (support depends on the host agent).
- `references/` — documentation loaded on demand (`REFERENCE.md`, domain
  files). Keep files focused: agents load them whole, smaller = less context.
- `assets/` — static resources: templates, images, lookup tables, schemas.

## Progressive disclosure

1. **Metadata** (~100 tokens): `name` + `description` load at startup for all skills.
2. **Instructions** (<5k tokens recommended): the full `SKILL.md` body on activation.
3. **Resources** (as needed): files in `scripts/`, `references/`, `assets/`.

## File references

Relative paths from the skill root, one level deep — no deeply nested chains:

```markdown
See [the reference guide](references/REFERENCE.md) for details.
Run the extraction script: scripts/extract.py
```

## Validation

Upstream reference validator: `skills-ref validate ./my-skill`
([agentskills/skills-ref](https://github.com/agentskills/agentskills/tree/main/skills-ref)).

This repo validates with its own pi-mirror instead — `cd scripts &&
npm run validate-skills` (strict). Classification: HARD errors (unparseable
frontmatter, empty `description`, duplicate `name`) mean pi refuses to load
the skill; warnings (name shape, `description` >1024) fail strict CI because
a canonical skills repo ships clean.

## Line budget (repo)

Every `.md` inside a non-vendored skill root: ≤150 lines clean, >250 a HARD
error (mechanics and exceptions: `LINE_BUDGET_EXCEPTIONS` in
`scripts/validate-skills.mjs`). Vendored skills (`impeccable`, `bailian-*`)
are exempt — refreshed wholesale from upstream.
