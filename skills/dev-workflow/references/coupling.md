# Coupling — intentional or documented

Depth page for gate 7. `llm-wiki` owns *how* to document coupling; this
page owns *what counts* and *how to spot it*.

## What counts

Coupling is anything that makes one component depend on another to build,
run, evolve, or be tested independently. The four kinds:

| Kind | Smell | Example |
|---|---|---|
| **Build-time** | one component won't build without another present | a library importing an app's `internal/` package; needing another's generated code to type-check |
| **Runtime** | one component imports/calls another directly | service A `import`s service B's handler instead of a contract/interface |
| **Data** | shared mutable schema/table/store with no contract | two services writing the same DB rows without an ownership boundary |
| **Temporal** | assumed start order / event timing | worker assumes the API is up before it boots; implicit fan-out sequencing |

## The rule

> **Avoid coupling unless it is part of the intended architecture. If
> unavoidable, document it in the wiki before the PR merges.**

- **Intended** = it appears in the project's design (architecture page,
  ADR, documented boundary). Intended coupling is fine — that is what
  architecture *is*.
- **Unavoidable but unintended** = pragmatic coupling the design did not
  ask for. It must become a **decision, not silent debt**: load
  **`llm-wiki`** and record the coupling, *why* it is required, and the
  boundary it creates — in the same PR, at minimum before merge.

Undocumented coupling compounds, surfaces as "why does this build need
that?" months later, and blocks independent testing — weakening the test
gate. Documenting it turns an accident into a choice future agents can
reason about.

## Detection heuristics (per ecosystem)

One-liners that catch common regressions. Run the relevant one before
opening the PR; a hit on something the change introduced means: remove the
dependency or document it.

**Go**
```bash
# cross-package imports into another component's internal/ tree
git diff --name-only origin/$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')...HEAD \
  | xargs -r grep -nE '"[^"]+/internal/' || true
go mod why <module>      # justify every new require
```

**TypeScript / JavaScript**
```bash
# deep relative imports crossing component roots (A pulling from B)
git diff origin/main...HEAD --name-only | xargs -r grep -nE "from ['\"]\.\./\.\./" || true
# a new direct dependency the change adds — justify in the PR
git diff origin/main...HEAD -- package.json package-lock.json
```

**Python**
```bash
git diff origin/main...HEAD --name-only | xargs -r grep -nE "from [a-z_]+\.[a-z_]+\." || true
```

**General — shared mutable state**
```bash
git diff origin/main...HEAD -- '**/migrations/**' '**/*.sql' '**/openapi*.yaml' '**/proto/**'
```

Heuristics, not oracles: a hit means "look here", not "block the PR". The
gate requires only that the keep-or-remove decision is *visible* (removed,
or documented).

## Project policy knob

**`COUPLING_POLICY`** in the project's AGENTS.md config block (injected by
`adopt`):

- `strict` (default) — new cross-component coupling must be designed or
  wiki-documented before merge.
- `documented-exceptions` — coupling allowed, every exception still gets a
  wiki page/ADR (projects that are deliberately a monolith).
- `legacy` — tolerated for now, each occurrence tracked as an issue for
  paydown. Inherited codebases only; time-box it.

If unset: treat as `strict`.
