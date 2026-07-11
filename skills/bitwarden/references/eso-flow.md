# ExternalSecrets ↔ Bitwarden Secrets Manager flow

How a secret created with `bw secrets create` reaches a pod:

1. **Bitwarden Secrets Manager** stores the secret under a *project*
   (`0901f4dc-19f0-42dd-8def-b2cb012a0841` for this platform), EU tenancy.
2. A **machine account** (access token in `external-secrets/bitwarden-access-token`)
   has read access to that project. ExternalSecrets Operator cannot call the BSM
   REST API directly — it talks to an in-cluster **`bitwarden-sdk-server`**
   deployment (`ghcr.io/external-secrets/bitwarden-sdk-server`), which exposes a
   gRPC interface that wraps the Bitwarden SDK using that access token.
3. A `ClusterSecretStore` (`bitwarden`) points ESO at the SDK server + the
   machine-account token.
4. An `ExternalSecret` names the Bitwarden key (`remoteRef.key`) + the target
   K8s `Secret` key + optional template (`fromJson` for JSON-structured values
   like S3 creds). ESO reconciles it into a native `Secret`.
5. Pods consume that `Secret` via `secretKeyRef` / `envFrom` / chart `existingSecret`.

**Implications for creating secrets:**

- The key NAME in Bitwarden must exactly match the `remoteRef.key` in the
  ExternalSecret (case-sensitive).
- The secret must be in the platform project or the machine account can't see it.
- BSM access tokens are not curl-able (proxied via SDK server gRPC). Use the
  user-authenticated `bw secrets ...` CLI or the web vault to create them.
- Rotating a value: update it in Bitwarden, then `kubectl annotate externalsecret
  <name> -n <ns> force-reconcile=now` (or wait for `refreshInterval`).

**Why a `BW_SESSION` from another terminal doesn't work here:** a session key only
decrypts a vault cached locally in `~/.config/Bitwarden CLI/data.json`. If that
file is in `unauthenticated` state (never logged in, or logged out), the session
is useless — `bw status` shows `unauthenticated, lastSync:null`. Re-run
`scripts/unlock.sh` (which performs `bw login` + `bw unlock` with `BW_PASSWORD`).
