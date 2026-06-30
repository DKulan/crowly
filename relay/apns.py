"""APNs client abstraction for the Crowly push relay.

Two implementations, one interface:

  * `MockAPNsClient` — records pushes in memory. Used by tests and by the
    relay's `dev` mode (no real Apple credentials configured). This is how
    we prove the chain end-to-end headlessly: the test boots a relay with
    a MockAPNsClient, drives `/push`, and asserts the mock saw the push.

  * `HTTP2APNsClient` — talks to APNs over HTTP/2 with a JWT signed by the
    `.p8` key. NOT exercised in CI (no Apple creds in CI); the user runs it
    against their own paid Apple Developer account using the env vars in
    relay/.env.example. **Python stdlib has no HTTP/2 client**, so this one
    optionally imports `httpx[http2]`. We isolate that import inside the
    class — the relay's core (Mock client, store, server) stays
    dependency-free. The companion never imports anything from this module
    at all; the companion only calls the relay over HTTP.

Privacy invariant: APNs clients MUST NOT log routing_tokens, device_tokens,
or pointer_text. Errors may be logged with the HTTP status / reason only.
"""

from __future__ import annotations

import dataclasses
import os
import threading
import time
from typing import Optional, Protocol


@dataclasses.dataclass
class APNsResult:
    """Result of a push attempt. Deliberately spare.

    `ok` — APNs accepted the push (HTTP 200).
    `unregistered` — APNs reported the device token is no longer valid
                     (HTTP 410). The relay reacts by deleting the row.
    `reason` — short string, set on failure only. Safe to log; contains no
               routing_token, device_token, or pointer_text.
    """
    ok: bool
    unregistered: bool = False
    reason: Optional[str] = None


class APNsClient(Protocol):
    """The interface the relay's /push handler talks to."""

    def send(
        self,
        device_token: str,
        pointer_text: str,
        *,
        topic: str,
    ) -> APNsResult:
        ...


# -------------------------------------------------------------------------
# MockAPNsClient — tests + dev mode
# -------------------------------------------------------------------------

@dataclasses.dataclass
class RecordedPush:
    device_token: str
    pointer_text: str
    topic: str
    at: float  # monotonic timestamp; only used by tests for ordering


class MockAPNsClient:
    """An in-memory recorder. Tests reach in to assert what was sent.

    Even though this is for tests, it intentionally mimics the privacy
    posture of the real client — the relay handler that calls `.send()`
    has no way to tell which kind of client it has, so the handler can't
    accidentally develop a "log only with Mock" habit.
    """

    def __init__(self) -> None:
        self.sent: list[RecordedPush] = []
        # The mock can be told to fail (e.g. to test the /push error path or
        # the "best-effort, never critical-path" contract on the companion
        # side via a stub relay).
        self._fail_next_with: Optional[APNsResult] = None
        self._lock = threading.Lock()

    def send(
        self,
        device_token: str,
        pointer_text: str,
        *,
        topic: str,
    ) -> APNsResult:
        with self._lock:
            if self._fail_next_with is not None:
                result = self._fail_next_with
                self._fail_next_with = None
                return result
            self.sent.append(
                RecordedPush(
                    device_token=device_token,
                    pointer_text=pointer_text,
                    topic=topic,
                    at=time.monotonic(),
                )
            )
            return APNsResult(ok=True)

    def fail_next_with(self, result: APNsResult) -> None:
        """Test affordance: the *next* .send() returns this result instead of
        succeeding. Used to drive the unregistered-feedback purge path."""
        with self._lock:
            self._fail_next_with = result

    def reset(self) -> None:
        with self._lock:
            self.sent.clear()
            self._fail_next_with = None


# -------------------------------------------------------------------------
# HTTP2APNsClient — real, optional dependency
# -------------------------------------------------------------------------

class HTTP2APNsClient:
    """Real APNs client. Optional dep: `httpx[http2]`.

    Apple's APNs HTTP/2 protocol:
      * POST to `https://api.sandbox.push.apple.com/3/device/<token>`
        (sandbox) or `https://api.push.apple.com/3/device/<token>` (prod).
      * Authorization: `bearer <jwt>` where the JWT is signed with the `.p8`
        ECDSA private key (alg ES256), kid=<APNS_KEY_ID>, iss=<APNS_TEAM_ID>.
      * `apns-topic: <bundle_id>` header.
      * `apns-push-type: alert`.
      * Body: `{"aps":{"alert":{"title":"<pointer_text>"}}}` — title only,
        NO body, because the pointer is content-free
        (docs/architecture.md § Push).

    Why not stdlib: `http.client` and `urllib` are HTTP/1.1 only. APNs
    requires HTTP/2. We isolate `httpx` here; the relay core never imports
    it. If `httpx` isn't installed, this class still imports (so type hints
    in server.py resolve), but `.send()` raises a clear error at call time.

    Config — from env (RELAY_APNS_* prefix; passed through main()):

      APNS_KEY_PATH  — path to the `.p8` private key file from App Store Connect
      APNS_KEY_ID    — the 10-char Key ID Apple shows alongside the .p8
      APNS_TEAM_ID   — the 10-char Apple Team ID
      APNS_TOPIC     — the iOS app's bundle identifier (e.g. com.example.Crowly)
      APNS_ENV       — "sandbox" or "production" (default: sandbox)

    The JWT is cached and refreshed every ~50 minutes (Apple's limit is 60).
    """

    SANDBOX_HOST = "api.sandbox.push.apple.com"
    PROD_HOST = "api.push.apple.com"
    # Apple says regenerate at most every 20 minutes; tokens are valid up to
    # 60 minutes. We refresh at 50 to leave a comfortable margin.
    _JWT_REFRESH_SECONDS = 50 * 60

    def __init__(
        self,
        *,
        key_path: str,
        key_id: str,
        team_id: str,
        env: str = "sandbox",
    ):
        if env not in ("sandbox", "production"):
            raise ValueError(f"APNS_ENV must be 'sandbox' or 'production', got {env!r}")
        self.key_path = key_path
        self.key_id = key_id
        self.team_id = team_id
        self.env = env
        self._host = self.PROD_HOST if env == "production" else self.SANDBOX_HOST
        self._jwt: Optional[str] = None
        self._jwt_minted_at: float = 0.0
        self._lock = threading.Lock()
        # Don't import httpx at module-import time — it's an optional dep.
        # We import in send() and at __init__ as a fail-fast sanity check.
        try:
            import httpx  # noqa: F401
        except ImportError as e:
            raise RuntimeError(
                "HTTP2APNsClient requires `httpx[http2]`. Install with:\n"
                "    pip install 'httpx[http2]'\n"
                "Or run the relay with the MockAPNsClient (RELAY_APNS_ENV=mock)."
            ) from e

    def _load_key_bytes(self) -> bytes:
        with open(self.key_path, "rb") as f:
            return f.read()

    def _mint_jwt(self) -> str:
        """ES256-signed JWT for the APNs bearer header.

        We hand-roll this to keep the dependency surface small — `httpx` is
        already non-stdlib, but it's a *transport* dep we can't avoid. A JWT
        library on top would be redundant. The `cryptography` package
        provides the EC primitive; PyJWT would also work. We use
        `cryptography` because httpx[http2] already pulls a TLS stack that
        depends on it, so we get it transitively.
        """
        import base64
        import json
        try:
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import ec
            from cryptography.hazmat.primitives.asymmetric.utils import (
                decode_dss_signature,
            )
        except ImportError as e:  # pragma: no cover — optional dep guard
            raise RuntimeError(
                "HTTP2APNsClient requires `cryptography` (pulled in by "
                "`httpx[http2]`). Install with: pip install 'httpx[http2]'"
            ) from e

        now = int(time.time())
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        claims = {"iss": self.team_id, "iat": now}

        def b64url(b: bytes) -> str:
            return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")

        header_b64 = b64url(json.dumps(header, separators=(",", ":")).encode())
        claims_b64 = b64url(json.dumps(claims, separators=(",", ":")).encode())
        signing_input = f"{header_b64}.{claims_b64}".encode("ascii")

        key = serialization.load_pem_private_key(self._load_key_bytes(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey):
            raise RuntimeError(
                f"APNS_KEY_PATH={self.key_path} is not an EC private key; "
                "APNs requires an ES256 (.p8) key"
            )
        der_sig = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        # APNs wants raw r||s, not DER. Convert.
        r, s = decode_dss_signature(der_sig)
        raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        return f"{header_b64}.{claims_b64}.{b64url(raw_sig)}"

    def _bearer(self) -> str:
        with self._lock:
            if (
                self._jwt is None
                or (time.time() - self._jwt_minted_at) > self._JWT_REFRESH_SECONDS
            ):
                self._jwt = self._mint_jwt()
                self._jwt_minted_at = time.time()
            return self._jwt

    def send(
        self,
        device_token: str,
        pointer_text: str,
        *,
        topic: str,
    ) -> APNsResult:
        import httpx
        url = f"https://{self._host}/3/device/{device_token}"
        headers = {
            "authorization": f"bearer {self._bearer()}",
            "apns-topic": topic,
            "apns-push-type": "alert",
        }
        # Pointer-only payload — title ONLY, no body. Per architecture.md
        # § Push: "carries no digest content".
        payload = {"aps": {"alert": {"title": pointer_text}}}
        try:
            with httpx.Client(http2=True, timeout=10.0) as client:
                resp = client.post(url, headers=headers, json=payload)
        except httpx.HTTPError as e:
            # Don't include the device_token or pointer_text in the log line.
            return APNsResult(ok=False, reason=f"transport: {type(e).__name__}")

        if resp.status_code == 200:
            return APNsResult(ok=True)
        if resp.status_code == 410:
            # APNs "unregistered" feedback: this device token is dead.
            return APNsResult(ok=False, unregistered=True, reason="unregistered")
        # Other 4xx/5xx — bubble a short reason. APNs returns a JSON body
        # like {"reason":"BadDeviceToken"}; we surface only the `reason`.
        reason = f"http {resp.status_code}"
        try:
            j = resp.json()
            r = j.get("reason")
            if isinstance(r, str):
                reason = f"http {resp.status_code} {r}"
        except Exception:
            pass
        return APNsResult(ok=False, reason=reason)


# -------------------------------------------------------------------------
# Factory
# -------------------------------------------------------------------------

def from_env() -> tuple[APNsClient, str]:
    """Build the APNs client the relay should use, from env vars.

    Returns (client, mode) where mode is one of "mock" | "sandbox" | "production".

    Defaults to the MockAPNsClient unless `APNS_ENV` is set to `sandbox` or
    `production` AND the real-mode env vars are present. This is deliberate:
    a fresh `docker compose up` of the relay (with no .p8 wired in) should
    boot cleanly into mock mode so the chain is testable; the operator opts
    in to real APNs by setting the env vars.

    Required for real mode (sandbox or production):
      APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC
    The topic is returned to the server (it's per-app config, not per-push),
    so we read it here and stash it on the client wrapper below.
    """
    env = (os.environ.get("APNS_ENV") or "mock").lower()
    if env in ("mock", "", "dev"):
        return MockAPNsClient(), "mock"

    missing = [
        k for k in ("APNS_KEY_PATH", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC")
        if not os.environ.get(k)
    ]
    if missing:
        raise SystemExit(
            f"relay: APNS_ENV={env!r} but these env vars are missing: "
            f"{', '.join(missing)}. See relay/README.md."
        )
    client = HTTP2APNsClient(
        key_path=os.environ["APNS_KEY_PATH"],
        key_id=os.environ["APNS_KEY_ID"],
        team_id=os.environ["APNS_TEAM_ID"],
        env=env,
    )
    return client, env
