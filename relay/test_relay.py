#!/usr/bin/env python3
"""End-to-end test for the Crowly push relay.

What this covers:

  1. /health 200 (no auth needed).
  2. /register mints a routing_token; re-register is idempotent on device_token.
  3. /push requires auth (401 without bearer).
  4. Happy path: /register → /push → MockAPNs received the push with the
     right device_token, the right pointer_text, the right topic.
  5. Unknown routing_token → /push returns 404.
  6. Rate limit per routing_token (configured low for the test).
  7. /unregister purges the row; subsequent /push returns 404.
  8. APNs "unregistered" feedback purges the row automatically.
  9. **The store schema literally cannot hold a digest title/URL** — we
     introspect the SQLite columns and assert there are no body/title/url
     fields. This is the load-bearing privacy invariant.
 10. The relay's stdout MUST NOT contain the routing_token, device_token,
     or pointer_text after a successful /push (fan-out and forget).
 11. Per-push semantics: /push returns 202, not 200, so the caller doesn't
     treat it as critical-path success.

Run (under the agent harness, loopback is sandboxed):
    python3 relay/test_relay.py
"""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUSH_TOKEN = "test-relay-push-token"
# Use a non-default APNS_TOPIC so we can assert it was passed through to the
# mock client without coincidentally matching the default.
TEST_TOPIC = "com.example.crowly.test"


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
    raise RuntimeError(f"relay did not become ready on :{port} — {last_err}")


def _spawn_relay(port: int, db_path: str, *, rate_limit: int = 30) -> subprocess.Popen:
    """Boot a real relay as a subprocess against MockAPNs (APNS_ENV=mock).

    PYTHONPATH includes the repo root so `import relay.*` resolves.
    """
    env = os.environ.copy()
    env["PYTHONPATH"] = REPO_ROOT
    env["RELAY_PUSH_TOKEN"] = PUSH_TOKEN
    env["RELAY_DB_PATH"] = db_path
    env["RELAY_HOST"] = "127.0.0.1"
    env["RELAY_PORT"] = str(port)
    env["RELAY_RATE_LIMIT_PER_MINUTE"] = str(rate_limit)
    env["APNS_ENV"] = "mock"
    env["APNS_TOPIC"] = TEST_TOPIC
    proc = subprocess.Popen(
        [sys.executable, "-m", "relay"],
        cwd=REPO_ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return proc


def _request(
    method: str,
    url: str,
    *,
    token: str | None = None,
    body: dict | str | None = None,
    expect: int | None = None,
) -> tuple[int, dict | str]:
    data = None
    headers = {}
    if body is not None:
        if isinstance(body, dict):
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        else:
            data = body.encode("utf-8")
            headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            status = resp.status
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        status = e.code
        raw = e.read().decode("utf-8", "replace")
    try:
        parsed: dict | str = json.loads(raw)
    except json.JSONDecodeError:
        parsed = raw
    if expect is not None and status != expect:
        raise AssertionError(
            f"{method} {url} -> {status} (expected {expect}); body={parsed!r}"
        )
    return status, parsed


def _check(label: str, condition: bool, detail: str = "") -> None:
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f"  ({detail})" if detail else ""))
    if not condition:
        raise AssertionError(f"{label} failed: {detail}")


def _run_subprocess_tests() -> int:
    """The subprocess-based tests (boot a real relay, hit it over HTTP)."""
    tmpdir = tempfile.mkdtemp(prefix="crowly-relay-e2e-")
    db_path = os.path.join(tmpdir, "relay.db")
    # Rate-limit set low so the test can exercise the 429 path quickly.
    rate_limit = 3
    port = _free_port()
    url = f"http://127.0.0.1:{port}"

    print(f"\n>>> Crowly relay end-to-end test")
    print(f"    db={db_path}  port={port}  rate_limit={rate_limit}/min\n")

    proc = _spawn_relay(port, db_path, rate_limit=rate_limit)
    try:
        _wait_ready(port)

        # ---- 1. /health -------------------------------------------------
        print("[1] /health")
        status, body = _request("GET", f"{url}/health", expect=200)
        _check("/health 200", body.get("status") == "ok", detail=str(body))
        _check("/health reports apns_mode=mock", body.get("apns_mode") == "mock")
        _check("/health reports 0 devices initially",
               body.get("registered_devices") == 0)

        # ---- 2. /register mints a routing_token -------------------------
        print("[2] /register")
        device_a = "device-token-aaa-" + "a" * 48  # mimic an APNs hex token length
        status, body = _request(
            "POST", f"{url}/register",
            body={"device_token": device_a}, expect=200,
        )
        rt_a = body.get("routing_token")
        _check("register returns a routing_token", isinstance(rt_a, str) and rt_a,
               detail=str(body))
        _check("routing_token has rt_ prefix", rt_a.startswith("rt_"),
               detail=rt_a)

        # Re-register the same device — same routing_token comes back.
        status, body = _request(
            "POST", f"{url}/register",
            body={"device_token": device_a}, expect=200,
        )
        _check("re-register is idempotent (same routing_token)",
               body.get("routing_token") == rt_a, detail=str(body))

        # Register a second device — different token.
        device_b = "device-token-bbb-" + "b" * 48
        status, body = _request(
            "POST", f"{url}/register",
            body={"device_token": device_b}, expect=200,
        )
        rt_b = body.get("routing_token")
        _check("second device gets distinct routing_token",
               rt_b != rt_a and rt_b.startswith("rt_"), detail=rt_b)

        status, body = _request("GET", f"{url}/health", expect=200)
        _check("/health now reports 2 devices",
               body.get("registered_devices") == 2)

        # /register validation
        _request("POST", f"{url}/register", body={}, expect=422)
        _check("register without device_token → 422", True)
        _request("POST", f"{url}/register", body={"device_token": ""}, expect=422)
        _check("register with empty device_token → 422", True)

        # ---- 3. /push auth gate ----------------------------------------
        print("[3] /push auth gate")
        _request(
            "POST", f"{url}/push",
            body={"routing_token": rt_a, "pointer_text": "Test: new digest →"},
            expect=401,
        )
        _check("/push without auth → 401", True)
        _request(
            "POST", f"{url}/push",
            token="wrong-token",
            body={"routing_token": rt_a, "pointer_text": "Test: new digest →"},
            expect=401,
        )
        _check("/push with wrong token → 401", True)

        # ---- 4. /push happy path → MockAPNs records it ------------------
        print("[4] /push happy path")
        pointer_a = "Harmony: new digest →"
        status, body = _request(
            "POST", f"{url}/push", token=PUSH_TOKEN,
            body={"routing_token": rt_a, "pointer_text": pointer_a},
            expect=202,
        )
        _check("/push returns 202 (not 200) — fire-and-forget semantics",
               body.get("status") == "accepted", detail=str(body))

        # ---- 5. /push unknown routing_token → 404 -----------------------
        print("[5] /push unknown routing_token → 404")
        _request(
            "POST", f"{url}/push", token=PUSH_TOKEN,
            body={"routing_token": "rt_does-not-exist", "pointer_text": pointer_a},
            expect=404,
        )
        _check("/push unknown routing_token → 404", True)

        # ---- 6. Rate-limit ---------------------------------------------
        print(f"[6] Rate-limit ({rate_limit}/min per routing_token)")
        # We just did one push to rt_a above. Burn through the rest of the
        # budget, then the next push should 429.
        # (The window is 60s; the test wall time is < 60s, so this is tight.)
        for i in range(rate_limit - 1):
            status, body = _request(
                "POST", f"{url}/push", token=PUSH_TOKEN,
                body={"routing_token": rt_a, "pointer_text": f"burst {i}"},
                expect=202,
            )
        _request(
            "POST", f"{url}/push", token=PUSH_TOKEN,
            body={"routing_token": rt_a, "pointer_text": "over the line"},
            expect=429,
        )
        _check("rate-limit kicks in once the per-minute budget is exhausted", True)

        # A different routing_token is on its own budget; should still 202.
        status, body = _request(
            "POST", f"{url}/push", token=PUSH_TOKEN,
            body={"routing_token": rt_b, "pointer_text": "different rt"},
            expect=202,
        )
        _check("rate-limit is per-routing-token (rt_b not affected)",
               body.get("status") == "accepted", detail=str(body))

        # ---- 7. /unregister --------------------------------------------
        print("[7] /unregister")
        status, body = _request(
            "POST", f"{url}/unregister",
            body={"routing_token": rt_b}, expect=200,
        )
        _check("/unregister 200 for known token", body.get("status") == "purged",
               detail=str(body))

        # Subsequent /push to rt_b is now 404.
        _request(
            "POST", f"{url}/push", token=PUSH_TOKEN,
            body={"routing_token": rt_b, "pointer_text": "should 404"},
            expect=404,
        )
        _check("/push after unregister → 404", True)

        # Unregister an unknown token → 404.
        _request(
            "POST", f"{url}/unregister",
            body={"routing_token": "rt_nope"}, expect=404,
        )
        _check("/unregister unknown token → 404", True)

        # ---- 8. Privacy: relay logs do not contain tokens or pointer ----
        # Drain stdout via terminate. We do this here because we have
        # accumulated enough lifecycle to inspect.
        proc.terminate()
        try:
            stdout, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, _ = proc.communicate(timeout=5)
        proc = None

        print("[8] Privacy: stdout has no routing_token / device_token / pointer_text")
        # routing_tokens
        _check(
            "routing_token rt_a not in stdout",
            rt_a not in stdout,
            detail=f"leak in: {[l for l in stdout.splitlines() if rt_a in l]}",
        )
        _check("routing_token rt_b not in stdout", rt_b not in stdout)
        # device tokens
        _check("device_token A not in stdout", device_a not in stdout)
        _check("device_token B not in stdout", device_b not in stdout)
        # pointer text
        _check(f"pointer_text {pointer_a!r} not in stdout", pointer_a not in stdout)
        _check("pointer 'over the line' not in stdout", "over the line" not in stdout,
               detail="rate-limit log must not echo the pointer it dropped")

        # Sanity: the log lines we *do* expect ARE there. Pin them so we
        # notice if the log shape regresses into accidentally echoing data.
        _check("expected 'register' log line present",
               "register: now" in stdout, detail=stdout[:400])
        _check("expected 'push delivered' log line present",
               "push delivered" in stdout, detail=stdout[:800])
        _check("expected 'rate-limit hit' log line present",
               "rate-limit hit" in stdout, detail=stdout[:800])
        _check("expected 'unregister' log line present",
               "unregister:" in stdout)

        return 0
    except AssertionError as e:
        print(f"\nFAILED: {e}\n")
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                stdout, _ = proc.communicate(timeout=2)
                print("--- relay stdout ---")
                print(stdout)
                print("--- end ---")
            except subprocess.TimeoutExpired:
                proc.kill()
        return 1
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()


def _run_inprocess_tests() -> int:
    """Tests that need direct access to the store / MockAPNs object — schema
    introspection, the unregistered-feedback path, etc. These run in-process
    so we can `import` the relay's pieces directly and reach into them.
    """
    print("\n>>> In-process relay tests (schema, store, APNs feedback)\n")
    # Make `import relay.*` resolvable.
    if REPO_ROOT not in sys.path:
        sys.path.insert(0, REPO_ROOT)

    from relay.store import Store
    from relay.apns import MockAPNsClient, APNsResult

    tmpdir = tempfile.mkdtemp(prefix="crowly-relay-unit-")
    db_path = os.path.join(tmpdir, "relay.db")

    print("[9] Privacy: store schema literally cannot hold digest content")
    store = Store(db_path)
    cols = store.column_names()
    print(f"    routes columns: {cols}")
    _check("routes has exactly 3 columns",
           sorted(cols) == ["created_at", "device_token", "routing_token"],
           detail=str(cols))
    # The load-bearing privacy guard: assert none of these forbidden names
    # is present. If a future commit adds `pointer_text` or `body` here,
    # this test fails immediately.
    forbidden = {
        "title", "body", "url", "summary", "bottom_line",
        "pointer_text", "pointer", "payload", "content",
        "digest_id", "digest", "job_id",
    }
    leaked = sorted(set(cols) & forbidden)
    _check("no forbidden columns in routes table",
           leaked == [], detail=f"forbidden columns present: {leaked}")

    # Same check on the live SQLite file, in case PRAGMA disagreed.
    import sqlite3
    with sqlite3.connect(db_path) as conn:
        rows = conn.execute("PRAGMA table_info(routes)").fetchall()
    raw_cols = sorted(r[1] for r in rows)
    _check("PRAGMA agrees on column set",
           raw_cols == sorted(cols), detail=str(raw_cols))

    print("[10] Store: upsert/lookup/delete round-trip")
    rt = store.upsert("device-X")
    _check("upsert returns a routing_token", isinstance(rt, str) and rt.startswith("rt_"),
           detail=rt)
    _check("device_token_for resolves the mapping",
           store.device_token_for(rt) == "device-X")
    _check("device_token_for unknown returns None",
           store.device_token_for("rt_nope") is None)
    _check("delete_by_routing_token returns True", store.delete_by_routing_token(rt))
    _check("post-delete lookup returns None", store.device_token_for(rt) is None)
    _check("delete on unknown returns False", store.delete_by_routing_token(rt) is False)

    print("[11] APNs 'unregistered' feedback purges the row")
    # We can't drive the live HTTP handler with a stubbed APNs result without
    # injecting the mock at construction time, which is what server.run()
    # supports. Boot a relay in-process on a fresh port instead.
    from relay.server import Config, run, _FastServer, Handler
    from relay.store import Store as RelayStore
    from relay.apns import MockAPNsClient as Mock
    import threading

    port = _free_port()
    db_path2 = os.path.join(tmpdir, "relay2.db")
    cfg = Config(
        push_token=PUSH_TOKEN,
        db_path=db_path2,
        host="127.0.0.1",
        port=port,
        apns_topic=TEST_TOPIC,
        rate_limit_per_minute=30,
    )
    mock = Mock()
    store2 = RelayStore(db_path2)

    # Wire the server up the same way run() would, but on a thread so we
    # can poke at the mock directly from this thread after each request.
    from relay.server import RateLimiter
    server = _FastServer(("127.0.0.1", port), Handler)
    server.config = cfg
    server.store = store2
    server.apns = mock
    server.apns_mode = "mock"
    server.rate_limiter = RateLimiter(30)

    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    try:
        _wait_ready(port)
        base = f"http://127.0.0.1:{port}"

        # Register a device.
        _, body = _request(
            "POST", f"{base}/register",
            body={"device_token": "device-feedback-test"}, expect=200,
        )
        rt_fb = body["routing_token"]

        # Happy push.
        _request(
            "POST", f"{base}/push", token=PUSH_TOKEN,
            body={"routing_token": rt_fb, "pointer_text": "p1"},
            expect=202,
        )
        _check("MockAPNs recorded the happy push", len(mock.sent) == 1)
        _check("recorded push has the right device_token",
               mock.sent[0].device_token == "device-feedback-test")
        _check("recorded push has the right pointer_text",
               mock.sent[0].pointer_text == "p1")
        _check("recorded push has the right topic",
               mock.sent[0].topic == TEST_TOPIC)

        # Now arrange for the next send to come back as 'unregistered'.
        mock.fail_next_with(APNsResult(ok=False, unregistered=True, reason="unregistered"))
        _request(
            "POST", f"{base}/push", token=PUSH_TOKEN,
            body={"routing_token": rt_fb, "pointer_text": "p2"},
            expect=202,  # still 202 — relay swallows the failure
        )
        # The row should now be gone.
        _check("APNs 'unregistered' feedback purged the row",
               store2.device_token_for(rt_fb) is None)

        # And subsequent /push is now 404.
        _request(
            "POST", f"{base}/push", token=PUSH_TOKEN,
            body={"routing_token": rt_fb, "pointer_text": "p3"},
            expect=404,
        )
        _check("post-feedback-purge /push → 404", True)

        # ---- 12. Bad bodies on /push -------------------------------------
        print("[12] /push validation")
        _request("POST", f"{base}/push", token=PUSH_TOKEN,
                 body={}, expect=422)
        _check("/push missing fields → 422", True)
        _request("POST", f"{base}/push", token=PUSH_TOKEN,
                 body={"routing_token": "rt_x"}, expect=422)
        _check("/push missing pointer_text → 422", True)
        _request("POST", f"{base}/push", token=PUSH_TOKEN,
                 body={"routing_token": "rt_x", "pointer_text": "x" * 300},
                 expect=422)
        _check("/push pointer_text > 200 chars → 422", True)

    finally:
        server.shutdown()
        server.server_close()

    return 0


def main() -> int:
    print(">>> Crowly relay tests")
    try:
        rc1 = _run_subprocess_tests()
        if rc1 != 0:
            return rc1
        rc2 = _run_inprocess_tests()
        if rc2 != 0:
            return rc2
    except AssertionError as e:
        print(f"\nFAILED: {e}\n")
        return 1
    print("\nALL PASSED\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
