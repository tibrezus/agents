# Wiring tests into CI — so the gate is real

Depth page for the CI-discipline wiring mandates. The local `dw_run_tests`
mirror and the CI pipeline must run the **same** suite, or the local loop
lies. If you are writing a script to validate your change that is not part
of the project's test infrastructure — stop: extend the existing suite, or
wire your tool into CI. A script that runs once and is deleted is the
anti-pattern this gate exists to kill.

## CI code is expensive — run the purpose audit first

CI is the most expensive code a repository carries, and the bill recurs
forever: every line runs again on every future push, whether or not anyone
remembers why. The costs compound:

- **Runner minutes** — each check paid on every push, PR, and re-run;
  a duplicate doubles the bill without doubling coverage.
- **Maintenance** — two checks with one purpose drift; both kept green,
  updated, migrated forever.
- **Signal dilution** — with two homes, neither is the contract; a flaky
  copy cries wolf until the real failure is dismissed.
- **Feedback loop** — dead weight in the fast tier taxes every change.

Before adding **any** CI logic — test, job, step, tool — run the
**purpose audit**, *before writing the first line of CI code*:

1. **Enumerate the entire CI surface** — every native CI file
   (`.github/workflows/`, `.forgejo/`, `.gitea/`, `.gitlab-ci.yml`) plus
   everything CI invokes: Makefile targets, `scripts/test`, composite
   actions, reusable workflows. A purpose often lives outside the YAML —
   a `tidy` Makefile target *is* a dependency-drift check once CI calls it.
2. **Reduce every existing check to its purpose** — the defect class it
   catches ("dependency drift", "unformatted sources", "CRD schema
   pruning"), not the command implementing it today.
3. **State the new check's purpose** and compare against the map:

| Audit result | Action |
|---|---|
| Purpose achieved, wrong form (manual, local-only, wrong tier/trigger) | **Move** the logic so the purpose becomes always-on or correctly tiered. One home, new shape. |
| Purpose achieved, form right | **Stop.** Add nothing. |
| Purpose partially covered | **Extend** the existing check; never open a parallel one. |
| Genuinely new purpose | Add it — once, in the tier its runtime belongs in. |

The canonical *move*: a check that runs only when someone remembers
(`make tidy`, a laptop lint script) is re-homed into CI so it runs always —
that relocates a purpose, it does not duplicate it. The anti-pattern:
writing a second copy into CI while the first survives elsewhere.

**The conservation law** (pairs with checks-preservation in
[invariants.md](invariants.md)): **a purpose has exactly one home in CI.
Checks move between homes; they are never cloned and never orphaned.**
Invariants.md forbids the removal half (a check may not vanish in a
refactor); this audit forbids the addition half (a purpose may not be
re-homed by copy-paste). `dw_ci_conformance` validates structure; whether a
*new* check's purpose collides stays a judgment call — **state the audit
result on the PR** (which existing checks were considered, why the new one
is not a duplicate) so the reviewer can falsify it.

## How the test command is resolved

Project-owned, not skill-owned. `dw_run_tests` (and the `Test command:`
`adopt` suggests) resolve, highest first:

1. **`CI_TEST_COMMAND` env var** — explicit session override.
2. **A committed runner in the repo** (language-agnostic, **preferred**) —
   `scripts/test` (executable), `scripts/test.sh`, `bin/test`, or a
   Makefile `test:` target. **What scales across projects:** the project
   commits its real command with real flags; the skill never needs editing.
3. **Language heuristics** (zero-config fallback) — `package.json`→
   `npm test`, `go.mod`→`go test ./...`, `build.zig`→`zig build test`,
   `Cargo.toml`→`cargo test`, `pyproject.toml`/`setup.py`→`pytest`,
   `meson.build`→`meson test`, `CMakeLists.txt`→ configure→build→`ctest`.

The heuristic list is deliberately short. **C/C++/CMake are
build-config dependent** (build dir, presets, toolchain) — commit
`scripts/test` with the real invocation. Same for monorepos,
containerised suites, bespoke harnesses. New stack ⇒ commit a runner (2)
or set `CI_TEST_COMMAND` (1), never edit the skill.

## When setting up or updating CI

1. **CI runs the project's real test command** (precedence above) — not a
   subset or a guess.
2. **Fail the build on test failure** — no `|| true`, no
   `continue-on-error` on the test job.
3. **Discover tests automatically** — new test files picked up without
   editing CI config.
4. **Tier integration/performance separately** — slow tier at ready
   declaration, never every push ([test-policy.md](test-policy.md)); new
   perf/integration/A-B tooling lands wired and running, never dormant.
5. **Keep the matrix honest** — one OS/Go/Node version in CI is an
   implicit pin; surface it.
6. **Prefer reusable components** — composite action or reusable workflow
   over copy-pasted jobs; create the reusable component if none exists.
7. **Run the purpose audit before adding anything** (above).

Per-platform *watch* patterns: [`platform-commands.md`](platform-commands.md);
the *run* side is project-defined via a committed runner or
`CI_TEST_COMMAND`.
