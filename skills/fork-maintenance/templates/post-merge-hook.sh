#!/usr/bin/env bash
# =============================================================================
# post-merge-hook.sh — per-fork hook skeleton (canonical template)
# =============================================================================
# Runs AFTER the upstream merge, BEFORE validation + PR creation. Owns all
# per-fork code generation that depends on the merged tree:
#   - regenerate SDKs / CLI commands from a changed swagger spec
#   - re-vendor charts / modules
#   - go mod tidy, ee-stripping, divergence cleanup
#
# Save as post-merge-hooks/<fork>.sh. No-op if you have nothing to regenerate.
#
# Environment (set by sync-fork.sh):
#   FORK_DIR   — the fork working tree (the merged checkout)
#   MAINT_DIR  — platform/fork-maintenance/ (or /workspace/ in the CronJob)
#
# The hook failing is non-fatal to the sync (a WARNING is printed), but it
# usually means codegen drift — the clean_tree validation check will then fail
# and the PR gets `needs-fix` instead of `auto-merge`. So fail loudly here.
# =============================================================================
set -euo pipefail

FORK_DIR="${FORK_DIR:?FORK_DIR must be set by sync-fork.sh}"
MAINT_DIR="${MAINT_DIR:?MAINT_DIR must be set by sync-fork.sh}"

cd "$FORK_DIR"

# Example: regenerate from a swagger spec (forgejo pattern)
# if [ -f contrib/swagger-ui/swagger.v1.json ]; then
#   go run build/generate-swagger.go contrib/swagger-ui/swagger.v1.json staging/...
# fi

# Example: ee-stripping for a community-only build (signoz pattern)
# rm -rf ee/ cmd/enterprise
# go mod tidy

# Example: re-vendor a chart
# helm dep update charts/<chart>

echo "post-merge hook: nothing to do (template)"
