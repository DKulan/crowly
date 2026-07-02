"""HTTP server for the Crowly companion.

This is the production companion the iOS app talks to. It implements only the
endpoints docs/architecture.md § Companion calls for, with state writes added
per the architecture's Store sub-bullet ("state lives here too, mirrored from
the app via simple state-change writes"). It is dependency-free Python 3 +
sqlite3, deliberately — easier for a future Hermes agent to install
unattended and for a user to audit.

Endpoints:
  GET  /              pairing payload (companion_url + pairing_token).
                      Gated behind CROWLY_PAIR_ENABLED (default OFF): when
                      disabled the route returns 404 so the endpoint doesn't
                      even advertise its existence. The operator flips the
                      env var on for the brief initial pairing window and
                      back off afterwards — the companion's Tailscale Funnel
                      hostname is discoverable via Certificate Transparency,
                      so a permanently-open /pair leaks the bearer token to
                      anyone who finds the URL. The startup banner still
                      prints the token to the operator's stdout regardless.
  GET  /pair          same payload, named explicitly. Same gate as above.
  GET  /health        liveness probe. Unauthed. Reports `status` and
                      `schema_versions_supported`. Only reports the `stored`
                      count when CROWLY_PAIR_ENABLED is on — otherwise
                      omitted so /health doesn't leak digest counts to
                      unauthenticated callers.
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


# Schema versions the app's decoder supports. v2 adds the optional top-level
# `content` array of typed blocks (additive-only, per docs/schema.md
# § Versioning); v1 digests (summary/sections) remain valid. `/health` reports
# this tuple so a freshly-paired app can tell whether the companion it's
# talking to is still in its support window. Note: ingest validation goes
# through the shared crowly_emit.validate(), which does NOT gate on the
# schema_version *value* (it only requires it be an int) — so bumping this
# tuple is purely an advertisement; no ingest-path change is needed.
SCHEMA_VERSIONS_SUPPORTED: tuple[int, ...] = (1, 2)


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
        pair_enabled: bool,
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
        # pair_enabled gates the network-reachable /pair (and /) endpoints.
        # Default OFF: the companion's public hostname is discoverable via
        # Certificate Transparency logs, and a permanently-open /pair leaks
        # the bearer token to anyone who finds the URL. Operator flips this
        # on for the initial pairing window, then off again.
        self.pair_enabled = pair_enabled

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            pairing_token=_env("CROWLY_PAIRING_TOKEN", required=True),
            db_path=_env("CROWLY_DB_PATH", "/opt/data/crowly.db"),
            host=_env("CROWLY_HOST", "0.0.0.0"),
            port=int(_env("CROWLY_PORT", "8787")),
            public_url=_env("CROWLY_PUBLIC_URL", ""),  # filled in below if empty
            # Default OFF. Treat "1"/"true"/"yes" (case-insensitive) as on;
            # anything else — including unset — is off. Keeping the accepted
            # truthy set narrow avoids a `CROWLY_PAIR_ENABLED=false` reading
            # as truthy just because the string is non-empty.
            pair_enabled=_env("CROWLY_PAIR_ENABLED", "").strip().lower()
                in ("1", "true", "yes"),
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
        § Pairing): `{companion_url, pairing_token}`. This payload contains
        the bearer token in cleartext, so the HTTP surface for it is gated
        by CROWLY_PAIR_ENABLED (see do_GET). Only callers that already
        passed that env gate reach this helper."""
        return {
            "companion_url": self.config.public_url,
            "pairing_token": self.config.pairing_token,
        }

    # -- routing ----------------------------------------------------------

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path in ("/", "/pair"):
            # /pair returns the bearer token in cleartext, so it's gated by
            # CROWLY_PAIR_ENABLED (default OFF). The operator flips the env
            # var on for the brief initial pairing window and back off
            # afterwards — the Tailscale Funnel hostname is discoverable via
            # Certificate Transparency logs, so a permanently-open /pair
            # leaks full read + ingest access. When disabled we return 404
            # (not 403) so we don't advertise the endpoint's existence.
            if not self.config.pair_enabled:
                self._send_json(404, {"error": f"not found: {path}"})
                return
            self._send_json(200, self._pairing_payload())
            return

        if path == "/health":
            # Liveness probe. Unauthed by design. `stored` is only reported
            # when pairing is enabled — otherwise it leaks the digest count
            # to any unauthenticated caller who finds the URL.
            payload: dict = {
                "status": "ok",
                "schema_versions_supported": list(SCHEMA_VERSIONS_SUPPORTED),
            }
            if self.config.pair_enabled:
                payload["stored"] = self.store.count()
            self._send_json(200, payload)
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
    """Print the pairing payload at startup. The operator's stdout is a
    local channel (not network-reachable), so we always print here — the
    operator needs the token to pair the app. What DOES change with
    CROWLY_PAIR_ENABLED is the network-reachable HTTP /pair endpoint;
    the banner calls that state out explicitly so the operator knows
    whether they need to flip the env var on for pairing."""
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
    if config.pair_enabled:
        print(
            f"HTTP /pair endpoint: EXPOSED (CROWLY_PAIR_ENABLED=on) — "
            f"also served at: {config.public_url}/pair",
            flush=True,
        )
        print(
            "  Flip CROWLY_PAIR_ENABLED off once the app is paired; the "
            "token is discoverable to anyone who finds this URL.",
            flush=True,
        )
    else:
        print(
            "HTTP /pair endpoint: GATED-OFF (CROWLY_PAIR_ENABLED unset). "
            "Requests to / and /pair return 404 over the network. To "
            "pair the app, set CROWLY_PAIR_ENABLED=1 and restart, then "
            "flip it back off after pairing.",
            flush=True,
        )
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
    server = _FastServer((config.host, config.port), Handler)
    server.config = config
    server.store = store

    _print_pairing_banner(config)
    print(
        f"[companion] listening on http://{config.host}:{config.port}  "
        f"(db={config.db_path}, public_url={config.public_url})",
        flush=True,
    )

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
