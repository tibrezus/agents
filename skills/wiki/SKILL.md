---
name: llm-wiki
description: "Operate on an LLM Wiki knowledge base — a persistent, compounding artifact maintained by LLM agents. Supports two documentation workflows: Generic (Mermaid diagrams, raw-source inputs) and Architecture/LC4 (LikeC4 models → Mermaid, code-graph-driven C4). Commands: read, update, create, prune, list, arch-sync. Use when the user asks to look something up, update wiki content, add/remove pages, sync architecture diagrams from a code graph, or get an overview of the knowledge base."
---

# LLM Wiki Skill

An LLM Wiki is a **persistent, compounding knowledge base** — not a RAG index.
Knowledge is compiled once and kept current by LLM agents. The human curates
sources and asks questions; the agent does the writing, cross-referencing,
filing, and bookkeeping.

## Before You Start

**Pull the latest changes.** The llm-wiki repo is a git repo — agents and
workflows may have updated it since your last operation. Before any
`read`/`consult`/`update`/`arch-sync`, pull the default branch:
```bash
git pull --ff-only
```

**Read the RIG first if it exists** (`raw/arch/<project>/rig.json`) — it's
the fastest way to understand structure (1–15K tokens). If none, use the wiki
directly. The routing table below shows the minimal source per need.

**Read the C4 model if it exists** (`raw/arch/<project>/model.c4`) — it
shows architecture views (components, containers, relationships) derived
from the RIG. Read this before wiki pages for architectural context.

1. **Read `wiki.config.yml`** at the repo root — defines the project domain,
   QMD search contexts, and whether any architecture projects are declared.
2. **Read `AGENTS.md`** (copied from `.llm-wiki/instance/AGENTS.md`) for the full
   schema: page format, frontmatter rules, entity types, naming conventions,
   cross-referencing rules, and the two documentation workflows.

Never skip these files. They define the wiki's structure.

> **How the docs pipeline is built & run** (RIG controller, KEDA/Dapr,
> PVC cache, deterministic RIG→C4→Mermaid generation) lives in the module's
> `AGENTS.md` / `README.md` (the `.llm-wiki` submodule). This skill covers
> *operations*; consult it only if asked how the system itself works.
>
> **Diagrams are generated deterministically by CI.** Do NOT invent or
> manually generate architecture diagrams — the CI pipeline (`rig-to-c4.py` →
> `likec4 gen mermaid`) produces them from the RIG. Your job: update wiki
> pages with the generated output, preserve manual content.

## Documentation Home

## Documentation Home

- **C4 boundary: llm-wiki carries context/container/component level only.**
  Code-level details (file paths, function signatures, implementation specifics,
  API reference) go to the **platform wiki** (GitHub/Forgejo) via `gh`/`fj`, not
  the llm-wiki. This keeps the llm-wiki unbloated.
- **No in-repo `docs/` folders.** Move `docs/`, ADRs, or design docs to the
  wiki (structure + reasoning) or the platform wiki (important ADRs via
  `gh`/`fj`). Root files (`README.md`, `AGENTS.md`, `CONTEXT.md`) are
  **indexes** — link to real docs, don't duplicate them.
- **Platform wikis** (GitHub/Forgejo) are first-class surfaces for low-level
  details and important ADRs. Check both when reading a project.

## How to absorb this wiki (least-context routing)

The wiki is layered so you answer most questions from the **smallest** source,
not by reading the whole repo. Route by need:

| You need to… | Read this | Why it's the minimal source |
|---|---|---|
| Catch a project's **structure** fast | `raw/arch/<project>/rig.json` | deterministic code graph, 1–15K tokens; often enough on its own |
| Understand the **architecture views** | `raw/arch/<project>/model.c4` | LikeC4 model with components, containers, relationships — from RIG |
| Understand a **decision + its reasoning** | the matching `wiki/` page(s) | the *why*, captured live at decision time |
| Find **what pages exist** | `index.md` | catalog, not a dir walk |
| See **what changed recently** | `log.md` | append-only activity |
| Move between related pages | a page's `## See Also` | the bidirectional link graph |

**Two layers, distinct jobs:** `raw/` = structure (RIG, deterministic,
evidence-backed); `wiki/` = reasoning (decisions, trade-offs, recorded live).
Automated arch-sync (RIG → LikeC4 → Mermaid) regenerates *structure*; the
wiki records *intent* — it captures what the pipeline cannot.

> **Never read the whole repo to answer a wiki question.** Route to the
> minimal source above. `wiki read` and `wiki update` load only the pages that
> match the topic — not the whole tree.

## Page-size discipline

A page you can absorb in one glance is one that needs minimal context — that
is the wiki's whole point. wiki CI enforces a deterministic **line limit per
page** (`pages.size_limit`, default **400**) so no page grows past a single
glance.

- **Default: warning.** An over-limit page emits a CI annotation naming the
  page and its line count. CI stays green; the annotation is the nudge.
- **Strict: `pages.size_strict: true`** makes an over-limit page fail CI.
- **When flagged, do one of:**
  - **Shrink** — tighten prose, collapse repetition, push raw detail into
    `raw/` and link to it.
  - **Split** — extract a sub-topic into its own page, cross-link both ways,
    and update `index.md`.

Treat an over-limit page as a signal to act on the next time you touch it —
not a verdict that blocks everything. Keep new pages focused from the start
(see `wiki create`).

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

The wiki supports distinct workflows. Each has its own inputs, diagram tool,
and CI validation. A project can use one or both.

### Workflow 1: Generic Documentation

For documenting anything that is NOT driven by a code graph — entities,
concepts, guides, reference material. Written from raw sources (articles,
READMEs, conversations, design docs).

- **Inputs**: raw sources in `raw/` (anything the human curates).
- **Diagrams**: **Mermaid only**. Renders natively on GitHub and Obsidian.
  Many types: `sequenceDiagram`, `flowchart TD/LR` + `subgraph`,
  `stateDiagram-v2`, `erDiagram`, `gantt`, etc. Pick the type that matches the
  content.
- **CI validation**: wiki CI validates markdown + mermaid syntax.

### Workflow 2: Architecture Documentation (LC4)

> **⚠ CRITICAL: Architecture diagrams are generated by CI. Do NOT write them. ⚠**
>
> CI runs `rig-to-c4.py` → `likec4 gen mermaid` to produce `model.c4` and Mermaid diagrams from `raw/arch/<project>/rig.json`. Your job: read the RIG, then update wiki pages with the generated diagrams. Do NOT invent architecture from memory.

For documenting a project's architecture from its code. CI generates the diagrams; you update the wiki pages.

**Prerequisite:** `raw/arch/<project>/rig.json` must exist. If missing → STOP.

- **Inputs**: `raw/arch/<project>/rig.json` — read it to understand structure.
- **Diagrams**: CI generates them (don't write `model.c4` or run `likec4 gen mermaid` yourself).
- **Your job**: Update wiki pages with CI-generated diagrams, preserve manual content.

---

## Commands

### `wiki read <topic>`

Search the wiki for information about a topic.

1. Search with qmd (if available):

   ```bash
   qmd query "topic" --json -n 10
   ```

2. Search with grep:

   ```bash
   grep -rl "topic" wiki/ index.md
   ```

3. Read every matching page **in full**.
4. Synthesize an answer with citations.
5. If substantial and not yet a page, offer to create one.

### `wiki update`

Ingest new information into the wiki (Generic workflow).

1. **Understand the change.** Read relevant existing pages.
2. **Save source** to `raw/` (e.g. `2026-06-26-topic-name.md`). **Never modify
   `raw/`** after saving.
3. **Update existing pages**: add information, add Markdown cross-references, update
   `sources: []` and `updated:` in frontmatter.
4. **Create new pages** for uncovered topics (correct entity-type directory).
5. **Add diagrams** as ` ```mermaid ` blocks where they help. Pick the type that
   matches the content (sequence for time-ordered, flowchart+subgraph for
   containment, etc.).
6. **Update `index.md`** and **append to `log.md`**.
7. **Validate**: `npm run check`.

### `wiki create <topic>`

Create a new wiki page.

1. Classify the entity type:
   - Specific technology/product → **entity**
   - Cross-cutting idea/pattern → **concept**
   - Step-by-step procedure → **guide**
   - Catalog/comparison/lookup → **reference**
2. Check for overlap — search `index.md` and `qmd query`.
3. Write the page:

   ```markdown
   ---
   title: Descriptive Specific Title
   type: entity|concept|guide|reference
   created: YYYY-MM-DD
   updated: YYYY-MM-DD
   sources: []
   tags: [type-tag, tag2, tag3]
   ---

   # Descriptive Specific Title

   Dense keyword-rich summary (2-3 sentences).

   ## Section Title

   Body with [Markdown links](../type/page-name.md) to other pages.

   ## See Also

   - [related-1](../type/related-1.md) — description
   - [related-2](../type/related-2.md) — description
   ```

4. Add Markdown links from existing pages to the new page. Use relative paths:
   from `wiki/concepts/x.md` to `wiki/entities/y.md` → `[y](../entities/y.md)`.
5. Ensure bidirectional links.
6. Update `index.md`, append to `log.md`, validate with `npm run check`.

### `wiki arch-sync <project>`

Update wiki prose after a deterministic RIG/C4/Mermaid refresh. The graphs are
already generated — your job is to summarize and route content.

1. **Verify artifacts exist**: `ls raw/arch/<project>/` (rig.json, model.c4, *.mmd).
2. **Read the RIG** to understand what changed (new/removed/changed components).
3. **Do NOT generate graphs** — model.c4 and *.mmd are deterministic. Do NOT run rig-to-c4.py or likec4.
4. **Embed Mermaid**: read `raw/arch/<project>/*.mmd`, copy into wiki pages as ` ```mermaid ` blocks.
5. **Write C4-level prose only** (context/container/component). Summarize what changed in 1-3 sentences.
6. **Offload low-level details** (file paths, function docs, implementation specifics) to the **platform wiki** via `gh`/`fj`. Keep llm-wiki unbloated.
7. **Preserve manual content** (deployment notes, runbooks, config).
8. **Update `index.md`** and **append to `log.md`**.
9. **Commit** (do NOT push — gate runs next).

### `wiki consult <project-repo-path>`

Help a project set up RIG graph generation (promotion to LC4). Inspects the
project repo, determines its language and build system, generates a CI
workflow that uses the reusable repo-map Action, and writes it into the
project repo.

> This command operates on the **project repo** (not the wiki). It is the
> only skill command that writes outside the wiki. It exists to *establish*
> the project→graph→wiki pipeline, then gets out of the way.

1. **Inspect the project repo** at `<project-repo-path>`:
   - Detect the language: check for `go.mod` (Go), `package.json` (TS/JS),
     `pyproject.toml`/`setup.py` (Python), `Cargo.toml` (Rust).
   - Detect the build system.
2. **Generate the workflow** that produces a RIG JSON using the reusable
   Action `tibrezus/llm-wiki/.github/actions/repo-map@vN`:

   ```yaml
   # .github/workflows/repo-map.yml
   name: Generate RIG
   on:
     push:
       tags: ['v*']
   jobs:
     rig:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: tibrezus/llm-wiki/.github/actions/repo-map@v1
           with:
             language: go          # detected language
         - name: Publish RIG
           uses: softprops/action-gh-release@v2
           with:
             files: repo-map.json
   ```

3. **Write the workflow** into `<project-repo-path>/.github/workflows/repo-map.yml`.
4. **Open a PR** in the project repo. After merge, the project will
   deterministically publish `repo-map.json` as a Release asset on every tag.
5. **If the project repo is private**, create a read-scoped token (fine-grained
   PAT on GitHub, or an access token on Forgejo) and store it as a CI secret in
   the **wiki** repo: `gh secret set <PROJECT>_RIG_TOKEN` (GitHub) or the
   equivalent in Forgejo. Then declare it in the wiki's `arch:` config as
   `rig_token_env: <PROJECT>_RIG_TOKEN` alongside `rig_url`. Public repos skip
   this step.
6. **Tell the human** to add the project to the wiki's `arch:` config with the
   Release asset URL as `rig_url` (and `rig_token_env` if private). From that
   point, the wiki CI will fetch and commit the RIG, and LC4 unlocks.
7. **After the first RIG lands** in `raw/arch/<project>/rig.json`, run the
   `arch-sync` command to write the initial LikeC4 model (`.c4`) from the RIG
   and generate the Mermaid architecture diagrams.

### `wiki prune <topic>`

Remove a page. **Never without explicit instruction.**

1. Find the page: `find wiki/ -name "topic.md"`.
2. Find all inbound links: `grep -rl "topic" wiki/` (check both `[topic](` and `[[topic]]`).
3. Remove/update Markdown links from referencing pages.
4. Delete the file.
5. Remove from `index.md`, append to `log.md`, validate.

### `wiki list`

Summarize the wiki contents.

1. Read `index.md` for the catalog.
2. Count pages by type:

   ```bash
   find wiki/entities -name "*.md" | wc -l
   find wiki/concepts -name "*.md" | wc -l
   find wiki/guides -name "*.md" | wc -l
   find wiki/reference -name "*.md" | wc -l
   ```

3. Check for architecture projects:

   ```bash
   ls -d raw/arch/*/ 2>/dev/null
   ```

4. Run health check:

   ```bash
   python3 .llm-wiki/scripts/wiki-health.py wiki/
   ```

5. Present: page counts, architecture projects, recent updates, warnings.

---

## Diagram Rules by Workflow

| Workflow | Tool | When | CI checks |
|----------|------|------|----------|
| Generic Documentation | **Mermaid only** | documenting from raw sources | markdown + mermaid render validity |
| Architecture (LC4) | **LikeC4 → Mermaid** | documenting from a code graph | C4 model validity + mermaid render |

Never mix: no LikeC4 models in generic docs, no hand-written Mermaid for C4
architecture diagrams (generate from the model).

### Mermaid type guide (Generic)

| Content | Type |
|---------|------|
| Time-ordered triggers | `sequenceDiagram` |
| Nested topology / containment | `flowchart TD` + `subgraph` |
| Linear pipeline / fan-out | `flowchart LR` |
| Dependency chain | `flowchart TD` |
| Decision branches | `flowchart TD` with `{rhombus}` |
| State transitions | `stateDiagram-v2` |
| Schema / relationships | `erDiagram`, `classDiagram` |
| Timeline / phases | `gantt`, `journey` |

Use ` ```text ` for file trees, procedures, pseudo-code, templates — not diagrams.

### LikeC4 C4 guide (Architecture)

| C4 Level | Scope | LikeC4 element/view |
|----------|-------|---------------------|
| Context | whole system + actors | `system` elements; `view` with `include *` |
| Container | one project | `container` in `system`; `view of <system>` |
| Component | one module | `component` in `container`; `view of <container>` |
| Code | few files | `component` details; `view of <component>` |

---

## Commit and Verify

A wiki change is **not done** when the local files are written. It is done
only when it is **committed, pushed to the remote, and CI is green**.

Local validation (`npm run check`) is necessary but not sufficient — it does
not catch submodule drift, tool-version differences, or environment-specific
failures. CI also validates diagrams (Mermaid render-checked via `mmdc`,
LikeC4 models via `likec4 format --check`) that local checks do not. Only the
remote CI run is authoritative.

The workflow, end to end:

1. Write the change locally.
2. `npm run check` — fast local gate (catches obvious mistakes early).
3. Commit and **push** to the remote.
4. **Watch the CI run** and confirm it is green. If it fails, fix and push
   again until it is green.
5. Only then is the change considered complete.

Use the right tool for the remote — they are NOT interchangeable:

- **GitHub** repos: use **`gh`** (`gh run watch`, `gh run list`).
- **Forgejo** repos: use **`fj`** (`fj actions tasks`, `fj actions jobs`).

Determine the platform from the remote URL before pushing, and use the
corresponding tool to watch CI. Do not assume — check.

## Validation Checklist

Before committing any wiki change:

- [ ] `npm run check` passes (markdownlint + remark + wiki-health)
- [ ] New pages: all 6 frontmatter fields present, correct type directory
- [ ] Tags: 2-7 items, first matches type, all lowercase
- [ ] `## See Also` with ≥2 links
- [ ] No duplicate filenames across `wiki/`
- [ ] `index.md` updated, `log.md` appended
- [ ] Bidirectional links maintained
- [ ] No `#` body headings, no inline HTML
- [ ] Cross-references use [Markdown links](relative/path.md) that render on Codeberg/GitHub
- [ ] Generic workflow pages: Mermaid only (no LikeC4 models)
- [ ] Architecture pages: Mermaid generated from LikeC4 model; model validates
- [ ] **Architecture diagrams derived from `raw/arch/` RIG — NOT from memory**
- [ ] **Every component/dependency in architecture diagrams is traceable to the
      RIG**
- [ ] **`raw/arch/<project>/rig.json` existed before architecture diagrams
      were written** (no RIG = no architecture workflow)
- [ ] **No page exceeds the size limit** (`pages.size_limit`, default 400
      lines); if the CI flags one, shrink or split it (see Page-size discipline)

After committing:

- [ ] **Pushed** to the remote
- [ ] **CI run watched** to green (via `gh` for GitHub, `fj` for Forgejo)
