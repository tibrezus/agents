#!/usr/bin/env bash
# =============================================================================
# resolve-conflict.sh — cherry-pick driver + LLM conflict resolution + monitor
# =============================================================================
# Sync strategy (see sync-fork.sh): the fork's customizations are replayed onto
# the LATEST upstream by cherry-pick, not merged into a stale base. sync-fork.sh
# does the deterministic cherry-pick fast-path; on conflict it aborts + emits
# fork.conflict.needs-resolution. THIS script is the consumer: it REDOES the
# cherry-pick and, where it conflicts, the LLM drives it to completion —
# resolving each conflict using the fork's wiki chapter as intent, then
# `git cherry-pick --continue`, repeating until done — then pushes.
#
# The LLM is given: the repo (cwd, mid-cherry-pick), the skill, its tools
# (read/grep/bash; gh authenticated), the fork's intent (the org wiki
# wiki/entities/<fork>.md "Fork Maintenance" chapter — cloned locally), and a
# pointer to the PR. It does NOT validate or merge — only resolve → continue →
# push → quit. The monitor phase (this script) then re-validates + merges.
#
# Usage: resolve-conflict.sh <fork-name>
# Env:   ZAI_API_KEY|LLM_WIKI_ZAI_TOKEN, <host token>, RESOLVER_MODEL, SKILL_PATH, MAINT_DIR,
#        FORK_MAINTENANCE_WIKI (default https://github.com/rezuscloud/llm-wiki)
# =============================================================================
set -euo pipefail

FORK_NAME="${1:?Usage: resolve-conflict.sh <fork-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_DIR="${MAINT_DIR:-$(dirname "$SCRIPT_DIR")}"
DEF_FILE="$MAINT_DIR/forks/${FORK_NAME}.yaml"
MODEL="${RESOLVER_MODEL:-zai/glm-5.2}"
SKILL_PATH="${SKILL_PATH:-$HOME/.agents/skills/fork-maintenance/SKILL.md}"
WIKI_REPO="${FORK_MAINTENANCE_WIKI:-https://github.com/rezuscloud/llm-wiki}"

[ -f "$DEF_FILE" ] || { echo "ERROR: fork definition not found: $DEF_FILE" >&2; exit 1; }
if [ -z "${ZAI_API_KEY:-}" ] && [ -n "${LLM_WIKI_ZAI_TOKEN:-}" ]; then export ZAI_API_KEY="$LLM_WIKI_ZAI_TOKEN"; fi
[ -n "${ZAI_API_KEY:-}" ] || { echo "ERROR: ZAI_API_KEY not set" >&2; exit 1; }
command -v pi >/dev/null 2>&1 || { echo "ERROR: pi not on PATH" >&2; exit 1; }

read_yaml() { yq -r "$1" "$DEF_FILE"; }
FORK_URL=$(read_yaml '.fork.url')
FORK_DEFAULT_BRANCH=$(read_yaml '.fork.default_branch')
UPSTREAM_URL=$(read_yaml '.upstream.url')
UPSTREAM_BRANCH=$(read_yaml '.upstream.branch')

echo "=== resolve-conflict: $FORK_NAME (cherry-pick strategy) ==="
source "$SCRIPT_DIR/git-host.sh"
host_setup

WORKDIR=$(mktemp -d)
WIKI_DIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR" "$WIKI_DIR"' EXIT

# ── Phase 1: clone fork + upstream + wiki; start the cherry-pick ─────────────
echo ""
echo "=== Cloning fork + upstream ==="
git clone --depth 100 "$FORK_URL" "$WORKDIR"
cd "$WORKDIR"
git remote add upstream "$UPSTREAM_URL"
git fetch --depth 100 upstream "$UPSTREAM_BRANCH" --tags

MERGE_BASE=$(git merge-base "HEAD" "upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "")
SYNC_DATE=$(date +%Y-%m-%d)
SYNC_BRANCH="rezus/sync-${SYNC_DATE}"
CUSTOM_COMMITS=$(git rev-list --reverse --no-merges "${MERGE_BASE}..${FORK_DEFAULT_BRANCH}" 2>/dev/null | grep -v '^$' || true)
CUSTOM_COUNT=$(printf '%s\n' "$CUSTOM_COMMITS" | grep -c . || echo 0)

git checkout -b "$SYNC_BRANCH" "upstream/$UPSTREAM_BRANCH"

# Clone the org wiki for the fork's intent (the "Fork Maintenance" chapter).
WIKI_PAGE=""
if git clone --depth 1 "$WIKI_REPO" "$WIKI_DIR" 2>/dev/null; then
  for cand in "wiki/entities/${FORK_NAME}.md" "wiki/concepts/${FORK_NAME}.md"; do
    [ -f "$WIKI_DIR/$cand" ] && { WIKI_PAGE="$WIKI_DIR/$cand"; break; }
  done
fi

echo ""
echo "=== Cherry-picking $CUSTOM_COUNT customization commit(s) ==="
NEEDS_LLM=0
if [ "$CUSTOM_COUNT" -gt 0 ] && ! git cherry-pick $CUSTOM_COMMITS; then
  NEEDS_LLM=1
  echo "  cherry-pick stopped on a conflict — LLM will drive it"
else
  echo "  cherry-pick clean"
fi

# ── Phase 2: the LLM drives the cherry-pick to completion (only if conflicted) ─
if [ "$NEEDS_LLM" = "1" ]; then
  echo ""
  echo "=== Invoking pi ($MODEL): drive cherry-pick → push → quit ==="
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | grep -v '^$' || true)
  cat > "/tmp/resolve-${FORK_NAME}-prompt.txt" <<PROMPT
You are driving a git cherry-pick that stopped on a conflict.

Working directory: $WORKDIR  (clone of the '$FORK_NAME' fork; on branch $SYNC_BRANCH,
mid-cherry-pick — replaying the fork's customizations onto fresh upstream
$UPSTREAM_BRANCH).

Conflicted files right now (also see \`git status\`):
$(echo "$CONFLICT_FILES" | sed 's/^/  - /')

Intent context — READ THIS to know WHY each customization exists and how to port it:
$([ -n "$WIKI_PAGE" ] && echo "  $WIKI_PAGE  (the \"## Fork Maintenance\" chapter)" || echo "  (no wiki chapter found — infer intent from the fork definition patches + the diff)")
  Skill: $SKILL_PATH  (references/conflict-resolution.md)
  Fork definition: $DEF_FILE  (patches with signatures + descriptions)

Tools: read, grep, bash (git available; gh authenticated).

Drive the cherry-pick to completion, in a loop:
1. Resolve every conflicted file: remove ALL <<<<<<< / ======= / >>>>>>> markers,
   porting each customization onto upstream's new shape (use the wiki intent — a
   customization whose signature no longer matches means upstream changed the API
   it depends on: port it, never drop it). \`git add\` each resolved file.
2. \`git cherry-pick --continue\` (commits this commit and moves to the next; may
   surface the NEXT conflict).
3. Repeat 1–2 until the cherry-pick is FINISHED: \`git status\` is clean (no
   unmerged paths) AND there is no cherry-pick in progress
   (\`test ! -e .git/CHERRY_PICK_HEAD\`).
4. Then:
       git push -f origin $SYNC_BRANCH
5. STOP. Do NOT merge, open/comment on PRs, run builds, or validate. Pushing the
   clean branch ends your work.

The release branch is sacrosanct — make $SYNC_BRANCH's tree correct (every
customization ported, zero markers) and push it. Merging is decided separately.
PROMPT

  set +e
  timeout "${RESOLVER_TIMEOUT:-1800}" pi --print \
    --skill "$SKILL_PATH" --model "$MODEL" --approve --no-skills \
    "$(cat "/tmp/resolve-${FORK_NAME}-prompt.txt")" 2>&1 | tee "/tmp/resolve-${FORK_NAME}-pi.log"
  set -e
  echo ""
  echo "LLM workflow ended — monitor takes over"
fi

# ── Phase 3: monitor — fetch the push, re-validate, merge if green ────────────
echo ""
echo "=== Monitor: fetching the agent's push + re-running gates ==="
# Conclude any unfinished cherry-pick state defensively, then sync to the pushed tip.
git cherry-pick --abort 2>/dev/null || true
git fetch --quiet origin "$SYNC_BRANCH" 2>/dev/null || true
git checkout --quiet "$SYNC_BRANCH" 2>/dev/null || true
git reset --hard --quiet "origin/$SYNC_BRANCH" 2>/dev/null || true

# Apply declarative deletions (belt-and-suspenders) before validating.
DELETIONS=$(read_yaml '.deletions[]' 2>/dev/null || true)
if [ -n "$DELETIONS" ]; then
  for del_path in $DELETIONS; do [ -e "${del_path%/}" ] && git rm -rf --quiet "${del_path%/}" 2>/dev/null || true; done
  git add -A 2>/dev/null || true
  git diff --cached --quiet || { git commit --no-edit --quiet 2>/dev/null || true; git push --quiet origin "$SYNC_BRANCH" 2>&1 || true; }
fi

PATCH_COUNT=$(read_yaml '.patches | length' 2>/dev/null || true)
RESOLVE_EXIT=0

MARKERS=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
if [ -n "$MARKERS" ]; then echo "❌ gate 1: markers remain"; echo "$MARKERS" | sed 's/^/  - /'; RESOLVE_EXIT=1; else echo "✅ gate 1: no markers"; fi

if [ -f "$MAINT_DIR/checks/validate-fork.sh" ]; then
  set +e; bash "$MAINT_DIR/checks/validate-fork.sh" "$FORK_NAME" "$WORKDIR" >/tmp/resolve-validate.log 2>&1; V=$?; set -e
  [ "$V" -eq 0 ] && echo "✅ gate 5: validation green" || { echo "❌ gate 5: validation failed"; tail -5 /tmp/resolve-validate.log | sed 's/^/    /'; RESOLVE_EXIT=1; }
fi

SF=0
for i in $(seq 0 $((PATCH_COUNT - 1))); do
  P_FILE=$(read_yaml ".patches[$i].file"); P_SIG=$(read_yaml ".patches[$i].signature")
  if [ -f "$P_FILE" ]; then
    [ "$(grep -cF "$P_SIG" "$P_FILE" 2>/dev/null || true)" -eq 0 ] && { echo "❌ gate 4: signature lost: $P_FILE"; SF=1; }
  fi
done
[ "$SF" -eq 0 ] && echo "✅ gate 4: signatures intact" || RESOLVE_EXIT=1

if [ "$RESOLVE_EXIT" -ne 0 ]; then
  echo ""
  echo "=== Not resolved — PR stays labelled needs-conflict-resolution ==="
  exit 1
fi

echo ""
echo "=== Conflicts resolved — opening PR + triggering merge ==="
host_label_create "auto-merge" 0E8A16 2>/dev/null || true
PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" \
  "sync: $FORK_NAME — cherry-pick resolved by agent ($SYNC_DATE)" \
  "Customizations cherry-picked onto fresh upstream; conflicts resolved by the agent (pi + skill + wiki intent). Gates: marker scan + validate-fork.sh + signatures." \
  "auto-merge" 2>/dev/null || echo "")
echo "  PR: ${PR_URL:-<none>}"

MERGE_SHA=$(host_pr_merge "$SYNC_BRANCH" 2>&1) || echo "WARNING: merge failed: $MERGE_SHA"
AUTO_RELEASE=$(read_yaml '.auto.release // false')
if [ -n "$MERGE_SHA" ] && [ "$AUTO_RELEASE" = "true" ]; then
  UPSTREAM_VER=$(git describe --tags --abbrev=0 "upstream/$UPSTREAM_BRANCH" 2>/dev/null | sed -E 's/(-rc\.[0-9]+|-rezus\.[0-9]+).*$//')
  if [ -n "$UPSTREAM_VER" ]; then
    LAST_N=$(git tag -l "${UPSTREAM_VER}-rezus.*" | sort -V | tail -1 | sed -nE 's/.*-rezus\.([0-9]+).*/\1/p'); [ -z "$LAST_N" ] && LAST_N=0
    REL="${UPSTREAM_VER}-rezus.$((LAST_N + 1))"
    git fetch --quiet origin "$FORK_DEFAULT_BRANCH"; git checkout --quiet "$FORK_DEFAULT_BRANCH" 2>/dev/null || true; git reset --hard --quiet "origin/$FORK_DEFAULT_BRANCH"
    [ -z "$(git tag --points-at HEAD | grep -E "${UPSTREAM_VER}-rezus\.")" ] && {
      git tag "$REL" && git push --quiet origin "$REL" 2>&1 && echo "=== Released $REL → image build → Flux deploys ==="
    }
  fi
fi

echo ""
echo "=== resolve-conflict complete: $FORK_NAME (merged) ==="
exit 0
