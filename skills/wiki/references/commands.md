# Commands — read, update, create, arch-sync, prune, list

Full procedures for the wiki commands. `consult` (project promotion to
LC4) lives in [`consult.md`](consult.md). All commands assume the
preconditions from [`SKILL.md`](../SKILL.md): latest default branch
pulled, `wiki.config.yml` and `AGENTS.md` read.

## `wiki read <topic>`

1. Search with qmd (if available): `qmd query "topic" --json -n 10`
2. Else grep: `grep -rl "topic" wiki/ index.md`
3. Read every matching page **in full**.
4. Synthesize an answer with citations.
5. If substantial and not yet a page, offer to create one.

## `wiki update`

1. **Understand the change.** Read relevant existing pages, then run the
   **placement audit** (hierarchy in [`SKILL.md`](../SKILL.md)): content
   about a single component belongs in code comments; a single project's
   internals belong in that project's repo wiki. Route misplaced content
   to its layer — moved, not copied — instead of writing it here.
2. **Save source** to `raw/` (e.g. `2026-06-26-topic-name.md`). **Never
   modify `raw/`** after saving.
3. **Update existing pages**: add information, add Markdown
   cross-references, update `sources: []` and `updated:` in frontmatter.
4. **Create new pages** for uncovered topics (correct entity-type
   directory).
5. **Add diagrams** as ` ```mermaid ` blocks where they help — pick the
   type that matches the content ([`diagrams.md`](diagrams.md)).
6. **Update `index.md`** and **append to `log.md`**.
7. **Validate**: `npm run check`.

## `wiki create <topic>`

1. **Placement gate** — decide the layer before writing: one component →
   **code comments**; one project's internals → that **project's repo
   wiki** (temporary admission here only while its repo wiki does not
   exist); cross-repo / system-level → proceed.
2. Classify the entity type: technology/product → **entity**;
   cross-cutting idea/pattern → **concept**; step-by-step procedure →
   **guide**; catalog/comparison/lookup → **reference**.
3. Check for overlap — search `index.md` and `qmd query`.
4. Write the page:

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

5. Add Markdown links from existing pages to the new page (relative
   paths: from `wiki/concepts/x.md` to `wiki/entities/y.md` →
   `[y](../entities/y.md)`).
6. Ensure bidirectional links.
7. Update `index.md`, append to `log.md`, validate with `npm run check`.

## `wiki arch-sync <project>`

Update wiki prose after a deterministic rig.db refresh. The graphs are
already generated — your job is to summarize and route content.

1. **Verify artifacts exist**: `ls raw/arch/<project>/` (rig.db, model.c4).
2. **Query the graph** (rig tool — [`graph-queries.md`](graph-queries.md)):
   `rig overview`, then `component`/`search` for detail. Compare
   component/symbol/edge counts with the previous log entry.
3. **Do NOT generate graphs** — model.c4 is deterministic. Do NOT run
   rig-to-c4.py or likec4.
4. **Embed Mermaid**: read `raw/arch/<project>/*.mmd`, copy into wiki
   pages as ` ```mermaid ` blocks.
5. **Write interaction-level prose only** (context/container; hierarchy in
   [`SKILL.md`](../SKILL.md)). Summarize what changed in 1-3 sentences.
6. **Route by hierarchy:** single-component detail → code comments;
   single-project architecture → the project's repo wiki (`gh`/`fj`);
   the llm-wiki keeps only the cross-repo view.
7. **Preserve manual content** (deployment notes, runbooks, config).
8. **Update `index.md`** and **append to `log.md`**.
9. **Commit** (do NOT push — gate runs next).

## `wiki prune <topic>`

**Never without explicit instruction.**

1. Find the page: `find wiki/ -name "topic.md"`.
2. Find all inbound links: `grep -rl "topic" wiki/` (check both
   `[topic](` and `[[topic]]`).
3. Remove/update links from referencing pages.
4. Delete the file.
5. Remove from `index.md`, append to `log.md`, validate.

## `wiki list`

1. Read `index.md` for the catalog.
2. Count pages by type (`find wiki/<type> -name "*.md" | wc -l` per dir).
3. Check for architecture projects: `ls -d raw/arch/*/ 2>/dev/null`.
4. Run health check: `python3 .llm-wiki/scripts/wiki-health.py wiki/`.
5. Present: page counts, architecture projects, recent updates, warnings.
