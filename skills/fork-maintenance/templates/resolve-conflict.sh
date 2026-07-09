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

# ── Phase 3: monitor + build-error feedback loop ────────────────────────────
# Re-validate the agent's push. On ANY gate failure, feed the CONCRETE error back
# to the agent (pi) to fix + push, then re-validate — up to MAX_FIX_RETRIES. This
# turns a "plausible but non-compiling" resolution (e.g. a port referencing an
# upstream-removed symbol, like signoz's GetAdditionTuples) into an automatic fix,
# mirroring the llm-wiki CI self-healing loop. Only a green gate set deploys.
MAX_FIX_RETRIES="${RESOLVER_FIX_RETRIES:-3}"
PATCH_COUNT=$(read_yaml '.patches | length' 2>/dev/null || true)
DELETIONS=$(read_yaml '.deletions[]' 2>/dev/null || true)

git cherry-pick --abort 2>/dev/null || true   # conclude any unfinished cherry-pick

add_fail() { FAIL_DETAIL="${FAIL_DETAIL:+$FAIL_DETAIL
}$1"; }

FIX_ATTEMPT=0
while true; do
  FIX_ATTEMPT=$((FIX_ATTEMPT + 1))
  FAIL_DETAIL=""
  RESOLVE_EXIT=0
  echo ""
  echo "=== Monitor (attempt $FIX_ATTEMPT/$MAX_FIX_RETRIES): fetching push + re-running gates ==="
  git fetch --quiet origin "$SYNC_BRANCH" 2>/dev/null || true
  git checkout --quiet "$SYNC_BRANCH" 2>/dev/null || true
  git reset --hard --quiet "origin/$SYNC_BRANCH" 2>/dev/null || true

  # declarative deletions (belt-and-suspenders) before validating
  if [ -n "$DELETIONS" ]; then
    for del_path in $DELETIONS; do [ -e "${del_path%/}" ] && git rm -rf --quiet "${del_path%/}" 2>/dev/null || true; done
    git add -A 2>/dev/null || true
    git diff --cached --quiet || { git commit --no-edit --quiet 2>/dev/null || true; git push --quiet origin "$SYNC_BRANCH" 2>&1 || true; }
  fi

  # gate 1 — conflict markers
  MARKERS=$(git grep -l -E '^(<<<<<<<|>>>>>>>|=======) ' -- . 2>/dev/null || true)
  if [ -n "$MARKERS" ]; then echo "❌ gate 1: markers remain"; echo "$MARKERS" | sed 's/^/  - /'; RESOLVE_EXIT=1; add_fail "Conflict markers remain in: $(echo "$MARKERS" | tr '\n' ' ')"; else echo "✅ gate 1: no markers"; fi

  # gate 5 — validate-fork.sh (build / codegen / integration)
  if [ -f "$MAINT_DIR/checks/validate-fork.sh" ]; then
    set +e; bash "$MAINT_DIR/checks/validate-fork.sh" "$FORK_NAME" "$WORKDIR" >/tmp/resolve-validate.log 2>&1; V=$?; set -e
    if [ "$V" -eq 0 ]; then echo "✅ gate 5: validation green"; else
      echo "❌ gate 5: validation failed"; tail -8 /tmp/resolve-validate.log | sed 's/^/    /'
      RESOLVE_EXIT=1; add_fail "Build/validation failed:\n$(tail -25 /tmp/resolve-validate.log)"
    fi
  fi

  # gate 4 — patch signatures
  SF=0; SIG_DETAIL=""
  for i in $(seq 0 $((PATCH_COUNT - 1))); do
    P_FILE=$(read_yaml ".patches[$i].file"); P_SIG=$(read_yaml ".patches[$i].signature")
    if [ -f "$P_FILE" ]; then
      [ "$(grep -cF "$P_SIG" "$P_FILE" 2>/dev/null || true)" -eq 0 ] && { echo "❌ gate 4: signature lost: $P_FILE"; SF=1; SIG_DETAIL="${SIG_DETAIL} $P_FILE"; }
    fi
  done
  [ "$SF" -eq 0 ] && echo "✅ gate 4: signatures intact" || { RESOLVE_EXIT=1; add_fail "Patch signatures lost in:${SIG_DETAIL}"; }

  # green → deploy
  if [ "$RESOLVE_EXIT" -eq 0 ]; then
    echo ""
    echo "=== Conflicts resolved — opening PR + triggering merge (after $FIX_ATTEMPT pass(es)) ==="
    host_label_create "auto-merge" 0E8A16 2>/dev/null || true
    PR_URL=$(host_pr_create "$FORK_DEFAULT_BRANCH" "$SYNC_BRANCH" \
      "sync: $FORK_NAME — cherry-pick resolved by agent ($SYNC_DATE)" \
      "Customizations cherry-picked onto fresh upstream; conflicts resolved by the agent (pi + skill + wiki intent) after $FIX_ATTEMPT validation pass(es). Gates: markers + validate-fork.sh + signatures." \
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
        [ -z "$(git tag --points-at HEAD | grep -E "${UPSTREAM_VER}-rezus\." )" ] && {
          git tag "$REL" && git push --quiet origin "$REL" 2>&1 && echo "=== Released $REL → image build → Flux deploys ==="
        }
      fi
    fi
    echo ""
    echo "=== resolve-conflict complete: $FORK_NAME (merged) ==="
    exit 0
  fi

  # failed — feed the error back to the agent (if retries remain)
  if [ "$FIX_ATTEMPT" -ge "$MAX_FIX_RETRIES" ]; then
    echo ""
    echo "=== Not resolved after $MAX_FIX_RETRIES attempts — PR stays labelled needs-conflict-resolution ==="
    exit 1
  fi
  echo ""
  echo "=== Gate failed (attempt $FIX_ATTEMPT) — feeding the error back to the agent for a fix ==="
  cat > "/tmp/resolve-${FORK_NAME}-fix-prompt.txt" <<FIXPROMPT
You are fixing a fork-sync resolution on branch $SYNC_BRANCH that did NOT pass the validation gates.

Working directory: $WORKDIR  (on branch $SYNC_BRANCH; fresh upstream $UPSTREAM_BRANCH + the fork's customizations).

The gates failed with:
$FAIL_DETAIL

Fix it:
1. Read the error(s) above. The usual cause is a customization ported onto an
   upstream API that has since changed (e.g. a removed/renamed symbol, or a
   changed function signature) — adapt the customization to upstream's CURRENT
   shape, preserving the fork's INTENT (see $([ -n "$WIKI_PAGE" ] && echo "$WIKI_PAGE '## Fork Maintenance' chapter" || echo "the fork definition patches and descriptions")). Do NOT drop the customization; port it correctly.
2. Ensure zero conflict markers remain (git grep -E '^(<<<<<<<|>>>>>>>|=======) ').
3. When fixed:
       git add -A
       git commit -m "fix: gate failures ($FORK_NAME) — attempt $FIX_ATTEMPT"
       git push origin $SYNC_BRANCH
4. STOP. Do not merge, open PRs, or run validation — only fix + push.

Release branch is sacrosanct — make $SYNC_BRANCH pass the gates (compiles, no
markers, signatures intact) and push.
FIXPROMPT
  set +e
  timeout "${RESOLVER_TIMEOUT:-1800}" pi --print \
    --skill "$SKILL_PATH" --model "$MODEL" --approve --no-skills \
    "$(cat "/tmp/resolve-${FORK_NAME}-fix-prompt.txt")" 2>&1 | tee -a "/tmp/resolve-${FORK_NAME}-pi.log"
  set -e
  echo "fix attempt $FIX_ATTEMPT done — re-validating"
done
