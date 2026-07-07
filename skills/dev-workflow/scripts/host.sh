#!/usr/bin/env bash
# host.sh — platform dispatch for the dev-workflow skill.
#
# Source this file from the project repo:
#   source "$SKILL_DIR/scripts/host.sh"
#
# Every function auto-detects the platform from `git remote get-url origin`
# and dispatches to `gh` (GitHub) or `fj` + REST API (Forgejo/Codeberg).
# Adding a host = one case arm in dw_detect_platform + dw_host.

dw_die() { echo "dev-workflow: $*" >&2; exit 1; }

# ── detection ──────────────────────────────────────────────────────────────

dw_detect_platform() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || dw_die "no 'origin' remote in $(pwd)"
  case "$url" in
    *github.com*)    echo github ;;
    *codeberg.org*)  echo codeberg ;;
    *)               echo forgejo ;;
  esac
}

# API host (REST base, without scheme/path)
dw_host() {
  local url platform
  url=$(git remote get-url origin 2>/dev/null)
  platform=$(dw_detect_platform)
  case "$platform" in
    github)   echo "api.github.com" ;;
    codeberg) echo "codeberg.org" ;;
    forgejo)  # git.rezus.cloud etc. — derive host from the remote URL
      url="${url#*://}"; url="${url#*@}"; url="${url%%[:/]*}"; echo "$url" ;;
  esac
}

# owner/repo from the origin remote (handles scp-like, ssh://, https://)
dw_owner_repo() {
  git remote get-url origin 2>/dev/null \
    | sed -E 's#\.git$##; s#(https?://|ssh://)?##; s#^[^@]*@##; s#^[^:/]+[:/]##' \
    | sed -E 's#^(.*/)?([^/]+/[^/]+)$#\2#'
}

dw_default_branch() {
  # Prefer origin/HEAD, fall back to main, then master
  local b
  b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  [ -n "$b" ] && { echo "$b"; return; }
  git show-ref --verify --quiet refs/heads/main && { echo main; return; }
  git show-ref --verify --quiet refs/heads/master && { echo master; return; }
  git ls-remote --symref origin HEAD 2>/dev/null | sed -n 's#.*refs/heads/##p' | head -1
}

# Pick the API token for the current platform
dw_token() {
  case "$(dw_detect_platform)" in
    github)   echo "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ;;
    codeberg) echo "${CODEBERG_TOKEN:-${FJ_TOKEN:-}}" ;;
    forgejo)  echo "${RZC_TOKEN:-${FJ_TOKEN:-${FORGEJO_TOKEN:-}}}" ;;
  esac
}

# ── issues ─────────────────────────────────────────────────────────────────

# dw_find_issue "<query>"  → echoes issue number (first open match) or nothing
dw_find_issue() {
  local query="$1" platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      gh issue list --repo "$owner_repo" --state open --search "$query" \
        --json number -q '.[0].number' 2>/dev/null ;;
    *)
      local host token
      host=$(dw_host); token=$(dw_token)
      curl -fsSL -H "Authorization: token $token" \
        "https://$host/api/v1/repos/$owner_repo/issues?state=open&type=issues&q=$(printf %s "$query" | jq -sRr @uri 2>/dev/null || printf %s "$query")" \
        2>/dev/null | jq -r '.[0].number // empty' 2>/dev/null ;;
  esac
}

# dw_create_issue "<title>" "<body>"  → echoes the new issue number
dw_create_issue() {
  local title="$1" body="${2:-}" platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      gh issue create --repo "$owner_repo" --title "$title" --body "$body" ;;
    *)
      local host token
      host=$(dw_host); token=$(dw_token)
      curl -fsSL -H "Authorization: token $token" -H 'Content-Type: application/json' \
        -X POST "https://$host/api/v1/repos/$owner_repo/issues" \
        -d "$(jq -n --arg t "$title" --arg b "$body" '{title:$t,body:$b}')" \
        2>/dev/null | jq -r '.number' ;;
  esac
}

# ── branches ───────────────────────────────────────────────────────────────

# dw_find_branch_for_issue "<issue#>"  → echoes matching branch name or nothing
dw_find_branch_for_issue() {
  local issue="$1"
  git branch -a --list "*${issue}*" 2>/dev/null \
    | sed 's/^[* ]*//; s#^remotes/origin/##' | grep -v HEAD | head -1
}

# dw_create_branch "<name>" "[base]"  → creates + switches to the branch
dw_create_branch() {
  local name="$1" base="${2:-$(dw_default_branch)}"
  git fetch origin "$base" >/dev/null 2>&1
  git switch -c "$name" "origin/$base"
}

# ── milestones ─────────────────────────────────────────────────────────────

# dw_resolve_milestone "<convention>"  → echoes "<id>:<title>" or empty
#   convention: current | none | <exact title>
dw_resolve_milestone() {
  local convention="${1:-current}"
  [ "$convention" = "none" ] && { echo ""; return; }
  local platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      if [ "$convention" = "current" ]; then
        gh api "repos/$owner_repo/milestones?state=open&sort=due_on&direction=desc" \
          --jq '.[0] | "\(.number):\(.title)"' 2>/dev/null
      else
        gh api "repos/$owner_repo/milestones?state=open" \
          --jq ".[] | select(.title==\"$convention\") | \"\(.number):\(.title)\"" 2>/dev/null
      fi ;;
    *)
      local host token
      host=$(dw_host); token=$(dw_token)
      local qs='state=open&sort=due_date&direction=desc'
      [ "$convention" != "current" ] && qs="$qs&title=$(printf %s "$convention" | jq -sRr @uri 2>/dev/null || printf %s "$convention")"
      curl -fsSL -H "Authorization: token $token" \
        "https://$host/api/v1/repos/$owner_repo/milestones?$qs" 2>/dev/null \
        | jq -r 'if .[0] then "\(.[0].id):\(.[0].title)" else empty end' 2>/dev/null ;;
  esac
}

# dw_set_milestone "<issue#>" "<milestone-id>"  → assigns the issue to a milestone
dw_set_milestone() {
  local issue="$1" mid="$2" platform owner_repo
  [ -z "$mid" ] && return 0
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      gh issue edit "$issue" --repo "$owner_repo" --milestone \
        "$(gh api "repos/$owner_repo/milestones" --jq ".[] | select(.number==$mid) | .title")" ;;
    *)
      local host token
      host=$(dw_host); token=$(dw_token)
      curl -fsSL -H "Authorization: token $token" -H 'Content-Type: application/json' \
        -X PATCH "https://$host/api/v1/repos/$owner_repo/issues/$issue" \
        -d "$(jq -n --argjson m "$mid" '{milestone:$m}')" >/dev/null ;;
  esac
}

# ── pull requests ──────────────────────────────────────────────────────────

# dw_open_pr "<head>" "<base>" "<title>" "<body>"  → echoes the PR URL/number
dw_open_pr() {
  local head="$1" base="$2" title="$3" body="${4:-}" platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      gh pr create --repo "$owner_repo" --base "$base" --head "$head" \
        --title "$title" --body "$body" ;;
    *)
      local host token
      host=$(dw_host); token=$(dw_token)
      curl -fsSL -H "Authorization: token $token" -H 'Content-Type: application/json' \
        -X POST "https://$host/api/v1/repos/$owner_repo/pulls" \
        -d "$(jq -n --arg h "$head" --arg b "$base" --arg t "$title" --arg bd "$body" \
            '{head:$h,base:$b,title:$t,body:$bd}')" 2>/dev/null | jq -r '.html_url' ;;
  esac
}

# dw_pr_number_from_branch "<branch>"  → echoes the open PR number on that head
dw_pr_number_from_branch() {
  local branch="$1" platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      gh pr list --repo "$owner_repo" --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null ;;
    *)
      local host token
      host=$(dw_host); token=$(dw_token)
      curl -fsSL -H "Authorization: token $token" \
        "https://$host/api/v1/repos/$owner_repo/pulls?state=open" 2>/dev/null \
        | jq -r --arg b "$branch" '.[] | select(.head.ref==$b) | .number' 2>/dev/null | head -1 ;;
  esac
}

# ── CI ──────────────────────────────────────────────────────────────────────

# dw_watch_ci "<pr# or branch>"  → blocks until CI finishes; exits 0 if green, 1 if any failed
dw_watch_ci() {
  local ref="$1" platform owner_repo pr
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      # ref may be a PR number or a branch; resolve to a PR for pr checks
      pr=$(gh pr list --repo "$owner_repo" --head "$ref" --state open --json number -q '.[0].number' 2>/dev/null)
      [ -z "$pr" ] && pr="$ref"
      gh pr checks "$pr" --repo "$owner_repo" --watch --interval 15 >/dev/null 2>&1
      # --watch exits non-zero if any check fails; double-check final state
      gh pr checks "$pr" --repo "$owner_repo" --json state -q 'all(.[]?.state=="SUCCESS") or (length==0)' 2>/dev/null | grep -q true ;;
    *)
      local host token sha status conclusion
      host=$(dw_host); token=$(dw_token)
      sha=$(git rev-parse "origin/$ref" 2>/dev/null || git rev-parse HEAD)
      echo "dev-workflow: polling CI on $owner_repo @ ${sha:0:8} (forgejo has no --watch)…" >&2
      for _ in $(seq 1 120); do
        # Forgejo actions status for the commit
        conclusion=$(curl -fsSL -H "Authorization: token $token" \
          "https://$host/api/v1/repos/$owner_repo/commits/$sha/status" 2>/dev/null \
          | jq -r '.state // empty')
        case "$conclusion" in
          success) return 0 ;;
          failure|error) return 1 ;;
          pending|"") sleep 15 ;;
          *) sleep 15 ;;
        esac
      done
      echo "dev-workflow: CI poll timed out after 30m" >&2; return 1 ;;
  esac
}

# dw_ci_green "<pr# or branch>"  → exit 0 if currently green, 1 otherwise
dw_ci_green() { dw_watch_ci "$1"; }

# ── merge ───────────────────────────────────────────────────────────────────

# dw_merge_pr "<pr#>" "<method: squash|merge|rebase>"  → merges ONLY if CI green
dw_merge_pr() {
  local pr="$1" method="${2:-squash}"
  dw_ci_green "$pr" || dw_die "refusing to merge PR #$pr: CI is not green"
  local platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      gh pr merge "$pr" --repo "$owner_repo" "--$method" --delete-branch ;;
    *)
      local host token do_verb
      host=$(dw_host); token=$(dw_token)
      case "$method" in squash) do_verb="squash";; rebase) do_verb="rebase";; *) do_verb="merge";; esac
      curl -fsSL -H "Authorization: token $token" -H 'Content-Type: application/json' \
        -X POST "https://$host/api/v1/repos/$owner_repo/pulls/$pr/merge" \
        -d "$(jq -n --arg d "$do_verb" '{Do:$d}')" \
        && echo "merged PR #$pr ($do_verb) into default branch" ;;
  esac
}
