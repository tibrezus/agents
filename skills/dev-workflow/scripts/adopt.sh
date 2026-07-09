#!/usr/bin/env bash
# adopt.sh — inject or update the development-workflow mandate into a project's AGENTS.md.
#
# Usage:  bash <skill-dir>/scripts/adopt.sh [repo-path]
#
# Idempotent: the injected section is wrapped in sentinel markers, so
# re-running `adopt` REPLACES the section with the current skill version.
# This is how "inject or change the development workflow to the one in the
# skill" works — update the skill template once, re-run adopt on each project.
#
# Behaviour:
#   - No AGENTS.md              → create one with a minimal title + the section
#   - Markers already present   → replace everything between (and incl.) markers
#   - Legacy "## Development Workflow" header (no markers) → replace that section
#   - Otherwise                 → append the marked section at the end

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SKILL_DIR/templates/agents-workflow-section.md"
# Shared test-command detection (also used by host.sh). Sourced, not copied,
# so the language/runner list evolves in one file.
# shellcheck source=detect-test-command.sh
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/detect-test-command.sh"

REPO="${1:-$PWD}"
cd "$REPO"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "adopt: not a git repo: $REPO" >&2; exit 1; }

# ── detect project metadata ────────────────────────────────────────────────
platform() {
  local url; url=$(git remote get-url origin 2>/dev/null) || echo "unknown"
  case "$url" in
    *github.com*)   echo github ;;
    *codeberg.org*) echo codeberg ;;
    *)              echo forgejo ;;
  esac
}

default_branch() {
  local b
  b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || true
  [ -n "$b" ] && { echo "$b"; return; }
  git show-ref --verify --quiet refs/heads/main && { echo main; return; } || true
  git show-ref --verify --quiet refs/heads/master && { echo master; return; } || true
  echo main
}

ci_watch() {
  case "$(platform)" in
    github)  echo 'gh pr checks <PR> --watch  (then verify green)' ;;
    *)       echo 'fj -H <host> actions tasks --repo <owner/repo>  (poll; no --watch)' ;;
  esac
}

# Best-effort detection of the project's test command (CI must run the same).
# Delegates to the shared detector so precedence + the language/runner list
# live in one place (detect-test-command.sh). Never returns empty so the
# template always has a value to show; the human confirms or overrides it.
test_command() {
  local cmd; cmd=$(dw_detect_test_command)
  echo "${cmd:-(project-specific — commit scripts/test or set CI_TEST_COMMAND)}"
}

# Escape a value so it is safe as a sed *replacement* string (delimiter '|').
# Needed because a detected test command can contain shell metacharacters such
# as '&&' (CMake: configure && build && ctest); '&' in a sed replacement means
# "the whole match", and '\' and '|' are special too.
_dw_sed_repl() { printf '%s' "$1" | sed -e 's/[&\\]/\\&/g' -e 's/|/\\|/g'; }

# ── render the section with detected values ────────────────────────────────
render() {
  PLATFORM=$(platform)
  DEFAULT_BRANCH=$(default_branch)
  CI_WATCH=$(ci_watch)
  TEST_CMD=$(_dw_sed_repl "$(test_command)")
  sed \
    -e "s|{{PLATFORM}}|$PLATFORM|g" \
    -e "s|{{DEFAULT_BRANCH}}|$DEFAULT_BRANCH|g" \
    -e "s|{{BRANCH_NAMING}}|<type>/<issue#>-<slug>|g" \
    -e "s|{{MILESTONE_CONVENTION}}|current|g" \
    -e "s|{{CI_WATCH}}|$CI_WATCH|g" \
    -e "s|{{TEST_COMMAND}}|$TEST_CMD|g" \
    -e "s|{{COUPLING_POLICY}}|strict|g" \
    -e "s|{{MERGE_METHOD}}|squash|g" \
    "$TEMPLATE"
}

BEGIN='<!-- BEGIN dev-workflow'
END='<!-- END dev-workflow -->'
RENDERED="$(mktemp)"; trap 'rm -f "$RENDERED"' EXIT
render > "$RENDERED"

AGENTS="AGENTS.md"

inject_create() {
  {
    echo "---"
    echo "title: $(basename "$PWD")"
    echo "---"
    echo
    cat "$RENDERED"
  } > "$AGENTS"
}

# Case 1: no AGENTS.md → create
if [ ! -f "$AGENTS" ]; then
  inject_create
  echo "adopt: created $AGENTS with the development-workflow section."
  exit 0
fi

# Case 2: markers present → splice-replace between markers
if grep -qF "$BEGIN" "$AGENTS"; then
  tmp="$(mktemp)"; trap 'rm -f "$RENDERED" "$tmp"' EXIT
  awk -v beg="$BEGIN" -v end="$END" -v new="$RENDERED" '
    index($0, beg) {
      while ((getline line < new) > 0) print line
      skip = 1; next
    }
    index($0, end) { skip = 0; next }
    !skip { print }
  ' "$AGENTS" > "$tmp"
  mv "$tmp" "$AGENTS"
  echo "adopt: updated existing dev-workflow section in $AGENTS."
  exit 0
fi

# Case 3: legacy unmarked "## Development Workflow" header → replace that section
if grep -qE '^## Development Workflow' "$AGENTS"; then
  tmp="$(mktemp)"; trap 'rm -f "$RENDERED" "$tmp"' EXIT
  awk -v new="$RENDERED" '
    /^## Development Workflow/ {
      while ((getline line < new) > 0) print line
      skip = 1; next
    }
    /^## / && skip { skip = 0 }
    !skip { print }
  ' "$AGENTS" > "$tmp"
  mv "$tmp" "$AGENTS"
  echo "adopt: replaced legacy '## Development Workflow' section in $AGENTS (now marker-managed)."
  exit 0
fi

# Case 4: append
{
  echo
  cat "$RENDERED"
} >> "$AGENTS"
echo "adopt: appended dev-workflow section to $AGENTS."
