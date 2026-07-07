#!/usr/bin/env bash
# =============================================================================
# resolve-conflict.sh — Agentic conflict resolver for fork-sync
# =============================================================================
# When sync-fork.sh hits a merge conflict (exit 2), this script RECREATES the
# conflict on a fresh sync branch and invokes the pi.dev harness with the
# fork-maintenance skill + a structured needs-fix payload. The agent resolves
# (mechanical or semantic, per skill/references/conflict-resolution.md), then
# this script re-runs the safeguard gates (marker scan + validate-fork.sh +
# patch signatures). On green it pushes the sync branch and auto-merges
# (+ auto-releases if the fork opts in) so the fork deploys. On failure it
# pushes the partial work and leaves the PR labelled needs-conflict-resolution
# for a human — the release branch is never the experiment.
#
# Why recreate instead of pushing conflict markers? git can't push a
# merge-in-progress cleanly, and shipping <<<<<<< markers is exactly the
# production bug gate 1 exists to prevent. Re-merging upstream is deterministic,
# so the agent sees the identical conflict sync-fork.sh saw.
#
# Usage: resolve-conflict.sh <fork-name>
# Env:   ZAI_API_KEY | LLM_WIKI_ZAI_TOKEN — ZAI API key for the model
#        GITHUB_TOKEN | <host token>      — git-host PAT (via git-host.sh)
#        RESOLVER_MODEL (default zai/glm-5.2)
#        SKILL_PATH (default ~/.agents/skills/fork-maintenance/SKILL.md)
#        MAINT_DIR   (default parent of this script's dir)
# Exit:  0 = resolved + deployed (merge happened); 1 = could not resolve (escalated)
# =============================================================================
set -euo pipefail

FORK_NAME="${1:?Usage: resolve-conflict.sh <fork-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_DIR="${MAINT_DIR:-$(dirname "$SCRIPT_DIR")}"
DEF_FILE="$MAINT_DIR/forks/${FORK_NAME}.yaml"
MODEL="${RESOLVER_MODEL:-zai/glm-5.2}"
SKILL_PATH="${SKILL_PATH:-$HOME/.agents/skills/fork-maintenance/SKILL.md}"

[ -f "$DEF_FILE" ] || { echo "ERROR: fork definition not found: $DEF_FILE" >&2; exit 1; }

# ZAI token (prefer explicit, fall back to the llm-wiki secret env name)
if [ -z "${ZAI_API_KEY:-}" ] && [ -n "${LLM_WIKI_ZAI_TOKEN:-}" ]; then
  export ZAI_API_KEY="$LLM_WIKI_ZAI_TOKEN"
fi
[ -n "${ZAI_API_KEY:-}" ] || { echo "ERROR: ZAI_API_KEY (or LLM_WIKI_ZAI_TOKEN) not set" >&2; exit 1; }
command -v pi >/dev/null 2>&1 || { echo "ERROR: pi not on PATH" >&2; exit 1; }

read_yaml() { yq -r "$1" "$DEF_FILE"; }

UPSTREAM_URL=$(read_yaml '.upstream.url')
UPSTREAM_BRANCH=$(read_yaml '.upstream.branch')
FORK_URL=$(read_yaml '.fork.url')
FORK_DEFAULT_BRANCH=$(read_yaml '.fork.default_branch')

echo "=== resolve-conflict: $FORK_NAME ==="
echo "  upstream: $UPSTREAM_URL ($UPSTREAM_BRANCH)"
echo "  fork:     $FORK_URL ($FORK_DEFAULT_BRANCH)"
echo "  model:    $MODEL"

# shellcheck source=scripts/git-host.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/git-host.sh"
host_setup

# ── 1. Clone fork + fetch upstream ─────────────────────────────────────────
WORKDIR=$(mktemp -d)
cleanup() {
  # keep the workdir on failure for inspection unless RESOLVE_KEEP_WORKDIR=0
  if [ "${RESOLVE_KEEP_WORKDIR:-1}" = "0" ] || [ "${RESOLVE_EXIT:-0}" = "0" ]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT

echo ""
echo "=== Cloning fork (shallow) ==="
git clone --depth 100 "$FORK_URL" "$WORKDIR"
cd "$WORKDIR"
git remote add upstream "$UPSTREAM_URL"
git fetch --depth 100 upstream "$UPSTREAM_BRANCH" --tags
git checkout "$FORK_DEFAULT_BRANCH" 2>/dev/null || git checkout -b "$FORK_DEFAULT_BRANCH" "origin/$FORK_DEFAULT_BRANCH"

# ── 2. Recreate the sync branch + conflict ─────────────────────────────────
SYNC_DATE=$(date +%Y-%m-%d)
SYNC_BRANCH="rezus/sync-${SYNC_DATE}"
# Reuse the branch if a prior attempt pushed it; otherwise start fresh.
git checkout -b "$SYNC_BRANCH"

MERGE_BASE=$(git merge-base "HEAD" "upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "")
UPSTREAM_HEAD=$(git rev-parse "upstream/$UPSTREAM_BRANCH")

echo ""
echo "=== Re-merging upstream/$UPSTREAM_BRANCH to reproduce the conflict ==="
MERGE_RC=0
git merge --no-edit "upstream/$UPSTREAM_BRANCH" || MERGE_RC=$?

# Apply permanent divergences (same as sync-fork.sh step 4) — these are NOT
# conflicts; re-strip them so the agent only sees real conflicts.
DELETIONS=$(read_yaml '.deletions[]' 2>/dev/null || true)
if [ -n "$DELETIONS" ]; then
  for del_path in $DELETIONS; do
    clean_path="${del_path%/}"
    [ -e "$clean_path" ] && git rm -rf --quiet "$clean_path" 2>/dev/null || true
  done
  git add -A 2>/dev/null || true
fi

# ── 3. Build the needs-fix payload ─────────────────────────────────────────
# Conflict files = git unmerged paths UNION files with textual markers (the
# gate-1 gotcha: git add -A clears the index state but leaves markers).
CONFLICT_FILES=$( { git diff --name-only --diff-filter=U 2>/dev/null; \
                    git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null; } \
                  | sort -u | grep -v '^$' || true )

if [ -z "$CONFLICT_FILES" ]; then
  echo ""
  echo "=== No conflict reproduced — upstream may already be merged ==="
  git merge --abort 2>/dev/null || true
  exit 0
fi

echo ""
echo "=== Conflict reproduced — conflicting files: ==="
echo "$CONFLICT_FILES" | sed 's/^/  - /'

# Patches at risk: signature grep against the (conflicted) tree.
PATCHES_JSON="[]"
PATCH_COUNT=$(read_yaml '.patches | length')
for i in $(seq 0 $((PATCH_COUNT - 1))); do
  P_FILE=$(read_yaml ".patches[$i].file")
  P_SIG=$(read_yaml ".patches[$i].signature")
  P_DESC=$(read_yaml ".patches[$i].description")
  STATUS="LOST"
  if [ -f "$P_FILE" ]; then
    OCC=$(grep -cF "$P_SIG" "$P_FILE" 2>/dev/null || echo 0)
    [ "$OCC" -gt 0 ] && STATUS="OK"
  else
    STATUS="MISSING"
  fi
  PATCHES_JSON=$(echo "$PATCHES_JSON" | jq --arg f "$P_FILE" --arg s "$P_SIG" \
    --arg d "$P_DESC" --arg st "$STATUS" \
    '. += [{file:$f, signature:$s, description:$d, status:$st}]')
done

PAYLOAD="$WORKDIR/.needs-fix.json"
jq -n \
  --arg fork "$FORK_NAME" \
  --arg sync_branch "$SYNC_BRANCH" \
  --arg upstream_url "$UPSTREAM_URL" \
  --arg upstream_branch "$UPSTREAM_BRANCH" \
  --arg upstream_range "${MERGE_BASE:0:12}..${UPSTREAM_HEAD:0:12}" \
  --argjson patches "$PATCHES_JSON" \
  --arg workdir "$WORKDIR" \
  --arg maint_dir "$MAINT_DIR" \
  '{fork:$fork, sync_branch:$sync_branch, upstream_url:$upstream_url,
    upstream_branch:$upstream_branch, upstream_range:$upstream_range,
    patches_at_risk:$patches, workdir:$workdir, maint_dir:$maint_dir}' \
  > "$PAYLOAD"
# conflict_files merged in separately (jq splitting a multiline shell var)
echo "$CONFLICT_FILES" | jq -R -s '{conflict_files: (split("\n") | map(select(length>0)))}' > "$WORKDIR/.cf.json"
jq -s '.[0] * .[1]' "$PAYLOAD" "$WORKDIR/.cf.json" > "$PAYLOAD.tmp" && mv "$PAYLOAD.tmp" "$PAYLOAD"

echo ""
echo "=== needs-fix payload ==="
cat "$PAYLOAD"

# ── 4. Invoke the pi harness with the fork-maintenance skill ───────────────
# The agent reads the skill (conflict-resolution.md protocol), the payload, and
# resolves IN THIS workdir. It must remove every marker and make the tree match
# our patch intent against upstream's new shape. It does NOT push or merge —
# this script re-validates and owns deployment.
PROMPT="You are resolving an upstream-sync merge conflict for the '$FORK_NAME' fork.

You are working in the fork checkout at: $WORKDIR (on branch $SYNC_BRANCH, mid-merge with upstream/$UPSTREAM_BRANCH).

Follow the skill's conflict-resolution protocol EXACTLY:
1. Load the skill: read $SKILL_PATH and especially references/conflict-resolution.md.
2. Read the needs-fix payload: cat $PAYLOAD
3. For EACH conflicting file (payload .conflict_files):
   - Decide MECHANICAL (our patch intent still applies — re-apply our lines, drop markers)
     or SEMANTIC (upstream changed the API/type our patch depends on — port our patch,
     or adopt upstream if it now does what ours did).
   - Gate-4 hint: for each patch in .patches_at_risk with status LOST/MISSING, the
     patch was dropped by upstream -> semantic. status OK -> mechanical.
   - Resolve the file: remove ALL <<<<<<< / ======= / >>>>>>> markers and produce a
     correct merge of our intent + upstream's change.
4. When all markers are gone, CONCLUDE the merge: git add -A && git commit --no-edit
5. Re-run the gates yourself and FIX until green:
   - git grep -E '^(<<<<<<<|>>>>>>>|=======) ' -- .    (must be empty)
   - bash $MAINT_DIR/checks/validate-fork.sh $FORK_NAME $WORKDIR
   - for each patch: grep -cF \"<signature>\" <file>    (count must be > 0)
   If validate-fork.sh needs tools you lack, say so explicitly rather than claiming success.
6. Do NOT push, do NOT open a PR, do NOT merge. Only resolve + commit on $SYNC_BRANCH.

If you CANNOT resolve with confidence (semantic conflict you can't verify, or the build
won't pass and you can't tell if it's your resolution or a pre-existing upstream breakage),
STOP — leave the tree where it is and say 'ESCALATE: <reason>'. Do not commit a guess.

The release branch is sacrosanct: a wrong resolution must never deploy."

echo ""
echo "=== Invoking pi ($MODEL) with fork-maintenance skill ==="
set +e
timeout "${RESOLVER_TIMEOUT:-1800}" pi --print \
  --skill "$SKILL_PATH" \
  --model "$MODEL" \
  --approve \
  --no-skills \
  "$PROMPT" 2>&1 | tee "$WORKDIR/.pi-output.log"
PI_RC=${PIPESTATUS[0]}
set -e
echo ""
echo "pi exit: $PI_RC"

# ── 5. Post-resolution gates (the non-negotiable proof) ────────────────────
# An agent's "I resolved it" is a claim. These gates are proof.
echo ""
echo "=== Gate 1: conflict-marker scan (must be empty) ==="
MARKERS=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
if [ -n "$MARKERS" ]; then
  echo "❌ markers remain:"; echo "$MARKERS" | sed 's/^/  - /'
  RESOLVE_EXIT=1
else
  echo "✅ no markers"
fi

echo ""
echo "=== Gate 5: validate-fork.sh ==="
if [ -f "$MAINT_DIR/checks/validate-fork.sh" ]; then
  set +e
  bash "$MAINT_DIR/checks/validate-fork.sh" "$FORK_NAME" "$WORKDIR" 2>&1 | tee "$WORKDIR/.validate.log"
  VAL_RC=${PIPESTATUS[0]}
  set -e
  if [ "$VAL_RC" -eq 0 ]; then echo "✅ validation green"; else echo "❌ validation failed"; RESOLVE_EXIT=1; fi
else
  echo "(no validator — skipping gate 5)"
fi

echo ""
echo "=== Gate 4: patch signatures ==="
SIG_FAIL=0
for i in $(seq 0 $((PATCH_COUNT - 1))); do
  P_FILE=$(read_yaml ".patches[$i].file")
  P_SIG=$(read_yaml ".patches[$i].signature")
  if [ -f "$P_FILE" ]; then
    OCC=$(grep -cF "$P_SIG" "$P_FILE" 2>/dev/null || echo 0)
    [ "$OCC" -eq 0 ] && { echo "❌ signature lost: $P_FILE"; SIG_FAIL=1; }
  fi
done
[ "$SIG_FAIL" -eq 0 ] && echo "✅ all signatures present" || RESOLVE_EXIT=1

# Did the agent explicitly escalate?
if grep -qi '^ESCALATE' "$WORKDIR/.pi-output.log" 2>/dev/null; then
  echo ""; echo "=== Agent chose to ESCALATE ==="
  RESOLVE_EXIT=1
fi

# ── 6. Deploy (green) or escalate (red) ────────────────────────────────────
RESOLVE_EXIT="${RESOLVE_EXIT:-0}"

if [ "$RESOLVE_EXIT" -ne 0 ]; then
  echo ""
  echo "=== Could not auto-resolve — pushing partial work for human review ==="
  # Commit whatever state the agent left (even if markers gone but build failed)
  git add -A 2>/dev/null || true
  git commit --no-edit --quiet 2>/dev/null || true
  git push --quiet origin "$SYNC_BRANCH" 2>&1 || true
  host_label_create "needs-conflict-resolution" 0E8A16 2>/dev/null || true
  host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" \
    "sync: $FORK_NAME — needs conflict resolution ($SYNC_DATE)" \
    "Agentic resolution attempted but did not pass all gates. See job logs. Review needed." \
    "needs-conflict-resolution" 2>/dev/null || true
  echo "ESCALATED — PR opened with needs-conflict-resolution label"
  exit 1
fi

echo ""
echo "=== Green — pushing resolved sync branch + deploying ==="
git push --quiet origin "$SYNC_BRANCH" 2>&1 || { echo "ERROR: push failed" >&2; exit 1; }

AUTO_MERGE=$(read_yaml '.auto.merge // false')
host_label_create "auto-merge" 0E8A16 2>/dev/null || true
PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" \
  "sync: merge upstream $UPSTREAM_BRANCH ($SYNC_DATE) — resolved by agent" \
  "Conflicts resolved by the fork-maintenance agent (pi + skill). Passed: marker scan, validate-fork.sh, patch signatures." \
  "auto-merge") || PR_URL=""

if [ "$AUTO_MERGE" = "true" ]; then
  echo "=== Auto-merging (auto.merge enabled) ==="
  MERGE_SHA=$(host_pr_merge "$SYNC_BRANCH" 2>&1) || echo "WARNING: merge failed: $MERGE_SHA"

  AUTO_RELEASE=$(read_yaml '.auto.release // false')
  if [ -n "$MERGE_SHA" ] && [ "$AUTO_RELEASE" = "true" ]; then
    git fetch --quiet origin "$FORK_DEFAULT_BRANCH"
    git checkout --quiet "$FORK_DEFAULT_BRANCH" 2>/dev/null || true
    git reset --hard --quiet "origin/$FORK_DEFAULT_BRANCH"
    UPSTREAM_VER=$(git describe --tags --abbrev=0 "upstream/$UPSTREAM_BRANCH" 2>/dev/null | sed -E 's/(-rc\.[0-9]+|-rezus\.[0-9]+).*$//')
    if [ -n "$UPSTREAM_VER" ]; then
      LAST_REZUS=$(git tag -l "${UPSTREAM_VER}-rezus.*" | sort -V | tail -1)
      LAST_N=$(echo "$LAST_REZUS" | sed -nE 's/.*-rezus\.([0-9]+).*/\1/p'); [ -z "$LAST_N" ] && LAST_N=0
      RELEASE_TAG="${UPSTREAM_VER}-rezus.$((LAST_N + 1))"
      HEAD_TAG=$(git tag --points-at HEAD | grep -E "${UPSTREAM_VER}-rezus\." || true)
      if [ -z "$HEAD_TAG" ]; then
        git tag "$RELEASE_TAG" && git push --quiet origin "$RELEASE_TAG" 2>&1 \
          && echo "=== Released $RELEASE_TAG → image build → Flux deploys ==="
      fi
    fi
  fi
else
  echo "=== PR left for review (auto.merge=$AUTO_MERGE) — $PR_URL ==="
fi

echo ""
echo "=== resolve-conflict complete: $FORK_NAME ==="
echo "  PR: $PR_URL"
RESOLVE_EXIT=0
exit 0
