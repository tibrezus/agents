---
name: wiki
description: Operate on an LLM Wiki knowledge base. Commands: read (search and read wiki pages about a topic), update (ingest new information into wiki pages), create (add new wiki pages), prune (remove outdated pages), list (summarize wiki contents). Use when the user asks to look something up in the wiki, update wiki content, add/remove pages, or get an overview of the knowledge base.
---

# LLM Wiki Operations

A wiki is a persistent, compounding knowledge base organized by entity type. It lives in a git repository with the structure:

```
.llm-wiki/          # Shared tooling (git submodule)
wiki.config.yml     # Project configuration
index.md            # Catalog of all pages
log.md              # Append-only activity log
raw/                # Immutable source documents
wiki/
├── entities/       # "What is X?" — technologies, products
├── concepts/       # "How does X work?" — patterns, principles
├── guides/         # "How to X?" — step-by-step procedures
└── reference/      # "Compare/Lookup X" — catalogs, comparisons
```

## Before You Start

1. **Read `wiki.config.yml`** at the repo root to understand the project domain.
2. **Read `AGENTS.md`** (usually copied from `.llm-wiki/AGENTS.md`) for the full schema — frontmatter rules, page format, naming conventions, cross-referencing rules.

These files define the wiki's structure. Never skip them.

## Commands

### `wiki read <topic>`

Search the wiki for information about a topic. Use before making changes to understand what's already documented.

**Steps:**

1. Search with qmd (if available):
   ```bash
   qmd query "topic" --json -n 10
   ```
2. Search with grep for pages mentioning the topic:
   ```bash
   grep -rl "topic" wiki/ index.md
   ```
3. Read every matching page **in full** — never summarize from titles alone.
4. Synthesize an answer with citations (mention which wiki pages contributed).
5. If the answer is substantial and not yet a wiki page, offer to create one.

### `wiki update`

Ingest new information into the wiki. Use when the user provides a source, describes changes, or asks to update the wiki.

**Steps:**

1. **Understand the change.** Ask the user for the source if not provided. Read relevant existing pages.
2. **Save source** to `raw/` with a descriptive filename (e.g., `2025-05-24-topic-name.md`). **Never modify files in `raw/`** after saving.
3. **Update existing pages.** For each page touched:
   - Add new information in the correct section
   - Add `[[wikilinks]]` for any newly-mentioned concepts that have pages
   - Update `sources: []` in frontmatter to include the new source filename
   - Update `updated: YYYY-MM-DD` in frontmatter
4. **Create new pages** for topics not yet covered. Follow the page format exactly:
   - Determine entity type (entity/concept/guide/reference) and place in correct directory
   - Frontmatter: `title`, `type`, `created`, `updated`, `sources`, `tags` (2-7, first matches type)
   - Body: `# Title` → summary paragraph → `## Sections` → `## See Also` (≥2 links)
   - File name: lowercase, hyphen-separated, unique across all of `wiki/`
5. **Update `index.md`** — add new pages, update modified page summaries.
6. **Append to `log.md`** — format: `## [YYYY-MM-DD] operation | Short Title`
7. **Run validation:**
   ```bash
   npm run check    # markdownlint + remark + wiki-health
   ```
   Fix any errors before committing.

**Cross-referencing rules:**
- Always use `[[wikilinks]]` (filename only, no path, no extension) — never markdown links for internal refs
- If page A links to B, B should link back to A (at minimum in `## See Also`)
- Every page must have `## See Also` with ≥2 related pages
- Never use `#` headings in body (reserved for title)
- Never use inline HTML

### `wiki create <topic>`

Create a new wiki page. Use when the user explicitly asks to add a page or when `wiki read` reveals a gap.

**Steps:**

1. Determine entity type from the topic:
   - **entity**: specific technology/product with a GitHub repo or version number
   - **concept**: cross-cutting idea, pattern, or architectural principle
   - **guide**: step-by-step procedure the reader follows
   - **reference**: catalog, comparison, or lookup table
2. Check for existing pages that might overlap — search `index.md` and `qmd query`.
3. Write the page following the format:
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

   Dense keyword-rich summary paragraph (2-3 sentences).

   ## Section Title

   Body content with [[wikilinks]].

   ## See Also

   - [[related-page-1]] — Brief description
   - [[related-page-2]] — Brief description
   ```
4. Add `[[wikilink]]` references from existing pages to the new page.
5. Ensure bidirectional links — the new page's `## See Also` must link back to pages that link to it.
6. Update `index.md` and append to `log.md`.
7. Validate with `npm run check`.

### `wiki prune <topic>`

Remove a page from the wiki. Use when the user explicitly asks to delete a page. **Never delete without explicit instruction.**

**Steps:**

1. Identify the page file: `find wiki/ -name "topic.md"`
2. Find all pages that link to it: `grep -rl "\[\[topic\]\]" wiki/`
3. Remove or update wikilinks from all referencing pages — replace with inline explanation or move content to a more appropriate page.
4. Delete the file.
5. Remove from `index.md`.
6. Append to `log.md` with operation `prune`.
7. Validate with `npm run check`.

### `wiki list`

Summarize the wiki contents. Use when the user wants an overview.

**Steps:**

1. Read `index.md` for the structured catalog.
2. Read `wiki.config.yml` for project context.
3. Count pages by type:
   ```bash
   find wiki/entities -name "*.md" | wc -l
   find wiki/concepts -name "*.md" | wc -l
   find wiki/guides -name "*.md" | wc -l
   find wiki/reference -name "*.md" | wc -l
   ```
4. Run health check to surface issues:
   ```bash
   python3 .llm-wiki/scripts/wiki-health.py wiki/
   ```
5. Present a structured summary: page counts by type, recent updates, any warnings or errors.

## Entity Type Decision Tree

When creating a page, classify using this decision tree:

- Does it have a GitHub repo, version number, or is it a specific product? → **entity**
- Is it a cross-cutting idea, pattern, or "how does X work?" concept? → **concept**
- Is the reader meant to follow steps to accomplish something? → **guide**
- Is it a catalog, comparison table, or lookup resource? → **reference**

## Validation Checklist

Before committing any wiki change:

- [ ] `npm run check` passes (markdownlint + remark + wiki-health)
- [ ] New pages have correct frontmatter (all 6 required fields)
- [ ] New pages are in the correct entity-type directory
- [ ] Tags: 2-7 items, first tag matches `type`, all lowercase
- [ ] `## See Also` present with ≥2 links
- [ ] No duplicate filenames across `wiki/`
- [ ] `index.md` updated
- [ ] `log.md` appended
- [ ] Bidirectional links maintained (if A→B then B→A)
- [ ] No `#` headings in body, no inline HTML, no markdown links for internal refs
