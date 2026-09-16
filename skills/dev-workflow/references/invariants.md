# The merge contract and the five CI-conformance invariants

Depth page for gates 10–11 enforcement and the `dw_ci_conformance`
command. Companion pages: [test-policy.md](test-policy.md) (what runs in
each tier), [ci-wiring.md](ci-wiring.md) (the purpose audit and command
resolution).

## The two gates, restated as a merge contract

A PR may merge only when **both** hold:

- **Test gate** — the change is covered by unit tests (mandatory, fast
  tier) and, where a suite exists, extended integration tests; those tests
  run and pass in CI. Performance/integration/A-B tooling added by the PR
  runs in the slow tier and passes at ready declaration before merge. A
  measurement relevant over time is wired in as a reusable slow-tier job,
  not an ad-hoc script.
- **Coupling gate** — every coupling the change introduces is either part
  of the documented architecture, or recorded in the wiki (via
  `llm-wiki`) before merge, per the project's `COUPLING_POLICY`.

Red on either gate is fixed on the branch and re-pushed — never merged.
These sit alongside (not instead of) the lifecycle gates in `SKILL.md`.

## The five invariants (cross-platform pattern layer)

Pipelines stay free-form: platforms, tiers, and shapes differ per project
by design. Conformance is **conceptual** — a fixed set of properties any
shape must satisfy, enforced by static validation of the native CI files.
No new CI application; the validator (`scripts/ci-conformance.py`, exposed
as `dw_ci_conformance`) is a linter the agent and the repo's own fast tier
run.

- **I1 — Check equivalence.** A logical check (lint, test, build, …) runs
  the same *normalized commands* on every backend that claims to run it.
  Normalization strips env prefixes, cache wrappers (`$(…)`
  substitutions), and whitespace — `zig build test $(tools/zig-cache.sh
  ci)` ≡ `zig build test`.
- **I2 — Matrix coherence.** Every leg of a matrix axis (runner, arch,
  accelerator) runs the same check set. Legs differ in *how* (toolchain
  fetch, cache paths), never in *what* is verified.
- **I3 — Justified non-suitability.** A leg that cannot run a check does
  not silently skip: the condition carries an adjacent machine-findable
  marker — `# not-suitable: runner=<token> — <reason>` — naming a
  **capability** (`requires CUDA device`, `missing rocm`), never a
  preference. The validator checks the marker statically; the runtime half
  is checked in strict repos by `dw_watch_ci`'s context classification and
  fleet audits.
- **I4 — No silent divergence.** Any check-inventory difference across
  backends or matrix legs not covered by I3 is a conformance failure.
- **I5 — Naming consistency.** One concept, one token. Job ids are kebab
  (`[a-z0-9]+(-[a-z0-9]+)*`); matrix values are runner tokens; status
  contexts decompose to tokens (`ci / test-arm64` → `test-arm64`);
  free-text expansions (`inputs.*`, `github.event.*`) never appear in a
  display name. Synonym detection is content-driven: the same normalized
  command under two job tokens is a duplicate-concept finding; one token
  under different commands across backends is an I1 collision.
  Dev-workflow helpers bind only via tokens (`dw_context_gate`) — when a
  repo's contexts don't parse, fix the workflow, not the helper.

**Checks preservation (policy beyond the five).** With a base ref, the
validator diffs normalized command inventories: a check present at base
and absent at head is a finding. CI checks are never *removed* — when a
naming or structure rule displaces one, it is **shifted into a separate
step/job (or tier)**, and the finding disappears because the command still
exists. Genuine obsolescence is justified to the reviewer, not silently
dropped.

**Severity and adoption.** Findings are `VIOLATION` (breaks an invariant)
or `ADVISORY` (likely drift, parser gap, vocabulary not yet adopted). A
repo runs advisory until it opts in with a `.ci-conformance` file
containing `strict` (or `dw_ci_conformance --strict`); strict mode fails
on violations. The framework stays O(invariants), not O(shapes): a
brand-new pipeline layout needs no contract change — only I1–I5.

**Deliberately out of scope:** dictating job structure, tier layout, file
names, or a global token registry. Projects extend the vocabulary by
declaring tokens in-repo; fleet-level comparison
(`dw_ci_conformance --fleet`) is advisory, surfacing convergence
opportunities without enforcing them.
