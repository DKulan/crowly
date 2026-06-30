"""HTTP server for the Crowly companion.

This is the production companion the iOS app talks to. It implements only the
endpoints docs/architecture.md § Companion calls for, with state writes added
per the architecture's Store sub-bullet ("state lives here too, mirrored from
the app via simple state-change writes"). It is dependency-free Python 3 +
sqlite3, deliberately — easier for a future Hermes agent to install
unattended and for a user to audit.

Endpoints:
  GET  /              pairing payload (companion_url + pairing_token)
                      so a freshly-deployed companion has a single URL the
                      operator can open in a browser to copy/scan into the
                      app. The iOS app reads the same payload after QR scan;
                      this endpoint is the QR fallback for manual entry.
  GET  /pair          same payload, named explicitly.
  GET  /health        liveness probe, also reports stored count.
  POST /ingest        bearer-auth; the emitter's only endpoint. Validates,
                      upserts on `id`, preserves unknown fields verbatim.
  GET  /list          bearer-auth; all digests, newest-first.
  GET  /summary       bearer-auth; unread count + latest few (widget).
  POST /state         bearer-auth; mirror an app-side {id, state} change.

Two gotchas to know about (already hit by emitter/companion_stub.py):

  * Loopback connections are blocked under the command sandbox the agent
    harness runs in. Local end-to-end tests need
    `dangerouslyDisableSandbox: true` on the Bash call.
  * `http.server`'s `server_bind` calls `socket.getfqdn()`, which hangs for
    seconds on boxes with no working reverse resolver. The `_FastServer`
    override below skips that — same pattern as in companion_stub.py.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Reuse the emitter's validator. This is the single source of truth for "is
# this a valid digest"; the companion runs the same check server-side so a
# malformed payload never reaches the store (defense in depth — the emitter
# already validates before POSTing, but we can't trust the emitter wasn't a
# hand-rolled `curl`). The import path makes `crowly_emit` importable when
# either the repo root or the emitter dir is on PYTHONPATH (covers both the
# raw `python3 -m companion` invocation and the Docker layout).
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for _candidate in (os.path.join(_REPO_ROOT, "emitter"), _REPO_ROOT):
    if _candidate not in sys.path:
        sys.path.insert(0, _candidate)

try:
    from crowly_emit import validate, EmitError  # type: ignore
except ImportError as _e:  # pragma: no cover - bootstrap only
    raise SystemExit(
        "companion: cannot import crowly_emit; ensure emitter/ is on "
        "PYTHONPATH. Looked in: "
        + ", ".join(p for p in sys.path if "emitter" in p or p == _REPO_ROOT)
        + f" ({_e})"
    )

from companion.store import Store, VALID_STATES
from companion.push import PushConfig, fire_push


# Schema versions the app's decoder supports. M1 is v1 only. When the
# emitter or app gains a v2 (additive-only, per docs/schema.md § Versioning),
# bump this tuple — `/health` reports it so a freshly-paired app can tell
# whether the companion it's talking to is still in its support window.
SCHEMA_VERSIONS_SUPPORTED: tuple[int, ...] = (1,)


# --------------------------------------------------------------------------
# Config — env vars only. No CLI for the production path; the docker-compose
# bundle passes env vars in. CLI flags exist only for the test harness.
# --------------------------------------------------------------------------

def _env(name: str, default: str | None = None, *, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        raise SystemExit(
            f"companion: required env var {name} is not set. "
            f"See companion/README.md for the deployment spec."
        )
    return val or ""


class Config:
    """Frozen config bundle, built once at startup. Env-var-driven so a future
    Hermes agent can install the companion unattended (no interactive
    prompts, no config file to template)."""

    def __init__(
        self,
        *,
        pairing_token: str,
        db_path: str,
        host: str,
        port: int,
        public_url: str,
    ):
        self.pairing_token = pairing_token
        self.db_path = db_path
        self.host = host
        self.port = port
        # public_url is what the *app* will dial — for the dockerised default
        # it's the HTTPS hostname Caddy fronts. For a raw local run it's just
        # http://host:port. The pairing payload prints this so the operator
        # doesn't have to guess.
        self.public_url = public_url.rstrip("/")

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            pairing_token=_env("CROWLY_PAIRING_TOKEN", required=True),
            db_path=_env("CROWLY_DB_PATH", "/opt/data/crowly.db"),
            host=_env("CROWLY_HOST", "0.0.0.0"),
            port=int(_env("CROWLY_PORT", "8787")),
            public_url=_env("CROWLY_PUBLIC_URL", ""),  # filled in below if empty
        )


# --------------------------------------------------------------------------
# Server plumbing
# --------------------------------------------------------------------------

class _FastServer(ThreadingHTTPServer):
    """ThreadingHTTPServer that skips the reverse-DNS lookup in server_bind.

    Same workaround as emitter/companion_stub.py: stock HTTPServer.server_bind
    calls `socket.getfqdn(host)`, which can hang for seconds on a box with no
    working reverse resolver. We don't need the FQDN, so call the grandparent
    (`socketserver.TCPServer.server_bind`) directly.
    """

    # The handler reads these off `self.server`. Set by main() at startup.
    config: Config
    store: Store
    push_config: PushConfig

    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


# --------------------------------------------------------------------------
# Handler
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    # We log our own one-liners on writes; suppress BaseHTTPRequestHandler's
    # default access log so the operator's stdout isn't drowning in noise.
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
    def push_config(self) -> PushConfig:
        return self.server.push_config  # type: ignore[attr-defined]

    def _send_json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # The companion is talked to over HTTPS in production (Caddy in
        # front). These headers are belt-and-braces — they cost nothing.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        """Bearer-token auth — same token the app received during QR pairing.
        The architecture (§ Security) explicitly reuses the pairing token for
        both app reads and emitter writes; we don't invent a second secret."""
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {self.config.pairing_token}"
        # Constant-time-ish compare. SQLite/HTTP overhead dwarfs any timing
        # signal, but the explicit check is also more readable than `==`.
        if len(auth) != len(expected):
            return False
        result = 0
        for a, b in zip(auth, expected):
            result |= ord(a) ^ ord(b)
        return result == 0

    def _read_json_body(self) -> tuple[dict | None, str | None]:
        """Returns (parsed, error_message). Caller sends 400 on error.

        Robust to a missing / non-numeric Content-Length header — a stray
        `Content-Length: foo` previously raised ValueError up to the server
        loop, surfacing as a 500 with a traceback. A bad payload is a 400
        with a clear message; never a server-side crash.
        """
        raw_len = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_len)
        except (TypeError, ValueError):
            return None, f"invalid Content-Length: {raw_len!r}"
        if length <= 0:
            return None, "empty request body"
        if length > 5 * 1024 * 1024:  # 5 MB — generous for a digest
            return None, "request body too large"
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8")), None
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            return None, f"malformed JSON: {e}"

    def _pairing_payload(self) -> dict:
        """The shape the app expects from QR pairing (architecture.md
        § Pairing): `{companion_url, pairing_token}`. We serve it here so the
        operator has a single URL to open after `docker compose up` — they
        can copy the JSON or scan a QR generated client-side (rendering an
        actual QR image stays out of M1; that's a noted follow-up)."""
        return {
            "companion_url": self.config.public_url,
            "pairing_token": self.config.pairing_token,
        }

    # -- routing ----------------------------------------------------------

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path in ("/", "/pair"):
            # Pairing payload is intentionally unauthenticated — the *whole
            # point* of the endpoint is to be reachable before the app has a
            # token. In production this URL is only ever hit by the operator
            # right after deploy; Caddy + the user's firewall scope who can
            # reach it. M2 may swap this for a single-use pairing flow.
            self._send_json(200, self._pairing_payload())
            return

        if path == "/health":
            self._send_json(200, {
                "status": "ok",
                "stored": self.store.count(),
                "schema_versions_supported": list(SCHEMA_VERSIONS_SUPPORTED),
            })
            return

        # Everything below requires auth.
        if not self._authed():
            self._send_json(401, {"error": "unauthorized: bad or missing bearer token"})
            return

        if path == "/list":
            self._send_json(200, {"digests": self.store.list_digests()})
            return

        if path == "/summary":
            self._send_json(200, self.store.summary())
            return

        self._send_json(404, {"error": f"not found: {path}"})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if not self._authed():
            self._send_json(401, {"error": "unauthorized: bad or missing bearer token"})
            return

        if path == "/ingest":
            self._handle_ingest()
            return

        if path == "/state":
            self._handle_state()
            return

        self._send_json(404, {"error": f"not found: {path}"})

    # -- /ingest ----------------------------------------------------------

    def _handle_ingest(self) -> None:
        digest, err = self._read_json_body()
        if err is not None or digest is None:
            self._send_json(400, {"error": err or "missing body"})
            return

        if not isinstance(digest, dict):
            self._send_json(400, {"error": "request body must be a JSON object"})
            return

        # Defense-in-depth: reject any top-level key beginning with `_`.
        # Underscore-prefixed keys are reserved for companion-injected,
        # non-contract fields (the wire-level convention paired with the
        # `/list` and `/summary` wrapper shape — state lives as a sibling
        # of `digest`, never inside it). The wrapper shape already makes
        # it impossible to re-POST a served digest and accidentally
        # persist `_state`; this 422 makes the invariant a structural
        # guarantee AND a guarded rule, so a buggy client surfaces fast
        # instead of silently writing odd-shaped blobs. The store stays
        # dumb; the wire-shape rule is visible at the wire boundary.
        reserved = sorted(k for k in digest if isinstance(k, str) and k.startswith("_"))
        if reserved:
            self._send_json(422, {
                "error": (
                    "keys beginning with '_' are reserved for non-contract use "
                    "and may not be persisted as digest content: "
                    + ", ".join(repr(k) for k in reserved)
                )
            })
            return

        # Server-side validation. The emitter validates client-side too, but
        # that's a courtesy — anyone can `curl -X POST` a malformed payload,
        # and we want them to see a 422 with field-level detail in their
        # logs, not a 5xx with a Python traceback.
        try:
            validate(digest)
        except EmitError as e:
            self._send_json(422, {"error": str(e)})
            return

        received_at = _now_iso()
        stored, was_update = self.store.upsert_digest(digest, received_at=received_at)

        # One-line operator log per write — useful when the cron is misbehaving.
        print(
            f"[companion] {'updated' if was_update else 'stored'} {stored['id']} "
            f"(urgency={stored.get('urgency')}, total={self.store.count()})",
            flush=True,
        )

        # Urgency-gated push (companion/push.py). Runs ONLY on first-store of
        # a new digest — a re-POST that just updates fields doesn't refire a
        # push. (The push is "new digest arrived"; an emitter editing the
        # body of an already-delivered digest is not a new event.) Push is
        # strictly best-effort: fire_push never raises, and even a failure
        # reason from the relay does not affect the ingest's 200/201 reply.
        if not was_update:
            push_status = fire_push(self.push_config, stored)
            print(
                f"[companion] push {push_status} "
                f"(urgency={stored.get('urgency')}, id={stored['id']})",
                flush=True,
            )

        self._send_json(
            200 if was_update else 201,
            {"status": "updated" if was_update else "stored", "id": stored["id"]},
        )

    # -- /state -----------------------------------------------------------

    def _handle_state(self) -> None:
        body, err = self._read_json_body()
        if err is not None or body is None:
            self._send_json(400, {"error": err or "missing body"})
            return

        digest_id = body.get("id") if isinstance(body, dict) else None
        state = body.get("state") if isinstance(body, dict) else None
        if not isinstance(digest_id, str) or not digest_id:
            self._send_json(422, {"error": "missing or invalid 'id'"})
            return
        if state not in VALID_STATES:
            self._send_json(
                422,
                {"error": f"invalid 'state': must be one of {list(VALID_STATES)}"},
            )
            return

        if not self.store.set_state(digest_id, state, updated_at=_now_iso()):
            self._send_json(404, {"error": f"no digest with id {digest_id!r}"})
            return

        print(f"[companion] state {digest_id} -> {state}", flush=True)
        self._send_json(200, {"status": "ok", "id": digest_id, "state": state})


def _now_iso() -> str:
    """Server clock, used for the digest's `received_at` / `updated_at`
    columns. NOT the digest's `created_at` — that's authored by the emitter
    and we never overwrite it (an emitter back-dating a digest is a feature)."""
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def _print_pairing_banner(config: Config) -> None:
    """Print the pairing payload at startup. The operator copies this into
    the app's manual-pairing UI (or scans a QR they generate client-side
    from the JSON). Rendering an actual QR image is a noted follow-up —
    keeping the package dependency-free is the higher priority for M1."""
    payload = {
        "companion_url": config.public_url,
        "pairing_token": config.pairing_token,
    }
    bar = "=" * 64
    print(bar, flush=True)
    print("Crowly companion — pairing payload", flush=True)
    print(bar, flush=True)
    print(json.dumps(payload, indent=2), flush=True)
    print(bar, flush=True)
    print(f"Also served at: {config.public_url}/pair", flush=True)
    print(bar, flush=True)


def run(config: Config) -> int:
    # Make sure the DB directory exists. Docker compose mounts /opt/data, but
    # a raw `python3 -m companion` run on the host should also Just Work.
    db_dir = os.path.dirname(os.path.abspath(config.db_path))
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)

    # If public_url wasn't set, fall back to the bind URL. In a real deploy
    # this is the HTTPS hostname Caddy fronts; the env var is required there.
    if not config.public_url:
        config.public_url = f"http://{config.host}:{config.port}"

    store = Store(config.db_path)
    push_config = PushConfig.from_env()
    server = _FastServer((config.host, config.port), Handler)
    server.config = config
    server.store = store
    server.push_config = push_config

    _print_pairing_banner(config)
    print(
        f"[companion] listening on http://{config.host}:{config.port}  "
        f"(db={config.db_path}, public_url={config.public_url})",
        flush=True,
    )
    # One-line, secret-free announcement of push posture. The companion runs
    # fine without push (single-user dev mode); this line is how the operator
    # confirms the gate is on/off intentionally and not by accident.
    print(f"[companion] {push_config.describe()}", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[companion] shutting down", flush=True)
    finally:
        server.server_close()
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point. Env vars are the production path; CLI flags exist only so
    the end-to-end test can boot a companion on a non-default port without
    polluting the host's environment."""
    parser = argparse.ArgumentParser(
        description="Crowly companion service (M1, env-var-configured)."
    )
    parser.add_argument("--port", type=int, help="override CROWLY_PORT")
    parser.add_argument("--host", help="override CROWLY_HOST")
    parser.add_argument("--db", help="override CROWLY_DB_PATH")
    parser.add_argument("--token", help="override CROWLY_PAIRING_TOKEN")
    parser.add_argument("--public-url", help="override CROWLY_PUBLIC_URL")
    args = parser.parse_args(argv)

    # CLI overrides write into the env so Config.from_env stays the single
    # construction path — env-var-first config is a hard requirement.
    if args.token:      os.environ["CROWLY_PAIRING_TOKEN"] = args.token
    if args.db:         os.environ["CROWLY_DB_PATH"]      = args.db
    if args.host:       os.environ["CROWLY_HOST"]         = args.host
    if args.port:       os.environ["CROWLY_PORT"]         = str(args.port)
    if args.public_url: os.environ["CROWLY_PUBLIC_URL"]   = args.public_url

    config = Config.from_env()
    return run(config)


if __name__ == "__main__":
    raise SystemExit(main())
