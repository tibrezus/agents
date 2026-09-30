# Graph queries — the `rig` tool and the gate-1 load protocol

The architecture graph (`raw/arch/<project>/rig.db`) is the fastest way to
understand structure: ~200 tokens per question instead of reading source
trees. In pi, use the `rig` tool (registered by this skill's
`extensions/rig-query.ts`, installed at `~/.pi/agent/extensions/`):

    rig overview                  # whole architecture, ~400 tokens
    rig component <name>          # deps + files + doc comments
    rig search 'symbol*'          # FTS5 symbol search → file:line
    rig deps <name> --reverse     # who depends on it
    rig brief diff=<patch>        # ONE-call review orientation: provenance, risk, orphans, clones
    rig dead [component]          # zero-caller exports (two-tier; needs call data)
    rig clones [symbol]           # near-clone pairs (MinHash+LSH, similar table)
    rig impact diff=<patch>       # diff → touched symbols, blast radius, risk
    rig trace '<a> <b>'           # shortest call paths between two symbols

Outside pi, the same commands exist as the module CLI:

    Q=.llm-wiki/.github/actions/repo-map/rig-query.py
    python3 "$Q" raw/arch/<project>/rig.db overview

**C4 architecture: project wiki is authoritative.** When a project has its
own wiki with `Architecture.md` (the single merged page: diagrams +
LikeC4 model + CI registry), that is the **source of truth** — regenerated
by CI on every push to the default branch. The llm-wiki instance's
`raw/arch/<project>/` (rig.db, model.c4) is a **fallback** that may be
stale. Always read the project wiki first; use `raw/arch/` only when the
project wiki has no architecture content. To access the project wiki: if
already cloned, pull first (`git pull --ff-only` — CI regenerates on every
push, a stale clone gives outdated diagrams); else `git clone
<remote>.wiki.git`. Look for `Architecture.md` and `C4-Model.md`. Raw
artifacts may also live on a dedicated branch (e.g. `arch-rig`).

## Serving implementation context (dev-workflow gate 1)

The wiki's core purpose is making implementation follow the architecture:
**before writing code in a graph-covered project, load the most compressed
accurate picture**, in order:

1. `rig overview` — every component, edge, and file count (~400 tokens).
2. `rig component <name>` + `rig search '<term>*'` for the area being
   changed — doc comments, exported symbols, exact `file:line` anchors.
3. The project wiki's merged `Architecture.md` for rendered views + the
   LikeC4 model (component descriptions verbatim from source doc
   comments).
4. Matching `wiki/` pages for the *why* (decisions, trade-offs).

**Deduplication rule:** before writing a new function/type, `rig search`
the capability — if it is already exported, extend it. This is the single
highest value the graph provides to code work.

**Two layers, distinct jobs:** `raw/` = structure (RIG, deterministic,
evidence-backed); `wiki/` = reasoning (decisions, trade-offs, recorded
live). Automated arch-sync (RIG → LikeC4 → Mermaid) regenerates
*structure*; the wiki records *intent* — what the pipeline cannot.

> **How the docs pipeline itself is built & run** (RIG controller,
> KEDA/Dapr, PVC cache, deterministic RIG→C4→Mermaid generation) lives in
> the module's `AGENTS.md` / `README.md` (the `.llm-wiki` submodule).
> This skill covers *operations*; consult it only if asked how the system
> itself works.
