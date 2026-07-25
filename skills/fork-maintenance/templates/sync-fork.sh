#!/usr/bin/env bash
# =============================================================================
# sync-fork.sh — Universal fork sync engine (MERGE model)
# =============================================================================
# Merges the upstream release branch INTO the fork's release branch (off a sync
# branch → PR), runs post-merge hooks, verifies patches + divergence integrity,
# validates, and opens a host-routed PR. Merge model (Codeberg-style): the fork's
# release branch carries our customizations as immutable commits; each sync
# appends an upstream merge, so custom SHAs never change (append-only, bisectable,
# no replay/accumulation). Conflicts are localized 3-way regions — the ideal
# substrate for the LLM conflict-resolver (resolve-conflict.sh). Parameterized by
# a fork definition YAML.
#
# Usage: sync-fork.sh <fork-name>
# Example: sync-fork.sh forgejo
#
# Requires: git, gh (GitHub CLI), yq, bash
# Environment: GITHUB_TOKEN (PAT with repo + workflow scope on rezuscloud/* forks)
#
# The fork definition (forks/<name>.yaml) specifies upstream URL/branch, fork
# URL/branches, patches with signatures, additive paths, and a post-merge hook.
# =============================================================================
set -euo pipefail

FORK_NAME="${1:?Usage: sync-fork.sh <fork-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MAINT_DIR is the parent of scripts/ — either platform/fork-maintenance/ in the
# repo, or /workspace/ in the CronJob (ConfigMap mount).
MAINT_DIR="$(dirname "$SCRIPT_DIR")"
DEF_FILE="$MAINT_DIR/forks/${FORK_NAME}.yaml"

if [ ! -f "$DEF_FILE" ]; then
  echo "ERROR: fork definition not found: $DEF_FILE" >&2
  exit 1
fi

echo "=== Loading fork definition: $FORK_NAME ==="

# Parse YAML definition into shell variables
read_yaml() { yq -r "$1" "$DEF_FILE"; }

# Deliver a fork.conflict.needs-resolution event (structured needs-fix payload) to
# the conflict-resolver. Delivered by direct HTTP POST to the resolver's /events
# endpoint (conflict-subscriber.py), with retries. We previously routed this
# through Dapr pub/sub (pubsub.redis), but Redis pub/sub is fire-and-forget —
# events published while the resolver was restarting were silently lost, AND the
# daprd sidecar in the sync Job never terminated so the Job hung and re-emission
# (every 30m) never happened. Direct HTTP fixes both. The payload is ALWAYS
# written to manifests/<fork>-needs-fix.json first (audit / manual-runs fallback).
# See skill/references/conflict-resolution.md "Agentic integration shape".
emit_conflict_event() {
  local cfiles="${1:-}" payload patches_json pcount i
  patches_json="[]"
  pcount=$(read_yaml '.patches | length' 2>/dev/null || true)
  for i in $(seq 0 $((pcount - 1))); do
    local pf ps pd st="LOST"
    pf=$(read_yaml ".patches[$i].file"); ps=$(read_yaml ".patches[$i].signature"); pd=$(read_yaml ".patches[$i].description")
    if [ -f "$pf" ]; then { [ "$(grep -cF "$ps" "$pf" 2>/dev/null || true)" -gt 0 ] && st="OK"; } || st="LOST"; else st="MISSING"; fi
    patches_json=$(echo "$patches_json" | jq --arg f "$pf" --arg s "$ps" --arg d "$pd" --arg st "$st" '. += [{file:$f,signature:$s,description:$d,status:$st}]')
  done
  payload=$(jq -n \
    --arg fork "$FORK_NAME" \
    --arg upstream_url "$UPSTREAM_URL" --arg upstream_branch "$UPSTREAM_BRANCH" \
    --arg upstream_range "${MERGE_BASE:0:12}..${UPSTREAM_HEAD:0:12}" \
    --argjson patches "$patches_json" \
    --arg conflict_files "$cfiles" \
    '{fork:$fork, upstream_url:$upstream_url, upstream_branch:$upstream_branch,
      upstream_range:$upstream_range, patches_at_risk:$patches,
      conflict_files: ($conflict_files | split("\n") | map(select(length>0)))}')
  mkdir -p "$MAINT_DIR/manifests" 2>/dev/null || true
  echo "$payload" > "$MAINT_DIR/manifests/${FORK_NAME}-needs-fix.json"
  # Direct HTTP delivery to the resolver (replaces Dapr pub/sub — see header).
  RESOLVER_URL="${RESOLVER_URL:-http://fork-conflict-resolver.fork-maintenance.svc.cluster.local/events}"   # Service port 80 → targetPort http(8080)
  ce=$(echo "$payload" | jq -c '{source:"fork-sync", type:"fork.conflict.needs-resolution", data:.}')
  delivered=false
  for attempt in 1 2 3 4 5; do
    if curl -sf -m 5 -X POST "$RESOLVER_URL" -H "Content-Type: application/json" -d "$ce" >/dev/null 2>&1; then
      echo "  delivered fork.conflict.needs-resolution → resolver"
      delivered=true; break
    fi
    echo "  resolver unreachable (attempt $attempt); retrying in ${attempt}s"
    sleep "$attempt"
  done
  $delivered || echo "  WARNING: resolver unreachable after retries — needs-fix payload at manifests/${FORK_NAME}-needs-fix.json"
}

UPSTREAM_URL=$(read_yaml '.upstream.url')
UPSTREAM_BRANCH=$(read_yaml '.upstream.branch')
FORK_URL=$(read_yaml '.fork.url')
FORK_DEFAULT_BRANCH=$(read_yaml '.fork.default_branch')
FORK_MIRROR_BRANCH=$(read_yaml '.fork.mirror_branch' 2>/dev/null || echo "")

echo "  upstream: $UPSTREAM_URL ($UPSTREAM_BRANCH)"
echo "  fork:     $FORK_URL ($FORK_DEFAULT_BRANCH)"

# =============================================================================
# 1. Clone fork + add upstream remote
# =============================================================================
WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo ""
echo "=== Cloning fork (shallow) ==="
git clone --depth 100 "$FORK_URL" "$WORKDIR"
cd "$WORKDIR"

# Configure git + gh CLI auth via the git-host abstraction (github | forgejo).
# The fork definition declares fork.platform + fork.token_env; host_setup
# resolves the right token, credential helper, and (for forgejo) REST base.
# shellcheck source=scripts/git-host.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/git-host.sh"
host_setup

git remote add upstream "$UPSTREAM_URL"
git fetch --depth 100 upstream "$UPSTREAM_BRANCH" --tags

CURRENT_BRANCH=$(git branch --show-current)
# If not on the default branch, check it out
if [ "$CURRENT_BRANCH" != "$FORK_DEFAULT_BRANCH" ]; then
  git checkout "$FORK_DEFAULT_BRANCH" 2>/dev/null || git checkout -b "$FORK_DEFAULT_BRANCH" "origin/$FORK_DEFAULT_BRANCH"
fi

# =============================================================================
# 2. Check if upstream has new commits since last merge
# =============================================================================
MERGE_BASE=$(git merge-base "HEAD" "upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "")
UPSTREAM_HEAD=$(git rev-parse "upstream/$UPSTREAM_BRANCH")

if [ "$MERGE_BASE" = "$UPSTREAM_HEAD" ]; then
  echo ""
  echo "=== Already up to date — upstream has no new commits ==="
  exit 0
fi

NEW_COMMITS=$(git rev-list --count "${MERGE_BASE}..upstream/${UPSTREAM_BRANCH}" 2>/dev/null || echo "?")
echo ""
echo "=== Upstream has $NEW_COMMITS new commits — syncing ==="

# ── Capture divergence baseline (deterministic, BEFORE sync) ───────────────
# Snapshot the fork's declared additive paths + auto-detected added roots +
# declared deletions vs upstream. After the sync, `verify` checks every one is
# still present — so a dropped feature (helm chart, licensing code, workflow)
# blocks auto-merge & release instead of shipping silently. See Gate 4b in
# skill/references/safeguards.md and plugins/divergence-track.
DT="$SCRIPT_DIR/divergence-track.sh"
{ read_yaml '.additive_paths[]' 2>/dev/null || true; } > "/tmp/${FORK_NAME}-additive.txt"
{ read_yaml '.deletions[]'       2>/dev/null || true; } > "/tmp/${FORK_NAME}-deletions.txt"
BASELINE="/tmp/${FORK_NAME}-divergence-baseline.json"
echo ""
echo "=== Capturing divergence baseline (declared additive + auto + deletions) ==="
bash "$DT" capture "$WORKDIR" "upstream/$UPSTREAM_BRANCH" "$FORK_DEFAULT_BRANCH" "$BASELINE" \
     "/tmp/${FORK_NAME}-additive.txt" "/tmp/${FORK_NAME}-deletions.txt"

# =============================================================================
# 3. Merge the upstream release branch into a sync branch off the release branch
# =============================================================================
# Sync strategy — MERGE model (see references/architecture.md "Sync model"):
# the fork's release branch already carries our customizations as immutable
# commits (stable SHAs). Each sync appends an upstream merge ON TOP, exactly as a
# human maintainer would `git merge upstream/<branch>`. This is the Codeberg model
# and it is the correct substrate for an LLM maintainer:
#   • conflicts are LOCALIZED 3-way regions (base / ours / theirs) where upstream
#     AND our patch both changed since the merge-base — small, precise, reviewable;
#   • a bad resolution is ONE revertible merge commit (`git revert -m 1`);
#   • custom SHAs never change → append-only, bisectable, no replay accumulation;
#   • release-branch deltas are small/stable → most merges are clean (no LLM).
# Additive paths (additive_paths) never conflict in either model (upstream has no
# such paths); this only changes how the SHARED tree is reconciled. When a merge
# conflicts, the LLM resolver (resolve-conflict.sh) re-creates this exact merge
# and resolves the 3-way regions from each patch's declared intent (the fork's
# wiki chapter). See references/conflict-resolution.md.
SYNC_DATE=$(date +%Y-%m-%d)
SYNC_BRANCH="rezus/sync-${SYNC_DATE}"

# Branch the sync work off the RELEASE branch (not upstream) so the merge result
# is release + upstream-delta — a clean superset that PRs back into the release.
git checkout -b "$SYNC_BRANCH" "$FORK_DEFAULT_BRANCH"

# --no-ff guarantees an explicit, auditable merge commit (revertible via -m 1).
if ! git merge --no-ff --no-edit \
     -m "sync: merge upstream ${UPSTREAM_BRANCH} into ${FORK_DEFAULT_BRANCH} (${SYNC_DATE})" \
     "upstream/${UPSTREAM_BRANCH}"; then
  # The merge stopped on conflicts (localized 3-way regions). Conclude it WITH
  # markers on the sync branch, open a needs-conflict-resolution PR for the LLM
  # resolver, and emit fork.conflict.needs-resolution. The resolver re-creates
  # this exact merge, resolves each region from the patch's wiki intent, then
  # re-runs the gates as proof before the monitor merges. No auto-merge here.
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | grep -v '^$' || true)
  echo ""
  echo "=== Merge conflict — opening a resolution PR for the LLM resolver ==="
  echo "Conflicting files:"; echo "$CONFLICT_FILES" | sed 's/^/  - /'
  git add -A 2>/dev/null || true
  git commit --no-edit --quiet 2>/dev/null || true   # conclude the merge WITH markers
  git push --quiet origin "$SYNC_BRANCH" 2>&1 || { echo "ERROR: cannot push conflict branch" >&2; exit 3; }
  host_label_create "needs-conflict-resolution" 0E8A16 2>/dev/null || true
  PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" \
    "sync: $FORK_NAME — needs conflict resolution ($SYNC_DATE)" \
    "Upstream merge produced conflicts (merge model — localized 3-way regions). The LLM conflict-resolver will resolve on this branch using each patch's declared intent; the monitor merges once every gate passes." \
    "needs-conflict-resolution" 2>/dev/null || echo "")
  echo "  resolution PR: ${PR_URL:-<none>}"
  emit_conflict_event "$CONFLICT_FILES"
  exit 2
fi

# =============================================================================
# 4. Handle permanent divergences (deletions from fork definition)
# =============================================================================
DELETIONS=$(read_yaml '.deletions[]' 2>/dev/null || true)
if [ -n "$DELETIONS" ]; then
  echo ""
  echo "=== Applying permanent divergences ==="
  for del_path in $DELETIONS; do
    clean_path="${del_path%/}"
    if [ -e "$clean_path" ]; then
      echo "  rm -rf $clean_path"
      git rm -rf --quiet "$clean_path" 2>/dev/null || true
    fi
  done
  # Re-stage after deletions may have resolved conflicts
  git add -A 2>/dev/null || true
  # If merge was in progress, try to conclude it
  if [ -f .git/MERGE_HEAD ]; then
    git commit --no-edit --quiet 2>/dev/null || true
  fi
fi

# ── Re-apply divergences the merge dropped (self-heal) ─────────────────────
# A merge (or its agentic conflict resolution) can drop an additive path
# the build gate can't see. Restore any dropped declared/auto root from the
# fork's release now, so the verify gate below passes on intact features and
# flags only what genuinely can't be recovered.
echo ""
echo "=== Re-applying dropped divergences (self-heal) ==="
bash "$DT" reapply "$WORKDIR" "$FORK_DEFAULT_BRANCH" "$BASELINE" || true

# ── Final marker guard (defensive assertion) ───────────────────────────────
# A clean merge leaves no conflict markers. This grep is an assertion: if it
# ever fires (it should not after the section-3 merge path), the sync is in an
# unexpected state — abort rather than ship a broken branch. The real conflict
# path is handled in section 3 (conclude WITH markers → needs-conflict-resolution PR).
CONFLICT_FILES=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
if [ -n "$CONFLICT_FILES" ]; then
  echo "ERROR: unexpected conflict markers after a clean merge — aborting sync" >&2
  echo "$CONFLICT_FILES" | sed 's/^/  - /' >&2
  exit 3
fi

echo ""
echo "=== Merge completed cleanly ==="

# =============================================================================
# 5. Run post-merge hook (per-fork: SDK regen, chart re-vendor, etc.)
# =============================================================================
HOOK_FILE="$MAINT_DIR/post-merge-hooks/${FORK_NAME}.sh"
if [ -f "$HOOK_FILE" ]; then
  echo ""
  echo "=== Running post-merge hook: ${FORK_NAME}.sh ==="
  FORK_DIR="$WORKDIR" MAINT_DIR="$MAINT_DIR" bash "$HOOK_FILE" || {
    echo "WARNING: post-merge hook failed — continuing but review needed"
  }
fi

# =============================================================================
# 5b. Run centralized validation (UNIVERSAL — checks declared per-fork)
# =============================================================================
# validate-fork.sh reads the fork definition's `validation:` block and runs only
# the checks this fork declares (go_build / clean_tree / integration). Output goes
# to a PER-FORK file so results never leak between forks sharing one pod.
VALIDATION_FILE="/tmp/fork-validation-${FORK_NAME}.md"
rm -f "$VALIDATION_FILE"   # clear any stale results from a prior fork run
VALIDATION_RESULTS="(validation not run)"
VALIDATION_FAILED=false
if [ -f "$MAINT_DIR/checks/validate-fork.sh" ]; then
  echo ""
  echo "=== Running validation ==="
  # Capture output (visible in job logs) AND persist to the per-fork file for
  # the PR body. Without the echo, validation details vanish when the push fails.
  VALIDATION_OUTPUT=$(bash "$MAINT_DIR/checks/validate-fork.sh" "$FORK_NAME" "$WORKDIR" 2>&1) && VALIDATION_RC=0 || VALIDATION_RC=$?
  echo "$VALIDATION_OUTPUT"
  echo "$VALIDATION_OUTPUT" > "$VALIDATION_FILE"
  VALIDATION_RESULTS="$VALIDATION_OUTPUT"
  if [ "$VALIDATION_RC" -eq 0 ]; then
    echo "  validation: ✅"
  else
    echo "  validation: ❌ (see above)"
    VALIDATION_FAILED=true
  fi
else
  echo "=== No validator available — skipping ==="
fi

# ── Gate 4b: divergence integrity (deterministic) ──────────────────────────
# The build gate (5) cannot see additive paths (charts, licensing, workflows
# aren't compiled). This gate verifies every declared additive path is present
# and every auto divergence survived the sync verbatim. RED ⟹ needs-fix ⟹ no
# auto-merge, no auto-release. The real bug behind the 2026-07-09 signoz sync
# that dropped deploy/charts/signoz-community + pkg/licensing/communitylicensing.
DIVERGENCE_FAILED=false
DIVERGENCE_REPORT=""
echo ""
echo "=== Verifying divergence integrity ==="
if DIVERGENCE_REPORT=$(bash "$DT" verify "$WORKDIR" "$BASELINE" 2>&1); then
  echo "  divergence: ✅ intact"
else
  echo "$DIVERGENCE_REPORT" >&2
  echo "  divergence: ❌ LOST — a fork feature is missing; PR will be needs-fix"
  DIVERGENCE_FAILED=true
fi

# =============================================================================
# 6. Verify patches (signature grep)
# =============================================================================
echo ""
echo "=== Verifying patches ==="
PATCH_STATUS="all-intact"
PATCH_RESULTS=""
PATCH_COUNT=$(read_yaml '.patches | length')
for i in $(seq 0 $((PATCH_COUNT - 1))); do
  PATCH_FILE=$(read_yaml ".patches[$i].file")
  PATCH_SIG=$(read_yaml ".patches[$i].signature")
  PATCH_DESC=$(read_yaml ".patches[$i].description")

  if [ ! -f "$PATCH_FILE" ]; then
    STATUS="MISSING"
    PATCH_STATUS="needs-review"
  else
    OCCURRENCES=$(grep -cF "$PATCH_SIG" "$PATCH_FILE" 2>/dev/null || true)
    if [ "$OCCURRENCES" -gt 0 ]; then
      STATUS="OK (${OCCURRENCES}x)"
    else
      STATUS="LOST"
      PATCH_STATUS="needs-review"
    fi
  fi
  echo "  ${STATUS} ${PATCH_FILE} — ${PATCH_DESC}"
  PATCH_RESULTS="${PATCH_RESULTS}  ${STATUS} ${PATCH_FILE}\n"
done

echo ""
echo "Patch status: $PATCH_STATUS"

# =============================================================================
# 7. Generate manifest (diff-based — for audit)
# =============================================================================
MANIFEST_FILE="$MAINT_DIR/manifests/${FORK_NAME}-rezus.yaml"
if [ -f "$MAINT_DIR/scripts/generate-manifest.sh" ]; then
  echo ""
  echo "=== Generating divergence manifest ==="
  if [ -n "$FORK_MIRROR_BRANCH" ]; then
    bash "$MAINT_DIR/scripts/generate-manifest.sh" "$FORK_DEFAULT_BRANCH" "upstream/$UPSTREAM_BRANCH" > "$MANIFEST_FILE" 2>/dev/null || true
  else
    bash "$MAINT_DIR/scripts/generate-manifest.sh" "$FORK_DEFAULT_BRANCH" "upstream/$UPSTREAM_BRANCH" > "$MANIFEST_FILE" 2>/dev/null || true
  fi
  echo "  manifest written: $MANIFEST_FILE"
fi

# =============================================================================
# 8. Push sync branch + open GitHub PR
# =============================================================================
echo ""
echo "=== Pushing sync branch ==="
git push --quiet origin "$SYNC_BRANCH" 2>&1 || {
  echo "ERROR: failed to push sync branch" >&2
  exit 3
}

# Determine upstream version for PR title
UPSTREAM_TAG=$(git describe --tags --abbrev=0 "upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "HEAD")
UPSTREAM_COMMITS_RANGE="${MERGE_BASE:0:8}..${UPSTREAM_HEAD:0:8}"

PR_TITLE="sync: merge upstream ${UPSTREAM_BRANCH} (${SYNC_DATE})"
PR_LABEL="auto-merge"
if [ "$PATCH_STATUS" = "needs-review" ]; then
  PR_LABEL="needs-conflict-resolution"
elif $VALIDATION_FAILED || $DIVERGENCE_FAILED; then
  PR_LABEL="needs-fix"
fi

PR_BODY=$(cat <<EOF
## Upstream sync: ${FORK_NAME}

**Upstream**: ${UPSTREAM_URL} (\`${UPSTREAM_BRANCH}\`)
**New commits**: ${NEW_COMMITS} since last sync
**Range**: ${UPSTREAM_COMMITS_RANGE}

### Patch verification

$(echo -e "$PATCH_RESULTS")

**Status**: ${PATCH_STATUS}

$(if [ "$PATCH_STATUS" = "needs-review" ]; then echo "⚠️ Some patches need manual review — a signature was not found after the merge."; else echo "✅ All patches verified — this PR is auto-mergeable."; fi)

### Post-merge hook

$(if [ -f "$HOOK_FILE" ]; then echo "Ran \`post-merge-hooks/${FORK_NAME}.sh\`"; else echo "(no post-merge hook)"; fi)

---

${VALIDATION_RESULTS}

---

### Divergence integrity

$(if $DIVERGENCE_FAILED; then echo "❌ A fork feature was LOST in this sync (see job logs). PR is labelled \`needs-fix\` — it will not auto-merge."; else echo "✅ All declared additive paths + auto divergences intact (Gate 4b)."; fi)

---

_Automated by platform/fork-maintenance (k8s-config GitOps)._
EOF
)

echo ""
echo "=== Opening PR ==="
# Ensure labels exist (create if missing)
for label in "$PR_LABEL" "needs-conflict-resolution"; do
  host_label_create "$label" 0E8A16
done

PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" "$PR_TITLE" "$PR_BODY" "$PR_LABEL") || {
  echo "WARNING: failed to open PR: $PR_URL" >&2
}

# =============================================================================
# 11. Auto-merge + auto-release (opt-in per fork via auto.merge / auto.release)
# =============================================================================
# Full automation: when the PR passed every gate (label == auto-merge) AND the
# fork opts in, merge it immediately and cut the next release tag so the fork's
# tag-triggered release workflow builds a new image. Flux image automation then
# deploys it. The centralized gates ARE the "CI" — there is no per-PR GitHub
# Actions CI to wait for. Forks that want human review set auto.merge: false.
# =============================================================================
AUTO_MERGE=$(read_yaml '.auto.merge // false')
AUTO_RELEASE=$(read_yaml '.auto.release // false')
RELEASE_TAG=""

if [ "$PR_LABEL" = "auto-merge" ] && [ "$AUTO_MERGE" = "true" ]; then
  echo ""
  echo "=== Auto-merging PR (all gates green, auto.merge enabled) ==="
  MERGE_SHA=$(host_pr_merge "$SYNC_BRANCH" 2>&1) || {
    echo "WARNING: auto-merge failed: $MERGE_SHA" >&2
  }
  if [ -n "$MERGE_SHA" ] && [ "$AUTO_RELEASE" = "true" ]; then
    # Re-sync the release branch so we can tag the merged commit.
    git fetch --quiet origin "$FORK_DEFAULT_BRANCH"
    git checkout --quiet "$FORK_DEFAULT_BRANCH" 2>/dev/null || true
    git reset --hard --quiet "origin/$FORK_DEFAULT_BRANCH"

    # Compute the next release tag: <upstream-version>-rezus.<N+1>.
    # Upstream version = nearest upstream tag reachable from the merge.
    UPSTREAM_VER=$(git describe --tags --abbrev=0 "upstream/$UPSTREAM_BRANCH" 2>/dev/null \
      | sed -E 's/(-rc\.[0-9]+|-rezus\.[0-9]+).*$//')
    if [ -z "$UPSTREAM_VER" ]; then
      echo "WARNING: could not determine upstream version for release tag — skipping auto-release"
    else
      # Highest existing rezus build for this upstream version; default 0.
      LAST_REZUS=$(git tag -l "${UPSTREAM_VER}-rezus.*" | sort -V | tail -1)
      LAST_N=$(echo "${LAST_REZUS}" | sed -nE 's/.*-rezus\.([0-9]+).*/\1/p')
      [ -z "$LAST_N" ] && LAST_N=0
      NEXT_N=$((LAST_N + 1))
      RELEASE_TAG="${UPSTREAM_VER}-rezus.${NEXT_N}"

      # Idempotent: skip if the release branch HEAD is already tagged.
      HEAD_TAG=$(git tag --points-at HEAD | grep -E "${UPSTREAM_VER}-rezus\." || true)
      if [ -n "$HEAD_TAG" ]; then
        echo "=== HEAD already tagged ($HEAD_TAG) — skipping auto-release ==="
      else
        echo "=== Auto-releasing: tagging $FORK_DEFAULT_BRANCH as $RELEASE_TAG ==="
        git tag "$RELEASE_TAG"
        if git push --quiet origin "$RELEASE_TAG" 2>&1; then
          echo "  tagged $RELEASE_TAG → fork release workflow will build + publish image"
        else
          echo "WARNING: failed to push tag $RELEASE_TAG"
          RELEASE_TAG=""
        fi
      fi
    fi
  fi
else
  echo ""
  echo "=== PR left for review (label=$PR_LABEL; auto.merge=$AUTO_MERGE) ==="
fi

echo ""
echo "=== Sync complete ==="
echo "  PR: $PR_URL"
echo "  Label: $PR_LABEL"
echo "  Patch status: $PATCH_STATUS"
echo "  Divergence: $(if $DIVERGENCE_FAILED; then echo '❌ LOST (needs-fix)'; else echo '✅ intact'; fi)"
[ -n "$RELEASE_TAG" ] && echo "  Released tag: $RELEASE_TAG (image build triggered)"
