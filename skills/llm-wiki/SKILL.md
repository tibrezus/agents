---
name: llm-wiki
description: "Operate on an LLM Wiki knowledge base — a persistent, compounding artifact maintained by LLM agents, and the architecture-context provider for implementation work (dev-workflow gate 1 loads a project's rig.db graph through this skill). Enforces the documentation hierarchy: code comments → repo wiki (intra-repo interactions) → llm-wiki (cross-repo interactions), no duplication, active demotion when a lower layer appears. Supports two documentation workflows: Generic (Mermaid diagrams, raw-source inputs) and Architecture/LC4 (LikeC4 models → Mermaid, code-graph-driven C4). Commands: read, update, create, prune, list, arch-sync. Use when the user asks to look something up, update wiki content, add/remove pages, sync architecture diagrams from a code graph, or get an overview of the knowledge base."
---

# LLM Wiki Skill

An LLM Wiki is a **persistent, compounding knowledge base** — not a RAG
index. Knowledge is compiled once and kept current by LLM agents; the
human curates sources and asks questions, the agent does the writing,
cross-referencing, filing, and bookkeeping. Command procedures:
[`references/commands.md`](references/commands.md); project promotion:
[`references/consult.md`](references/consult.md).

## Documentation Hierarchy — where documentation lives

Documentation sits **as close to the source code as possible**. Three
layers; each documents only the **interactions** between the elements of
the layer below:

| Layer | Lives in | Documents |
|---|---|---|
| **0 — Code** | doc comments next to the source (`///`, `//!`, docstrings) | one **component**: behavior, invariants, usage |
| **1 — Repository wiki** | the project's own platform wiki (`<repo>.wiki.git`) | **interactions inside one repo**: components/entities relations, design choices, ADRs |
| **2 — LLM-wiki** | the wiki instance | **interactions between repositories**: cross-repo flows, system-level design |

Placement rules (hard):

1. **A single component is documented in code only.** Never in a repo
   wiki or the llm-wiki — those layers document *interactions*, not
   members.
2. **A single project is documented in its repo wiki only.** The llm-wiki
   never carries one repo's internals.
3. **Temporary admission, mandatory migration.** While a project has no
   repo wiki, its pages may live in the llm-wiki as placeholders; the
   moment the repo wiki is created, that content **moves** into it — the
   llm-wiki keeps only the cross-repo view plus a link. Same one layer
   down: component notes parked in a repo wiki move into code comments
   when the code is next touched.
4. **No duplication across layers — link instead.** When content exists
   at two layers, the **lower layer is authoritative**; the upper copy
   becomes a link. Never copy content upward for visibility.
5. **The boundary is the subject, not the name.** A page about an
   external technology is layer 2 when it describes how *your
   repositories* interact with it; a page confined to one repo's internals
   is layer 1 even if it names many technologies.

Placement is audited on every write — `update`, `create`, `arch-sync` all
begin by asking *which layer owns this content*; misplaced content is
**moved down**, never copied or summarized into place. Migration steps
(project repo wiki created → move single-project pages there, keep the
thin cross-repo page, prune leftovers, fix links, update `index.md`,
append `log.md`, push, watch CI green) follow the same one-layer-down
pattern as folding a repo-wiki section into code comments.

**Corollaries:**

- **C4 boundary:** the llm-wiki carries context/container-level and
  cross-repo reasoning; code-level detail (file paths, signatures,
  implementation specifics) belongs at layer 1 or 0.
- **No in-repo `docs/` folders.** Move `docs/`, ADRs, design docs down
  the hierarchy; root files (`README.md`, `AGENTS.md`, `CONTEXT.md`) are
  **indexes** — link to real docs, don't duplicate them.
- **Platform wikis are layer 1 — first-class.** They hold a project's
  low-level details and important ADRs; some also push auto-generated C4
  architecture (`Architecture.md`, `C4-Model.md`,
  `Component---*.md`) via CI — check both when reading a project.

## Before you start

1. **Pull the latest default branch** (`git pull --ff-only`) — agents and
   workflows may have updated the repo since your last operation.
2. **Read `wiki.config.yml`** (project domain, QMD search contexts,
   declared architecture projects) and **`AGENTS.md`** (the full schema:
   page format, frontmatter rules, entity types, naming, cross-referencing,
   the two workflows). Never skip these files.
3. **Query the graph if it exists** (`raw/arch/<project>/rig.db`) — the
   `rig` tool, the module-CLI fallback, and the gate-1 load protocol live
   in [`references/graph-queries.md`](references/graph-queries.md).
   **Diagrams are generated deterministically by CI** — never invent or
   manually generate architecture diagrams ([`references/diagrams.md`](references/diagrams.md)).

## How to absorb this wiki (least-context routing)

Answer most questions from the **smallest** source, never by reading the
whole repo:

| You need… | Read | Why minimal |
|---|---|---|
| A project's **structure** fast | pi `rig` tool (`overview`/`component`/`deps`/`search`) | targeted SQL, ~200 tokens/question |
| Review orientation on a diff | `rig brief diff=<patch>` | provenance + risk + orphans + clones in ONE capped call |
| The **architecture views** | project wiki's `Architecture.md` | CI-generated, renders natively, always current |
| A **decision + its reasoning** | the matching `wiki/` pages | the *why*, captured at decision time |
| What pages exist | `index.md` | catalog, not a dir walk |
| Recent changes | `log.md` | append-only activity |
| Related pages | a page's `## See Also` | the link graph |

**Serving implementation context (dev-workflow gate 1):** load `rig
overview` → targeted `component`/`search` → the project wiki's
`Architecture.md` → matching `wiki/` pages for the *why*; before writing
a new function/type, `rig search` the capability — extend what exists.
Full protocol: [`references/graph-queries.md`](references/graph-queries.md).
`wiki read` and `wiki update` load only the pages that match the topic —
never the whole tree.

## Page-size discipline

Wiki CI enforces a deterministic **line limit per page**
(`pages.size_limit`, default **400**) so no page grows past a single
glance. Default: warning (CI annotation names the page; CI stays green);
`pages.size_strict: true` makes it fail. When flagged: **shrink**
(tighten prose, push raw detail into `raw/` and link) or **split**
(extract a sub-topic page, cross-link both ways, update `index.md`).
Treat it as a signal to act next touch, not a blocker; keep new pages
focused from the start.

## Repository Layout

```text
.llm-wiki/          # Shared tooling (git submodule)
wiki.config.yml     # Project configuration
AGENTS.md           # Wiki schema (copied from .llm-wiki/instance/AGENTS.md)
index.md            # Catalog of all pages
log.md              # Append-only activity log
raw/                # Immutable source documents
  └── arch/         # CI-fetched RIG JSON (architecture workflow)
wiki/
├── entities/       # "What is X?" — technologies, products
├── concepts/       # "How does X work?" — patterns, principles
├── guides/         # "How to X?" — step-by-step procedures
└── reference/      # "Compare/Lookup X" — catalogs, comparisons
```

## Two Documentation Workflows

- **Generic** (anything not code-graph-driven): inputs are raw sources in
  `raw/`; diagrams are **Mermaid only** (type guide:
  [`references/diagrams.md`](references/diagrams.md)); CI validates
  markdown + mermaid.
- **Architecture / LC4**: prerequisite `raw/arch/<project>/rig.db` (if
  missing → STOP); CI generates model.c4 + Mermaid deterministically —
  your job is prose and routing only. Never write `model.c4` or run
  likec4 yourself.

## Commands

| Command | What it does | Key rule |
|---|---|---|
| `wiki read <topic>` | qmd/grep search, read matches in full, synthesize with citations | offer to create a page if substantial and uncovered |
| `wiki update` | ingest new information | placement audit FIRST; save source to `raw/` (immutable); update pages/frontmatter; `index.md` + `log.md`; `npm run check` |
| `wiki create <topic>` | new page | placement gate → entity type → overlap check → template (see reference) → bidirectional links |
| `wiki arch-sync <project>` | prose after a rig.db refresh | query, never generate; embed generated `*.mmd`; route by hierarchy; preserve manual content; commit, don't push |
| `wiki consult <repo>` | promote a project to LC4 | writes in the project repo; full procedure in [`references/consult.md`](references/consult.md) |
| `wiki prune <topic>` | remove a page | **never without explicit instruction**; fix all inbound links first |
| `wiki list` | summarize contents | counts by type + health check + recent updates |

Full procedures: [`references/commands.md`](references/commands.md).

## Commit and verify

A wiki change is done only when it is **committed, pushed, and CI is
green** — `npm run check` locally is necessary but not sufficient (CI
also validates diagrams via `mmdc` and LikeC4 via `likec4 format
--check`); only the remote run is authoritative. Write → `npm run check`
→ commit + push → watch CI to green (fix and push until green). Use the
right tool: **`gh`** on GitHub, **`fj`** on Forgejo — determine the
platform from the remote URL first; they are NOT interchangeable.

## Validation checklist

Before committing: `npm run check` passes; **placement audit done**
(lowest layer that can hold it); **no cross-layer duplication** (lower
authoritative, upper links); single-project pages only as flagged
temporary admission; new pages have all 6 frontmatter fields, correct
type directory, tags 2-7 (first = type, lowercase), `## See Also` ≥2
links; no duplicate filenames; `index.md` updated, `log.md` appended;
bidirectional links; no `#` body headings, no inline HTML; Markdown
cross-references (render on GitHub/Codeberg); Generic pages Mermaid-only;
Architecture pages' Mermaid generated from the LikeC4 model; **diagrams
derived from `raw/arch/` RIG, never memory, every component traceable**;
no page over `pages.size_limit` (default 400). After committing: pushed,
CI watched to green via the platform's tool.
