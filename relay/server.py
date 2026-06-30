"""HTTP server for the Crowly push relay.

This is the project-operated central piece — the one thing the user does NOT
self-host (docs/architecture.md § Push). It is intentionally small: a
mapping table, an APNs client, four endpoints.

Endpoints:
  GET  /health        liveness probe. Reports the configured APNs mode
                      (mock/sandbox/production) and the number of registered
                      devices. **Does not report routing_tokens or device_tokens.**
  POST /register      app-facing: `{device_token, routing_token?}` → `{routing_token}`.
                      Idempotent on device_token (re-register returns the existing
                      routing_token).
  POST /unregister    privacy purge: `{routing_token}` → 200/404.
  POST /push          companion-facing, bearer-auth: `{routing_token, pointer_text}`
                      → 202 accepted. Fire-and-forget; the companion does NOT wait
                      on APNs success. Rate-limited per routing_token.

Privacy rules baked into this file:
  * The /push handler NEVER logs the routing_token, device_token, or pointer_text.
    Only errors and rate-limit events are logged, and those carry no
    per-push metadata.
  * The /register handler logs only the action (not the tokens).
  * /push returns 202 even if APNs ultimately fails (fan-out and forget):
    the companion is best-effort, so a failure here would only invite the
    companion to retry, which we don't want.

Same gotchas as companion/server.py:
  * Loopback connections are sandbox-blocked under the agent harness — local
    tests use `dangerouslyDisableSandbox: true`.
  * `_FastServer` skips `socket.getfqdn()` for the same hang-on-bind reason.
"""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional

from relay.apns import APNsClient, APNsResult, MockAPNsClient, from_env as apns_from_env
from relay.store import Store


# -------------------------------------------------------------------------
# Config — env vars only.
# -------------------------------------------------------------------------

def _env(name: str, default: Optional[str] = None, *, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        raise SystemExit(
            f"relay: required env var {name} is not set. "
            f"See relay/README.md for the deployment spec."
        )
    return val or ""


class Config:
    def __init__(
        self,
        *,
        push_token: str,
        db_path: str,
        host: str,
        port: int,
        apns_topic: str,
        rate_limit_per_minute: int,
    ):
        self.push_token = push_token
        self.db_path = db_path
        self.host = host
        self.port = port
        # `apns-topic` is the iOS app's bundle id. It's per-app config, not
        # per-push, so we read it once and bake it into every push.
        self.apns_topic = apns_topic
        self.rate_limit_per_minute = rate_limit_per_minute

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            push_token=_env("RELAY_PUSH_TOKEN", required=True),
            db_path=_env("RELAY_DB_PATH", "/opt/data/relay.db"),
            host=_env("RELAY_HOST", "0.0.0.0"),
            port=int(_env("RELAY_PORT", "8788")),
            # Topic is required for real APNs; for mock mode we accept a
            # placeholder so the operator doesn't have to invent a bundle id
            # just to boot the relay in dev.
            apns_topic=_env("APNS_TOPIC", "dev.mock.crowly"),
            rate_limit_per_minute=int(_env("RELAY_RATE_LIMIT_PER_MINUTE", "30")),
        )


# -------------------------------------------------------------------------
# Rate limiter — per routing_token, sliding window, in-memory.
# -------------------------------------------------------------------------

class RateLimiter:
    """Sliding-window rate limit, keyed by routing_token.

    In-memory only (single-process relay). M2-level scale-out would need to
    move this to Redis or similar, but the M1 relay is one box: a misbehaving
    cron pinning a single routing_token at 1000 rps is what we're stopping,
    and a per-process limiter handles that.

    The default 30/min is generous: even an urgent-heavy cron probably emits
    < 5 pushes/hour. We tune up if real usage demands it.
    """

    def __init__(self, per_minute: int):
        self.per_minute = per_minute
        self._windows: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        cutoff = now - 60.0
        with self._lock:
            window = self._windows.get(key)
            if window is None:
                window = deque()
                self._windows[key] = window
            # Trim old entries.
            while window and window[0] < cutoff:
                window.popleft()
            if len(window) >= self.per_minute:
                return False
            window.append(now)
            return True


# -------------------------------------------------------------------------
# Server plumbing
# -------------------------------------------------------------------------

class _FastServer(ThreadingHTTPServer):
    """Same getfqdn-skip pattern as companion/server.py._FastServer."""

    config: Config
    store: Store
    apns: APNsClient
    apns_mode: str
    rate_limiter: RateLimiter

    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


# -------------------------------------------------------------------------
# Handler
# -------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    # Suppress the default access log; we emit our own one-liners and
    # those deliberately avoid per-push metadata.
    def log_message(self, fmt, *args):  # noqa: N802
        pass

    # -- helpers ----------------------------------------------------------

    @property
    def config(self) -> Config:
        return self.server.config  # type: ignore[attr-defined]

    @property
    def store(self) -> Store:
        return self.server.store  # type: ignore[attr-defined]

    @property
    def apns(self) -> APNsClient:
        return self.server.apns  # type: ignore[attr-defined]

    @property
    def rate_limiter(self) -> RateLimiter:
        return self.server.rate_limiter  # type: ignore[attr-defined]

    def _send_json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authed_push(self) -> bool:
        """The /push bearer check. Same constant-time-ish compare as the
        companion. Distinct token from the companion's pairing token — the
        relay is operated by the project; the push token is shared with all
        companions and rotated centrally."""
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {self.config.push_token}"
        if len(auth) != len(expected):
            return False
        result = 0
        for a, b in zip(auth, expected):
            result |= ord(a) ^ ord(b)
        return result == 0

    def _read_json_body(self) -> tuple[Optional[dict], Optional[str]]:
        """Robust body reader. Same shape as companion/server.py."""
        raw_len = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_len)
        except (TypeError, ValueError):
            return None, f"invalid Content-Length: {raw_len!r}"
        if length <= 0:
            return None, "empty request body"
        if length > 64 * 1024:
            # Generous for a pointer payload, tight enough to stop garbage.
            # The biggest legitimate body is /register with a device token
            # (~80 bytes) and an optional routing_token (~50 bytes).
            return None, "request body too large"
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8")), None
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            return None, f"malformed JSON: {e}"

    # -- routing ----------------------------------------------------------

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/", "/health"):
            self._send_json(200, {
                "status": "ok",
                "apns_mode": self.server.apns_mode,  # type: ignore[attr-defined]
                "registered_devices": self.store.count(),
            })
            return
        self._send_json(404, {"error": f"not found: {path}"})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path == "/register":
            self._handle_register()
            return
        if path == "/unregister":
            self._handle_unregister()
            return
        if path == "/push":
            # /push is the only auth-gated endpoint. Auth check before
            # reading the body so a flood of unauthenticated POSTs can't
            # spike the parser.
            if not self._authed_push():
                self._send_json(401, {"error": "unauthorized: bad or missing bearer token"})
                return
            self._handle_push()
            return

        self._send_json(404, {"error": f"not found: {path}"})

    # -- /register --------------------------------------------------------

    def _handle_register(self) -> None:
        body, err = self._read_json_body()
        if err is not None or body is None:
            self._send_json(400, {"error": err or "missing body"})
            return
        if not isinstance(body, dict):
            self._send_json(400, {"error": "request body must be a JSON object"})
            return

        device_token = body.get("device_token")
        routing_token = body.get("routing_token")  # optional
        if not isinstance(device_token, str) or not device_token:
            self._send_json(422, {"error": "missing or invalid 'device_token'"})
            return
        if routing_token is not None and (
            not isinstance(routing_token, str) or not routing_token
        ):
            self._send_json(422, {"error": "if provided, 'routing_token' must be a non-empty string"})
            return

        try:
            rt = self.store.upsert(device_token, routing_token=routing_token)
        except ValueError as e:
            self._send_json(422, {"error": str(e)})
            return

        # Log only the count, not the tokens.
        print(
            f"[relay] register: now {self.store.count()} device(s) registered",
            flush=True,
        )
        self._send_json(200, {"routing_token": rt})

    # -- /unregister ------------------------------------------------------

    def _handle_unregister(self) -> None:
        body, err = self._read_json_body()
        if err is not None or body is None:
            self._send_json(400, {"error": err or "missing body"})
            return
        if not isinstance(body, dict):
            self._send_json(400, {"error": "request body must be a JSON object"})
            return

        routing_token = body.get("routing_token")
        if not isinstance(routing_token, str) or not routing_token:
            self._send_json(422, {"error": "missing or invalid 'routing_token'"})
            return

        deleted = self.store.delete_by_routing_token(routing_token)
        # Log only the action and the resulting count.
        print(
            f"[relay] unregister: {'purged' if deleted else 'no-op'}; "
            f"{self.store.count()} device(s) remain",
            flush=True,
        )
        if not deleted:
            self._send_json(404, {"error": "unknown routing_token"})
            return
        self._send_json(200, {"status": "purged"})

    # -- /push ------------------------------------------------------------

    def _handle_push(self) -> None:
        body, err = self._read_json_body()
        if err is not None or body is None:
            self._send_json(400, {"error": err or "missing body"})
            return
        if not isinstance(body, dict):
            self._send_json(400, {"error": "request body must be a JSON object"})
            return

        routing_token = body.get("routing_token")
        pointer_text = body.get("pointer_text")
        if not isinstance(routing_token, str) or not routing_token:
            self._send_json(422, {"error": "missing or invalid 'routing_token'"})
            return
        if not isinstance(pointer_text, str) or not pointer_text:
            self._send_json(422, {"error": "missing or invalid 'pointer_text'"})
            return
        # Bound the pointer length. The privacy rule (content-free pointer)
        # is on the *companion* side — the relay can't know what content is
        # — but a hard length cap means a bug or compromise on the companion
        # side can't accidentally exfiltrate a digest body through the
        # pointer field. 200 chars is generous for "Job: new digest →".
        if len(pointer_text) > 200:
            self._send_json(422, {"error": "pointer_text too long (max 200 chars)"})
            return

        # Rate-limit per routing_token. If we're over the limit, drop the
        # push and 429 — the relay is best-effort on the companion side,
        # so a 429 is just a "skip"; the next push will come through.
        if not self.rate_limiter.allow(routing_token):
            # Log only the event, not the token.
            print("[relay] rate-limit hit; dropping push", flush=True)
            self._send_json(429, {"error": "rate limit exceeded"})
            return

        device_token = self.store.device_token_for(routing_token)
        if device_token is None:
            # Unknown routing_token — could be a stale companion still
            # configured against a disconnected device. 404 so the companion
            # operator can spot it, but we don't include the token in the body.
            self._send_json(404, {"error": "unknown routing_token"})
            return

        # Fire-and-forget. We respond 202 first, then send. There's a
        # subtlety: returning early before send() would leak Unix-y races,
        # so we send synchronously here and respond 202 right after, in the
        # same handler. The semantic the companion sees is the same — 202,
        # not 200 — which is the signal it should NOT block on success.
        result = self.apns.send(
            device_token,
            pointer_text,
            topic=self.config.apns_topic,
        )

        if result.unregistered:
            # APNs reports the device is gone. Purge the row so future
            # /push calls 404 cleanly instead of repeatedly trying a dead
            # token. This is the device-side purge path — the in-app
            # "disconnect" hits /unregister; this is the operator-side
            # equivalent driven by APNs feedback.
            self.store.delete_by_device_token(device_token)
            print("[relay] apns reported unregistered; row purged", flush=True)
        elif not result.ok:
            # Log the reason (safe; no token), but still 202 the caller.
            print(f"[relay] apns send failed: {result.reason}", flush=True)
        else:
            # Success — log only that a push went out, not who or what.
            print("[relay] push delivered", flush=True)

        # 202 regardless: the caller does NOT wait on Apple, by contract.
        self._send_json(202, {"status": "accepted"})


# -------------------------------------------------------------------------
# main
# -------------------------------------------------------------------------

def _print_boot_banner(config: Config, apns_mode: str) -> None:
    bar = "=" * 64
    print(bar, flush=True)
    print("Crowly push relay", flush=True)
    print(bar, flush=True)
    print(f"  listening on   http://{config.host}:{config.port}", flush=True)
    print(f"  db             {config.db_path}", flush=True)
    print(f"  apns mode      {apns_mode}", flush=True)
    print(f"  apns topic     {config.apns_topic}", flush=True)
    print(f"  rate limit     {config.rate_limit_per_minute}/min per routing_token", flush=True)
    print(bar, flush=True)


def run(
    config: Config,
    *,
    apns_client: Optional[APNsClient] = None,
    apns_mode: Optional[str] = None,
) -> int:
    db_dir = os.path.dirname(os.path.abspath(config.db_path))
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)

    # Tests can inject a MockAPNsClient directly; the production path goes
    # through apns_from_env() which respects APNS_ENV.
    if apns_client is None:
        apns_client, apns_mode = apns_from_env()
    elif apns_mode is None:
        apns_mode = "mock" if isinstance(apns_client, MockAPNsClient) else "injected"

    store = Store(config.db_path)
    rate_limiter = RateLimiter(config.rate_limit_per_minute)

    server = _FastServer((config.host, config.port), Handler)
    server.config = config
    server.store = store
    server.apns = apns_client
    server.apns_mode = apns_mode
    server.rate_limiter = rate_limiter

    _print_boot_banner(config, apns_mode)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[relay] shutting down", flush=True)
    finally:
        server.server_close()
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    """Entry point. Env vars are the production path; CLI flags exist only
    so the test harness can boot a relay on a non-default port without
    polluting the host's environment."""
    parser = argparse.ArgumentParser(description="Crowly push relay")
    parser.add_argument("--port", type=int, help="override RELAY_PORT")
    parser.add_argument("--host", help="override RELAY_HOST")
    parser.add_argument("--db", help="override RELAY_DB_PATH")
    parser.add_argument("--push-token", help="override RELAY_PUSH_TOKEN")
    parser.add_argument("--apns-topic", help="override APNS_TOPIC")
    args = parser.parse_args(argv)

    if args.push_token: os.environ["RELAY_PUSH_TOKEN"] = args.push_token
    if args.db:         os.environ["RELAY_DB_PATH"]    = args.db
    if args.host:       os.environ["RELAY_HOST"]       = args.host
    if args.port:       os.environ["RELAY_PORT"]       = str(args.port)
    if args.apns_topic: os.environ["APNS_TOPIC"]       = args.apns_topic

    config = Config.from_env()
    return run(config)


if __name__ == "__main__":
    raise SystemExit(main())
