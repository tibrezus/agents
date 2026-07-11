---
name: bitwarden
description: Unlock and operate the Bitwarden vault / Bitwarden Secrets Manager (BSM) from a non-interactive agent shell. Detects auth state, unlocks with BW_PASSWORD, persists the session so subsequent `bw` commands work, and provides helpers to get/create secrets and sync them into ExternalSecrets. Use when the task touches Bitwarden, BSM, `bw` CLI, BW_SESSION, or creating platform secrets.
---

# Bitwarden unlock & secret management

The `bw` CLI cannot be unlocked by pasting a `BW_SESSION` from another shell — a
session key only decrypts a vault that is **already logged in** on this machine
(`~/.config/Bitwarden CLI/data.json`). So the reliable, prompt-free flow is:
ensure logged in → unlock with the master password from an env var → persist the
session to a file every command sources.

## Prerequisites

- `bw` CLI on PATH (`npm i -g @bitwarden/cli`).
- The master password in the `BW_PASSWORD` env var. Set it once for the session:
  ```bash
  export BW_PASSWORD='...'        # never commit; never echo
  ```
- The server must match the vault (this platform uses EU): `bw config server https://vault.bitwarden.eu` (run once if `bw status` shows a different/no server).

## Unlock flow (run before any `bw`/secret work)

```bash
export BW_PASSWORD='...'   # master password; never commit/echo
source "$HOME/.agents/skills/bitwarden/scripts/unlock.sh"
```

`unlock.sh` is idempotent and safe to re-run: it logs in if unauthenticated,
unlocks if locked, and exports `BW_SESSION` into the current shell plus writes it
to `~/.config/bw-session` for child processes. It bails with a clear message if
`BW_PASSWORD` is missing.

After it returns, plain `bw ...` commands work in the shell — no `--session`.

## Common operations

```bash
bw sync                                 # pull latest
bw status                               # confirm 'status: unlocked'

# Secrets Manager (BSM) — machine secrets the cluster reads via ExternalSecrets.
# Platform project ID: 0901f4dc-19f0-42dd-8def-b2cb012a0841
PROJ=0901f4dc-19f0-42dd-8def-b2cb012a0841

bw secrets list --project "$PROJ" | jq -r '.[].name'           # what exists
# create (note: value is the 2nd positional arg)
bw secrets create MY_KEY "$(pwgen -s 40 1)" --project "$PROJ"
```

**Preferred: BSM via the `bws` CLI.** `bw secrets` is the *user vault* CLI;
the platform's machine secrets live in BSM and the machine account is what the
cluster uses. `bws` (v2.1.0, `cargo install bws`) is installed and is the correct
read+write path for BSM:

```bash
export BWS_ACCESS_TOKEN="$(kubectl -n external-secrets get secret bitwarden-access-token -o jsonpath='{.data.token}' | base64 -d)"
bws secret list "$PROJ"                                    # list (project id positional)
bws secret create <KEY> <VALUE> "$PROJ"                     # create (positional)
bws secret delete <SECRET_ID>                              # delete
```

Do NOT use raw `curl` against `api.bitwarden.eu` (404 — tokens are proxied
through the ESO SDK server's gRPC; `bws` wraps the SDK correctly).

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
- **Project-scoped machine account**: secrets must live in project
  `0901f4dc-...` or the cluster's ExternalSecrets can't read them.
- **BW_SESSION does not cross shells**: a session minted in one terminal will
  not work in another that has a different (or no) local `data.json`. Always
  re-run `unlock.sh` in the shell that will issue `bw` commands.
- **Never print `BW_PASSWORD` or session secrets** in transcripts/logs.

## See also

- `references/eso-flow.md` — how ExternalSecrets + bitwarden-sdk-server consume these secrets in-cluster.
