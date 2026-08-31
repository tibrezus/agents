#!/usr/bin/env bash
# host.sh — platform dispatch for the dev-workflow skill.
#
# Source this file from the project repo:
#   source "$SKILL_DIR/scripts/host.sh"
#
# Every function auto-detects the platform from `git remote get-url origin`
# and dispatches to `gh` (GitHub) or `fj` + REST API (Forgejo/Codeberg).
# Adding a host = one case arm in dw_detect_platform + dw_host.

# Shared test-command detection (also used by adopt.sh). Defined once so the
# language/runner list evolves in a single file.
_dw_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=detect-test-command.sh
# shellcheck disable=SC1091
. "$_dw_dir/detect-test-command.sh"

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

# dw_request_review "<pr#>" "[label]"  → guarded ingress to the adversarial review.
#   REFUSES unless the full pipeline (fast tier when none is configured) is
#   green at the PR's current head SHA — reviewing unvalidated code is
#   pointless by contract (dev-workflow gates 11→12 handoff).
dw_request_review() {
  local pr="$1" label="${2:-needs-review}"
  local platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  local head; head=$(dw_pr_head "$pr")
  [ -n "$head" ] || dw_die "cannot resolve head SHA of PR #$pr"
  if [ -n "$(dw_full_pipeline_workflows)" ]; then
    dw_full_green "$head" \
      || dw_die "refusing review: full pipeline not green at head ${head:0:8} — declare ready first (dw_trigger_full_pipeline), or fix red CI on the branch"
  else
    dw_watch_ci "$pr" >/dev/null 2>&1 \
      || dw_die "refusing review: fast tier not green at head ${head:0:8} — fix on the branch and re-push"
  fi
  # Ensure the label exists (GitHub 422s / Gitea 404s unknown labels) — same
  # create-if-missing pattern as dw_trigger_full_pipeline, so there is no
  # per-repo one-time setup.
  case "$platform" in
    github)
      gh label create "$label" --repo "$owner_repo" --color fbca04 \
        --description "request the adversarial review (declare ready)" >/dev/null 2>&1 || true ;;
    *)
      local rhost rtoken exists
      rhost=$(dw_host); rtoken=$(dw_token)
      exists=$(curl -fsSL -H "Authorization: token $rtoken" \
        "https://$rhost/api/v1/repos/$owner_repo/labels?limit=50" 2>/dev/null \
        | jq -r --arg l "$label" '.[] | select(.name==$l) | .id' | head -1)
      [ -z "$exists" ] && curl -fsSL -H "Authorization: token $rtoken" -H 'Content-Type: application/json' \
        -X POST "https://$rhost/api/v1/repos/$owner_repo/labels" \
        -d "$(jq -n --arg n "$label" '{name:$n,color:"fbca04",description:"request the adversarial review (declare ready)"}')" >/dev/null ;;
  esac
  case "$platform" in
    github)
      gh issue edit "$pr" --repo "$owner_repo" --add-label "$label" 2>/dev/null \
        || gh api "repos/$owner_repo/issues/$pr/labels" -f "labels[]=$label" >/dev/null 2>&1 ;;
    *)
      local host token
      host=$(dw_host); token=$(dw_token)
      curl -fsSL -H "Authorization: token $token" -H 'Content-Type: application/json' \
        -X POST "https://$host/api/v1/repos/$owner_repo/issues/$pr/labels" \
        -d "$(jq -n --arg l "$label" '{labels:[$l]}')" >/dev/null ;;
  esac
  echo "dev-workflow: added '$label' label to PR #$pr — the reviewer polls the label (every ~10 min); verdict typically lands within 15 min" >&2
}

# dw_wait_review "<pr#>" → polls PR comments for the verdict trailer
#   <!-- pr-review: APPROVE @ <sha> --> bound to the CURRENT head SHA.
#   Exit 0 = APPROVE @ head; exit 2 = REQUEST_CHANGES (fix, re-declare);
#   exit 1 = timeout (30 min).
dw_wait_review() {
  local pr="$1" head; head=$(dw_pr_head "$pr")
  [ -n "$head" ] || dw_die "cannot resolve head SHA of PR #$pr"
  local platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  echo "dev-workflow: waiting for adversarial review verdict @ ${head:0:8}…" >&2
  local bodies
  for _ in $(seq 1 60); do
    case "$platform" in
      github) bodies=$(gh api "repos/$owner_repo/issues/$pr/comments" --jq '.[].body' 2>/dev/null) ;;
      *) local host token; host=$(dw_host); token=$(dw_token)
         bodies=$(curl -fsSL -H "Authorization: token $token" \
           "https://$host/api/v1/repos/$owner_repo/issues/$pr/comments" 2>/dev/null | jq -r '.[].body // empty') ;;
    esac
    if echo "$bodies" | grep -qF "<!-- pr-review: APPROVE @ $head -->"; then
      echo "dev-workflow: review APPROVE @ ${head:0:8}" >&2; return 0
    fi
    if echo "$bodies" | grep -qF "<!-- pr-review: REQUEST_CHANGES @ $head -->"; then
      echo "dev-workflow: review REQUEST_CHANGES @ ${head:0:8} — address findings, then re-declare ready" >&2; return 2
    fi
    sleep 30
  done
  echo "dev-workflow: review verdict timed out after 30 min" >&2; return 1
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
      gh pr checks "$pr" --repo "$owner_repo" --json state -q 'all(.state=="SUCCESS") or (length==0)' 2>/dev/null | grep -q true ;;
    *)
      local host token sha status conclusion
      host=$(dw_host); token=$(dw_token)
      sha=$(git rev-parse --verify -q "origin/$ref" 2>/dev/null || git rev-parse --verify -q HEAD)
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

# ── full pipeline (merge-gated tier) ───────────────────────────────────────
#
# Config precedence: DW_FULL_PIPELINE env > AGENTS.md "Full pipeline:" line
# ("none" = explicitly off) > full-ci.yml autodetect > none (fast tier only).

dw_full_pipeline_workflows() {
  local cfg="${DW_FULL_PIPELINE:-}"
  if { [ -z "$cfg" ] || [ "$cfg" = "auto" ]; } && [ -f AGENTS.md ]; then
    cfg=$(sed -n 's/^[-*] \*\*[Ff]ull pipeline:\*\* `\([^`]*\)`.*/\1/p' AGENTS.md | head -1)
  fi
  [ "$cfg" = "none" ] && return 0
  if [ -z "$cfg" ]; then
    local d
    for d in .github/workflows .forgejo/workflows .gitea/workflows; do
      [ -f "$d/full-ci.yml" ] && { echo full-ci.yml; return; }
    done
    return 0
  fi
  echo "$cfg" | tr ',' ' '
}

# dw_pr_head "<pr#>" → head SHA of the PR
dw_pr_head() {
  local pr="$1" platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github) gh pr view "$pr" --repo "$owner_repo" --json headRefOid -q .headRefOid 2>/dev/null ;;
    *) local host token; host=$(dw_host); token=$(dw_token)
       curl -fsSL -H "Authorization: token $token" \
         "https://$host/api/v1/repos/$owner_repo/pulls/$pr" 2>/dev/null | jq -r '.head.sha' ;;
  esac
}

# dw_dispatch_full_pipeline "<branch>" → low-level API dispatch of every
#   configured workflow on the branch. FALLBACK only, for workflows wired
#   with workflow_dispatch alone — the primary trigger is the full-pipeline
#   label (dw_trigger_full_pipeline). Prints the bound head SHA.
dw_dispatch_full_pipeline() {
  local branch="$1" wf
  local wfs; wfs=$(dw_full_pipeline_workflows)
  [ -z "$wfs" ] && { echo "dev-workflow: no full pipeline configured — fast tier is the pipeline" >&2; return 0; }
  local sha; sha=$(git rev-parse --verify -q "origin/$branch" 2>/dev/null || git rev-parse --verify -q "$branch")
  local platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  for wf in $wfs; do
    case "$platform" in
      github)
        gh workflow run "$wf" --repo "$owner_repo" --ref "$branch" \
          || dw_die "dispatch of $wf failed" ;;
      *)
        # fj quirk: 204 success surfaces as "decode: EOF" stderr noise with
        # exit 0 — not a failure. curl fallback covers hosts without fj auth.
        local host token; host=$(dw_host); token=$(dw_token)
        fj api repo dispatch-workflow --owner "${owner_repo%%/*}" --repo "${owner_repo##*/}" \
          --workflowfilename "$wf" --body "{\"ref\":\"$branch\"}" >/dev/null 2>&1 \
          || curl -fsSL -H "Authorization: token $token" -X POST \
               "https://$host/api/v1/repos/$owner_repo/actions/workflows/$wf/dispatches" \
               -H 'Content-Type: application/json' -d "{\"ref\":\"$branch\"}" >/dev/null \
          || dw_die "dispatch of $wf failed" ;;
    esac
    echo "dev-workflow: dispatched $wf on $branch @ ${sha:0:8}" >&2
  done
  echo "$sha"
}

# dw_trigger_full_pipeline "<pr#|branch>" → THE primary full-pipeline trigger:
#   sets the full-pipeline label on the PR (removing it first if set, so a
#   re-trigger after a push always fires exactly one fresh labeled event).
#   Creates the label if missing. Works for agents and mirrors the human
#   action (ticking the label in the UI). Prints the bound head SHA.
dw_trigger_full_pipeline() {
  local pr="$1"
  case "$pr" in ''|*[!0-9]*) pr=$(dw_pr_number_from_branch "$pr") ;; esac
  [ -n "$pr" ] || dw_die "cannot resolve a PR from '$1'"
  [ -z "$(dw_full_pipeline_workflows)" ] && { echo "dev-workflow: no full pipeline configured — fast tier is the pipeline" >&2; return 0; }
  local label="${DW_FULL_PIPELINE_LABEL:-full-pipeline}"
  local head; head=$(dw_pr_head "$pr")
  [ -n "$head" ] || dw_die "cannot resolve head SHA of PR #$pr"
  local platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  case "$platform" in
    github)
      gh label create "$label" --repo "$owner_repo" --color 0ea5e9 \
        --description "run the full pipeline on the current head (declare ready)" >/dev/null 2>&1 || true
      gh issue edit "$pr" --repo "$owner_repo" --remove-label "$label" >/dev/null 2>&1 || true
      gh issue edit "$pr" --repo "$owner_repo" --add-label "$label" >/dev/null 2>&1 \
        || dw_die "failed to set '$label' on PR #$pr" ;;
    *)
      local host token lid exists
      host=$(dw_host); token=$(dw_token)
      # ensure the label exists — CHECK FIRST: Gitea allows duplicate names on
      # create (no unique constraint), so a blind POST can mint duplicates
      exists=$(curl -fsSL -H "Authorization: token $token" \
        "https://$host/api/v1/repos/$owner_repo/labels?limit=50" 2>/dev/null \
        | jq -r --arg l "$label" '.[] | select(.name==$l) | .id' | head -1)
      [ -z "$exists" ] && curl -fsSL -H "Authorization: token $token" -H 'Content-Type: application/json' \
        -X POST "https://$host/api/v1/repos/$owner_repo/labels" \
        -d "$(jq -n --arg n "$label" '{name:$n,color:"0ea5e9",description:"run the full pipeline on the current head (declare ready)"}')" >/dev/null
      # remove if present (loop: handles duplicate-name attach states) →
      # exactly one fresh labeled event on re-add
      for lid in $(curl -fsSL -H "Authorization: token $token" \
        "https://$host/api/v1/repos/$owner_repo/issues/$pr/labels" 2>/dev/null \
        | jq -r --arg l "$label" '.[] | select(.name==$l) | .id'); do
        curl -fsSL -X DELETE -H "Authorization: token $token" \
          "https://$host/api/v1/repos/$owner_repo/issues/$pr/labels/$lid" >/dev/null 2>&1 || true
      done
      curl -fsSL -H "Authorization: token $token" -H 'Content-Type: application/json' \
        -X POST "https://$host/api/v1/repos/$owner_repo/issues/$pr/labels" \
        -d "$(jq -n --arg l "$label" '{labels:[$l]}')" >/dev/null \
        || dw_die "failed to set '$label' on PR #$pr" ;;
  esac
  echo "dev-workflow: set '$label' on PR #$pr — full pipeline will run @ ${head:0:8}" >&2
  echo "$head"
}

# dw_full_green "<sha>" → exit 0 iff every configured workflow has a SUCCESS
#   run with head_sha == <sha>. Empty config → checks combined commit status
#   (fast tier) instead, mirroring dw_request_review's fallback.
dw_full_green() {
  local sha="$1" platform owner_repo wfs
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  wfs=$(dw_full_pipeline_workflows)
  if [ -z "$wfs" ]; then
    case "$platform" in
      github)
        gh pr checks "$(dw_pr_number_from_branch "$(git branch --show-current)")" \
          --repo "$owner_repo" --json state -q 'length>0 and all(.state=="SUCCESS")' 2>/dev/null | grep -q true ;;
      *) local host token; host=$(dw_host); token=$(dw_token)
         [ "$(curl -fsSL -H "Authorization: token $token" \
             "https://$host/api/v1/repos/$owner_repo/commits/$sha/status" 2>/dev/null \
             | jq -r '.state // empty')" = success ] ;;
    esac
    return
  fi
  local wf
  for wf in $wfs; do
    case "$platform" in
      github)
        gh api "repos/$owner_repo/actions/runs?head_sha=$sha" --paginate \
          --jq "[.workflow_runs[] | select((.path | endswith(\"$wf\")) or (.name==\"$wf\"))][0].conclusion" 2>/dev/null \
          | grep -q '^success$' || return 1 ;;
      *)
        local host token; host=$(dw_host); token=$(dw_token)
        # NOTE: Forgejo run records expose the workflow *name*, not filename —
        # configure the name in Full pipeline: when they differ.
        curl -fsSL -H "Authorization: token $token" \
          "https://$host/api/v1/repos/$owner_repo/actions/runs?limit=100" 2>/dev/null \
          | jq -e --arg sha "$sha" --arg wf "$wf" \
              '[.workflow_runs[] | select(.commit_sha==$sha and .name==$wf)][0].status=="success"' >/dev/null || return 1 ;;
    esac
  done
}

# dw_watch_full_pipeline "<branch>" → blocks until all configured workflows
#   are green at the branch head; 120×30s = 60 min budget (GPU matrices are long).
#   No configured workflows → delegates to dw_watch_ci (fast tier is the pipeline).
dw_watch_full_pipeline() {
  local branch="$1" sha
  [ -z "$(dw_full_pipeline_workflows)" ] && { dw_watch_ci "$branch"; return; }
  sha=$(git rev-parse --verify -q "origin/$branch" 2>/dev/null || git rev-parse --verify -q "$branch")
  echo "dev-workflow: waiting for full pipeline @ ${sha:0:8} (up to 60 min)…" >&2
  local _
  for _ in $(seq 1 120); do
    dw_full_green "$sha" && { echo "dev-workflow: full pipeline green @ ${sha:0:8}" >&2; return 0; }
    sleep 30
  done
  echo "dev-workflow: full pipeline timed out after 60 min" >&2; return 1
}

# ── tests (local mirror of CI) ──────────────────────────────────────────────
#
# These run the SAME suite CI runs, locally, for a fast feedback loop — the
# local half of the test gate; CI is the authoritative half (see the skill's
# references/ci-concepts.md §1). Detection lives in detect-test-command.sh
# (shared with adopt.sh) so the precedence + language list are defined once.

# dw_test_command  → echoes the project's test command, or empty.
#   Thin alias over dw_detect_test_command (see detect-test-command.sh for the
#   full precedence: CI_TEST_COMMAND env → committed runner → language heuristic).
dw_test_command() { dw_detect_test_command; }

# dw_run_tests  → run the project's tests locally; exit code is the suite's.
#   Dies with guidance if no command can be determined.
dw_run_tests() {
  local cmd; cmd=$(dw_test_command)
  [ -n "$cmd" ] || dw_die "no test command detected — commit scripts/test, set CI_TEST_COMMAND, or add a 'Test command' in the project's AGENTS.md (see references/ci-concepts.md)"
  echo "dev-workflow: running tests: $cmd" >&2
  sh -c "$cmd"
}

# ── merge ───────────────────────────────────────────────────────────────────

# dw_rebase_onto_default  → rebase current feature branch onto latest default.
#   Fetches the default branch, rebases onto it, and force-pushes (with lease)
#   the FEATURE branch only — never the default branch.
#   Call at ready-declaration, BEFORE dw_trigger_full_pipeline — never after
#   (the rebase changes the head SHA and would invalidate the dispatched chain).
dw_rebase_onto_default() {
  local default current
  default=$(dw_default_branch)
  current=$(git branch --show-current)
  [ "$current" = "$default" ] && dw_die "refusing to rebase: you are on the default branch '$default' — switch to a feature branch first"
  echo "dev-workflow: rebasing $current onto origin/$default" >&2
  git fetch origin "$default" >/dev/null 2>&1
  git rebase "origin/$default" || dw_die "rebase had conflicts — resolve them, then 'git rebase --continue' and re-run"
  git push --force-with-lease origin "$current" 2>&1 | grep -v '^remote:' | grep -v '^To ' || true
}

# dw_merge_readiness "<pr#>" → the falsifiable merge gate. Exit 0 only when
#   ALL pass at one frozen head SHA: fast tier green, full pipeline green
#   (skipped when none configured), review APPROVE (verdict trailer), and
#   merge-base(head, default) == default head.
dw_merge_readiness() {
  local pr="$1" fail=0
  local head; head=$(dw_pr_head "$pr"); [ -n "$head" ] || dw_die "cannot resolve PR #$pr head"
  local platform owner_repo
  platform=$(dw_detect_platform); owner_repo=$(dw_owner_repo)
  echo "merge-readiness for PR #$pr @ ${head:0:8}:"
  # 2. fast tier (combined status / pr checks)
  if dw_watch_ci "$pr" >/dev/null 2>&1; then echo "  ✔ fast tier green"; else echo "  ✘ fast tier red"; fail=1; fi
  # 3. full pipeline @ head
  if [ -n "$(dw_full_pipeline_workflows)" ]; then
    if dw_full_green "$head"; then echo "  ✔ full pipeline green @ ${head:0:8}"; else echo "  ✘ full pipeline not green @ ${head:0:8}"; fail=1; fi
  else echo "  – full pipeline: none configured (fast tier is the pipeline)"; fi
  # 4. review verdict trailer bound to head
  local bodies=""
  case "$platform" in
    github) bodies=$(gh api "repos/$owner_repo/issues/$pr/comments" --jq '.[].body' 2>/dev/null) ;;
    *) local host token; host=$(dw_host); token=$(dw_token)
       bodies=$(curl -fsSL -H "Authorization: token $token" \
         "https://$host/api/v1/repos/$owner_repo/issues/$pr/comments" 2>/dev/null | jq -r '.[].body // empty') ;;
  esac
  if echo "$bodies" | grep -qF "<!-- pr-review: APPROVE @ $head -->"; then
    echo "  ✔ adversarial review APPROVE @ ${head:0:8}"
  else echo "  ✘ no APPROVE verdict for ${head:0:8} (stale or missing — re-declare ready)"; fail=1; fi
  # 5. rebase-clean against default
  local default dbase dhead
  default=$(dw_default_branch)
  git fetch origin "$default" >/dev/null 2>&1
  dbase=$(git merge-base "$head" "origin/$default" 2>/dev/null)
  dhead=$(git rev-parse "origin/$default")
  if [ "$dbase" = "$dhead" ]; then echo "  ✔ rebased onto origin/$default"; else echo "  ✘ not rebased onto origin/$default — re-declare ready (rebase BEFORE dispatch)"; fail=1; fi
  return "$fail"
}

# dw_merge_pr "<pr#>" "<method: squash|merge|rebase>"  → merges ONLY a merge-ready PR.
#   Does NOT rebase anymore — the rebase lives at ready-declaration; re-rebasing
#   here would change the head SHA and invalidate the full-pipeline + review
#   chain bound to it. Readiness is verified via dw_merge_readiness first.
dw_merge_pr() {
  local pr="$1" method="${2:-squash}"
  dw_merge_readiness "$pr" || dw_die "refusing to merge PR #$pr: not merge-ready (see checklist)"
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
