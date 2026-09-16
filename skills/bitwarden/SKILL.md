---
name: bitwarden
description: Unlock and operate the Bitwarden vault / Bitwarden Secrets Manager (BSM) from a non-interactive agent shell. Detects auth state, prompts for the master password, keeps the session in the shell environment only, and provides helpers to get/create secrets and sync them into ExternalSecrets. Use when the task touches Bitwarden, BSM, `bw` CLI, BW_SESSION, or creating platform secrets.
---

# Bitwarden unlock & secret management

The `bw` CLI cannot be unlocked by pasting a `BW_SESSION` from another shell — a
session key only decrypts a vault that is **already logged in** on this machine
(`~/.config/Bitwarden CLI/data.json`). So the reliable flow is: ensure logged
in → unlock with the master password → keep the session in the shell
environment.

## Secrets-hygiene rules (enforced by the scripts)

- **No personal values in this skill**: the server URL and BSM project ID live
  only in the machine-local env file. Nothing here identifies a tenancy.
- **Master password is never persisted**: passed via `BW_PASSWORD` for the one
  command or typed at a hidden prompt; `unlock.sh` always unsets it when done.
- **Session key stays in the environment**: no session file is written unless
  you explicitly opt in with `BW_SESSION_FILE`.

## Local configuration (machine-only, never commit)

`~/.config/bitwarden-agent/env` (override location with `BW_ENV_FILE`), mode
`0600`:

```bash
export BW_SERVER_URL='https://vault.example.tld'     # your server URL
export BW_PROJECT_ID='<bsm-project-uuid>'            # BSM project for machine secrets
#export BW_SESSION_FILE="$HOME/.config/bw-session"   # opt-in session persistence to disk
```

Both scripts source this file automatically. It is the only place your real
values exist outside the vault itself.

## Unlock flow (run before any `bw`/secret work)

```bash
source "$HOME/.agents/skills/bitwarden/scripts/unlock.sh"
# prompts for the master password (hidden input); or one-shot, non-interactive:
# BW_PASSWORD='...' source "$HOME/.agents/skills/bitwarden/scripts/unlock.sh"
```

`unlock.sh` is idempotent and safe to re-run: it configures the server from
`BW_SERVER_URL` if needed, logs in if unauthenticated, unlocks if locked, and
exports `BW_SESSION` into the current shell. When it returns, plain `bw ...`
commands work — and neither the environment nor disk holds the master password.

## Common operations

```bash
bw sync                                 # pull latest
bw status                               # confirm 'status: unlocked'

# Secrets Manager (BSM) — machine secrets the cluster reads via ExternalSecrets.
bw secrets list --project "$BW_PROJECT_ID" | jq -r '.[].name'   # what exists
# create (note: value is the 2nd positional arg)
bw secrets create MY_KEY "$(pwgen -s 40 1)" --project "$BW_PROJECT_ID"
```

**Preferred: BSM via the `bws` CLI.** `bw secrets` is the *user vault* CLI;
machine secrets live in BSM and the machine account is what the cluster uses.
`bws` (v2.1.0, `cargo install bws`) is installed and is the correct read+write
path for BSM:

```bash
export BWS_ACCESS_TOKEN="$(kubectl -n external-secrets get secret bitwarden-access-token -o jsonpath='{.data.token}' | base64 -d)"
bws secret list "$BW_PROJECT_ID"                            # list (project id positional)
bws secret create <KEY> <VALUE> "$BW_PROJECT_ID"            # create (positional)
bws secret delete <SECRET_ID>                               # delete
```

Do NOT use raw `curl` against the BSM API (404 — tokens are proxied through the
ESO SDK server's gRPC; `bws` wraps the SDK correctly).

## Creating a set of platform secrets (helper)

```bash
SKILL="$HOME/.agents/skills/bitwarden"
"$SKILL/scripts/create-secret.sh" NAME                 # generates + creates a 40-char secret
"$SKILL/scripts/create-secret.sh" NAME 'json-value-here'   # explicit value
```

Each prints the created id and is idempotent-safe to re-run only if you intend
to overwrite (it will error on duplicate name — check existence first).

## Gotchas

- **`bw secrets create` value escaping**: pass the value as a single quoted
  positional arg. JSON values (e.g. S3 creds) must be a single shell-quoted string.
- **Project-scoped machine account**: secrets must live in `$BW_PROJECT_ID`
  (from the local env file) or the cluster's ExternalSecrets can't read them.
- **BW_SESSION does not cross shells**: the session lives only in the
  environment of the shell that sourced `unlock.sh`. Re-run it in the shell
  that will issue `bw` commands.
- **No session file by default**: set `BW_SESSION_FILE` in the local env file
  to opt in. To revoke a persisted session: `rm` the file and run `bw lock`.
- **Never print `BW_PASSWORD` or session secrets** in transcripts/logs.

## See also

- `references/eso-flow.md` — how ExternalSecrets + bitwarden-sdk-server consume these secrets in-cluster.
