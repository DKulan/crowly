#!/usr/bin/env python3
"""End-to-end test for the companion's urgency-gated push (companion/push.py).

What this covers:

  1. **Urgency gate** — ingest at each tier exactly once, assert:
       * `urgent` and `high` → fire one push at the stub relay.
       * `normal` and `low`  → do NOT push.
  2. **Content-free pointer** — the pointer text the relay receives is
     `"<job_id>: new digest"`. NONE of the title / bottom_line / summary /
     sources URL leak across the wire.
  3. **Bearer auth** — the companion presents the configured relay token
     on `/push`.
  4. **Routing token** — the companion sends the configured
     `CROWLY_ROUTING_TOKEN`, not anything from the digest.
  5. **Best-effort, never critical-path** — point the companion at a dead
     relay URL (port not listening). Ingest of a `high`-urgency digest
     still succeeds (201, stored, listable). The companion logs
     `push failed: …` but does NOT 5xx.
  6. **No-op when unconfigured** — boot a companion with no relay env vars.
     Ingest of an `urgent` digest still succeeds and does NOT attempt any
     network call (we'd notice via timing — and the log line says
     `push skipped-unconfigured`).
  7. **Re-POST does not refire push** — POSTing the same digest id twice
     fires push only once. (The push is "new digest arrived"; an update
     is not a new event.)

Run:
    python3 companion/test_push_gate.py
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPANION_TOKEN = "test-companion-pairing-token"
RELAY_TOKEN = "test-relay-push-token"
ROUTING_TOKEN = "rt_test-routing-token-12345"


# ----------------------------------------------------------------------
# Stub relay — records every /push, with the body + auth header
# ----------------------------------------------------------------------

class _StubRelayHandler(BaseHTTPRequestHandler):
    """In-process stub of the relay's POST /push. Records what arrives so
    the test can assert what the companion sent. Returns 202 (the real
    relay's success code), or whatever the harness has configured."""

    def log_message(self, fmt, *args):  # noqa: N802
        pass

    def do_POST(self):  # noqa: N802
        if self.path != "/push":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        auth = self.headers.get("Authorization", "")
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            body = {"_unparseable": raw.decode("utf-8", "replace")}
        recorder: _StubRelay = self.server.recorder  # type: ignore[attr-defined]
        recorder.received.append({"auth": auth, "body": body})
        code = recorder.next_status
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "20")
        self.end_headers()
        self.wfile.write(b'{"status":"accepted"}')


class _StubRelay:
    """In-process stub the companion can POST to. The companion is a
    subprocess (so we exercise the real env-var → boot path), but the relay
    runs in this Python process so the test can inspect what arrived
    without a second subprocess of stdout-scraping."""

    def __init__(self, port: int):
        self.port = port
        self.received: list[dict] = []
        self.next_status = 202

        class _FastServer(ThreadingHTTPServer):
            recorder: "_StubRelay"
            def server_bind(self):  # same getfqdn-skip
                import socketserver
                socketserver.TCPServer.server_bind(self)
                host, p = self.server_address[:2]
                self.server_name = host
                self.server_port = p

        self._server = _FastServer(("127.0.0.1", port), _StubRelayHandler)
        self._server.recorder = self
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()

    def reset(self) -> None:
        self.received.clear()
        self.next_status = 202


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_ready(port: int, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    last_err = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/health", timeout=0.5
            ) as r:
                if r.status == 200:
                    return
        except (urllib.error.URLError, ConnectionError) as e:
            last_err = e
            time.sleep(0.05)
    raise RuntimeError(f"companion did not become ready on :{port} — {last_err}")


def _spawn_companion(
    port: int,
    db_path: str,
    *,
    relay_url: str | None,
    relay_token: str | None = RELAY_TOKEN,
    routing_token: str | None = ROUTING_TOKEN,
) -> subprocess.Popen:
    env = os.environ.copy()
    env["PYTHONPATH"] = REPO_ROOT + os.pathsep + os.path.join(REPO_ROOT, "emitter")
    env["CROWLY_PAIRING_TOKEN"] = COMPANION_TOKEN
    env["CROWLY_DB_PATH"] = db_path
    env["CROWLY_HOST"] = "127.0.0.1"
    env["CROWLY_PORT"] = str(port)
    env["CROWLY_PUBLIC_URL"] = f"http://127.0.0.1:{port}"
    # Push: set or unset depending on the test.
    if relay_url is not None:
        env["CROWLY_RELAY_URL"] = relay_url
    else:
        env.pop("CROWLY_RELAY_URL", None)
    if relay_token is not None:
        env["CROWLY_RELAY_TOKEN"] = relay_token
    else:
        env.pop("CROWLY_RELAY_TOKEN", None)
    if routing_token is not None:
        env["CROWLY_ROUTING_TOKEN"] = routing_token
    else:
        env.pop("CROWLY_ROUTING_TOKEN", None)
    # Tight timeout so the "dead relay" test doesn't blow our wall budget.
    env["CROWLY_RELAY_TIMEOUT"] = "0.5"
    return subprocess.Popen(
        [sys.executable, "-m", "companion"],
        cwd=REPO_ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )


def _post_ingest(url: str, digest: dict, *, expect: int) -> tuple[int, dict | str]:
    data = json.dumps(digest).encode("utf-8")
    req = urllib.request.Request(
        url + "/ingest",
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {COMPANION_TOKEN}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=5.0) as r:
            status = r.status
            raw = r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        status = e.code
        raw = e.read().decode("utf-8", "replace")
    try:
        parsed: dict | str = json.loads(raw)
    except json.JSONDecodeError:
        parsed = raw
    if status != expect:
        raise AssertionError(
            f"POST /ingest -> {status} (expected {expect}); body={parsed!r}"
        )
    return status, parsed


def _digest(urgency: str, *, suffix: str = "") -> dict:
    """Build a schema-valid digest at the given urgency, with a unique id."""
    return {
        "schema_version": 1,
        "id": f"dgst_2026-06-30_gate-test_{urgency}{('-' + suffix) if suffix else ''}",
        "job_id": "gate-test-job",
        "source": "test",
        "title": f"Secret title for {urgency}",
        "created_at": "2026-06-30T12:00:00+00:00",
        "urgency": urgency,
        "bottom_line": f"Secret bottom line for {urgency}.",
        "summary": "Secret summary that should never reach the relay.",
        "sources": [{"title": "Secret source", "url": "https://example.invalid/secret"}],
    }


def _check(label: str, condition: bool, detail: str = "") -> None:
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f"  ({detail})" if detail else ""))
    if not condition:
        raise AssertionError(f"{label} failed: {detail}")


def _drain(proc: subprocess.Popen) -> str:
    """Terminate and read stdout from a companion subprocess."""
    if proc.poll() is None:
        proc.terminate()
    try:
        out, _ = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate(timeout=5)
    return out


# ----------------------------------------------------------------------
# Test scenarios
# ----------------------------------------------------------------------

def scenario_gate_and_privacy() -> None:
    """Tests 1–4 + 7: gated firing, content-free pointer, bearer/routing
    correctness, re-POST does not refire."""
    print("\n[A] urgency gate + content-free pointer + re-POST idempotency")
    tmpdir = tempfile.mkdtemp(prefix="crowly-gate-")
    db_path = os.path.join(tmpdir, "crowly.db")
    relay_port = _free_port()
    companion_port = _free_port()
    relay = _StubRelay(relay_port)
    proc = _spawn_companion(
        companion_port, db_path,
        relay_url=relay.url,
        relay_token=RELAY_TOKEN,
        routing_token=ROUTING_TOKEN,
    )
    try:
        _wait_ready(companion_port)
        url = f"http://127.0.0.1:{companion_port}"

        # low — no push
        _post_ingest(url, _digest("low"), expect=201)
        # normal — no push
        _post_ingest(url, _digest("normal"), expect=201)
        _check("low + normal ingests: no pushes recorded",
               len(relay.received) == 0,
               detail=f"unexpected: {relay.received}")

        # high — push
        _post_ingest(url, _digest("high"), expect=201)
        # urgent — push
        _post_ingest(url, _digest("urgent"), expect=201)

        # Give the in-process stub a moment to receive (it's synchronous
        # from the companion's POV, but we have a thread boundary).
        time.sleep(0.2)
        _check("high + urgent ingests: 2 pushes recorded",
               len(relay.received) == 2,
               detail=f"got: {relay.received}")

        # ---- Bearer auth ------------------------------------------------
        for rec in relay.received:
            _check("/push call carries the configured bearer",
                   rec["auth"] == f"Bearer {RELAY_TOKEN}", detail=rec["auth"])

        # ---- Routing token ---------------------------------------------
        for rec in relay.received:
            _check("/push call carries the configured routing_token",
                   rec["body"].get("routing_token") == ROUTING_TOKEN,
                   detail=str(rec["body"]))

        # ---- Content-free pointer --------------------------------------
        for rec in relay.received:
            body = rec["body"]
            pointer = body.get("pointer_text", "")
            _check(f"pointer_text is content-free: {pointer!r}",
                   pointer == "gate-test-job: new digest",
                   detail=pointer)
            # The acid test: nothing from the digest body can appear in
            # what the relay sees.
            blob = json.dumps(body)
            for forbidden in (
                "Secret title", "Secret bottom line",
                "Secret summary", "Secret source",
                "example.invalid",
            ):
                _check(
                    f"forbidden string {forbidden!r} not in /push body",
                    forbidden not in blob,
                    detail=blob,
                )

        # ---- Re-POST does not refire push -----------------------------
        # The push semantic is "new digest arrived". A re-POST that just
        # updates fields is not a new arrival; we should NOT push twice.
        relay.reset()
        # The 'high' digest from above is already stored. Re-POST it with
        # a new bottom_line — same id, edited content. This is the update
        # path (200, not 201) and MUST NOT fire a fresh push.
        update = _digest("high")
        update["bottom_line"] = "Updated bottom line"
        _post_ingest(url, update, expect=200)  # 200 = updated, not created
        time.sleep(0.2)
        _check("re-POST (update) did NOT refire push",
               len(relay.received) == 0,
               detail=f"got: {relay.received}")
    finally:
        out = _drain(proc)
        relay.stop()

        # ---- Operator-log shape ----
        # We can't be too strict about the lines (their order interleaves with
        # ingest + push), but we *must* see one push line per fired push and
        # the right "skipped-by-urgency" reason for the gated ones.
        _check("companion log shows 'push fired' line(s)",
               "push fired" in out, detail=out[:1200])
        _check("companion log shows 'push skipped-by-urgency' for low/normal",
               "push skipped-by-urgency" in out, detail=out[:1200])


def scenario_relay_down_does_not_fail_ingest() -> None:
    """Test 5: relay-down does NOT fail ingest. The digest must still be
    stored and listable."""
    print("\n[B] best-effort: relay down does not fail ingest")
    tmpdir = tempfile.mkdtemp(prefix="crowly-relay-down-")
    db_path = os.path.join(tmpdir, "crowly.db")
    companion_port = _free_port()
    # Point at a dead port (nothing listening). Connection-refused, fast.
    dead_relay = f"http://127.0.0.1:{_free_port()}"
    proc = _spawn_companion(
        companion_port, db_path,
        relay_url=dead_relay,
        relay_token=RELAY_TOKEN,
        routing_token=ROUTING_TOKEN,
    )
    try:
        _wait_ready(companion_port)
        url = f"http://127.0.0.1:{companion_port}"

        # An urgent digest must still 201 even though the relay is gone.
        d = _digest("urgent")
        _post_ingest(url, d, expect=201)

        # And it must be in /list.
        req = urllib.request.Request(
            url + "/list",
            headers={"Authorization": f"Bearer {COMPANION_TOKEN}"},
        )
        with urllib.request.urlopen(req, timeout=5.0) as r:
            payload = json.loads(r.read().decode("utf-8"))
        ids = [e["digest"]["id"] for e in payload["digests"]]
        _check("urgent digest is stored despite relay-down",
               d["id"] in ids, detail=str(ids))
    finally:
        out = _drain(proc)
        _check("companion logged 'push failed' (with no traceback)",
               "push failed" in out and "Traceback" not in out,
               detail=out[-1200:])


def scenario_unconfigured_noop() -> None:
    """Test 6: no relay env vars → silent no-op. Ingest works as before."""
    print("\n[C] unconfigured: silent no-op on push")
    tmpdir = tempfile.mkdtemp(prefix="crowly-unconfig-")
    db_path = os.path.join(tmpdir, "crowly.db")
    companion_port = _free_port()
    proc = _spawn_companion(
        companion_port, db_path,
        relay_url=None, relay_token=None, routing_token=None,
    )
    try:
        _wait_ready(companion_port)
        url = f"http://127.0.0.1:{companion_port}"
        # Even an urgent ingest just gets stored.
        d = _digest("urgent")
        _post_ingest(url, d, expect=201)
    finally:
        out = _drain(proc)
        _check("boot banner says push disabled",
               "push disabled (missing:" in out, detail=out[:1200])
        _check("ingest of urgent digest → 'push skipped-unconfigured'",
               "push skipped-unconfigured" in out, detail=out[-1200:])


def scenario_relay_5xx_does_not_fail_ingest() -> None:
    """Belt-and-braces: a relay that's reachable but returns a 5xx must
    not poison ingest either."""
    print("\n[D] relay 5xx: still doesn't fail ingest")
    tmpdir = tempfile.mkdtemp(prefix="crowly-relay-5xx-")
    db_path = os.path.join(tmpdir, "crowly.db")
    companion_port = _free_port()
    relay_port = _free_port()
    relay = _StubRelay(relay_port)
    relay.next_status = 503
    proc = _spawn_companion(
        companion_port, db_path,
        relay_url=relay.url,
        relay_token=RELAY_TOKEN,
        routing_token=ROUTING_TOKEN,
    )
    try:
        _wait_ready(companion_port)
        url = f"http://127.0.0.1:{companion_port}"
        d = _digest("high")
        _post_ingest(url, d, expect=201)
        time.sleep(0.2)
        _check("relay was called once", len(relay.received) == 1)
    finally:
        out = _drain(proc)
        relay.stop()
        _check("companion logged 'push failed: http 503'",
               "push failed: http 503" in out, detail=out[-1200:])


def main() -> int:
    print(">>> Crowly companion urgency-gate tests")
    try:
        scenario_gate_and_privacy()
        scenario_relay_down_does_not_fail_ingest()
        scenario_unconfigured_noop()
        scenario_relay_5xx_does_not_fail_ingest()
    except AssertionError as e:
        print(f"\nFAILED: {e}\n")
        return 1
    print("\nALL PASSED\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
