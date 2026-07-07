#!/usr/bin/env bash
# =============================================================================
# check-drift.sh — verify skill templates match the live implementation
# =============================================================================
# The canonical skill lives at platform/fork-maintenance/skill/ (source of
# truth for what agents load). Its engine templates are VERBATIM copies of the
# live generic scripts. This script checks they have not drifted, so the skill
# an agent reads always matches what the CronJob actually runs.
#
# Two modes:
#   bash check-drift.sh            # verify — exit 1 on drift (CI-gatable)
#   bash check-drift.sh --sync     # regenerate the verbatim templates from impl
#
# Only the generic ENGINE templates are verbatim-managed here:
#   sync-fork.sh, git-host.sh, verify-patches.sh, generate-manifest.sh,
#   cronjob-entrypoint.sh, validate-fork.sh,
#   cronjob-sync-forks.yaml, external-secret-github.yaml
#
# Hand-maintained generic templates are NOT touched (they are documentation
# examples, not copies):
#   fork.yaml, post-merge-hook.sh, alert-upstream-changes.yaml,
#   gitrepository-upstreams.yaml
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"          # platform/fork-maintenance/skill
MAINT_DIR="$(cd "$SKILL_DIR/.." && pwd)"           # platform/fork-maintenance
TPL="$SKILL_DIR/templates"

# map:  template  <-  implementation source
declare -A MAP=(
  [sync-fork.sh]=scripts/sync-fork.sh
  [git-host.sh]=scripts/git-host.sh
  [resolve-conflict.sh]=scripts/resolve-conflict.sh
  [verify-patches.sh]=scripts/verify-patches.sh
  [generate-manifest.sh]=scripts/generate-manifest.sh
  [cronjob-entrypoint.sh]=scripts/cronjob-entrypoint.sh
  [validate-fork.sh]=checks/validate-fork.sh
  [cronjob-sync-forks.yaml]=flux/cronjob-sync-forks.yaml
  [external-secret-github.yaml]=flux/external-secret-github.yaml
)

MODE="${1:-verify}"

if [ "$MODE" = "--sync" ]; then
  echo "Regenerating verbatim skill templates from the live implementation…"
  for tpl in "${!MAP[@]}"; do
    src="${MAP[$tpl]}"
    cp "$MAINT_DIR/$src" "$TPL/$tpl"
    echo "  ✏️  $tpl  ←  $src"
  done
  echo "Done. Review with: git diff $TPL"
  exit 0
fi

# --- verify mode ---
# The guard only works from the canonical location (sibling of scripts/ checks/ flux/).
# The synced ~/.agents copy has no implementation sibling — detect and explain.
if [ ! -f "$MAINT_DIR/scripts/sync-fork.sh" ]; then
  echo "NOTE: this skill copy has no sibling implementation (no scripts/sync-fork.sh)."
  echo "      The drift guard only runs from the canonical location:"
  echo "        <gitops>/platform/fork-maintenance/skill/scripts/check-drift.sh"
  echo "      Run it there, or in that repo's CI — not from the synced ~/.agents copy."
  exit 0
fi

drifted=0
echo "Checking skill templates against the live implementation…"
for tpl in "${!MAP[@]}"; do
  src="${MAP[$tpl]}"
  if ! [ -f "$MAINT_DIR/$src" ]; then
    echo "  ❌ MISSING impl: $src"; drifted=1; continue
  fi
  if ! diff -q "$MAINT_DIR/$src" "$TPL/$tpl" >/dev/null 2>&1; then
    echo "  ⚠️  DRIFT: $tpl  ≠  $src"
    drifted=1
  else
    echo "  ✅ $tpl"
  fi
done

if [ "$drifted" -eq 1 ]; then
  echo ""
  echo "FAIL: skill templates have drifted from the implementation."
  echo "Fix: bash $SCRIPT_DIR/check-drift.sh --sync   # then review + commit"
  exit 1
fi
echo ""
echo "OK: all verbatim templates match the implementation."
