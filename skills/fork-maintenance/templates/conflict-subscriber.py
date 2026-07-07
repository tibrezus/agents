#!/usr/bin/env python3
"""conflict-subscriber.py — Dapr pub/sub consumer for fork-sync conflicts.

Always-on Deployment that subscribes to the ``fork.conflict.needs-resolution``
topic (published by sync-fork.sh's emit_conflict_event when a merge conflicts).
For each event it ACKs immediately (so Dapr doesn't redeliver) and spawns
``resolve-conflict.sh <fork>`` detached in the background — the resolution is
long-running (minutes: pi + re-validation) and must not block the Dapr delivery.

Dapr pub/sub (redis) retains undelivered events in a stream, so a subscriber
restart doesn't lose a conflict event; and fork-sync re-emits every 30m anyway
for any conflict that still exists, so the path self-heals. A per-fork
in-flight guard prevents two concurrent resolutions of the same fork if Dapr
redelivers before the first ACK lands.

Mirrors the llm-wiki event-subscriber pattern. Standard library only.
"""
import http.server
import json
import os
import socket
import subprocess
import threading
from datetime import datetime, timezone

LISTEN_PORT = int(os.environ.get("PORT", "8080"))
NAMESPACE = os.environ.get("NAMESPACE", "fork-maintenance")
PUBSUB_NAME = os.environ.get("DAPR_PUBSUB", "pubsub")
TOPIC = "fork.conflict.needs-resolution"
RESOLVER = os.environ.get("RESOLVER_SCRIPT", "/workspace/scripts/resolve-conflict.sh")
LOG_DIR = os.environ.get("RESOLVER_LOG_DIR", "/tmp/resolver")

SUBSCRIPTIONS = [{"pubsubname": PUBSUB_NAME, "topic": TOPIC, "route": "/events"}]

# Per-fork in-flight guard: only one resolution per fork at a time.
_inflight = set()
_inflight_lock = threading.Lock()


def log(msg: str) -> None:
    print(f"[conflict-subscriber] {datetime.now(timezone.utc).isoformat()} {msg}", flush=True)


def spawn_resolution(fork: str, payload: dict) -> None:
    """Spawn resolve-conflict.sh detached, logging to a per-run file."""
    os.makedirs(LOG_DIR, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    log_path = os.path.join(LOG_DIR, f"{fork}-{ts}.log")
    try:
        with open(log_path, "wb") as lf:
            # start_new_session=True detaches the child from this handler so it
            # keeps running after the HTTP response is sent. Env (ZAI_API_KEY,
            # GITHUB_TOKEN, MAINT_DIR, SKILL_PATH, ...) is inherited from the pod.
            proc = subprocess.Popen(
                ["bash", RESOLVER, fork],
                stdout=lf, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
                cwd="/workspace",
            )
        log(f"spawned resolve-conflict.sh {fork} (pid {proc.pid}) → {log_path}")
    except Exception as e:  # noqa: BLE001
        log(f"ERROR: could not spawn resolver for {fork}: {e}")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/dapr/subscribe":
            self._send(200, SUBSCRIPTIONS)
        elif self.path == "/healthz":
            self._send(200, {"status": "ok", "inflight": sorted(_inflight)})
        else:
            self._send(404, {"error": "not found"})

    def do_HEAD(self):
        self._send(200 if self.path == "/healthz" else 404, {})

    def do_POST(self):
        if self.path != "/events":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            envelope = json.loads(raw.decode() or "{}")
        except Exception:  # noqa: BLE001
            envelope = {}
        data = envelope.get("data", envelope) if isinstance(envelope, dict) else {}
        fork = data.get("fork", "unknown")
        log(f"event received: fork={fork} conflict_files={data.get('conflict_files')}")

        # ACK immediately (Dapr pub/sub contract) and resolve async.
        with _inflight_lock:
            if fork in _inflight:
                log(f"  {fork} already resolving — skipping (ACK to drop redelivery)")
                self._send(200, {"status": "SUCCESS"})
                return
            _inflight.add(fork)
        spawn_resolution(fork, data)
        # The in-flight marker is best-effort; resolution may outlive this guard.
        self._send(200, {"status": "SUCCESS"})

    def log_message(self, fmt, *args):  # noqa: A003
        pass


class DualStackServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        super().server_bind()


def ensure_yq():
    """Download yq if missing (the resolver image has git/jq/go/pi but not yq).
    resolve-conflict.sh + sync-fork.sh parse fork defs with yq."""
    import shutil
    import urllib.request
    if shutil.which("yq"):
        return
    dest = "/usr/local/bin/yq"
    url = "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
    try:
        urllib.request.urlretrieve(url, dest)
        os.chmod(dest, 0o755)
        log("installed yq → /usr/local/bin/yq")
    except Exception as e:  # noqa: BLE001
        log(f"WARN: could not install yq ({e}); resolve-conflict.sh will fail on fork defs")


def ensure_gh():
    """Download the GitHub CLI if missing so the agent has `gh`, authenticated via
    GH_TOKEN (= FORK_MAINTENANCE_GITHUB_TOKEN from BWS). gh reads GH_TOKEN
    automatically — no `gh auth login` needed."""
    import shutil
    import tarfile
    import urllib.request
    if shutil.which("gh"):
        return
    import json as _json
    try:
        with urllib.request.urlopen(
            "https://api.github.com/repos/cli/cli/releases/latest", timeout=15
        ) as r:
            ver = _json.load(r)["tag_name"].lstrip("v")
        url = f"https://github.com/cli/cli/releases/download/v{ver}/gh_{ver}_linux_amd64.tar.gz"
        tgz = "/tmp/gh.tar.gz"
        urllib.request.urlretrieve(url, tgz)
        with tarfile.open(tgz) as t:
            t.extract(f"gh_{ver}_linux_amd64/bin/gh", "/tmp")
        src = f"/tmp/gh_{ver}_linux_amd64/bin/gh"
        os.chmod(src, 0o755)
        os.replace(src, "/usr/local/bin/gh")
        log(f"installed gh v{ver} → /usr/local/bin/gh")
    except Exception as e:  # noqa: BLE001
        log(f"WARN: could not install gh ({e}); PR operations will be unavailable")


def main():
    ensure_yq()
    ensure_gh()
    log(f"starting on [::]:{LISTEN_PORT} (dual-stack, ns={NAMESPACE})")
    log(f"subscribed to pubsub={PUBSUB_NAME} topic={TOPIC} → spawns {RESOLVER}")
    httpd = DualStackServer(("::", LISTEN_PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
