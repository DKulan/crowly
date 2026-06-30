"""Crowly push relay — the one piece users don't self-host.

Why it exists: an APNs `.p8` auth key is bound to the iOS app's Apple Team +
bundle id, so a user can't self-host push the way they self-host their
companion. The relay is the thinnest possible bridge across that gap.

What it does — and pointedly, what it does NOT do (docs/architecture.md
§ Push, § Privacy & data, CLAUDE.md § Invariants):

  * Stores ONLY `routing_token → device_token`. **No digests, no titles, no
    URLs, ever.** The SQLite schema below has no column that could even hold
    a body — the privacy invariant is structural, not policy.
  * On a `/push` from a companion, looks up the device token and sends a
    content-free pointer push ("Harmony: new digest →") via APNs. **It does
    NOT log the routing_token, the device_token, or the pointer text** — fan
    out and forget. Errors and rate-limit events may be logged; per-push
    metadata may not.
  * `/push` is gated by a shared bearer token (`RELAY_PUSH_TOKEN`) the
    companion presents. `/register` and `/unregister` are app-facing; for M1
    device-token possession is the credential (a hardening follow-up is
    noted in the README).
  * Best-effort, never critical-path. A relay outage degrades the product to
    pull, not to broken — that contract is enforced on the *companion* side
    (the gate wraps the relay call in best-effort error handling); the relay
    itself just tries to deliver and 202s the caller.

Module map:
  store.py    — SQLite mapping `routing_token → device_token` (and nothing else).
  apns.py     — APNsClient interface + MockAPNsClient (tests) + HTTP2APNsClient
                (real; optional dependency, isolated).
  server.py   — HTTP handlers + main() entrypoint.
  __main__.py — `python3 -m relay` runs the service.
"""
