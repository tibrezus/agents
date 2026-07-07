#!/usr/bin/env bash
# =============================================================================
# resolve-conflict.sh — narrow LLM conflict resolver + monitor/merge
# =============================================================================
# Two cleanly separated phases, per the event-driven design:
#
#   Phase 2 (LLM): the agent's ONLY job is to resolve the conflict and push, then
#     quit. It is given the cloned repo (on the sync branch, which sync-fork.sh
#     already pushed WITH the conflict markers + opened as a PR), the
#     fork-maintenance skill, and its tools (read/grep/bash; the git-host CLI is
#     authenticated). It is NOT given the repo as pre-loaded context — it searches
#     with its tools. It does NOT validate or merge. Pushing the clean branch ends
#     the LLM workflow.
#
#   Phase 3 (monitor): after the LLM quits, THIS script fetches the push and
#     re-runs the safeguard gates (marker scan + validate-fork.sh + signatures).
#     Green → the merge is triggered (the PR that sync-fork.sh opened). Not green
#     → the PR stays labelled needs-conflict-resolution. "If conflicts are
#     resolved, the merge is triggered."
#
# Usage: resolve-conflict.sh <fork-name>
# Env:   ZAI_API_KEY | LLM_WIKI_ZAI_TOKEN, <host token>, RESOLVER_MODEL, SKILL_PATH, MAINT_DIR
# Exit:  0 = resolved + merged; 1 = not resolved (PR left for review)
# =============================================================================
set -euo pipefail

FORK_NAME="${1:?Usage: resolve-conflict.sh <fork-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_DIR="${MAINT_DIR:-$(dirname "$SCRIPT_DIR")}"
DEF_FILE="$MAINT_DIR/forks/${FORK_NAME}.yaml"
MODEL="${RESOLVER_MODEL:-zai/glm-5.2}"
SKILL_PATH="${SKILL_PATH:-$HOME/.agents/skills/fork-maintenance/SKILL.md}"

[ -f "$DEF_FILE" ] || { echo "ERROR: fork definition not found: $DEF_FILE" >&2; exit 1; }
if [ -z "${ZAI_API_KEY:-}" ] && [ -n "${LLM_WIKI_ZAI_TOKEN:-}" ]; then export ZAI_API_KEY="$LLM_WIKI_ZAI_TOKEN"; fi
[ -n "${ZAI_API_KEY:-}" ] || { echo "ERROR: ZAI_API_KEY (or LLM_WIKI_ZAI_TOKEN) not set" >&2; exit 1; }
command -v pi >/dev/null 2>&1 || { echo "ERROR: pi not on PATH" >&2; exit 1; }

read_yaml() { yq -r "$1" "$DEF_FILE"; }
FORK_URL=$(read_yaml '.fork.url')
FORK_DEFAULT_BRANCH=$(read_yaml '.fork.default_branch')

echo "=== resolve-conflict: $FORK_NAME ==="
echo "  fork: $FORK_URL ($FORK_DEFAULT_BRANCH) | model: $MODEL"

# shellcheck source=scripts/git-host.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/git-host.sh"
host_setup

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ── Phase 1: clone + checkout the sync branch (markers pushed by sync-fork.sh) ─
echo ""
echo "=== Cloning fork ==="
git clone --depth 100 "$FORK_URL" "$WORKDIR"
cd "$WORKDIR"

SYNC_BRANCH="rezus/sync-$(date +%Y-%m-%d)"
# sync-fork.sh concluded the merge WITH markers and pushed this branch. A shallow
# clone only brings the default branch, so fetch the sync branch explicitly with
# a refspec that creates origin/<branch> (a bare `git fetch origin <branch>` only
# updates FETCH_HEAD and leaves no remote-tracking ref → checkout would fail).
git fetch --depth 100 origin "refs/heads/${SYNC_BRANCH}:refs/remotes/origin/${SYNC_BRANCH}" 2>/dev/null || true
git checkout -B "$SYNC_BRANCH" "origin/${SYNC_BRANCH}" 2>/dev/null || {
  echo "=== No sync branch '$SYNC_BRANCH' on origin — nothing to resolve (or not a conflict PR) ==="
  exit 0
}

MARKER_FILES=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
if [ -z "$MARKER_FILES" ]; then
  echo "=== No conflict markers on $SYNC_BRANCH — already resolved or not a conflict PR ==="
  exit 0
fi
echo ""
echo "=== Conflict markers present in: ==="
echo "$MARKER_FILES" | sed 's/^/  - /'

# The PR sync-fork.sh opened (for the prompt pointer + the Phase-3 merge).
PR_URL=""
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
  PR_URL=$(gh pr list --repo "$FORK_URL" --head "$SYNC_BRANCH" --state open \
           --json url -q '.[0].url' 2>/dev/null || true)
fi

# ── Phase 2: the LLM resolves + pushes + quits (narrow, tool-driven) ──────────
# The agent is given: the repo (cwd), the skill, its tools, and a pointer to the
# PR. NOT the repo as context — it searches with read/grep. It pushes, then stops.
echo ""
echo "=== Invoking pi ($MODEL): resolve → push → quit ==="
cat > "/tmp/resolve-${FORK_NAME}-prompt.txt" <<PROMPT
You are resolving merge conflicts on a fork-sync branch.

Working directory: $WORKDIR  (a clone of the '$FORK_NAME' fork; you are on branch $SYNC_BRANCH)
$([ -n "$PR_URL" ] && echo "PR: $PR_URL")

These files contain unresolved git conflict markers (<<<<<<< / ======= / >>>>>>>):
$(echo "$MARKER_FILES" | sed 's/^/  - /')

You have tools: read, grep, bash (git is available; the git-host CLI is authenticated).
Load the fork-maintenance skill at $SKILL_PATH — read references/conflict-resolution.md.

Your ONLY task, in this order:
1. For each conflicted file: read it and search the surrounding code (read/grep —
   explore whatever you need to understand both sides). Resolve by removing ALL
   conflict markers and producing a correct merge of our fork's intent (the
   rezus/* patches) and upstream's change. A patch whose signature no longer
   matches means upstream changed the API it depends on (semantic) — port it.
2. When EVERY marker is gone from EVERY file:
       git add -A
       git commit -m "resolve: upstream sync conflicts ($FORK_NAME)"
       git push origin $SYNC_BRANCH
3. Then STOP. Do NOT merge, open or comment on PRs, run builds, or validate.
   Pushing the clean branch is the end of your work.

The release branch is sacrosanct — you only make THIS branch correct and push it.
Merging is decided separately, after the branch is re-validated by the gates.
PROMPT

set +e
timeout "${RESOLVER_TIMEOUT:-1800}" pi --print \
  --skill "$SKILL_PATH" --model "$MODEL" --approve --no-skills \
  "$(cat "/tmp/resolve-${FORK_NAME}-prompt.txt")" 2>&1 | tee "/tmp/resolve-${FORK_NAME}-pi.log"
PI_RC=${PIPESTATUS[0]}
set -e
echo ""
echo "LLM workflow ended (pi exit: $PI_RC) — monitor takes over"

# ── Phase 3: monitor — fetch the push, re-validate, merge if green ────────────
echo ""
echo "=== Monitor: fetching the agent's push + re-running gates ==="
git fetch --quiet origin "$SYNC_BRANCH" 2>/dev/null || true
git checkout --quiet "$SYNC_BRANCH" 2>/dev/null || true
git reset --hard --quiet "origin/$SYNC_BRANCH" 2>/dev/null || true

PATCH_COUNT=$(read_yaml '.patches | length' 2>/dev/null || echo 0)
RESOLVE_EXIT=0

# Gate 1 — conflict markers must be gone (the real "conflicts resolved" signal).
MARKERS=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
if [ -n "$MARKERS" ]; then
  echo "❌ gate 1: markers remain:"; echo "$MARKERS" | sed 's/^/  - /'; RESOLVE_EXIT=1
else
  echo "✅ gate 1: no markers"
fi

# Gate 5 — validate-fork.sh (build / codegen / integration, per the fork def).
if [ -f "$MAINT_DIR/checks/validate-fork.sh" ]; then
  set +e
  bash "$MAINT_DIR/checks/validate-fork.sh" "$FORK_NAME" "$WORKDIR" >/tmp/resolve-validate.log 2>&1
  V=$?
  set -e
  if [ "$V" -eq 0 ]; then echo "✅ gate 5: validation green"; else
    echo "❌ gate 5: validation failed"; tail -5 /tmp/resolve-validate.log | sed 's/^/    /'; RESOLVE_EXIT=1
  fi
fi

# Gate 4 — patch signatures intact.
SF=0
for i in $(seq 0 $((PATCH_COUNT - 1))); do
  P_FILE=$(read_yaml ".patches[$i].file"); P_SIG=$(read_yaml ".patches[$i].signature")
  if [ -f "$P_FILE" ]; then
    [ "$(grep -cF "$P_SIG" "$P_FILE" 2>/dev/null || echo 0)" -eq 0 ] && { echo "❌ gate 4: signature lost: $P_FILE"; SF=1; }
  fi
done
[ "$SF" -eq 0 ] && echo "✅ gate 4: signatures intact" || RESOLVE_EXIT=1

if [ "$RESOLVE_EXIT" -ne 0 ]; then
  echo ""
  echo "=== Conflicts NOT resolved — PR stays labelled needs-conflict-resolution ==="
  exit 1
fi

# Green → trigger the merge on the PR sync-fork.sh opened.
echo ""
echo "=== Conflicts resolved — triggering merge ==="
MERGE_SHA=$(host_pr_merge "$SYNC_BRANCH" 2>&1) || { echo "WARNING: merge failed: $MERGE_SHA"; }

# Opt-in auto-release (same logic as sync-fork.sh).
AUTO_RELEASE=$(read_yaml '.auto.release // false')
if [ -n "$MERGE_SHA" ] && [ "$AUTO_RELEASE" = "true" ]; then
  git fetch --quiet origin "$FORK_DEFAULT_BRANCH"
  git checkout --quiet "$FORK_DEFAULT_BRANCH" 2>/dev/null || true
  git reset --hard --quiet "origin/$FORK_DEFAULT_BRANCH"
  UPSTREAM_URL=$(read_yaml '.upstream.url'); UPSTREAM_BRANCH=$(read_yaml '.upstream.branch')
  git remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
  git fetch --quiet --tags upstream "$UPSTREAM_BRANCH" 2>/dev/null || true
  UPSTREAM_VER=$(git describe --tags --abbrev=0 "upstream/$UPSTREAM_BRANCH" 2>/dev/null | sed -E 's/(-rc\.[0-9]+|-rezus\.[0-9]+).*$//')
  if [ -n "$UPSTREAM_VER" ]; then
    LAST_N=$(git tag -l "${UPSTREAM_VER}-rezus.*" | sort -V | tail -1 | sed -nE 's/.*-rezus\.([0-9]+).*/\1/p'); [ -z "$LAST_N" ] && LAST_N=0
    REL="${UPSTREAM_VER}-rezus.$((LAST_N + 1))"
    [ -z "$(git tag --points-at HEAD | grep -E "${UPSTREAM_VER}-rezus\.")" ] && {
      git tag "$REL" && git push --quiet origin "$REL" 2>&1 && echo "=== Released $REL → image build → Flux deploys ==="
    }
  fi
fi

echo ""
echo "=== resolve-conflict complete: $FORK_NAME (merged) ==="
exit 0
