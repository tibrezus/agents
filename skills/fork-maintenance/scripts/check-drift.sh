#!/usr/bin/env bash
# =============================================================================
# check-drift.sh — verify skill templates match the live implementation
# =============================================================================
# The canonical skill lives in the harmostes CHART (ADR-0011):
# chart/fork-maintenance/skill/ + chart/fork-maintenance/{scripts,checks}/.
# This repo's templates/ are VERBATIM copies of the live scripts; this script
# verifies the copies have not drifted, so the skill an agent reads always
# matches what the cluster's per-Attempt Jobs actually run. Primary home: the
# harmostes CI, where both sides are in one checkout (this repo via the
# .agents submodule, the chart in-tree); HARMOSTES_CHART_DIR points there.
#
# Two modes:
#   bash check-drift.sh            # verify — exit 1 on drift (CI-gatable)
#   bash check-drift.sh --sync     # regenerate the verbatim templates from impl
#
# Verbatim-managed templates (each maps to its live chart counterpart):
#   scripts: sync-fork.sh resolve-conflict.sh git-host.sh verify-patches.sh
#            generate-manifest.sh backport.sh conflict-event.sh
#            derive-release-version.sh divergence-track.sh mapping-mode.sh
#   checks:  gate-resolved.sh validate-fork.sh
#
# Hand-maintained doc templates (documentation examples, not copies):
#   fork.yaml, post-merge-hook.sh, alert-upstream-changes.yaml,
#   gitrepository-upstreams.yaml
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"          # this repo's skills/fork-maintenance
TPL="$SKILL_DIR/templates"
# The CHART is canonical (ADR-0011): resolve it via HARMOSTES_CHART_DIR (the
# harmostes checkout's chart/fork-maintenance) — in the harmostes CI both
# sides of the comparison sit in one checkout via the .agents submodule.
CHART_DIR="${HARMOSTES_CHART_DIR:?set HARMOSTES_CHART_DIR to <harmostes>/chart/fork-maintenance}"

# map:  template  <-  implementation source
declare -A MAP=(
  [sync-fork.sh]=scripts/sync-fork.sh
  [resolve-conflict.sh]=scripts/resolve-conflict.sh
  [git-host.sh]=scripts/git-host.sh
  [verify-patches.sh]=scripts/verify-patches.sh
  [generate-manifest.sh]=scripts/generate-manifest.sh
  [backport.sh]=scripts/backport.sh
  [conflict-event.sh]=scripts/conflict-event.sh
  [derive-release-version.sh]=scripts/derive-release-version.sh
  [divergence-track.sh]=scripts/divergence-track.sh
  [mapping-mode.sh]=scripts/mapping-mode.sh
  [validate-fork.sh]=checks/validate-fork.sh
  [gate-resolved.sh]=checks/gate-resolved.sh
)

MODE="${1:-verify}"

if [ "$MODE" = "--sync" ]; then
  echo "Regenerating verbatim skill templates from the live implementation…"
  for tpl in "${!MAP[@]}"; do
    src="${MAP[$tpl]}"
    cp "$CHART_DIR/$src" "$TPL/$tpl"
    echo "  ✏️  $tpl  ←  $src"
  done
  echo "Done. Review with: git diff $TPL"
  exit 0
fi

# --- verify mode ---
# The guard only works from the canonical location (sibling of scripts/ checks/ flux/).
# The synced ~/.agents copy has no implementation sibling — detect and explain.
if [ ! -d "$CHART_DIR/scripts" ]; then
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
  if ! [ -f "$CHART_DIR/$src" ]; then
    echo "  ❌ MISSING impl: $src"; drifted=1; continue
  fi
  if ! diff -q "$CHART_DIR/$src" "$TPL/$tpl" >/dev/null 2>&1; then
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
