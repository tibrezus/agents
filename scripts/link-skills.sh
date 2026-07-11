#!/usr/bin/env bash
set -euo pipefail

# Maintainer-only dev script: symlink every skill in this repo into the local
# harness skill directories used by each agent harness:
#   - ~/.agents/skills  — pi and other Agent-Skills-standard harnesses
#   - ~/.claude/skills  — Claude Code (when --claude is passed)
# Each entry is a symlink into this repo, so a `git pull` is all that's needed
# to keep installed skills up to date.
#
# For end users, prefer `npx tibrezus-agents link` or
# `npm install -g tibrezus-agents` instead — they call the same logic.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DESTS=("$HOME/.agents/skills")

if [[ "${1:-}" == "--claude" || "${1:-}" == "-c" ]]; then
  DESTS+=("$HOME/.claude/skills")
fi

# Collect the repo's skills once, link into every destination.
names=()
srcs=()
while IFS= read -r -d '' skill_md; do
  src="$(dirname "$skill_md")"
  names+=("$(basename "$src")")
  srcs+=("$src")
done < <(find "$REPO/skills" -name SKILL.md -not -path '*/node_modules/*' -print0)

for DEST in "${DESTS[@]}"; do
  # If $DEST is a symlink that resolves into this repo, we'd end up writing the
  # per-skill symlinks back into the repo's own skills/ tree. Detect and bail.
  if [ -L "$DEST" ]; then
    resolved="$(readlink -f "$DEST")"
    case "$resolved" in
      "$REPO"|"$REPO"/*)
        echo "error: $DEST is a symlink into this repo ($resolved)." >&2
        echo "Remove it (rm \"$DEST\") and re-run; the script will recreate it as a real dir." >&2
        exit 1
        ;;
    esac
  fi

  mkdir -p "$DEST"

  for i in "${!names[@]}"; do
    name="${names[$i]}"
    src="${srcs[$i]}"
    target="$DEST/$name"

    if [ -e "$target" ] && [ ! -L "$target" ]; then
      rm -rf "$target"
    fi

    ln -sfn "$src" "$target"
    echo "linked $name -> $src ($DEST)"
  done
done
