#!/usr/bin/env bash
# Idempotently log in + unlock the Bitwarden vault and export BW_SESSION into
# the current shell (source this file).
#
# Secrets hygiene enforced here:
#   - Master password: taken from BW_PASSWORD if already set for this command,
#     otherwise prompted with hidden input. It is ALWAYS unset before this
#     script returns — never kept as a long-lived export.
#   - Session key: exported as BW_SESSION in the shell environment only. It is
#     written to disk ONLY if BW_SESSION_FILE is explicitly set (opt-in).
#   - Personal values (server URL, project id) are read from the machine-local
#     env file below — they must never be hardcoded or committed anywhere.
set -euo pipefail

BW_ENV_FILE="${BW_ENV_FILE:-$HOME/.config/bitwarden-agent/env}"
# shellcheck disable=SC1090
[ -f "$BW_ENV_FILE" ] && . "$BW_ENV_FILE"

die() { echo "bitwarden: $*" >&2; return 1 2>/dev/null || exit 1; }

command -v bw >/dev/null 2>&1 || die "'bw' CLI not found on PATH (npm i -g @bitwarden/cli)"

status_field() { # $1 = json field of `bw status`
  printf '%s' "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$1') or '')" 2>/dev/null || true
}

refresh_status() {
  STATUS_JSON="$(bw status 2>/dev/null || echo '{}')"
}

refresh_status
state="$(status_field status)"
server="$(status_field serverUrl)"

# Point the CLI at the right server (URL lives in the local env file).
if [ -n "${BW_SERVER_URL:-}" ] && [ "$server" != "$BW_SERVER_URL" ]; then
  echo "bitwarden: configuring server from BW_SERVER_URL" >&2
  bw config server "$BW_SERVER_URL" >/dev/null
  refresh_status
  state="$(status_field status)"
fi

# Shell already holds a valid session: nothing to unlock.
if [ "$state" = "unlocked" ]; then
  unset _BW_PASS BW_PASSWORD 2>/dev/null || true
  return 0 2>/dev/null || exit 0
fi

# Master password: one-shot env var or hidden prompt; never stored.
if [ -n "${BW_PASSWORD:-}" ]; then
  _BW_PASS="$BW_PASSWORD"
elif [ -t 0 ]; then
  printf 'bitwarden: vault master password: ' >&2
  read -rs _BW_PASS || true
  echo >&2
else
  die "BW_PASSWORD is not set and stdin is not a TTY to prompt on.
           run: BW_PASSWORD='...' source ${BASH_SOURCE[0]:-$0}"
fi
[ -n "${_BW_PASS:-}" ] || die "empty master password"

session=""
if [ "$state" = "unauthenticated" ]; then
  echo "bitwarden: logging in..." >&2
  # </dev/null: fail fast instead of hanging on an interactive email prompt.
  session="$(BW_PASSWORD="$_BW_PASS" bw login --passwordenv BW_PASSWORD --raw </dev/null 2>/dev/null || true)"
  refresh_status
  state="$(status_field status)"
fi

if [ -z "$session" ]; then
  [ "$state" = "locked" ] || die "unexpected state '${state:-unknown}' — run 'bw login' manually"
  session="$(BW_PASSWORD="$_BW_PASS" bw unlock --passwordenv BW_PASSWORD --raw </dev/null 2>/dev/null || true)"
  [ -n "$session" ] || die "unlock failed (wrong master password?)"
fi

export BW_SESSION="$session"

if [ -n "${BW_SESSION_FILE:-}" ]; then
  umask 077
  mkdir -p "$(dirname "$BW_SESSION_FILE")"
  printf '%s' "$session" >"$BW_SESSION_FILE"
  echo "bitwarden: unlocked (session persisted to $BW_SESSION_FILE — opt-in via BW_SESSION_FILE)" >&2
else
  echo "bitwarden: unlocked (session kept in BW_SESSION env only)" >&2
fi

bw sync >/dev/null 2>&1 || true

# Never leave the master password in the environment.
unset _BW_PASS BW_PASSWORD
return 0 2>/dev/null || exit 0
