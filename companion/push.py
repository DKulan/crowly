"""Urgency-gated push to the Crowly relay (companion side).

This is the *companion's* half of the push flow (docs/architecture.md § Push).
The companion is best-effort about push: on ingest, if a digest's urgency
crosses the gate AND a relay is configured, the companion POSTs a
content-free pointer to the relay. The relay does the APNs fan-out.

Invariants this module enforces, in order:

  1. **Gated on urgency ≥ high.** Only `high` and `urgent` cross. `normal`
     and `low` do not push — they wait to be pulled. This is the only
     surfacing decision in M1 (see architecture.md § Push: "Why urgency, not
     per-job toggle").
  2. **Content-free pointer.** The pointer text is a short title-only string
     like "`<job_id>: new digest`" — the relay enforces a hard length cap
     (200 chars) as a defense in depth, but the privacy invariant
     ("no digest content over the wire to the relay") lives here.
  3. **Best-effort, never critical-path.** A relay outage / timeout / 5xx
     MUST NOT fail the ingest. The digest is still stored, /list still
     serves it, and the user will see it on next pull or widget refresh.
     Failures here log one line and return.
  4. **Silent no-op when unconfigured.** If `CROWLY_RELAY_URL`,
     `CROWLY_RELAY_TOKEN`, or `CROWLY_ROUTING_TOKEN` is missing, the gate
     becomes a no-op. A single-user dev run without a relay still works.

Routing-token storage decision (asked in the build spec):

  For M1, the routing_token is **companion config** — a single env var
  (`CROWLY_ROUTING_TOKEN`) the operator pastes in after pairing. This is
  the minimum thing that satisfies the architecture spec ("the app hands the
  companion its routing_token during pairing"): until the M1 pairing flow
  exists on the iOS side (docs/onboarding.md Step 3 is 🔨), the operator
  acts as the integration layer — they take the routing_token the app
  shows after registering with the relay, paste it into `/opt/data/.env`,
  and restart the companion.

  The design space considered:
    * **Env var** (chosen): zero new APIs, plays with the companion's
      existing env-var-first config, and the operator's `.env` file is
      already where secrets live. One env var → one paired routing_token,
      which matches the M1 single-user single-device model exactly.
    * **Pairing endpoint** (deferred): `POST /pair` from the app, writing
      the routing_token into the companion's SQLite. Necessary once the
      iOS pairing flow exists, because the user is not going to manually
      paste a routing_token. **Open for the team-lead to confirm:** add
      now as a stub that writes to the same store, or wait for the iOS
      side. Leaning "wait" — there's nothing to call it from yet, and the
      env var is a clean migration target.
    * **Multi-device** (M2+): a single companion paired with multiple
      iPhones (user + spouse) needs multiple routing_tokens. Out of scope
      for M1 single-user; the env var becomes a list later, no protocol
      changes.

  This is the routing_token storage answer in `docs/architecture.md`
  § Pairing's "[app] hands the companion its routing_token" — for M1, the
  storage IS the env var. The path forward is a one-liner.
"""

from __future__ import annotations

import json
import os
import socket
import urllib.error
import urllib.request
from typing import Optional

# Urgency tiers that fire a push. Mirrors docs/schema.md `urgency` field and
# docs/architecture.md § Push: "Push fires only when a digest's `urgency`
# is `high` or `urgent`."
PUSH_URGENCIES = ("high", "urgent")


class PushConfig:
    """Companion-side push config. Frozen at startup.

    All three fields must be present to enable push. Missing any one → the
    gate becomes a silent no-op and the companion logs that exactly once at
    startup (so the operator can tell whether the gate is off because they
    meant it to be, or because they fat-fingered an env var).
    """

    def __init__(
        self,
        *,
        relay_url: str = "",
        relay_token: str = "",
        routing_token: str = "",
        timeout_seconds: float = 2.0,
    ):
        self.relay_url = relay_url.rstrip("/")
        self.relay_token = relay_token
        self.routing_token = routing_token
        # 2s is tight on purpose. Push is best-effort, so a slow relay must
        # not make the ingest path feel slow. Tune up only if the relay is
        # legitimately far away (cross-region) AND the operator accepts a
        # slower ingest p99.
        self.timeout_seconds = timeout_seconds

    @property
    def enabled(self) -> bool:
        return bool(self.relay_url and self.relay_token and self.routing_token)

    @classmethod
    def from_env(cls) -> "PushConfig":
        return cls(
            relay_url=os.environ.get("CROWLY_RELAY_URL", ""),
            relay_token=os.environ.get("CROWLY_RELAY_TOKEN", ""),
            routing_token=os.environ.get("CROWLY_ROUTING_TOKEN", ""),
            timeout_seconds=float(os.environ.get("CROWLY_RELAY_TIMEOUT", "2.0")),
        )

    def describe(self) -> str:
        """One-line, secret-free description for the boot banner."""
        if not self.enabled:
            missing = [
                name for name, val in (
                    ("CROWLY_RELAY_URL", self.relay_url),
                    ("CROWLY_RELAY_TOKEN", self.relay_token),
                    ("CROWLY_ROUTING_TOKEN", self.routing_token),
                ) if not val
            ]
            return f"push disabled (missing: {', '.join(missing)})"
        # Echo the URL (operationally useful, not a secret) but redact the
        # tokens (both are secrets).
        return f"push enabled → {self.relay_url}"


def should_push(urgency: Optional[str]) -> bool:
    """The gate. Centralised so tests can pin behaviour without booting the
    server. Anything not in `PUSH_URGENCIES` is "don't push", including
    None and garbage strings — defensively conservative."""
    return isinstance(urgency, str) and urgency in PUSH_URGENCIES


def pointer_for(digest: dict) -> str:
    """Build the content-free pointer text for a digest.

    Shape: `"<job_id>: new digest"`. Just enough for the lock-screen banner
    to say "Harmony: new digest" without revealing the title, bottom_line,
    or any URL. The job_id is a series identifier the user already knows
    (they configured the cron); it's not "content" in the privacy sense,
    and the relay length cap is 200 chars regardless.

    Falls back to a generic pointer if job_id is missing (a malformed
    digest would already 422 before we get here, but belt-and-braces).
    """
    job_id = digest.get("job_id")
    if isinstance(job_id, str) and job_id:
        return f"{job_id}: new digest"
    return "Crowly: new digest"


def fire_push(config: PushConfig, digest: dict) -> str:
    """Fire a push for this digest, if the gate + config allow.

    Returns a short status string for the caller's one-line log:
      "skipped-by-urgency" — gate said no
      "skipped-unconfigured" — relay env vars not all present
      "fired"             — relay returned 2xx
      "failed: <reason>"  — relay errored; ingest continues regardless

    NEVER raises. The ingest path catches nothing from this function; the
    "best-effort, never critical-path" rule lives here, not at the caller.
    """
    urgency = digest.get("urgency")
    if not should_push(urgency):
        return "skipped-by-urgency"
    if not config.enabled:
        return "skipped-unconfigured"

    body = json.dumps({
        "routing_token": config.routing_token,
        "pointer_text": pointer_for(digest),
    }).encode("utf-8")
    req = urllib.request.Request(
        config.relay_url + "/push",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {config.relay_token}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=config.timeout_seconds) as resp:
            status = resp.status
    except urllib.error.HTTPError as e:
        # 4xx/5xx — read the status, drop the body. The relay's bodies
        # don't carry secrets, but defensively we only surface the status
        # in the operator log.
        return f"failed: http {e.code}"
    except (urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
        # Connection refused, DNS, timeout. The relay is best-effort;
        # we report and move on.
        return f"failed: transport: {type(e).__name__}"

    if 200 <= status < 300:
        # 202 is the expected success code from /push (fire-and-forget).
        # We accept any 2xx to be tolerant of relay revisions.
        return "fired"
    return f"failed: http {status}"
