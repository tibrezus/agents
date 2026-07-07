#!/bin/sh
# CronJob entrypoint — installs tools, then runs the sync scripts.
# This file is delivered via the fork-maintenance-scripts ConfigMap.
set -x  # trace every command so failures are visible in pod logs

echo "=== Fork sync: $(date -u) ==="

# Install yq + gh (Go is already in the golang:alpine image)
apk add --no-cache git curl jq bash || { echo "FATAL: apk add failed"; exit 1; }

# yq (static binary)
curl -fSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
  -o /usr/local/bin/yq || { echo "FATAL: yq download failed"; exit 1; }
chmod +x /usr/local/bin/yq

# gh CLI (static binary)
GH_VER=$(curl -sfL "https://api.github.com/repos/cli/cli/releases/latest" \
  | jq -r .tag_name | sed 's/v//') || { echo "FATAL: gh version lookup failed"; exit 1; }
curl -fSL "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_amd64.tar.gz" \
  -o /tmp/gh.tar.gz || { echo "FATAL: gh download failed"; exit 1; }
tar xzf /tmp/gh.tar.gz -C /tmp
cp "/tmp/gh_${GH_VER}_linux_amd64/bin/gh" /usr/local/bin/gh

echo "tools: $(yq --version 2>&1), $(gh --version 2>&1 | head -1)"

# scip-go (Sourcegraph SCIP indexer — for deterministic code graphs)
# Installed via go install (the golang:alpine image has go)
echo "=== Installing scip-go ==="
go install github.com/sourcegraph/scip-go/cmd/scip-go@latest 2>&1 | tail -1 || echo "WARNING: scip-go install failed (non-fatal)"
echo "scip-go: $(scip-go --version 2>&1 || echo 'not available')"

# Make scripts + hooks executable
chmod +x /workspace/scripts/*.sh /workspace/post-merge-hooks/*.sh

# Sync each fork (or a specific one if FORK_NAME is set)
if [ -n "$FORK_NAME" ]; then
  echo "=== Syncing fork: $FORK_NAME ==="
  /workspace/scripts/sync-fork.sh "$FORK_NAME" || true
else
  for def in /workspace/forks/*.yaml; do
    fork=$(basename "$def" .yaml)
    echo "=== Syncing fork: $fork ==="
    /workspace/scripts/sync-fork.sh "$fork" || true
  done
fi

echo "=== Fork sync complete: $(date -u) ==="
