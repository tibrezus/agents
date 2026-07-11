#!/usr/bin/env bash
# Create a Bitwarden Secrets Manager secret in the platform project.
#   create-secret.sh NAME                  # 40-char random value
#   create-secret.sh NAME 'value'          # explicit value (single-quoted)
#
# Requires the vault to be unlocked (source scripts/unlock.sh first) and
# BW_SESSION exported.
set -euo pipefail

NAME="${1:?usage: create-secret.sh NAME [value]}"
VALUE="${2:-}"
PROJ="${BW_PROJECT_ID:-0901f4dc-19f0-42dd-8def-b2cb012a0841}"

if [ -z "${BW_SESSION:-}" ]; then
  echo "create-secret: BW_SESSION not set — source scripts/unlock.sh first" >&2
  exit 1
fi

# Bail if it already exists (avoid silent overwrite).
if bw secrets list --project "$PROJ" 2>/dev/null \
   | python3 -c "import sys,json; sys.exit(0 if any(s.get('name')=='$NAME' for s in json.load(sys.stdin)) else 1)"; then
  echo "create-secret: '$NAME' already exists — not overwriting (delete it in the vault first if intended)" >&2
  exit 1
fi

[ -n "$VALUE" ] || VALUE="$(pwgen -s 40 1 2>/dev/null || openssl rand -base64 30 | tr -d '/+=' | cut -c1-40)"

bw secrets create "$NAME" "$VALUE" --project "$PROJ" >/dev/null
echo "$NAME created (value hidden)"
