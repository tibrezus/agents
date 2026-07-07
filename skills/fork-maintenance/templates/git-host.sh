#!/usr/bin/env bash
# =============================================================================
# git-host.sh — Git-host abstraction for fork maintenance
# =============================================================================
# Sources by sync-fork.sh. Dispatches git-push, label, and PR creation to the
# correct host API based on the fork definition's `fork.platform` field.
#
# Supported platforms:
#   github  — uses the `gh` CLI (default; works for GitHub-hosted forks)
#   forgejo — uses the Codeberg/Forgejo/Gitea REST API via curl (no `tea` dep)
#
# The fork definition declares its host:
#
#   fork:
#     url: https://codeberg.org/rezuscloud/foo   # or github.com/...
#     platform: forgejo                           # github (default) | forgejo
#     api_url: https://codeberg.org/api/v1        # forgejo only — REST base
#     token_env: CODEBERG_TOKEN                   # env var holding the PAT
#                                                  # default: GITHUB_TOKEN (github)
#                                                  #          CODEBERG_TOKEN (forgejo)
#
# Git push uses the credential helper regardless of platform — only the label
# and PR creation differ (gh CLI vs REST). Auth is set up once via host_setup.
# =============================================================================
# Usage (from sync-fork.sh):
#   source git-host.sh
#   host_setup             # configure git auth + resolve platform/token
#   host_label_create NAME COLOR
#   host_pr_create BASE HEAD TITLE BODY LABEL  -> echoes PR URL
# =============================================================================

# Read a YAML path from the active fork definition ($DEF_FILE, set by caller).
_git_host_ry() { yq -r "$1" "${DEF_FILE:?DEF_FILE must be set by caller}" 2>/dev/null; }

# ---- accessors ---------------------------------------------------------------

host_platform() {
  local p
  p=$(_git_host_ry '.fork.platform // "github"')
  case "$p" in github|forgejo|local) echo "$p" ;; *) echo "github" ;; esac
}

# Env var holding the PAT for this fork's host (defaults per platform).
host_token_env() {
  local env_name platform
  env_name=$(_git_host_ry '.fork.token_env // ""')
  if [ -z "$env_name" ]; then
    platform=$(host_platform)
    case "$platform" in
      forgejo) env_name="CODEBERG_TOKEN" ;;
      *)       env_name="GITHUB_TOKEN" ;;
    esac
  fi
  echo "$env_name"
}

# owner/repo parsed from fork.url (host-agnostic: works for github + codeberg).
host_owner_repo() {
  _git_host_ry '.fork.url' | sed -E 's#https?://[^/]+/([^/]+)/([^/]+)(\.git)?/?.*#\1/\2#'
}

# Bare hostname of the fork repo (for the git credential helper).
host_git_host() {
  _git_host_ry '.fork.url' | sed -E 's#(https?://[^/]+)/.*#\1#' | sed -E 's#https?://##'
}

# ---- one-time setup (call after cloning the fork) ---------------------------

host_setup() {
  local platform token_env token
  platform=$(host_platform)

  # Local file:// repos (testing / local validation): no auth, no API.
  if [ "$platform" = "local" ]; then
    git config --global user.name "fork-maintenance-bot" 2>/dev/null || true
    git config --global user.email "flux@rezus.cloud" 2>/dev/null || true
    echo "[git-host] platform=local repo=$FORK_URL (no auth)"
    return 0
  fi

  token_env=$(host_token_env)
  token="${!token_env:-}"   # expand the env var named by token_env

  if [ -z "$token" ]; then
    echo "ERROR: token env var '$token_env' is empty for fork '$FORK_NAME'" >&2
    return 1
  fi
  export FORK_TOKEN="$token"

  # Git push works identically on both platforms via the credential helper.
  git config --global user.name "fork-maintenance-bot" 2>/dev/null || true
  git config --global user.email "flux@rezus.cloud" 2>/dev/null || true
  git config --global credential.helper store 2>/dev/null || true
  local gh_host
  gh_host=$(host_git_host)
  echo "https://x-access-token:${token}@${gh_host}" > ~/.git-credentials
  chmod 600 ~/.git-credentials

  case "$platform" in
    github)
      export GH_TOKEN="$token"
      ;;
    forgejo)
      local api
      api=$(_git_host_ry '.fork.api_url // ""')
      if [ -z "$api" ]; then
        echo "ERROR: forgejo fork '$FORK_NAME' requires fork.api_url (REST base)" >&2
        return 1
      fi
      export FORGEJO_API="$api"
      ;;
  esac
  echo "[git-host] platform=$platform token_env=$token_env repo=$(host_owner_repo)"
}

# ---- label creation ----------------------------------------------------------

host_label_create() {
  local label="$1" color="${2:-0E8A16}"
  local platform owner_repo
  platform=$(host_platform)
  owner_repo=$(host_owner_repo)

  case "$platform" in
    github)
      gh label create "$label" --repo "$FORK_URL" --color "$color" \
        --if-not-exists --quiet 2>/dev/null || true
      ;;
    forgejo)
      # Codeberg/Gitea expects color WITH leading '#'.
      curl -sf -X POST "${FORGEJO_API}/repos/${owner_repo}/labels" \
        -H "Authorization: token ${FORK_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${label}\",\"color\":\"#${color}\"}" >/dev/null 2>&1 || true
      ;;
    local) ;;  # no-op
  esac
}

# ---- PR creation (echoes the new PR URL on success) --------------------------

host_pr_create() {
  local base="$1" head="$2" title="$3" body="$4" label="${5:-}"
  local platform owner_repo
  platform=$(host_platform)
  owner_repo=$(host_owner_repo)

  case "$platform" in
    github)
      # First attempt with the label; fall back without it (label/perm issues).
      gh pr create --repo "$FORK_URL" --base "$base" --head "$head" \
        --title "$title" ${label:+--label "$label"} --body "$body" 2>&1 || \
        gh pr create --repo "$FORK_URL" --base "$base" --head "$head" \
          --title "$title" --body "$body" 2>&1
      ;;
    local)
      # No PR API on a file:// repo; report a synthetic URL. The merge itself
      # is performed by host_pr_merge (local git merge into the default branch).
      echo "local://${FORK_URL}#${head}"
      ;;
    forgejo)
      local body_json pr_url
      body_json=$(printf '%s' "$body" | jq -Rs .)
      pr_url=$(jq -n \
        --arg head "$head" --arg base "$base" --arg title "$title" \
        --argjson body "$body_json" \
        '{head:$head, base:$base, title:$title, body:$body}' \
        | curl -sf -X POST "${FORGEJO_API}/repos/${owner_repo}/pulls" \
            -H "Authorization: token ${FORK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d @-)
      echo "$pr_url" | jq -r '.html_url // "ERROR: PR creation failed"' 2>&1
      # Attach the label to the new PR if provided.
      if [ -n "$label" ] && [ -n "$pr_url" ]; then
        local index
        index=$(echo "$pr_url" | jq -r '.number // empty' 2>/dev/null)
        [ -n "$index" ] && curl -sf -X POST \
          "${FORGEJO_API}/repos/${owner_repo}/issues/${index}/labels" \
          -H "Authorization: token ${FORK_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"labels\":[\"${label}\"]}" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

# ---- PR merge (squash) -------------------------------------------------------
# Merges a PR by number or head branch. Used for auto-merge when all gates pass.
# Echoes the resulting merge commit SHA on success; returns non-zero on failure.
host_pr_merge() {
  local pr_ref="$1"   # PR number (github/forgejo) — resolve from head branch first
  local platform owner_repo
  platform=$(host_platform)
  owner_repo=$(host_owner_repo)

  case "$platform" in
    github)
      # Resolve PR number from the head branch if a branch name was passed.
      if ! [[ "$pr_ref" =~ ^[0-9]+$ ]]; then
        pr_ref=$(gh pr list --repo "$FORK_URL" --head "$pr_ref" --state open \
                 --json number -q '.[0].number' 2>/dev/null)
      fi
      [ -z "$pr_ref" ] && { echo "ERROR: could not resolve PR number"; return 1; }
      gh pr merge "$pr_ref" --repo "$FORK_URL" --squash --delete-branch 2>&1 \
        && gh pr view "$pr_ref" --repo "$FORK_URL" --json mergeCommit -q '.mergeCommit.oid' 2>/dev/null
      ;;
    forgejo)
      # Resolve PR index from head branch if needed.
      if ! [[ "$pr_ref" =~ ^[0-9]+$ ]]; then
        pr_ref=$(curl -sf "${FORGEJO_API}/repos/${owner_repo}/pulls?state=open" \
                 -H "Authorization: token ${FORK_TOKEN}" \
                 | jq -r --arg h "$pr_ref" '.[] | select(.head.ref==$h) | .number' 2>/dev/null | head -1)
      fi
      [ -z "$pr_ref" ] && { echo "ERROR: could not resolve PR index"; return 1; }
      curl -sf -X POST "${FORGEJO_API}/repos/${owner_repo}/pulls/${pr_ref}/merge" \
        -H "Authorization: token ${FORK_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"Do":"squash","merge_title_field":"auto-merge (all gates green)","delete_branch":true}' \
        && curl -sf "${FORGEJO_API}/repos/${owner_repo}/pulls/${pr_ref}" \
           -H "Authorization: token ${FORK_TOKEN}" | jq -r '.merge_commit_sha // .number' 2>/dev/null
      ;;
    local)
      # Locally merge the resolved sync branch into the fork's default branch,
      # then push it back to origin so the canonical fork repo reflects the
      # deploy (mirrors what the github/forgejo API merge does on the remote).
      # pr_ref is the sync branch name. Returns the new HEAD sha.
      git checkout "$FORK_DEFAULT_BRANCH" 2>/dev/null || git checkout -b "$FORK_DEFAULT_BRANCH"
      git merge --no-edit "$pr_ref" >/dev/null 2>&1
      git push --quiet origin "$FORK_DEFAULT_BRANCH" 2>&1 || true
      git rev-parse HEAD
      ;;
  esac
}
