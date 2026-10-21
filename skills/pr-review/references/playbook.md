# Playbook — per-pillar depth recipes

Load this when a pillar needs more than its quick pass. Each recipe has
two modes: **with a map** (the project maintains an architecture map,
dependency graph, or design wiki) and **without** (derive structure from
the code itself). A suspicion becomes a finding only when it survives an
attempt to falsify it.

## Boundaries (structural fit)

With a map: read the touched components' edges. Every new cross-component
call in the diff must correspond to an existing or newly documented edge;
an undocumented edge is a finding. Check the shape stays scalable: no new
cycles, no component turning into a hub everything reaches through.

Without: extract the diff's new imports/calls; draw the component boundary
by directory or module root; any call crossing it gets the same question:
*is this crossing legitimate?* — answered by the project's docs, or by a
comment/structure that clearly sanctions it. A crossing nobody sanctions
is a finding.

## Design intent (alignment + duplication)

With a map: search the whole graph for the capability the diff adds — a
matching export anywhere means *extend, don't duplicate*. Near-identical
shapes (paraphrased copies) count as duplication too.

Without: search the repo for the new symbol names and for what the new
code *does* in plain words ("parse", "retry", "cache", "validate"). Read
the design docs the project keeps, wherever they live. A second
implementation of an existing capability is a finding; a new export that
nothing will ever call is also a finding (dead surface).

Also verify the change does not contradict a documented decision. When
the PR's author also authored that decision, give its load-bearing
assumptions an extra adversarial pass.

## Interface stability

List the exported/public symbols, API routes, schema shapes, or stored
data formats the diff modifies. Search the repo for every usage. A change
that breaks a caller without a version bump, migration, or compat shim is
a finding — cite the caller.

## CI cost

Every check runs on every future push, forever. When the diff adds or
moves CI work: enumerate the project's whole check surface (workflows,
invoked runners, scripts CI calls), state each check's **purpose** in one
line (the defect it catches), and compare the diff's additions against
that map. A new check whose purpose an existing check already achieves,
the same purpose re-homed by copy-paste, or a new purpose placed in the
wrong tier (per-push work that belongs nightly, or vice versa) is a
finding. Inefficiency inside a legitimate check (no caching, unbounded
matrix, missing cancellation) is a minor note.

Test quality hunts *missing* coverage; CI cost hunts *redundant*
coverage — together they bound the test delta from both sides.

## Correctness

Read the changed logic line by line with the adversarial question: *what
input, state, or ordering breaks this?* Check: error paths (swallowed
errors, wrong fallback), boundaries (empty, one, max, off-by-one),
concurrency (races, deadlocks, check-then-act), invariants (validate them
at the edges they can break). Run the project's tests for the touched
parts. When a call-chain question matters — who reaches this path, what
breaks if this invariant flips — trace it from the call sites, not from
the function's name.

## Security

For diffs touching auth, crypto, network, SQL, or input parsing: check
injection at every boundary (strings into commands, queries, paths, URLs),
authorization on every new route/handler (who may call it, is that
enforced server-side), secrets handling (logs, errors, caches), and
deserialization of untrusted data. If you have a search tool, check the
specific functions/patterns against current advisories. Cite the pattern;
name the advisory when one exists.

## Performance

Identify the hot path the diff touches (a request handler, a per-item
loop, an allocator). Check algorithmic complexity (does a loop now hide a
loop?), allocation churn, unbounded growth (maps/slices/channels that
only grow), and leaked resources (handles, connections, goroutines,
timers) on every path — especially error paths. Run the project's
benchmarks for the touched code if they exist.

## Observability

Walk every new error and async path in the diff: is the failure logged or
surfaced with enough context to debug it (what failed, on what, why)?
A silent error path — swallowed return, empty catch, fire-and-forget
async — is a finding. New user-visible behavior needs a way to answer
"did it happen?" in production: a log line, a metric, a trace span.

## Test quality

Tests must pin **behavior through public interfaces**, not implementation
details (a test coupled to internals breaks on every refactor and guards
nothing). For each behavior the diff adds or alters: is there a test?
Does it cover the edges the correctness pass found (empty, max,
concurrent)? Missing tests for new behavior is a finding. Prefer
extending an existing suite over creating a parallel one.

## Hardened checks — apply when a finding leans on them

**Mutation probe.** When your confidence rests on "the tests catch
this": change the guarded value to nonsense, run the suite, require red,
revert. A test that still passes guards nothing.

**One fact, one home.** When a fix updates a stated fact — a limit, a
name, a chain, a constant — search for every other home of that fact
(comments, docblocks, docs pages, sibling constants) and verify each was
updated. A stale second home is a finding.

**Manifest-grounded deployment claims.** Any claim about durability,
environment, volumes, topology, or configuration is verified against the
actual manifests and runtime wiring — never against a doc's prose. Prose
says what was intended; the manifest says what is.

## Repository wiki (context gathering, #726)

When the workspace carries `/workspace/repo-wiki/` — the reviewed
repository's OWN architecture documentation (a different artifact from
the project wiki): consult it BEFORE structural grepping. Order of
consultation across the whole review: the coverage ledger and research
layer (what prior rounds established), then the repo wiki's standard
docs — `DESIGN.md`, `TOBE.md`, `ARCHITECTURE.md`, and the other
top-level `*.md` — then the tree itself.

Use it for: component boundaries (the Boundaries pillar's "map" mode —
the documented architecture IS a map), documented decisions (Design
intent's contradiction check), and naming/structure expectations. A
finding may cite the doc and section a change deviates from ("conflicts
with TOBE.md §deploy").

Direction beats divergence: the docs are context, not gospel. A PR
moving the code TOWARD the documented TOBE state complies even where it
diverges from the current AS-IS tree. Report a doc/code divergence as a
finding only when the PR moves AWAY from the documented direction — and
when the docs themselves look stale (paths that no longer exist,
components renamed), say so in the finding or coverage note and let the
author decide which side moves.

## Pillar scan (#727 discipline)

Walk the pillars breadth-first, one proven gap at a time: scan a
pillar → when a finding is PROVEN (it survived its falsification
attempt), POST its anchored thread immediately → switch to the next
pillar. After the first pass, return for the deep proofs of the
remaining uncertainties. The proof bar never moves — nothing
unverified is posted, ever.

Posting per pillar is what makes the review asynchronous for the
author: fix work on proven findings starts while the round continues
on the next pillar. Record each posted thread's reference in
review.json (`thread_ref`) — the pipeline's gate counts posted threads
exactly as it counts pipeline-posted ones, and its publisher publishes
only what was never posted.
