#!/usr/bin/env python3
"""End-to-end test for the Crowly companion.

What this covers (vs. emitter/test_crowly_emit.py, which is unit tests over
the helper's envelope/validation logic with no network):

  1. Boot the real companion on a free port + temp SQLite file.
  2. Hit /health, /pair (unauthed) — both return 200.
  3. Auth gates: an unauthenticated /list and /ingest both return 401.
  4. Run `python3 emitter/crowly_emit.py` against the companion end-to-end —
     the same flow emitter/README.md documents.
  5. `GET /list` and `GET /summary` see the digest with state='unread'.
  6. Re-POST the *same* digest — companion returns 200 (updated, not 201).
  7. Unknown-field passthrough: POST a digest carrying a `meta_v2` key the
     v1 contract doesn't know about, and confirm /list returns it verbatim.
     This is the hard invariant — if it ever regresses, the companion can't
     be fixed later without a data migration.
  8. POST /state flips state from 'unread' to 'read', /list reflects it.
  9. 400 on malformed JSON, 422 on a validation failure (clear field error).
 10. **Restart persistence**: stop the companion, start a new one against
     the same DB file, confirm the digest is still in /list. Persistence is
     the difference between the production companion and the test stub —
     this test is what proves we got it right.

Run:
    python3 companion/test_end_to_end.py
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMITTER = os.path.join(REPO_ROOT, "emitter", "crowly_emit.py")
SAMPLE_CONTENT = os.path.join(REPO_ROOT, "emitter", "sample_content.json")
TOKEN = "test-pairing-token-e2e"


def _free_port() -> int:
    """Ask the kernel for a free TCP port. Racy but fine for a test harness."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_ready(port: int, timeout: float = 5.0) -> None:
    """Poll /health until it responds 200, or fail the test loudly."""
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


def _spawn_companion(port: int, db_path: str) -> subprocess.Popen:
    """Boot a real companion as a subprocess. PYTHONPATH includes the repo
    root so `import companion.store` and `import crowly_emit` both resolve."""
    env = os.environ.copy()
    env["PYTHONPATH"] = REPO_ROOT + os.pathsep + os.path.join(REPO_ROOT, "emitter")
    env["CROWLY_PAIRING_TOKEN"] = TOKEN
    env["CROWLY_DB_PATH"] = db_path
    env["CROWLY_HOST"] = "127.0.0.1"
    env["CROWLY_PORT"] = str(port)
    env["CROWLY_PUBLIC_URL"] = f"http://127.0.0.1:{port}"
    proc = subprocess.Popen(
        [sys.executable, "-m", "companion"],
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
    token: str | None = TOKEN,
    body: dict | str | None = None,
    expect: int | None = None,
) -> tuple[int, dict | str]:
    """Tiny HTTP client. Returns (status, parsed-json-or-raw). If `expect` is
    set and the status doesn't match, raises with the body for fast debug."""
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


def main() -> int:
    tmpdir = tempfile.mkdtemp(prefix="crowly-e2e-")
    db_path = os.path.join(tmpdir, "crowly.db")
    port = _free_port()
    url = f"http://127.0.0.1:{port}"

    print(f"\n>>> Crowly companion end-to-end test")
    print(f"    db={db_path}  port={port}\n")

    proc = _spawn_companion(port, db_path)
    try:
        _wait_ready(port)

        # ---- 1. Unauthed liveness + pairing -----------------------------
        print("[1] Liveness + pairing payload")
        status, body = _request("GET", f"{url}/health", token=None, expect=200)
        _check("/health 200", body.get("status") == "ok", detail=str(body))

        status, body = _request("GET", f"{url}/pair", token=None, expect=200)
        _check(
            "/pair returns {companion_url, pairing_token}",
            body == {"companion_url": url, "pairing_token": TOKEN},
            detail=str(body),
        )

        # ---- 2. Auth gates ----------------------------------------------
        print("[2] Auth gates")
        _request("GET", f"{url}/list", token=None, expect=401)
        _request("POST", f"{url}/ingest", token=None, body={"x": 1}, expect=401)
        _request("GET", f"{url}/list", token="wrong-token", expect=401)
        _check("unauth GET /list and POST /ingest both 401", True)

        # ---- 3. End-to-end via the real emitter -------------------------
        print("[3] Emitter → companion end-to-end (emitter/crowly_emit.py)")
        env = os.environ.copy()
        env["CROWLY_COMPANION_URL"] = url
        env["CROWLY_TOKEN"] = TOKEN
        result = subprocess.run(
            [sys.executable, EMITTER, "--content-file", SAMPLE_CONTENT],
            env=env, capture_output=True, text=True,
        )
        _check(
            "emitter exit 0",
            result.returncode == 0,
            detail=f"stdout={result.stdout!r} stderr={result.stderr!r}",
        )
        resp = json.loads(result.stdout.strip().splitlines()[0])
        _check("emitter response is {status:stored,id:…}", resp.get("status") == "stored",
               detail=str(resp))
        digest_id = resp["id"]

        # ---- 4. /list + /summary (wrapper shape) -----------------------
        # Contract: each entry in `digests` is `{"digest": <verbatim>,
        # "state": "..."}` — state as a sibling so the digest object stays
        # pure (docs/schema.md is content-only; state is a UI concern).
        print("[4] /list + /summary  (wrapper shape: {digest, state})")
        status, body = _request("GET", f"{url}/list", expect=200)
        entries = body["digests"]
        _check("/list returns 1 entry", len(entries) == 1, detail=str(entries))
        entry = entries[0]
        _check("entry has wrapper keys {digest, state}",
               set(entry.keys()) == {"digest", "state"},
               detail=f"keys={sorted(entry.keys())}")
        _check("entry.digest.id matches emitter",
               entry["digest"]["id"] == digest_id)
        _check("entry.state defaults to 'unread'",
               entry["state"] == "unread", detail=entry["state"])
        _check(
            "digest payload survived round-trip (bottom_line preserved)",
            entry["digest"]["bottom_line"].startswith("Council met Thursday"),
        )
        # And: the inner digest dict must NOT carry any underscore-prefixed
        # key. The wrapper shape's job is to keep the digest pure; pin it.
        inner_underscore = [k for k in entry["digest"] if k.startswith("_")]
        _check("inner digest has zero underscore-prefixed keys",
               inner_underscore == [], detail=f"found: {inner_underscore}")

        status, body = _request("GET", f"{url}/summary", expect=200)
        _check("/summary unread_count==1", body["unread_count"] == 1, detail=str(body))
        _check("/summary latest has the digest", len(body["latest"]) == 1)
        _check("/summary latest entry uses the wrapper shape",
               set(body["latest"][0].keys()) == {"digest", "state"},
               detail=str(body["latest"][0].keys()))

        # ---- 5. Idempotent re-POST -------------------------------------
        print("[5] Re-POST same id → 200 (updated, not 201)")
        # Pull the digest out of the wrapper and POST the inner object —
        # exactly what the emitter would build, exactly what the app would
        # re-POST in a hypothetical "edit + resubmit" flow.
        digest_json = dict(entry["digest"])
        status, body = _request(
            "POST", f"{url}/ingest", body=digest_json, expect=200,
        )
        _check("re-POST returns status:updated", body.get("status") == "updated",
               detail=str(body))
        status, body = _request("GET", f"{url}/list", expect=200)
        _check("re-POST did not duplicate row", len(body["digests"]) == 1)

        # ---- 6. Unknown-field passthrough ------------------------------
        print("[6] Unknown-field passthrough (the load-bearing invariant)")
        v2_digest = dict(digest_json)
        v2_digest["id"] = "dgst_2026-06-30_passthrough-test_abcdef01"
        v2_digest["meta_v2"] = {"category": "community", "tags": ["test", "v2"]}
        v2_digest["future_scalar"] = 42
        status, body = _request("POST", f"{url}/ingest", body=v2_digest, expect=201)
        status, body = _request("GET", f"{url}/list", expect=200)
        passthrough_entry = next(
            e for e in body["digests"] if e["digest"]["id"] == v2_digest["id"]
        )
        _check(
            "unknown meta_v2 preserved verbatim",
            passthrough_entry["digest"].get("meta_v2") ==
                {"category": "community", "tags": ["test", "v2"]},
            detail=str(passthrough_entry["digest"].get("meta_v2")),
        )
        _check(
            "unknown future_scalar preserved verbatim",
            passthrough_entry["digest"].get("future_scalar") == 42,
            detail=str(passthrough_entry["digest"].get("future_scalar")),
        )

        # ---- 7. State writes -------------------------------------------
        print("[7] State writes (POST /state)")
        status, body = _request(
            "POST", f"{url}/state",
            body={"id": digest_id, "state": "read"},
            expect=200,
        )
        _check("state write returns 200", body.get("state") == "read")
        status, body = _request("GET", f"{url}/list", expect=200)
        target = next(e for e in body["digests"] if e["digest"]["id"] == digest_id)
        _check("state reflected in /list", target["state"] == "read")

        status, body = _request("GET", f"{url}/summary", expect=200)
        # With two digests stored and one marked read, unread_count should be 1.
        _check("/summary unread_count == 1 after one state flip",
               body["unread_count"] == 1, detail=str(body))

        # Invalid state -> 422
        _request("POST", f"{url}/state",
                 body={"id": digest_id, "state": "nope"}, expect=422)
        _check("invalid state → 422", True)

        # Missing id -> 422
        _request("POST", f"{url}/state",
                 body={"state": "read"}, expect=422)
        _check("missing id → 422", True)

        # Unknown id -> 404
        _request("POST", f"{url}/state",
                 body={"id": "no-such-id", "state": "read"}, expect=404)
        _check("unknown id → 404", True)

        # ---- 8. B1 regression: underscore-prefixed keys rejected --------
        # Under the new wrapper shape, /list returns `{digest, state}` so a
        # consumer never sees an underscore-prefixed key inside the digest
        # object. As a defense-in-depth guard, /ingest still rejects
        # underscore-prefixed keys with 422 — this protects against a buggy
        # client that hand-builds a payload with reserved keys. The pair
        # (structural separation + explicit rejection) is what makes the
        # invariant load-bearing.
        print("[8] B1: underscore-prefixed keys are rejected on ingest (422)")
        bad_underscore = dict(digest_json)
        bad_underscore["_state"] = "read"
        status, body = _request(
            "POST", f"{url}/ingest", body=bad_underscore, expect=422,
        )
        _check("ingest with `_state` key → 422",
               "_state" in str(body.get("error", "")),
               detail=str(body))

        # Multiple underscore keys at once → all named in the error
        bad_two = dict(digest_json)
        bad_two["_state"] = "read"
        bad_two["_companion_internal"] = {"x": 1}
        status, body = _request("POST", f"{url}/ingest", body=bad_two, expect=422)
        _check("error message names both reserved keys",
               "_state" in str(body) and "_companion_internal" in str(body),
               detail=str(body))

        # Belt-and-braces: peek at the SQLite blob directly. Even after
        # those rejected POSTs, the stored blob must remain underscore-free.
        # If the guard ever regresses to "strip instead of reject" without
        # the wrapper, this catches it the moment _state ends up in a blob.
        import sqlite3, json as _json
        with sqlite3.connect(db_path) as _conn:
            blobs = [
                _json.loads(r[0]) for r in _conn.execute(
                    "SELECT blob FROM digests"
                ).fetchall()
            ]
        underscore_keys_in_any_blob = sorted({
            k for blob in blobs for k in blob if k.startswith("_")
        })
        _check("no stored blob in SQLite contains an underscore-prefixed key",
               underscore_keys_in_any_blob == [],
               detail=f"found: {underscore_keys_in_any_blob}")

        # ---- 9. B2 regression: bad Content-Length is a 400 not 500 ------
        # http.server's `int(self.headers["Content-Length"])` used to raise
        # ValueError on a non-numeric header, surfacing as a 500 with a
        # traceback. _read_json_body now catches that and returns 400.
        print("[9] B2: malformed Content-Length is a 400, not a 500 traceback")
        # Build the raw HTTP request by hand (urllib won't let us set a
        # non-numeric Content-Length on a request that also has a body).
        import socket as _socket
        host = "127.0.0.1"
        host_port = int(url.rsplit(":", 1)[1])
        body_bytes = b'{"hello":"world"}'
        raw_req = (
            b"POST /ingest HTTP/1.1\r\n"
            b"Host: " + host.encode() + b":" + str(host_port).encode() + b"\r\n"
            b"Authorization: Bearer " + TOKEN.encode() + b"\r\n"
            b"Content-Type: application/json\r\n"
            b"Content-Length: not-a-number\r\n"
            b"Connection: close\r\n"
            b"\r\n"
            + body_bytes
        )
        with _socket.create_connection((host, host_port), timeout=3.0) as sock:
            sock.sendall(raw_req)
            chunks = []
            while True:
                buf = sock.recv(4096)
                if not buf:
                    break
                chunks.append(buf)
        response = b"".join(chunks).decode("utf-8", "replace")
        status_line = response.split("\r\n", 1)[0]
        _check("bad Content-Length → HTTP/1.1 400",
               "400" in status_line, detail=f"status line: {status_line!r}")
        _check("error body mentions 'Content-Length'",
               "Content-Length" in response, detail=response[:200])

        # ---- 10. S2 regression: date-only created_at rejected -----------
        # The iOS decoder's `CrowlyISO8601.parse` requires a time component;
        # the emitter helper's `_parse_iso` used to accept "2026-06-29"
        # (date-only), which would store something the app crashes on.
        # Server-side validate() reuses the same helper, so a 422 here pins
        # both client- and server-side behaviour.
        print("[10] S2: date-only created_at rejected on ingest (422)")
        date_only = {
            "schema_version": 1,
            "id": "dgst_date-only-test",
            "job_id": "date-only-test",
            "source": "test",
            "title": "Date-only",
            "created_at": "2026-06-29",  # NO time component
            "urgency": "low",
            "bottom_line": "Should be rejected.",
        }
        status, body = _request("POST", f"{url}/ingest", body=date_only, expect=422)
        _check("date-only created_at → 422",
               "created_at" in str(body.get("error", "")),
               detail=str(body))

        # Sanity: a properly-formed `created_at` still works.
        ok_payload = dict(date_only)
        ok_payload["id"] = "dgst_with-time-test"
        ok_payload["created_at"] = "2026-06-29T19:00:00+00:00"
        status, body = _request("POST", f"{url}/ingest", body=ok_payload, expect=201)
        _check("created_at with a time component is accepted",
               body.get("status") == "stored", detail=str(body))

        # ---- 11. Error shapes ------------------------------------------
        print("[11] Error shapes")
        # Malformed JSON
        _request("POST", f"{url}/ingest", body="not json {", expect=400)
        _check("malformed body → 400", True)

        # Schema-invalid (missing required field)
        bad = {
            "schema_version": 1, "id": "x",
            "created_at": "2026-06-29T00:00:00Z",
        }
        status, body = _request("POST", f"{url}/ingest", body=bad, expect=422)
        _check("schema-invalid → 422 with field detail",
               "invalid digest" in str(body.get("error", "")).lower(),
               detail=str(body))

        # ---- 12. Restart persistence -----------------------------------
        print("[12] Restart persistence — kill companion, boot a fresh one against the same DB")
        proc.terminate()
        proc.wait(timeout=5)
        proc = None

        # Boot a *new* server on a new port against the same DB file.
        new_port = _free_port()
        new_url = f"http://127.0.0.1:{new_port}"
        proc = _spawn_companion(new_port, db_path)
        _wait_ready(new_port)

        status, body = _request("GET", f"{new_url}/list", expect=200)
        ids = {e["digest"]["id"] for e in body["digests"]}
        _check("digest from before restart is still in /list",
               digest_id in ids, detail=f"ids={ids}")
        _check("v2 passthrough digest also survived",
               v2_digest["id"] in ids)

        # And state survived too
        target = next(
            e for e in body["digests"] if e["digest"]["id"] == digest_id
        )
        _check("state survived restart (still 'read')",
               target["state"] == "read", detail=str(target))

        # And unknown fields survived restart (the actual passthrough proof)
        passthrough_entry = next(
            e for e in body["digests"] if e["digest"]["id"] == v2_digest["id"]
        )
        _check("unknown meta_v2 survived restart",
               passthrough_entry["digest"].get("meta_v2") ==
                   {"category": "community", "tags": ["test", "v2"]})

        # And: the wrapper shape itself is what survived — every entry
        # in /list must still expose {digest, state}. A regression that
        # accidentally re-injects state into the digest dict on restart
        # (or on a code path that bypasses _row_to_payload) is caught here.
        misshaped = [
            e for e in body["digests"]
            if set(e.keys()) != {"digest", "state"}
        ]
        _check("every /list entry uses the wrapper shape after restart",
               misshaped == [], detail=f"misshaped entries: {misshaped}")

        print("\nALL PASSED\n")
        return 0

    except AssertionError as e:
        print(f"\nFAILED: {e}\n")
        return 1
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                stdout, _ = proc.communicate(timeout=2)
                print("\n--- companion stdout ---")
                print(stdout)
                print("--- end ---")
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
