#!/usr/bin/env bash
# forgejo-cli first-shot orientation.
# Prints: whether `fj` is installed + its version, every authenticated host,
# and — if run inside a git checkout — the Forgejo remote(s) so you know which
# `-H <host> -R <remote>` (or `-r owner/name`) to use.
#
# Run this BEFORE issuing any `fj` command when landing fresh on a task.
#   bash "$HOME/.agents/skills/forgejo-cli/scripts/first-shot.sh"
set -u

say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

say "fj on PATH?"
if command -v fj >/dev/null 2>&1; then
  printf '  yes: %s\n' "$(command -v fj)"
  fj version --client 2>/dev/null | sed 's/^/  /'
else
  cat >&2 <<'EOF'
  NO. Install the Go `fj` (NOT go install — module path is forgejo.org):

    OS=$(uname -s | tr A-Z a-z); ARCH=$([ "$(uname -m)" = aarch64 ] && echo arm64 || echo amd64)
    REL=forgejo-v16.0.2
    curl -fsSL "https://github.com/rezuscloud/forgejo/releases/download/${REL}/fj-${OS}-${ARCH}.tar.gz" | tar -xz -C /tmp
    install -m 0755 "/tmp/fj-${OS}-${ARCH}" ~/.local/bin/fj
EOF
  exit 1
fi

say "authenticated hosts (from ~/.local/share/forgejo-cli/keys.json)"
fj auth list 2>/dev/null | sed 's/^/  /' || echo "  (none — run: fj auth login <host>)"

# Inside a git checkout? Show Forgejo remotes → tells you which -R works + owner/name.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  say "git remotes in this checkout (use -R <remote> -H <host>)"
  while read -r name url; do
    # owner/name = last two path segments after stripping .git;
    # host = segment before the first ':' or '/' after credentials/scheme.
    repo=$(printf '%s' "$url" | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')
    host=$(printf '%s' "$url" | sed -E 's#^[a-z+]+://##; s#^git@##; s#[:/].*##')
    printf '  -%-10s %s   → -H %s -r %s\n' "$name" "$url" "$host" "$repo"
  done < <(git remote -v 2>/dev/null | awk '!seen[$1]++ {print $1, $2}')
else
  say "not in a git checkout"
  echo "  → you MUST pass both -H <host> AND -r owner/name on every command"
  echo "    (bare commands fall back to github.com → 'not logged in to github.com')"
fi

say "reminder"
cat <<'EOF'
  • Always pass -H <host> (e.g. git.rezus.cloud | codeberg.org).
  • In a checkout, -R <remote> resolves the repo; otherwise pass -r owner/name.
  • CI reading order:  fj actions runs  →  fj actions jobs <RUN>  →  fj actions logs --job <JOB>
EOF
