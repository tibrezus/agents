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
suite. Two rules govern it:

> A test that is not executed by CI does not protect the change. The next
> contributor's laptop is not CI.

> CI instrumentation is cumulative — it evolves with the project. The local
> test command and the CI command are the same thing: run the project's own
> runner (`make test`, `npm test`, `scripts/test`) locally, never a throwaway
> script. Consolidation is the default practice: before creating any component
> — a tool, a CI job, a wiki page — quickly check that an equivalent doesn't
> already exist (tooling folders: `scripts/`, `tools/`, `bench/`) and extend
> it. New tools are wired into CI, unless you explicitly decide a tool is a
> one-off diagnostic and say so on the issue. A one-off script that is
> discarded after local verification leaves CI frozen while the code moves
> forward — it looks like coverage but protects nothing.

CI is authoritative; the local run is a fast feedback loop. Both matter, in
that order: iterate locally with the **project's own tooling** (not a parallel
script), then let CI confirm on a clean runner. The local loop is only valid
when it runs the same suite CI does — otherwise it lies.

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
  doesn't discover, a `*.skip`, an excluded directory); or
- **its validation was a throwaway script** — a one-off `test_my_change.sh`
  that ran once locally and was deleted. If it wasn't wired into CI, it
  protected nothing, and CI stayed frozen while the code moved on.

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

### 1.3 Test stratification — fast vs slow tier

Not all tests should run on every push. CI is tiered by execution cost so
expensive work doesn't block the inner dev loop:

| Tier | When it runs | What belongs here | Gate |
|---|---|---|---|
| **Fast** | Every push, every PR | unit tests, lint, type-check | Gate 10 floor |
| **Slow** | Pre-merge (required check) or manual (`workflow_dispatch`) | performance benchmarks, integration A/B harnesses, long evaluations, multi-service integration | blocks merge, not every commit |

**The rule:** a test that is not executed by CI does not protect the change —
but it doesn't need to run on every push. The question is *which tier*, not
*whether*. If a PR adds performance measurement, integration harness, or A/B
tooling, that infrastructure must be wired into the slow tier — never left
sitting in the repo unrun. A benchmark that only runs on someone's laptop is
the same failure mode as a unit test that only runs locally: it looks like
coverage but isn't.

**How to implement the tiers per platform:**

- **GitHub Actions** — fast tier in the `on: [push, pull_request]` workflow;
  slow tier as a separate workflow (`on: [workflow_dispatch]` + optionally
  triggered by a label or the PR environment) that is a **required** status
  check on the branch protection rule.
- **Forgejo / Gitea Actions** — same model; `workflow_dispatch` +
  conditional triggers.
- **Manual fallback** — if the platform has no `workflow_dispatch`, gate the
  slow tier behind a comment-triggered bot or a labeled re-run; the point is
  it runs *before merge*, not never.

**Boundary rule:** a job belongs in the slow tier only if it takes long enough
that running it on every push harms the feedback loop (rule of thumb: > 30s
beyond the fast tier). If it's fast, keep it in the fast tier — don't fragment
the suite.

### 1.4 Measurements as reproducible CI artifacts

A measurement whose value is in comparing it across runs — a benchmark, a
performance trace, an A/B comparison, a resource profile, a model-quality
eval — is a **CI artifact**, not a script someone runs once. The reason is
reproducibility: the same harness on the same runner class with the same
inputs produces **comparable data points over time**, enabling regression
detection and trend analysis. A one-off run on a laptop is an anecdote; a CI
run is a measurement.

**The rule:** if a change introduces or touches a measurement that should be
comparable over time (now vs. next month, before vs. after this PR), wire it
into CI — in the slow tier, manually triggered (`workflow_dispatch`). Manual
triggering is not a fallback here; it is the **correct** trigger for work too
expensive for every push but whose reproducibility over time is the point.
Each manual run is a data point with a known runner, known inputs, known
harness — queryable later, not lost to a terminal scrollback.

**Reusability is the constraint that prevents bloat.** Each measurement does
not get its own bespoke job. One harness, many invocations:

| Mechanism | When |
|---|---|
| **Composite action** (`.github/actions/<name>/action.yml` / `.forgejo/actions/`) | shared setup + one measurement step, reused across workflows |
| **Reusable workflow** (`on: workflow_call`) | a full slow-tier harness called from multiple workflows |
| **Committed harness script** (`scripts/bench`, `scripts/ab-test`) | measurement logic lives in the repo, versioned, called by CI — not inlined in YAML |

The anti-patterns:

- **Ad-hoc script** — a benchmark in the repo with no CI wiring. Runs once
  on a laptop, result lost. Looks like coverage; isn't.
- **Copy-pasted job** — each new measurement gets a new YAML job with
  duplicated checkout/setup/build. Bloats CI and drifts. Instead, one harness
  takes the measurement name as a parameter.
- **Non-deterministic harness** — unpinned deps, floating runner images, no
  fixed seed. Runs aren't comparable; "regression" is noise.

**Determinism matters.** Pin what you can: runner image, dependency
versions, input data, RNG seeds. Record what you cannot (network latency,
shared-hardware variance) as known noise. A measurement job that isn't
deterministic is theater.

**Results are artifacts, not stdout.** Upload measurement output as a CI
artifact (or commit to a results branch) so each run is a queryable data
point, not a log line that expires. This is what makes "reproducible
behaviour over time" real.

### 1.5 MC/DC for safety-critical boolean logic

When a project declares `SAFETY_LEVEL: mcdc` in its AGENTS.md config block,
every boolean decision in changed code must achieve Modified
Condition/Decision Coverage — each atomic condition proven to independently
affect the decision's outcome. This catches the masked-condition bug class
that branch and condition coverage miss.

MC/DC is a **deterministic pipeline** (AST → BDD → independence pairs →
minimal test set → compiler measurement), not an LLM reasoning task. The
agent's job is translation: a pre-computed spec (`mcdc-spec.json`) defines
the exact test vectors; the agent generates test code from it, and the
compiler's coverage instrumentation verifies correctness deterministically.

It belongs in the **slow tier** as a reusable measurement job (§1.4),
triggered pre-merge for safety-critical paths. Full playbook, spec format,
language support matrix, and graceful degradation:
[`mcdc.md`](mcdc.md).

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
suite, or the local loop lies. There is no "my local test" vs "CI's test" —
there is one suite. If you find yourself writing a script to validate your
change that is not part of the project's test infrastructure, stop: extend
the existing suite with your test, or wire your tool into CI. A script that
runs once and is deleted is the anti-pattern this gate exists to kill.

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
4. **Tier integration/performance tests separately.** They run in the slow
   tier (pre-merge or manual `workflow_dispatch`), not on every push — see
   [§1.3](#13-test-stratification--fast-vs-slow-tier). Fast tests stay in the
   fast tier; don't fragment the suite. New performance/integration/A-B
   tooling added by a PR must land in the slow tier wired and running, never
   as a dormant script.
5. **Keep the matrix honest.** If CI runs on one OS/Go/Node version, the
   project has implicitly pinned that version; surface it, don't hide it.
6. **Prefer reusable CI components over copy-pasted jobs.** When a change
   adds CI work (measurement, build matrix, environment setup), check whether
   a composite action or reusable workflow already exists — extend it, don't
   duplicate. If none exists, create a reusable component, not a one-off job.
   This keeps CI lean as it grows. (See [§1.4](#14-measurements-as-reproducible-ci-artifacts).)

Per-platform patterns live in [`platform-commands.md`](platform-commands.md)
for the *watch* side; the *run* side is project-defined via `TEST_COMMAND`.

## 4. The two gates, restated as a merge contract

A PR may merge only when **both** hold:

- **Test gate** — the change is covered by unit tests (mandatory, fast tier)
  and, where a suite exists, extended integration tests; those tests run and
  pass in CI. Performance/integration/A-B tooling added by the PR runs in the
  slow tier and passes before merge (or on manual trigger). A measurement
  relevant over time is wired in as a reusable slow-tier job, not an ad-hoc
  script (§1.4).
- **Coupling gate** — every coupling the change introduces is either part of
  the documented architecture, or recorded in the wiki (via `llm-wiki`) before
  merge, per the project's `COUPLING_POLICY`.

Red on either gate is fixed on the branch and re-pushed — never merged. These
sit alongside (not instead of) the lifecycle gates in `SKILL.md`.
