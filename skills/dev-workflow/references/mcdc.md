# MC/DC — Modified Condition/Decision Coverage

Load this reference when the project declares `SAFETY_LEVEL: mcdc` in its
AGENTS.md config block, or when a change touches a boolean decision with ≥4
conditions in a safety-relevant code path.

This is the depth page for the MC/DC rule stated in
[`ci-concepts.md` §1.5](ci-concepts.md). The rule: every boolean decision in
the changed code must prove that each condition independently affects the
outcome. The methodology is a **deterministic pipeline** — the agent's job is
translation, not boolean reasoning.

## What MC/DC proves

For a decision like `(a && b) || c`, branch coverage passes even if `b` is
always masked by `a=false`. MC/DC requires an **independence pair** for each
condition: two tests where only that condition flips and the decision outcome
flips with it. This catches the masked-condition bug class that branch and
condition coverage miss.

For N conditions in a Singular Boolean Expression (each variable appears once
— 99.7% of real decisions), the minimal test set is **N+1** vectors. For
non-SBEs (coupled conditions), use Masking MC/DC (⌈2√N⌉ vectors).

## The deterministic pipeline

```
Source ─► AST walk ─► boolean decisions ─► condition decomposition ─► SBE check
      ─► BDD construction ─► masking table ─► independence pairs ─► test vectors
      ─► constraint filter ─► mcdc-spec.json
```

Every step is deterministic. The output (`mcdc-spec.json`) is structured data
the agent translates into test code. The agent never evaluates boolean logic,
guesses test vectors, or decides which pairs to exercise.

## The spec format

The spec generator outputs JSON the agent consumes directly:

```json
{
  "decisions": [
    {
      "id": "src/safety.c:42:5",
      "function": "check_collision",
      "expression": "(a && b) || c",
      "conditions": [
        {"id": "a", "source": "speed > 0",      "line": 42},
        {"id": "b", "source": "altitude < 1000", "line": 42},
        {"id": "c", "source": "mode == ALERT",   "line": 42}
      ],
      "sbe": true,
      "flavor": "unique-cause",
      "test_vectors": [
        {"id": "v0", "values": {"a": true,  "b": true,  "c": false}, "outcome": true},
        {"id": "v1", "values": {"a": false, "b": true,  "c": false}, "outcome": false},
        {"id": "v2", "values": {"a": true,  "b": false, "c": false}, "outcome": false},
        {"id": "v3", "values": {"a": true,  "b": true,  "c": true},  "outcome": true}
      ],
      "independence_pairs": [
        {"condition": "a", "pair": ["v0", "v1"]},
        {"condition": "b", "pair": ["v0", "v2"]},
        {"condition": "c", "pair": ["v1", "v3"]}
      ],
      "unsatisfiable": false
    }
  ]
}
```

## The agent playbook

### Step 1 — Ensure the spec generator exists

Check for a committed harness script (`scripts/mcdc-spec` or
`scripts/mcdc-spec.py`). This is a §3 committed-runner — it lives in the repo,
versioned, called by CI. If it does not exist, build it. The generator is a
PLUGIN SCRIPT (Python is allowed for scripts, not for framework runtime).

The generator has two parts:

1. **Language-specific extractor** — walks the AST, finds boolean decisions
   (`if`/`while`/`?:` containing `&&`/`||`), extracts atomic conditions with
   source locations. Pattern per language:
   - C/C++: libclang (`clang.cindex`) or `clang -E` + regex
   - Go: `go/ast` (`BinaryExpr` nodes with `&&`/`||` operators)
   - Rust: `syn` crate (`Expr::Binary`)
   - Python: `ast` module (`BoolOp` nodes)
   - Zig: `std.zig.Ast` (`ast.Node.IfStmt` / `.WhileStmt` with bool exprs)
2. **Language-agnostic analyzer** — takes extracted boolean expressions,
   builds reduced ordered BDDs, computes the masking table (GCC 14 algorithm:
   BDD vertices with in-degree ≥ 2), finds independence pairs, constructs the
   minimal test set (Robin's Rule for SBEs). This part is the same for every
   language.

Key: the generator must be **deterministic** — same source, same output, same
order. No randomization, no heuristic search. Robin's Rule is a direct
construction algorithm; the BDD is canonical given variable ordering.

### Step 2 — Generate the spec

```bash
python3 scripts/mcdc-spec.py src/ --output mcdc-spec.json
```

Review the output. If any decision has `"unsatisfiable": true`, the condition
is coupled and cannot achieve Unique-Cause MC/DC — flag it on the issue and
fall back to Masking MC/DC for that decision.

### Step 3 — Translate vectors into tests

For each decision in the spec, for each test vector:
- Use the **condition→input mapping** (how to set each atomic condition to
  true/false via concrete function inputs — e.g. `speed > 0` ←
  `set_speed(100)` for true, `set_speed(-1)` for false). Derive this from the
  function signature and the condition source text.
- Write a test that sets those inputs, calls the function, and asserts the
  expected `outcome` from the spec.

The agent does NOT evaluate the boolean expression — it trusts the spec's
pre-computed outcomes. The test is a translation: `values` → concrete setup,
`outcome` → assertion.

### Step 4 — Wire coverage measurement into CI (slow tier)

MC/DC coverage is a **measurement relevant over time** (§1.4) — it belongs in
the slow tier as a reusable job, triggered pre-merge for safety-critical paths
or manually (`workflow_dispatch`).

| Language | Instrumentation | Measurement | Notes |
|----------|----------------|-------------|-------|
| **C/C++ (GCC 14+)** | `gcc -fcondition-coverage` | `gcov --conditions` | Masking MC/DC, native |
| **C/C++ (Clang 17+)** | `clang -fcoverage-mcdc` | `llvm-cov show --show-mcdc` | Masking MC/DC, native |
| **Ada** | GNATprove / GNATcoverage | `gnatcov coverage --level=mcdc` | Native |
| **Rust** | `RUSTFLAGS="-C instrument-coverage"` | branch/condition proxy | MC/DC-optimal tests, branch-coverage measurement |
| **Go** | `go test -covermode=count` | branch/condition proxy | same |
| **Python** | `coverage.py --branch` | branch/condition proxy | same |
| **Zig** | `zig build test` | branch/condition proxy | same |

For languages with native MC/DC (C/C++/Ada), the compiler instruments the
code, the test suite runs, and the coverage tool reports which independence
pairs were exercised. **The gate is binary**: 100% of required pairs exercised,
or fail.

For languages without native MC/DC, the spec generator still produces
MC/DC-optimal test vectors (the test *design* is deterministic and provably
minimal). Branch/condition coverage serves as a proxy: if the test suite
achieves 100% branch coverage AND the vectors are MC/DC-optimal, the boolean
logic is exercised at least as thoroughly as native MC/DC. Document this
limitation in the PR.

### Step 5 — Set the gate

The CI job fails if any required independence pair is not exercised:

```yaml
# Slow-tier job (pre-merge for SAFETY_LEVEL: mcdc)
mcdc-coverage:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Build with MC/DC instrumentation
      run: gcc -fcondition-coverage -c src/*.c
    - name: Run tests
      run: ./run_mcdc_tests
    - name: Measure MC/DC
      run: gcov --conditions src/*.gcda
    - name: Gate
      run: |
        python3 scripts/mcdc-gate.py --threshold 100 --spec mcdc-spec.json
    - uses: actions/upload-artifact@v4
      with:
        name: mcdc-report
        path: mcdc-report.json
```

The `mcdc-gate.py` script reads the compiler's coverage report and the spec,
checks every independence pair was exercised, and fails with a precise
diagnostic on any gap (which condition, which pair, which test vector is
missing). Results are uploaded as artifacts for regression tracking across
time (§1.4).

## Graceful degradation

When the language has no native MC/DC compiler support:

1. **Test design is still MC/DC-optimal** — the spec generator produces the
   same N+1 minimal vectors regardless of language. The test suite exercises
   every independence pair by construction.
2. **Measurement is approximate** — branch/condition coverage confirms
   execution but cannot prove independence. Document this in the PR: "MC/DC
   test design achieved (N+1 vectors, all independence pairs); coverage
   measured via branch proxy."
3. **The gap is in measurement, not design** — the tests are still more
   rigorous than random or branch-guided tests because the vector selection
   is provably minimal and covers every condition's independent effect.

## Relationship to the gate chain

MC/DC coverage is a **strengthening of Gate 6** (test coverage) for
`SAFETY_LEVEL: mcdc` projects. Instead of "unit tests cover the behavior"
(Gate 6 floor), the requirement is "every boolean condition is proven to
independently affect the decision." This sits in the slow tier alongside other
measurements (§1.4) — not on every push, but before merge for safety-critical
paths.
