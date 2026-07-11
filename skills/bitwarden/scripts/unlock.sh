#!/usr/bin/env bash
# Idempotently log in + unlock the Bitwarden vault and export BW_SESSION into the
# current shell (source this file) and to ~/.config/bw-session for child processes.
#
# Requires: BW_PASSWORD env var (the vault master password).
# Bails loudly if bw is missing, the server is wrong, or BW_PASSWORD is unset.
set -euo pipefail

BW_SESSION_FILE="${BW_SESSION_FILE:-$HOME/.config/bw-session}"

if ! command -v bw >/dev/null 2>&1; then
  echo "bitwarden: 'bw' CLI not found on PATH (npm i -g @bitwarden/cli)" >&2
  return 1 2>/dev/null || exit 1
fi

status_json="$(bw status 2>/dev/null || echo '{}')"
state="$(printf '%s' "$status_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")"

# If already unlocked with a usable session, re-export it and return.
if [ "$state" = "unlocked" ] && [ -f "$BW_SESSION_FILE" ]; then
  export BW_SESSION="$(cat "$BW_SESSION_FILE")"
  return 0 2>/dev/null || exit 0
fi

if [ -z "${BW_PASSWORD:-}" ]; then
  echo "bitwarden: BW_PASSWORD env var is required to unlock (set it: export BW_PASSWORD='...')" >&2
  echo "           current state: ${state:-unknown}" >&2
  return 1 2>/dev/null || exit 1
fi

# Log in if needed (passwordless unlock can't proceed without a logged-in data.json).
if [ "$state" = "unauthenticated" ]; then
  echo "bitwarden: logging in (BW_PASSWORD)..." >&2
  bw login --passwordenv BW_PASSWORD >/dev/null 2>&1 || bw login --raw </dev/null >/dev/null 2>&1 || true
  status_json="$(bw status 2>/dev/null || echo '{}')"
  state="$(printf '%s' "$status_json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")"
fi

if [ "$state" != "locked" ] && [ "$state" != "unlocked" ]; then
  echo "bitwarden: unexpected state '$state' after login attempt. Run 'bw login' manually." >&2
  return 1 2>/dev/null || exit 1
fi

if [ "$state" = "locked" ]; then
  echo "bitwarden: unlocking..." >&2
  session="$(BW_PASSWORD="$BW_PASSWORD" bw unlock --passwordenv BW_PASSWORD --raw 2>/dev/null \
             || bw unlock --raw <<<"$BW_PASSWORD" 2>/dev/null || true)"
  if [ -z "$session" ]; then
    echo "bitwarden: unlock failed (wrong BW_PASSWORD?). Aborting." >&2
    return 1 2>/dev/null || exit 1
  fi
else
  session="$(bw unlock --raw <<<"${BW_PASSWORD}" 2>/dev/null || true)"
  [ -z "$session" ] && session="${BW_SESSION:-}"
fi

export BW_SESSION="$session"
umask 077
mkdir -p "$(dirname "$BW_SESSION_FILE")"
printf '%s' "$session" >"$BW_SESSION_FILE"
bw sync >/dev/null 2>&1 || true
echo "bitwarden: unlocked (session persisted to $BW_SESSION_FILE)" >&2
return 0 2>/dev/null || exit 0
