# MC/DC — Modified Condition/Decision Coverage

Load when the project declares `SAFETY_LEVEL: mcdc` in its AGENTS.md config
block, or a change touches a boolean decision with ≥4 conditions in a
safety-relevant path. Depth page for the rule in
[test-policy.md](test-policy.md): every boolean decision in changed code
must prove each condition independently affects the outcome. The
methodology is a **deterministic pipeline** — the agent's job is
translation, not boolean reasoning.

## What MC/DC proves

For `(a && b) || c`, branch coverage passes even if `b` is always masked
by `a=false`. MC/DC requires an **independence pair** per condition: two
tests where only that condition flips and the decision outcome flips with
it — catching the masked-condition bug class. For N conditions in a
Singular Boolean Expression (each variable appears once — 99.7% of real
decisions), the minimal test set is **N+1** vectors; for non-SBEs use
Masking MC/DC (⌈2√N⌉).

## The deterministic pipeline

```
Source ─► AST walk ─► boolean decisions ─► condition decomposition ─► SBE check
      ─► BDD construction ─► masking table ─► independence pairs ─► test vectors
      ─► constraint filter ─► mcdc-spec.json
```

Every step is deterministic; the output (`mcdc-spec.json`) is structured
data the agent translates into test code. The agent never evaluates
boolean logic, guesses vectors, or decides pairs. Spec shape:

```json
{"decisions": [{
  "id": "src/safety.c:42:5", "function": "check_collision",
  "expression": "(a && b) || c",
  "conditions": [
    {"id": "a", "source": "speed > 0",       "line": 42},
    {"id": "b", "source": "altitude < 1000", "line": 42},
    {"id": "c", "source": "mode == ALERT",   "line": 42}],
  "sbe": true, "flavor": "unique-cause",
  "test_vectors": [
    {"id": "v0", "values": {"a": true,  "b": true,  "c": false}, "outcome": true},
    {"id": "v1", "values": {"a": false, "b": true,  "c": false}, "outcome": false},
    {"id": "v2", "values": {"a": true,  "b": false, "c": false}, "outcome": false},
    {"id": "v3", "values": {"a": true,  "b": true,  "c": true},  "outcome": true}],
  "coverage": {"required_pairs": ["a", "b", "c"], "satisfied_by": {"a": ["v0","v1"], "b": ["v0","v2"], "c": ["v1","v3"]}}
}]}
```

## The agent playbook

### Step 1 — Ensure the spec generator exists

Check for a committed harness (`scripts/mcdc-spec[.py]`) — a committed
runner (ci-wiring.md resolution rule), versioned, called by CI. If absent,
build it. Two parts:

1. **Language-specific extractor** — walks the AST for boolean decisions
   (`if`/`while`/`?:` with `&&`/`||`), extracts atomic conditions with
   source locations. C/C++: libclang or `clang -E` + regex; Go:
   `go/ast` (`BinaryExpr`); Rust: `syn`; Python: `ast.BoolOp`; Zig:
   `std.zig.Ast`.
2. **Language-agnostic analyzer** — builds reduced ordered BDDs, computes
   the masking table (GCC 14 algorithm: BDD vertices with in-degree ≥ 2),
   finds independence pairs, constructs the minimal set (Robin's Rule for
   SBEs). Same for every language.

The generator must be **deterministic** — same source, same output, same
order. No randomization, no heuristic search; Robin's Rule is direct
construction, the BDD canonical given variable ordering.

### Step 2 — Generate the spec

```bash
python3 scripts/mcdc-spec.py src/ --output mcdc-spec.json
```

Review the output: any decision with `"unsatisfiable": true` has coupled
conditions and cannot achieve Unique-Cause MC/DC — flag it on the issue,
fall back to Masking MC/DC for that decision.

### Step 3 — Translate vectors into tests

For each decision, each vector: use the **condition→input mapping** (how
to set each atomic condition via concrete function inputs — `speed > 0` ←
`set_speed(100)` / `set_speed(-1)`), derived from the signature and the
condition source text. The test sets those inputs, calls the function,
asserts the spec's `outcome`. The agent does NOT evaluate the boolean
expression — it trusts the pre-computed outcomes; the test is a
translation.

### Step 4 — Wire coverage measurement into CI (slow tier)

MC/DC coverage is a measurement over time (test-policy.md) — slow tier,
reusable job, pre-merge for safety-critical paths or `workflow_dispatch`.

| Language | Instrumentation | Measurement | Notes |
|----------|----------------|-------------|-------|
| **C/C++ (GCC 14+)** | `gcc -fcondition-coverage` | `gcov --conditions` | Masking MC/DC, native |
| **C/C++ (Clang 17+)** | `clang -fcoverage-mcdc` | `llvm-cov show --show-mcdc` | Masking MC/DC, native |
| **Ada** | GNATprove / GNATcoverage | `gnatcov coverage --level=mcdc` | Native |
| **Rust / Go / Python / Zig** | standard coverage flags | branch/condition proxy | MC/DC-optimal tests, proxy measurement |

With native MC/DC, the compiler instruments, the suite runs, the tool
reports which independence pairs were exercised. **The gate is binary**:
100% of required pairs exercised, or fail. Without native MC/DC, the
generator still produces MC/DC-optimal vectors (provably minimal design);
100% branch coverage + optimal vectors exercises the logic at least as
thoroughly as native MC/DC — document the proxy limitation in the PR.

### Step 5 — Set the gate

The CI job fails if any required independence pair is not exercised —
slow-tier job (`SAFETY_LEVEL: mcdc`): checkout → build with
instrumentation (`gcc -fcondition-coverage`) → run tests → measure
(`gcov --conditions`) → `python3 scripts/mcdc-gate.py --threshold 100
--spec mcdc-spec.json` → upload the report as an artifact (regression
tracking over time). `mcdc-gate.py` reads the compiler's coverage report
and the spec, checks every independence pair was exercised, and fails
with a precise diagnostic on any gap (which condition, which pair, which
vector is missing).

## Graceful degradation

When the language has no native MC/DC compiler support:

1. **Test design is still MC/DC-optimal** — the generator produces the
   same N+1 minimal vectors regardless of language; the suite exercises
   every independence pair by construction.
2. **Measurement is approximate** — branch/condition coverage confirms
   execution but cannot prove independence. Document in the PR: "MC/DC
   test design achieved (N+1 vectors, all independence pairs); coverage
   measured via branch proxy."
3. **The gap is in measurement, not design** — the tests remain more
   rigorous than random or branch-guided tests: vector selection is
   provably minimal and covers every condition's independent effect.

Coupled conditions (non-SBE, `"unsatisfiable": true`): fall back to
Masking MC/DC for that decision (step 2). No boolean decisions with ≥2
conditions in the diff: MC/DC is trivially satisfied — state it on the PR.
Generator cannot parse a construct: flag it on the issue; never hand-wave
coverage for a decision the spec missed.

## Relationship to the gate chain

Gate 6 requires MC/DC when `SAFETY_LEVEL: mcdc` is set; the slow tier
(gate 11) runs the measurement; `dw_merge_readiness` requires it green at
the merge SHA alongside the other gates.
