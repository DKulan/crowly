# Crowly push relay

The relay is the **one piece of Crowly that users don't self-host**. APNs `.p8` auth keys are bound to the iOS app's Apple Team + bundle id, so push is the one credential the project has to hold centrally (`docs/architecture.md` § Push).

What it is, in one line: a `routing_token → device_token` lookup table with a `/push` endpoint that forwards content-free pointers to APNs.

## Privacy invariants — these are load-bearing

1. **The store holds only `routing_token → device_token`.** No digests, no titles, no URLs, no pointer text. The SQLite schema literally has no column that could hold a body — see `relay/store.py` and the `test_relay.py` schema-introspection test that pins this.
2. **The relay does NOT log push metadata.** No `routing_token`, `device_token`, or `pointer_text` ever lands in stdout. Errors and rate-limit events may be logged, but they carry no per-push detail. This is the "fan out and forget" rule.
3. **Push is fire-and-forget.** `/push` always returns `202 accepted`; the companion is best-effort and never blocks on Apple. A relay outage degrades the product to pull, not to broken.

## Endpoints

| Method | Path           | Auth | Caller     | Purpose |
|--------|----------------|------|------------|---------|
| GET    | `/health`      | —    | anyone     | Liveness + `apns_mode` (`mock`/`sandbox`/`production`) + `registered_devices` count. |
| POST   | `/register`    | —    | iOS app    | `{device_token, routing_token?}` → `{routing_token}`. Idempotent on `device_token`. |
| POST   | `/unregister`  | —    | iOS app    | `{routing_token}` → 200/404. The "disconnect" privacy purge. |
| POST   | `/push`        | bearer (`RELAY_PUSH_TOKEN`) | companion | `{routing_token, pointer_text}` → 202. Rate-limited per `routing_token`. |

> **M1 auth note:** `/register` and `/unregister` are device-facing and have no explicit token — possession of a real APNs `device_token` is the credential. A hardening follow-up: bind `/unregister` to the original `routing_token` only (already), and consider adding a short-lived nonce flow to `/register` (M2).

## Local test

The relay is sandbox-free Python 3 + stdlib in mock mode:

```bash
python3 relay/test_relay.py
```

Runs both subprocess tests (real HTTP through a child `python3 -m relay`) and in-process tests (schema introspection, APNs unregistered-feedback path). Under the agent harness, loopback is sandboxed — use `dangerouslyDisableSandbox: true`.

## Deploy

```bash
cd relay/
cp .env.example .env       # set RELAY_PUSH_TOKEN, APNS_*
docker compose up -d
```

The image installs `httpx[http2]` (needed for real APNs); mock mode doesn't use it. The companion image deliberately does NOT pull this dep.

## Plugging in your real Apple credentials

The user has a paid Apple Developer account. To go from `APNS_ENV=mock` to real APNs delivery:

1. **Create an APNs Auth Key** in App Store Connect (Users & Access → Integrations → Keys → APNs). Download the `.p8` file. Note the 10-char **Key ID** Apple shows alongside it.
2. **Note your 10-char Team ID** (top-right of App Store Connect).
3. **Note your iOS app's bundle id** (e.g. `com.example.Crowly`) — this is `APNS_TOPIC`.
4. **Copy the `.p8` onto the relay host.** Put it in `./apns-keys/AuthKey_XXXXXXXXXX.p8` (the path the compose file mounts read-only into the container).
5. **Edit `relay/.env`:**
   ```env
   APNS_ENV=sandbox            # or `production` once you ship App Store
   APNS_TOPIC=com.example.Crowly
   APNS_KEY_ID=XXXXXXXXXX
   APNS_TEAM_ID=YYYYYYYYYY
   APNS_KEY_PATH=/etc/apns/AuthKey_XXXXXXXXXX.p8
   ```
6. **Restart the relay:** `docker compose up -d`. `GET /health` now reports `"apns_mode": "sandbox"` (or `production`).
7. **Test against a real device:**
   - Build the iOS app on a development-provisioned device (sandbox APNs) or TestFlight (production-ish).
   - The app calls `POST /register` on first launch with its device token; you should see `[relay] register: now 1 device(s) registered`.
   - Configure a companion with `CROWLY_RELAY_URL` and `CROWLY_RELAY_TOKEN` (the same `RELAY_PUSH_TOKEN`), plus `CROWLY_ROUTING_TOKEN` (the value the app handed it during pairing).
   - Emit a digest with `urgency: high`. The companion should log `[companion] push fired (urgency=high)` and the relay should log `[relay] push delivered`. The device should get a banner with the pointer text and no body.

**Sandbox vs production** maps to your build's APS environment entitlement (`development` vs `production`), which itself maps to how the device was provisioned. A TestFlight build connects to the *production* APNs environment despite being pre-release — set `APNS_ENV=production` for TestFlight.

## Sanity-check checklist for the first real device

- `GET /health` → `apns_mode: "sandbox"` (not `mock`).
- App's `register` lands → relay log shows `register: now N device(s) registered`.
- High-urgency emit → companion log shows `push fired`.
- Relay log shows `push delivered`.
- Device receives a banner showing **only the pointer title** (e.g. `"Harmony: new digest →"`), with no body text.
- Normal/low-urgency emit → companion log shows `skipped-by-urgency`. Relay log unchanged. Device gets nothing until next pull / widget refresh.

If a banner ever shows the digest's body or a URL, that's a privacy bug — the pointer payload is supposed to be content-free.
