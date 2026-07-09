# CI Concepts — Tests as the Quality Gate, Coupling by Design

This is the depth page for the CI-discipline rules stated briefly in
[`SKILL.md`](../SKILL.md). The skill enforces *that* tests exist and run in CI
and *that* coupling is intentional-or-documented; this page explains *what
counts*, *how to spot it*, and *how to wire it into CI*.

Two sister skills own the adjacent depth and are loaded on demand rather than
duplicated here:

- **`tdd`** — *how* to write good tests (behavior over implementation,
  vertical red-green slices, mocking discipline). dev-workflow only requires
  that tests exist and run; it does not teach test design.
- **`llm-wiki`** — *how* to document architectural coupling in the project's
  persistent wiki (pages, ADRs, cross-references). dev-workflow only makes
  "documented coupling" a merge gate.

## 1. "CI green" means tests pass — not "it compiled"

A build that compiles is necessary but not sufficient. CI is the gate where a
change proves its behavior survives the project's full, environment-stable
suite. The rule the gate enforces:

> A test that is not executed by CI does not protect the change. The next
> contributor's laptop is not CI.

CI is authoritative; the local run is a fast feedback loop. Both matter, in
that order: iterate locally (`dw_run_tests`), then let CI confirm on a clean
runner.

### 1.1 Test policy (mandatory by default)

| Test kind | Requirement | Rationale |
|---|---|---|
| **Unit tests** | **Mandatory** for every behavior the change adds or alters. | Unverified behavior regresses silently on the next merge. |
| **Integration tests** | **Extended whenever the project already has a suite.** A change to an integrated path must add/extend coverage; never shrink the suite. | A suite that stops tracking the code is worse than no suite — it looks green while lying. |
| **No suite yet** | Do **not** invent one unprompted; surface the gap on the issue. | Forcing a harness the team hasn't chosen creates coupling to a tool nobody maintains. |

A change is **not covered** if:

- it adds/alters observable behavior but ships no new or updated unit test; or
- it touches an integration-tested path but does not extend the integration
  test; or
- its tests exist locally but are not wired into CI (e.g. a new test file CI
  doesn't discover, a `*.skip`, an excluded directory).

### 1.2 Writing the tests

Load the **`tdd`** skill and follow its vertical red-green loop: one test →
one behavior → minimal code. Tests verify **behavior through public
interfaces**, not implementation. The two anti-patterns to refuse, inherited
from `tdd`:

- **Horizontal slicing** — writing a batch of tests against imagined behavior
  before the implementation exists. They test shape, not behavior.
- **Implementation coupling** — tests that mock internal collaborators or
  assert on private structure. They fail on every refactor though behavior is
  unchanged.

## 2. Coupling is intentional or documented

### 2.1 What counts as coupling

Coupling is anything that makes one component depend on another to build,
run, evolve, or be tested independently. A clean change keeps components
independently buildable and testable. The four kinds to watch for:

| Kind | Smell | Example |
|---|---|---|
| **Build-time** | one component won't compile/build without another present | a library that imports an app's `internal/` package; a module that needs another's generated code to type-check |
| **Runtime** | one component imports/calls another directly | service A `import`s service B's handler instead of going through a contract/interface |
| **Data** | components share a mutable schema, table, or store with no contract | two services writing the same DB rows without a shared ownership boundary |
| **Temporal** | components assume each other's start order / event timing | worker assumes API is up and ready before it boots; implicit sequencing in a fan-out |

### 2.2 The rule

> **Avoid coupling unless it is part of the intended architecture. If
> unavoidable, document it in the wiki before the PR merges.**

- **Intended** = the coupling appears in the project's design (architecture
  page, ADR, or an existing documented boundary). Intended coupling is fine;
  that is what architecture *is*.
- **Unavoidable but unintended** = a pragmatic coupling the change introduces
  that the design did not ask for. This must become a **decision**, not silent
  debt: load the **`llm-wiki`** skill and add or update a page/ADR that records
  the coupling, *why* it is required, and the boundary it creates. Do this
  **ASAP** — ideally in the same PR, at minimum before merge.

Undocumented coupling is the failure mode the gate prevents: it compounds,
surfaces as "why does this build need that?" months later, and blocks
independent testing — which in turn weakens the test gate above. Documenting
it turns it from an accident into a choice a future agent can reason about.

### 2.3 Detection heuristics (per ecosystem)

dev-workflow cannot mechanically detect coupling across all languages, but
these one-liners catch the common regressions. Run the relevant one before
opening the PR; if it returns something the change introduced, either remove
the dependency or document it.

**Go**
```bash
# cross-package imports into another component's internal/ tree
git diff --name-only origin/$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')...HEAD \
  | xargs -r grep -nE '"[^"]+/internal/' || true
go mod why <module>      # justify every new require
```

**TypeScript / JavaScript**
```bash
# deep relative imports that cross component roots (src/components/A pulling from src/components/B)
git diff origin/main...HEAD --name-only | xargs -r grep -nE "from ['\"]\.\./\.\./" || true
# a new direct dependency the change adds — justify in the PR
git diff origin/main...HEAD -- package.json package-lock.json
```

**Python**
```bash
# intra-repo imports that reach across package boundaries
git diff origin/main...HEAD --name-only | xargs -r grep -nE "from [a-z_]+\.[a-z_]+\." || true
```

**General — shared mutable state**
```bash
# a change that edits a schema/migration consumed by another component
git diff origin/main...HEAD -- '**/migrations/**' '**/*.sql' '**/openapi*.yaml' '**/proto/**'
```

These are heuristics, not oracles. A hit means "look here", not "block the
PR". The decision to keep or remove the coupling is the contributor's; the
gate requires only that the decision is *visible* (removed, or documented).

### 2.4 Project policy knob

A project may relax or tighten the default by setting **`COUPLING_POLICY`** in
its AGENTS.md project-configuration block (injected by `adopt`):

- `strict` (default) — any new cross-component coupling must be designed or
  wiki-documented before merge.
- `documented-exceptions` — coupling allowed, but every exception still gets
  a wiki page/ADR (used by projects that are deliberately a monolith).
- `legacy` — coupling tolerated for now; each occurrence is tracked as an
  issue so it can be paid down. Use only for inherited codebases, and time-box
  it.

If unset, treat the project as `strict`.

## 3. Wiring tests into CI (so the gate is real)

The local `dw_run_tests` mirror and the CI pipeline must run the **same**
ssuite, or the local loop lies.

### How the test command is resolved

The command is **project-owned**, not skill-owned. `dw_run_tests` (and the
`Test command:` `adopt` suggests in AGENTS.md) resolve it in this precedence,
highest first:

1. **`CI_TEST_COMMAND` env var** — explicit override for the session.
2. **A committed runner in the repo** (language-agnostic, **preferred**) —
   `scripts/test` (executable), `scripts/test.sh`, `bin/test`, or a Makefile
   `test:` target (`make test`). **This is what scales across many projects:**
   the project commits its real command with its real flags, and the skill
   never needs editing. Use it for anything non-standard.
3. **Language heuristics** (zero-config fallback for common stacks) —
   `package.json`→`npm test`, `go.mod`→`go test ./...`, `build.zig`→
   `zig build test`, `Cargo.toml`→`cargo test`, `pyproject.toml`/`setup.py`→
   `pytest`, `meson.build`→`meson test`, `CMakeLists.txt`→ a configure→build→
   `ctest` one-liner.

The heuristic list is deliberately short. **C / C++ / CMake are build-config
dependent** (build dir, presets, toolchain) — the heuristic is only a starting
point; commit `scripts/test` with the real invocation. Same for monorepos,
containerised suites, and bespoke harnesses. Adding a new stack never requires
editing the skill: commit a runner (2) or set `CI_TEST_COMMAND` (1).

When setting up or updating CI:

1. **Make CI run the project's real test command** — exactly what the project
   declares (precedence above), not a subset or a guess.
2. **Fail the build on test failure.** Non-zero exit must fail the workflow —
   no `|| true`, no `continue-on-error` on the test job.
3. **Discover tests automatically.** New test files added by a PR must be
   picked up without editing CI config (standard runners do this; bespoke
   allowlists don't).
4. **Run integration tests too** — in a separate job if they need services,
   but they must run on the PR, not only nightly.
5. **Keep the matrix honest.** If CI runs on one OS/Go/Node version, the
   project has implicitly pinned that version; surface it, don't hide it.

Per-platform patterns live in [`platform-commands.md`](platform-commands.md)
for the *watch* side; the *run* side is project-defined via `TEST_COMMAND`.

## 4. The two gates, restated as a merge contract

A PR may merge only when **both** hold:

- **Test gate** — the change is covered by unit tests (mandatory) and, where a
  suite exists, extended integration tests; those tests run and pass in CI.
- **Coupling gate** — every coupling the change introduces is either part of
  the documented architecture, or recorded in the wiki (via `llm-wiki`) before
  merge, per the project's `COUPLING_POLICY`.

Red on either gate is fixed on the branch and re-pushed — never merged. These
sit alongside (not instead of) the lifecycle gates in `SKILL.md`.
