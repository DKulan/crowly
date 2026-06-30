# Onboarding (single-user runbook)

The step-by-step a single user follows to install Crowly and connect it to their Hermes agent — and the team's **debug checklist** when something goes sideways. The MVP is **pull-only** (no push notifications, no central relay): the app pulls from the user's companion directly, and the widget refreshes on its own timeline. Every step has a *Verify* line (what "done" looks like) and a *Common failures* line, and is tagged with its build status:

- ✅ **works today** — exercised end-to-end against what currently exists in the repo.
- 🔨 **needs building** — design is settled (see linked doc), code isn't there yet.
- 👤 **irreducibly human** — a step automation can't take for the user.

This is the **manual single-user path** (M1). The agent-driven seamless install — a Hermes `setup-crowly` skill that provisions the companion for the user — is **M2 "stranger onboarding"** (`docs/roadmap.md` § M2 step 7), and per the **M1-gates-M2** rule we don't build it until the two-week test (`docs/validation.md`) passes.

> **Security rule for the future installer:** it must be a **pinned, reviewable Hermes skill**, never "tell the agent to fetch and run instructions from a live URL." Live-URL install is a supply-chain footgun — a compromised or spoofed page would run arbitrary commands on the user's VPS. Pin the skill, review the diff, then run it.

---

## Step 0 — Prerequisites 👤

Everything below assumes the user already has:

- **A VPS running Docker** where Hermes (or any cron that can POST JSON) already runs. The companion deploys alongside it.
- **One networking decision** — pick exactly one, because the iPhone refuses plain `http://` (App Transport Security; `docs/architecture.md` § Networking):
  - **(A) Hostname pointed at the VPS** — an A/AAAA record on a domain the user controls. Companion auto-issues TLS via Caddy + Let's Encrypt. Default.
  - **(B) Tunnel (Cloudflare Tunnel / Tailscale Funnel)** — a public hostname with valid TLS, no DNS or open ports required. Trade-off: a third party sits in front of the user's traffic.

*Verify:* `dig <hostname>` resolves to the VPS, **or** the tunnel's `https://` URL returns *anything* in a browser (even a 404 from "no service yet" is fine — what matters is that TLS terminates).

*Common failures:* DNS not propagated; ports 80/443 firewalled (Let's Encrypt's HTTP-01 challenge needs port 80 reachable); using a no-TLS tunnel (the app will refuse it).

---

## Step 1 — Install the app ✅ mechanism / 🔨 real distribution

M1 = own device via Xcode (or TestFlight once enrolled). The public App Store listing is M2 (`docs/roadmap.md` § M2 step 10).

```bash
xcodegen generate
xcodebuild -project Crowly.xcodeproj -scheme Crowly \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build build
```

Or use the `run-crowly` skill, which already wraps build + launch.

*Verify:* app opens to **Demo Mode** with three canned digests of varying urgency (`docs/ux.md` § First-run).

*Common failures:* `xcodegen` not installed (`brew install xcodegen`); wrong simulator name; iOS 26 SDK missing (deployment target is iOS 26).

---

## Step 2 — Stand up the companion ✅ built / 👤 deploy

> **Today: the production companion is built** — `companion/` is the real validating ingest + SQLite store + serve service, with `docker-compose.yml`, `Dockerfile`, and a `Caddyfile` for auto-HTTPS. End-to-end tested by `python3 companion/test_end_to_end.py` (all passed: ingest/list/summary wrapper shape, state mirroring, schema-version passthrough, restart persistence, error shapes). The deploy itself is operator-👤.

The shape:

1. Generate a `PAIRING_TOKEN` (any 32+ char random string).
2. Write `companion/.env` on the VPS (see `companion/.env.example`):
   ```
   COMPANION_HOSTNAME=inbox.example.com
   PAIRING_TOKEN=<the random string>
   ```
   Secrets live here, plaintext-but-gitignored, **never in any vault or this repo** (`docs/architecture.md` § Security).
3. `docker compose up -d` from `companion/`. Caddy auto-issues the TLS cert on first request; the companion serves `/ingest`, `/list`, `/summary`, `/state`, `/health`, `/pair`.

*Verify:* `curl https://<hostname>/health` returns `ok` over valid HTTPS (no `-k`).

*Common failures:*
- **Cert didn't issue** — DNS not pointed at the VPS, or port 80 blocked (Let's Encrypt HTTP-01 challenge).
- **Companion exits at startup** — by design it **fails loud without valid TLS** (`docs/architecture.md` § Networking); it will not silently serve cleartext the app can't reach. Check Caddy logs for the ACME error.
- **`401` on every request** — `PAIRING_TOKEN` mismatch between `companion/.env` and what the client is sending.

---

## Step 3 — Pair the phone ✅ manual / 🔨 QR

The companion exposes `GET /pair`, which returns `{companion_url, pairing_token}` (`docs/architecture.md` § Pairing). The verified M1 path is **manual URL+token entry**: the app's `PairCompanionView` ("Enter URL and token instead") writes both into a throwaway slot, calls `/health` and `/list` to prove the combo really is a Crowly companion with this token, and only then persists them to the **Keychain** and swaps `DigestStore` from demo to live (`App/Views/PairCompanionView.swift`, `App/Net/CompanionClient.swift`, `App/Net/KeychainStore.swift`).

> **Today: manual entry is wired end-to-end and validate-before-persist works.** QR scan is stubbed — the entry point in `PairCompanionView` is reserved (`showQRScanner`) but `AVFoundation` integration is M2 (`docs/roadmap.md` § M2).

*Verify:* app leaves Demo Mode after pairing; pull-to-refresh shows an **empty real inbox** ("No digests yet. Send your first one from Hermes." per `docs/ux.md`); the inline error path surfaces typed errors (unreachable / unauthorized / decode) without crashing back to demo.

*Common failures:*
- **Clock skew** — pairing token rejected if the phone or VPS clock is far off. Sync NTP on the VPS.
- **`401`** — pairing token wasn't actually typed correctly (no QR yet).
- **Cert untrusted** — the companion's cert chain is invalid; the iPhone won't connect. Re-check Step 2's verify.
- **Unreachable URL** — the app refuses `http://` (ATS); URL must be `https://` with valid TLS.

---

## Step 4 — Wire the emitter into Hermes ✅ helper + real companion / 🔨 Hermes-skill install

The emitter kit is in `emitter/` and the wire contract is in `docs/emitter.md`. The helper builds the envelope (`schema_version`, `id`, `created_at`), validates required fields, and POSTs to `{companion_url}/ingest` with `Authorization: Bearer <pairing_token>`.

Two env vars do all the routing:

```bash
export CROWLY_COMPANION_URL=https://inbox.example.com
export CROWLY_TOKEN=<the same PAIRING_TOKEN from Step 2>
```

A Hermes cron pipes its content JSON to the helper:

```bash
hermes-run morning-briefing | python3 /opt/crowly/crowly_emit.py
```

*Verify:* helper exits `0`; the digest appears in the app's inbox on pull-to-refresh and in the widget's "latest" row.

*Common failures:*
- **Exit `2` (validation error)** — required field missing or `urgency` not in `low|normal|high|urgent`. The error names the field; fix the LLM prompt, not the helper.
- **Exit `3` (transport error)** — wrong URL, cert untrusted, or `401`. Same diagnosis as Step 2/3.

> **Today: helper is verified against the real companion** — the end-to-end test in `companion/test_end_to_end.py` exercises ingest → list → summary → state through the same wire contract the helper writes. The only remaining gap is the **Hermes-skill registry install** itself: `emitter/hermes-skill/` contains a pinned-skill wrapper, but actually installing it into a live Hermes deployment is still manual/unverified (🔨). Per the security note above, that install must remain a pinned, reviewable skill — never a live-URL fetch.

---

## Step 5 — Steady state ✅ (the reading experience itself)

This is what the two-week test measures (`docs/validation.md`):

- Hermes cron emits → companion stores → app/widget pulls → user reads in the app → archives.
- Opening a digest marks it read; archive (with undo) is the only triage move (no "handled," no snooze — `CLAUDE.md` § Invariants).
- The home-screen widget is the steady-state cue: latest digests + unread count, `Link`-deeplink rows, **read-only** (no `Button(intent:)`). The widget refreshes itself on its `TimelineProvider` (~15-minute floor); the app refreshes on open or pull-to-refresh.

*Verify:* most days, the user opens the app **unprompted** after the seeding period; archive is the natural end-state, not a guilt pile (`docs/validation.md` § Success criteria).

*Common failures (test-level, not bug-level):* no unprompted opens in two weeks → **stop at M1**, do not build the public layer (`docs/validation.md` § Kill criteria).

---

## What's real today

| Step | Status | Remaining work |
|---|---|---|
| 0. Prerequisites | 👤 | — |
| 1. Install the app | ✅ mechanism / 🔨 distribution | TestFlight + App Store (M2) |
| 2. Stand up the companion | ✅ built / 👤 deploy | Operator `docker compose up` on their VPS; Caddy auto-issues TLS from their hostname |
| 3. Pair the phone | ✅ manual entry / 🔨 QR scan | QR scan (M2) |
| 4. Wire the emitter | ✅ helper against real companion / 🔨 Hermes-skill registry install | Pinned-skill install into a live Hermes deployment |
| 5. Steady state | ✅ as a *reading experience* on demo digests; live loop runs once Steps 2–4 are deployed | The two-week behavioral test itself (`docs/validation.md`) |

The gap at a glance: **the software is built.** What remains is operator deployment (Step 2 onto the user's VPS), the Hermes-skill registry install (Step 4), and the M1 behavioral gate itself — the two-week validation test (`docs/validation.md`).
