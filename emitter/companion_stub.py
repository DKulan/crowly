#!/usr/bin/env python3
"""companion_stub.py — a minimal Crowly companion for testing the emitter.

This is NOT the production companion (that ships as a Docker bundle with
auto-HTTPS, per docs/architecture.md). It exists so the emitter's wire
contract can be exercised end-to-end on a dev box: it implements just enough
of the companion to prove a digest the emitter builds is accepted, stored, and
served back in the shape the iOS app expects.

What it does (the M1 companion-core contract, docs/architecture.md §2):
  POST /ingest    bearer-auth, validate, store idempotent on digest.id,
                  PRESERVE UNKNOWN FIELDS VERBATIM, return {"status","id"}.
                  4xx with a clear JSON error on a malformed payload; 401 on a
                  bad/missing token. A bad payload never crashes the store.
  GET  /list      all stored digests, newest-first (the app's card list).
  GET  /summary   latest few + unread count (the widget's cheap endpoint).

What it deliberately omits (out of scope for a test stub): TLS (the real one
requires it and fails loud without it), persistence across restarts (store is
in-memory), pagination, read/archive state writes, the relay push hop.

Run:
    python3 companion_stub.py --port 8788 --token testtoken
    # then point the emitter at it:
    CROWLY_COMPANION_URL=http://127.0.0.1:8788 CROWLY_TOKEN=testtoken \
      python3 crowly_emit.py --content-file sample.json
"""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Reuse the emitter's validator so the stub rejects exactly what the app would
# fail to decode — single source of truth for "is this a valid digest".
from crowly_emit import validate, EmitError, VALID_URGENCY  # noqa: F401

# In-memory store: id -> full digest blob (unknown fields preserved verbatim).
STORE: dict[str, dict] = {}
# Insertion/update order tracking so /list and /summary can sort newest-first
# by created_at, falling back to arrival order.
TOKEN = "testtoken"


class _FastServer(ThreadingHTTPServer):
    """ThreadingHTTPServer that skips the reverse-DNS lookup in server_bind.

    The stock HTTPServer.server_bind() calls socket.getfqdn(host), which makes
    a reverse-DNS query that hangs for seconds (or forever) on boxes with no
    working reverse resolver. We don't need the FQDN, so set it directly.
    """

    def server_bind(self):
        # Bypass HTTPServer.server_bind (which calls getfqdn) and call its
        # grandparent, socketserver.TCPServer.server_bind, which just binds.
        import socketserver
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def _sorted_digests() -> list[dict]:
    """Newest-first by created_at (string ISO sorts correctly), stable."""
    return sorted(
        STORE.values(),
        key=lambda d: d.get("created_at", ""),
        reverse=True,
    )


class Handler(BaseHTTPRequestHandler):
    # Quiet the default noisy stderr logging; we print our own one-liners.
    def log_message(self, fmt, *args):  # noqa: N802
        pass

    def _send(self, code: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {TOKEN}"

    # -- ingest -----------------------------------------------------------
    def do_POST(self):  # noqa: N802
        if self.path.rstrip("/") != "/ingest":
            self._send(404, {"error": "not found"})
            return
        if not self._authed():
            self._send(401, {"error": "unauthorized: bad or missing bearer token"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            digest = json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            self._send(400, {"error": f"malformed JSON: {e}"})
            return

        # Validate exactly as the app would. A bad payload is a clear 4xx in
        # the cron author's logs, never a crash or a silent accept.
        try:
            validate(digest)
        except EmitError as e:
            self._send(422, {"error": str(e)})
            return

        digest_id = digest["id"]
        is_update = digest_id in STORE
        # Store the WHOLE blob — including any keys not in KNOWN_KEYS — so a
        # field a newer app understands survives a round-trip (passthrough).
        STORE[digest_id] = digest
        print(f"[companion] {'updated' if is_update else 'stored'} {digest_id} "
              f"(urgency={digest.get('urgency')}, {len(STORE)} total)")
        self._send(200 if is_update else 201,
                   {"status": "updated" if is_update else "stored", "id": digest_id})

    # -- serve ------------------------------------------------------------
    def do_GET(self):  # noqa: N802
        path = self.path.rstrip("/")
        if path == "/list":
            self._send(200, {"digests": _sorted_digests()})
        elif path == "/summary":
            latest = _sorted_digests()[:3]
            # "unread count" — the stub has no read-state writes, so treat all
            # stored digests as unread. Enough to exercise the widget endpoint.
            self._send(200, {
                "unread_count": len(STORE),
                "latest": [
                    {"id": d["id"], "title": d.get("title"),
                     "bottom_line": d.get("bottom_line"),
                     "job_id": d.get("job_id"),
                     "urgency": d.get("urgency"),
                     "created_at": d.get("created_at")}
                    for d in latest
                ],
            })
        elif path in ("", "/", "/health"):
            self._send(200, {"status": "ok", "stored": len(STORE)})
        else:
            self._send(404, {"error": "not found"})


def main(argv: list[str] | None = None) -> int:
    global TOKEN
    parser = argparse.ArgumentParser(description="Minimal Crowly companion (test stub)")
    parser.add_argument("--port", type=int, default=8788)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--token", default="testtoken",
                        help="bearer token clients must present on /ingest")
    args = parser.parse_args(argv)
    TOKEN = args.token

    server = _FastServer((args.host, args.port), Handler)
    print(f"[companion] listening on http://{args.host}:{args.port} "
          f"(token={args.token!r})  POST /ingest  GET /list  GET /summary")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[companion] shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
