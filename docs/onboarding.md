# Onboarding (single-user runbook)

The step-by-step a single user follows to install Crowly and connect it to their Hermes agent — and the team's **debug checklist** when something goes sideways. Every step has a *Verify* line (what "done" looks like) and a *Common failures* line, and is tagged with its build status:

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
- **(Optional) A paid Apple Developer account** — only needed for push. Pull works without it; push won't (`docs/architecture.md` § Push).

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

## Step 2 — Stand up the companion 🔨

> **Today: only `emitter/companion_stub.py` exists** — an in-memory, no-TLS test stub used to exercise the wire contract on a dev box (`docs/emitter.md` § Quickstart). The production companion is the **#1 thing to build** for M1 (`docs/roadmap.md` § M1 step 1).

The shape, once built:

1. Generate a `PAIRING_TOKEN` (any 32+ char random string).
2. Write `/opt/data/.env` on the VPS:
   ```
   COMPANION_HOSTNAME=inbox.example.com
   PAIRING_TOKEN=<the random string>
   ```
   Secrets live here, plaintext-but-gitignored, **never in any vault or this repo** (`docs/architecture.md` § Security).
3. `docker compose up -d` — Caddy auto-issues the TLS cert on first request; the companion serves `/ingest`, `/list`, `/summary`.

*Verify:* `curl https://<hostname>/health` returns `ok` over valid HTTPS (no `-k`).

*Common failures:*
- **Cert didn't issue** — DNS not pointed at the VPS, or port 80 blocked (Let's Encrypt HTTP-01 challenge).
- **Companion exits at startup** — by design it **fails loud without valid TLS** (`docs/architecture.md` § Networking); it will not silently serve cleartext the app can't reach. Check Caddy logs for the ACME error.
- **`401` on every request** — `PAIRING_TOKEN` mismatch between `/opt/data/.env` and what the client is sending.

---

## Step 3 — Pair the phone 👤+🔨

The companion (on deploy) exposes a QR encoding `{companion_url, pairing_token}` (`docs/architecture.md` § Pairing). The app's `PairCompanionView` (`docs/ux.md` § First-run) scans it, hits the companion over HTTPS to validate, stores both in the **Keychain**, then hands the companion its **`routing_token`** (never the raw APNs device token).

> **Today: the app has no networking, no pairing flow, no Keychain wiring yet** — only the demo-mode reader (`docs/roadmap.md` § M1 step 3).

*Verify:* app leaves Demo Mode; pull-to-refresh shows an **empty real inbox** ("No digests yet. Send your first one from Hermes." per `docs/ux.md`); manual fallback "Enter URL and token instead" succeeds with the same values.

*Common failures:*
- **Clock skew** — pairing token rejected if the phone or VPS clock is far off. Sync NTP on the VPS.
- **Relay unreachable** — should degrade gracefully: pairing **must complete** even if the relay is down (push is best-effort, never critical-path; `docs/architecture.md` § Push). If pairing blocks on relay reachability, that's a bug.
- **`401`** — pairing token wasn't actually copied into the QR / typed correctly.
- **Cert untrusted** — the companion's cert chain is invalid; the iPhone won't connect. Re-check Step 2's verify.

---

## Step 4 — Wire the emitter into Hermes ✅ helper / 🔨 skill-install

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

*Verify:* helper exits `0`; the digest appears in the app's inbox on pull-to-refresh and in the widget's "latest" row (once Steps 2–3 exist).

*Common failures:*
- **Exit `2` (validation error)** — required field missing or `urgency` not in `low|normal|high|urgent`. The error names the field; fix the LLM prompt, not the helper.
- **Exit `3` (transport error)** — wrong URL, cert untrusted, or `401`. Same diagnosis as Step 2/3.
- **Hermes-skill install** — the `emitter/hermes-skill/` wrapper is built but the skill-registry install step into a real Hermes deployment is still 🔨 (recipe lives in `emitter/hermes-skill/`).

> **Today: helper is built and verified against `companion_stub.py`** (`docs/emitter.md` § Quickstart). It has **not** been exercised against a real companion, because no real companion exists yet — Step 2 unblocks that.

---

## Step 5 — Push (optional for the test) 🔨+👤

Push is **best-effort, never critical-path** (`docs/architecture.md` § Push). The two-week test (`docs/validation.md`) can run on pull + widget alone; push only makes high-urgency digests feel instant.

The shape, once built:

1. Emit a digest with `"urgency": "high"` (or `"urgent"`).
2. Companion sees the urgency tier crosses the gate, pings the relay with `{routing_token, "Harmony: new digest →"}` — **no digest content** (`docs/architecture.md` § Push).
3. Relay looks up `routing_token → device_token`, sends the APNs push.
4. Phone shows a thin pointer notification; the widget timeline reloads.

*Verify:* `urgency: high` digest produces a banner on the lock screen with the title only (no body); `urgency: normal` produces **no push** and waits to be pulled. The widget updates within ~15 min even with the relay offline (the timeline reload floor, `docs/architecture.md` § Push).

*Common failures:*
- **No paid Apple Developer account** — free provisioning can't enable push and expires weekly. Pull-only is a valid M1 configuration.
- **Push fires for `normal`/`low`** — gate bug; only `high`/`urgent` should cross.
- **Push carries digest body** — privacy bug; pointer must be content-free.

> **Today: relay doesn't exist** (`docs/roadmap.md` § M1 step 4). The relay is project-operated and the one piece that can't be self-hosted, because APNs is bound to the app's Apple Team + bundle id.

---

## Step 6 — Steady state ✅ (the reading experience itself)

This is what the two-week test measures (`docs/validation.md`):

- Hermes cron emits → companion stores → app/widget pulls → user reads in the app → archives.
- Opening a digest marks it read; archive (with undo) is the only triage move (no "handled," no snooze — `CLAUDE.md` § Invariants).
- The home-screen widget is the steady-state cue: latest digests + unread count, `Link`-deeplink rows, **read-only** (no `Button(intent:)`).

*Verify:* most days, the user opens the app **unprompted** after the seeding period; archive is the natural end-state, not a guilt pile (`docs/validation.md` § Success criteria).

*Common failures (test-level, not bug-level):* no unprompted opens in two weeks → **stop at M1**, do not build the public layer (`docs/validation.md` § Kill criteria).

---

## What's real today

| Step | Status | Blocking work |
|---|---|---|
| 0. Prerequisites | 👤 | — |
| 1. Install the app | ✅ mechanism / 🔨 distribution | TestFlight + App Store (M2) |
| 2. Stand up the companion | 🔨 | **#1 M1 build:** validating ingest + store + serve + Caddy bundle |
| 3. Pair the phone | 🔨 | Companion (Step 2) + app networking/Keychain/QR (M1 step 3) |
| 4. Wire the emitter | ✅ helper, against the stub / 🔨 against a real companion / 🔨 skill-install | Step 2; Hermes-skill registry install |
| 5. Push | 🔨 + 👤 | Relay (M1 step 4) + Apple Developer account |
| 6. Steady state | ✅ as a *reading experience* on demo digests | All of the above for the real loop |

The gap at a glance: the reader (Steps 1, 6) and the input side (Step 4) work today against fixtures and a stub. The **companion + pairing + relay** (Steps 2, 3, 5) is the real M1 build queue.
