# The per-change procedure — full bash

Load this when making a change. The gate-chain summary lives in
[`SKILL.md`](../SKILL.md); this is the executable form. From the project
repo:

```bash
source "$(dirname "$(readlink -f "$0")")/scripts/host.sh"   # or source the absolute skill path
```

1. **Consult the wiki** for the project's documented design
   (`/skill:llm-wiki` `consult`/`read`) — entities, concepts, ADRs.
2. **Resolve the issue.** Search, else create:
   ```bash
   ISSUE=$(dw_find_issue "<short task description>")
   [ -z "$ISSUE" ] && ISSUE=$(dw_create_issue "<Title>" "<Body with acceptance criteria>")
   ```
3. **Resolve the branch.** Find by issue number, else create off the default branch:
   ```bash
   BRANCH=$(dw_find_branch_for_issue "$ISSUE")
   if [ -z "$BRANCH" ]; then
     BRANCH="feat/${ISSUE}-<slug>"
     dw_create_branch "$BRANCH"
   else git switch "$BRANCH"; fi
   ```
4. **Assign a milestone** (convention from the project's AGENTS.md):
   ```bash
   M=$(dw_resolve_milestone current)        # → "<id>:<title>"
   dw_set_milestone "$ISSUE" "${M%%:*}"
   ```
5. **Make the change** on the branch, **including its tests** — consolidate:
   before adding any test, tool, or CI job, audit the entire CI surface for
   a check that already achieves the purpose — extend or move it, never
   duplicate it; the same applies to tooling and wiki pages (see
   [ci-wiring.md](ci-wiring.md)). If the change introduces coupling not
   part of the documented design, document it in the wiki now
   (`/skill:llm-wiki`). Commit with `Refs #$ISSUE`.
6. **Simplification pass** — re-read the full diff (`git diff` against the
   default branch). Ask: "can this be simpler?" Remove dead code, collapse
   redundant abstractions, eliminate speculative generality. If you change
   code, re-verify locally before proceeding. (Gate 8; hard rule 5.)
7. **Green locally first — the PR is the expensive step:**
   ```bash
   dw_run_tests || { echo "local tests red — fix before pushing"; exit 1; }
   ```
   Run the project's fast-tier workloads locally (build + lint +
   `dw_run_tests`) until green and the simplification pass (gate 8) is
   done. Opening a PR consumes CI on the forge — push and open it **once**,
   when the local mirror is green. Probe the conflict state BEFORE pushing:
   a branch that conflicts with the default branch is DIRTY, and GitHub
   creates no merge ref for a DIRTY PR — `pull_request` workflows silently
   never run, which reads as "CI is slow" but is actually "CI is absent":
   ```bash
   git fetch origin "$(dw_default_branch)" -q
   git merge-tree --write-tree "HEAD" "origin/$(dw_default_branch)" >/dev/null 2>&1 \
     || { echo "branch conflicts with $(dw_default_branch) — rebase BEFORE pushing (CI will not run otherwise)"; exit 1; }
   git push -u origin "$BRANCH"
   dw_open_pr "$BRANCH" "$(dw_default_branch)" "<title>" "Closes #$ISSUE"
   ```
8. **Fast CI confirms on a clean runner** (it re-runs what you ran
   locally):
   ```bash
   dw_watch_ci "$BRANCH" || { echo "fast CI red — fix on the branch and re-push"; exit 1; }
   ```
   **"No checks reported" is a STATE, not slowness.** On GitHub, check
   `gh pr view --json mergeStateStatus` first: `DIRTY`/`CONFLICTING` means
   the merge ref could not be created, so **no workflow will ever run for
   this PR** — no amount of waiting or reopen cycles helps. Rebase onto
   the default branch (carrying only this branch's changes) and force-push
   the branch; runs appear within a minute. On Forgejo the same state is
   the PR's `mergeable == false`.
   If the change touched workflow files, CI conformance must hold:
   ```bash
   dw_ci_conformance "origin/$(dw_default_branch)" \
     || { echo "CI conformance red — satisfy I1–I5 (shift checks, never delete)"; exit 1; }
   ```
9. **Declare ready — full pipeline, review (when armed), merge:**
   ```bash
   PR=$(dw_pr_number_from_branch "$BRANCH")
   dw_rebase_onto_default "$BRANCH"        # hard rule 3 — BEFORE triggering
   dw_trigger_full_pipeline "$PR"          # gate 11: sets the full-pipeline label; REFUSES unrebased heads (no-op if none configured)
   dw_watch_full_pipeline "$BRANCH" || { echo "full pipeline red — fix, re-push, re-declare"; exit 1; }
   dw_request_review "$PR"                 # gate 12 — ONLY when adversarial review is required (opt-in)
   dw_wait_review "$PR"                    # blocks for the verdict trailer — skip when not armed
   dw_merge_pr "$PR" squash                # gate 13 — refuses unless merge-ready
   ```
   A REQUEST_CHANGES verdict means: address the findings — for each, sweep
   for the class first (hard rule 6): an isolated mistake is fixed at its
   instance; a repeated pattern takes the structural fix (every instance +
   root cause: component refactor, or an architectural-change proposal when
   it exceeds this PR). Resolve every thread as its fix lands — on Forgejo
   `fj review resolve <PR> <COMMENT-ID>` is the standard close-out — then,
   when everything is done, the actual replies (`fj review reply`,
   `in_reply_to`, discussion notes) carry `path:line → fix SHA + rationale`
   as the round record (TODOs too). Re-run this step — the new head SHA
   re-opens gates 11 and 12. When adversarial review was not armed, gate
   11 green is enough — merge.

The agent is not bound to these exact commands — they illustrate the dispatch.
Load [`platform-commands.md`](platform-commands.md) for the raw per-platform
forms and token env vars when adapting.
