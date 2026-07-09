#!/usr/bin/env bash
# =============================================================================
# resolve-conflict.sh — cherry-pick + harmostes-orchestrated agent + gate/deploy
# =============================================================================
# sync-fork.sh cherry-picks the fork's customizations onto fresh upstream; on
# conflict it aborts + emits fork.conflict.needs-resolution. THIS script is the
# consumer: it REDOES the cherry-pick (Phase 1) and, where it conflicts, hands
# the work to harmostes (Phase 2) — a shared pi.dev RPC orchestrator
# (github.com/tibrezus/harmostes) that runs ONE warm agent session: the agent
# drives the cherry-pick to completion + pushes, harmostes runs gate-resolved.sh
# (markers + validate-fork.sh + signatures), and on failure feeds the error back
# to the SAME session (the agent keeps context) up to N fixes. Only a green gate
# deploys. Then this script replaces the release branch + releases.
#
# This replaces the old `pi --print` + cold-reinvoke-on-failure loop: warm
# session continuation + full tool-call observability + a tool allowlist.
#
# Usage: resolve-conflict.sh <fork-name>
# Env:   ZAI_API_KEY|LLM_WIKI_ZAI_TOKEN, <host token>, RESOLVER_MODEL, SKILL_PATH,
#        MAINT_DIR, HARMOSTES (default 'harmostes'), FORK_MAINTENANCE_WIKI,
#        RESOLVER_FIX_RETRIES (default 3), RESOLVER_TIMEOUT (default 1800)
# =============================================================================
set -euo pipefail

FORK_NAME="${1:?Usage: resolve-conflict.sh <fork-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_DIR="${MAINT_DIR:-$(dirname "$SCRIPT_DIR")}"
DEF_FILE="$MAINT_DIR/forks/${FORK_NAME}.yaml"
MODEL="${RESOLVER_MODEL:-zai/glm-5.2}"
SKILL_PATH="${SKILL_PATH:-$HOME/.agents/skills/fork-maintenance/SKILL.md}"
WIKI_REPO="${FORK_MAINTENANCE_WIKI:-https://github.com/rezuscloud/llm-wiki}"
HARMOSTES="${HARMOSTES:-harmostes}"

[ -f "$DEF_FILE" ] || { echo "ERROR: fork definition not found: $DEF_FILE" >&2; exit 1; }
if [ -z "${ZAI_API_KEY:-}" ] && [ -n "${LLM_WIKI_ZAI_TOKEN:-}" ]; then export ZAI_API_KEY="$LLM_WIKI_ZAI_TOKEN"; fi
[ -n "${ZAI_API_KEY:-}" ] || { echo "ERROR: ZAI_API_KEY not set" >&2; exit 1; }
command -v pi >/dev/null 2>&1 || { echo "ERROR: pi not on PATH" >&2; exit 1; }
# Resolve the harmostes binary into an ARRAY so a "python3 /path/harmostes.py"
# value word-splits correctly (a quoted scalar would be one command name →
# exit 127). Honors $HARMOSTES, else 'harmostes' on PATH, else the baked-in .py.
if [ -n "${HARMOSTES:-}" ]; then
    read -ra HARMOSTES_CMD <<<"$HARMOSTES"
elif command -v harmostes >/dev/null 2>&1; then
    HARMOSTES_CMD=(harmostes)
elif [ -x /usr/local/bin/harmostes.py ]; then
    HARMOSTES_CMD=(python3 /usr/local/bin/harmostes.py)
else
    echo "ERROR: harmostes not found" >&2; exit 1
fi

read_yaml() { yq -r "$1" "$DEF_FILE"; }
FORK_URL=$(read_yaml '.fork.url')
FORK_DEFAULT_BRANCH=$(read_yaml '.fork.default_branch')
UPSTREAM_URL=$(read_yaml '.upstream.url')
UPSTREAM_BRANCH=$(read_yaml '.upstream.branch')

echo "=== resolve-conflict: $FORK_NAME (cherry-pick + harmostes) ==="
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
  echo "  cherry-pick stopped on a conflict — harmostes will drive it"
else
  echo "  cherry-pick clean"
fi

# ── Phase 2: harmostes — agent task → gate → feedback-as-session-continuation ─
# harmostes drives ONE warm pi RPC session. The agent drives the cherry-pick to
# completion + pushes; harmostes runs gate-resolved.sh (markers + validate-fork.sh
# + signatures); on failure it feeds the error back to the SAME session up to
# RESOLVER_FIX_RETRIES. Exit 0 = gate green; 1 = failed after N; 2 = pi error.
if [ "$NEEDS_LLM" = "1" ]; then
  CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | grep -v '^$' || true)
  cat > "/tmp/resolve-${FORK_NAME}-task.txt" <<PROMPT
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
5. STOP. Do NOT merge, open/comment on PRs, or run validation. Pushing the clean
   branch ends your work — the gate runs separately.

If a later validation gate fails (you'll be told the exact error in this same
session), fix it on $SYNC_BRANCH and push again. The release branch is sacrosanct.
PROMPT

  echo ""
  echo "=== harmostes: agent task → gate → feedback (warm pi RPC session) ==="
  set +e
  "${HARMOSTES_CMD[@]}" task \
    --skill "$SKILL_PATH" --model "$MODEL" --tools read,bash,edit,grep \
    --workdir "$WORKDIR" \
    --task-file "/tmp/resolve-${FORK_NAME}-task.txt" \
    --gate "bash '$MAINT_DIR/checks/gate-resolved.sh' '$FORK_NAME' '$WORKDIR'" \
    --max-fixes "${RESOLVER_FIX_RETRIES:-3}" \
    --log "/tmp/resolve-${FORK_NAME}-events.jsonl" \
    --timeout "${RESOLVER_TIMEOUT:-1800}"
  HARMOSTES_RC=$?
  set -e
  if [ "$HARMOSTES_RC" -ne 0 ]; then
    echo ""
    echo "=== Not resolved (harmostes exit $HARMOSTES_RC) — PR stays labelled needs-conflict-resolution ==="
    git push --quiet origin "$SYNC_BRANCH" 2>&1 || true   # push partial work for review
    exit 1
  fi
fi

# ── Phase 3: gate green — replace the release branch + release ────────────────
# (cherry-pick model: the sync branch IS the new release branch — fresh upstream
# + ported customizations. force-update, don't merge.)
git checkout --quiet "$SYNC_BRANCH" 2>/dev/null || true
git add -A 2>/dev/null || true
git diff --cached --quiet || git commit --no-edit --quiet 2>/dev/null || true
git push --quiet origin "$SYNC_BRANCH" 2>&1 || true

echo ""
echo "=== Conflicts resolved — opening PR + triggering merge ==="
host_label_create "auto-merge" 0E8A16 2>/dev/null || true
PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" \
  "sync: $FORK_NAME — cherry-pick resolved by agent ($SYNC_DATE)" \
  "Customizations cherry-picked onto fresh upstream; conflicts resolved via harmostes (pi RPC + skill + wiki intent + gate-feedback loop)." \
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
