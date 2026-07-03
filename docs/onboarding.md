# Onboarding (single-user runbook)

The step-by-step a single user follows to install Crowly and connect it to their Hermes agent — and the team's **debug checklist** when something goes sideways. The MVP is **pull-only** (no push notifications, no central relay): the app pulls from the user's companion directly, and the widget refreshes on its own timeline. Every step has a *Verify* line (what "done" looks like) and a *Common failures* line, and is tagged with its build status:

- ✅ **works today** — exercised end-to-end against what currently exists in the repo.
- 🔨 **needs building** — design is settled (see linked doc), code isn't there yet.
- 👤 **irreducibly human** — a step automation can't take for the user.

This is the **manual single-user path** (M1) — and the team's debug checklist. The agent-driven seamless install — a Hermes `setup-crowly` skill that provisions the companion for the user — is **now built** (`emitter/hermes-skill/setup-crowly/`, M2 "stranger onboarding", `docs/roadmap.md` § M2 step 7). Under the original **M1-gates-M2** rule this waited on the two-week test (`docs/validation.md`); the owner **waived that gate 2026-07-02**, so M2 (including `setup-crowly`) came into scope. **Keep both paths in this doc:** the seamless path below is the one most users take; the manual runbook stays as the fallback and the debug checklist when the automated install goes sideways.

> **The seamless path (3 steps, the blog flow):**
> 1. **Install the Crowly app** (App Store / TestFlight).
> 2. **Install the `setup-crowly` skill from the Hermes Skills Hub and ask Hermes to run it** — `hermes skills install DKulan/setup-crowly`. It fetches the companion source itself (a pinned clone — Step 0 below), detects the host, stands up the companion, gives it a Tailscale-Funnel HTTPS address, mints a pairing token + renders a pairing QR *locally on the host*, and installs the `emit-crowly-digest` skill + a starter cron so the inbox isn't empty on first open. (No need to pre-clone the monorepo — the skill pulls the companion source in Step 0.)
> 3. **Click one tunnel auth, then scan the QR** in the app.
>
> That's the realistic M2 ceiling — "install app → ask Hermes → click one auth → scan one QR." Both skills live on the **Hermes Skills Hub** and are security-scanned on install (`docs/publishing-skills.md` is the publish runbook); the `setup-crowly` skill playbook is `emitter/hermes-skill/setup-crowly/SKILL.md`, and the manual steps below are what it automates (and your fallback when a step needs a human eye). To inspect from source instead of the hub, clone the repo and copy `emitter/hermes-skill/setup-crowly/` onto the host — same skill, no hub scan.

> **Security rule for the installer:** it is a **pinned, reviewable Hermes skill** — installed from the Hermes Skills Hub (`hermes skills install`, which runs Hermes's security scan) or copied from a source checkout, never "tell the agent to fetch and run instructions from a live URL." Live-URL install is a supply-chain footgun — a compromised or spoofed page would run arbitrary commands on the user's host. The skill's Step 0 fetches the companion source via a **pinned clone** (`scripts/fetch_companion.py`, a specific release tag), which is still pinned-and-reviewable — a known commit, not a live-run of remote instructions. The `setup-crowly` provisioner honors this: it is **plan-first** (prints what it will do, only mutates under `--apply`) and never runs the human-in-the-loop steps.

---

## Where the companion can run

**The companion is dependency-free Python 3 + sqlite3** (`companion/server.py`, env-var configured via `Config.from_env`). It runs as a bare process — `python3 -m companion` — anywhere Python 3 runs. **Docker is a packaging convenience, not a requirement.** The Docker/Compose steps below are one concrete worked example (Daniel's VPS+Docker setup, the one in `docs/deployment-learnings.md`); they are not the only path. Users run heterogeneous setups, and the runbook (and the `setup-crowly` installer — `emitter/hermes-skill/setup-crowly/`, which detects the host shape and branches across all three) must span them:

| Topology | Run the companion as | TLS approach | Always-on? |
|---|---|---|---|
| **VPS + Docker** (Daniel's setup) | `docker compose up` (bundled Caddy, or `docker-compose.local.yml` behind a tunnel) | Funnel default; bundled Caddy or existing-proxy labels for power users | Yes — server stays up |
| **VPS, no Docker** | bare `python3 -m companion` (systemd unit / nohup); env vars set the token, DB path, port, public URL | Funnel default; systemd + Caddy (or existing proxy) as a power-user option | Yes — server stays up |
| **Personal computer** (laptop/desktop at home) | bare `python3 -m companion` (or Docker if installed) | **Funnel** — works behind NAT with no public IP / port-forward, one auth click | **⚠ Caveat below** |

- **Tailscale Funnel is the cross-topology unifier.** It gives a public `https://` hostname with valid TLS on *all three* — a VPS, a no-Docker VPS, and a laptop behind NAT — with no domain, DNS, ACME, or open ports. It's already the documented default TLS (`docs/architecture.md` § Networking); the reason to prefer it is precisely that it's the one path that spans setups. Existing-proxy (Traefik/nginx labels) and systemd + Caddy stay as power-user options where the host already terminates TLS.
- **Why HTTPS at all:** the app refuses plain `http://` for any non-loopback host (App Transport Security; `CompanionClient.normalize` prepends `https://` when the scheme is missing). Whatever the topology, the app-facing URL must be `https://` with a publicly-trusted cert.
- **⚠ Always-on caveat (personal-computer case).** Crowly is **pull-only** — the app and widget fetch from the companion; nothing pushes. **A companion on a laptop that sleeps can't be pulled**, so the app and widget show the *last snapshot* until the machine wakes. This is honest and unavoidable for a sometimes-off host: the pull model cannot engineer it away (push is deferred, `docs/roadmap.md` Phase 4 — do **not** reach for it as the fix). A VPS or an always-on desktop avoids it. Surface this to laptop users rather than silently handing them a companion that's unreachable half the day.

The steps below use the **Docker path** as the concrete worked example, because it's the one deployed and end-to-end tested. Where a step is Docker-specific, the bare-`python3 -m companion` equivalent is called out.

---

## Step 0 — Prerequisites 👤

Everything below assumes the user already has:

- **A host that can run Python 3 and stay reachable** — a VPS (with or without Docker) or a personal computer (see § *Where the companion can run* for the topology matrix and the laptop always-on caveat). Some cron or agent that can POST JSON (Hermes, a systemd timer, a plain shell script) runs there or alongside; the companion deploys next to it.
- **One networking decision** — pick exactly one, because the iPhone refuses plain `http://` for a non-loopback host (App Transport Security; `docs/architecture.md` § Networking):
  - **(A) Tunnel — Tailscale Funnel (default, spans all topologies)** — a public hostname with valid TLS, no domain / DNS / open ports; works on a VPS, a no-Docker VPS, and a laptop behind NAT. TLS terminates on the user's own node, so no third party sees content. This is the recommended default.
  - **(B) Hostname pointed at the host** — an A/AAAA record on a domain the user controls. Companion auto-issues TLS via Caddy + Let's Encrypt (bundled), or the host's existing reverse proxy terminates TLS. Power-user option; needs a domain + reachable ports 80/443.
  - **(C) Cloudflare Tunnel** — also gives a public HTTPS hostname, but TLS terminates at Cloudflare (it can see content in principle) — a weaker fit for the privacy thesis than Funnel.

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

On **first launch** the app now runs a 4-screen in-app onboarding carousel (M2 Phase 3b, 2026-07-02) that walks the user through the same shape this runbook covers — a self-hosted companion, the agent/emitter hookup, and pairing — before handing off to the pair sheet. "Skip"/"Look around first" drops straight into Demo Mode. (The carousel uses the real crow art extracted from the app icon; the whole flow sits on the fixed warm brand palette from the 2026-07-02 redesign — see `docs/ux.md` § Onboarding and `docs/design-system.md`.)

*Verify:* first launch shows the onboarding carousel; skipping (or on a subsequent launch) the app opens to **Demo Mode** with three canned digests of varying urgency (`docs/ux.md` § Onboarding).

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

**No-Docker equivalent** (VPS without Docker, or a personal computer): the companion is dependency-free Python 3 + sqlite3, so skip Compose entirely and run the bare process, env-var configured:

```bash
CROWLY_PAIRING_TOKEN=<the random string> \
CROWLY_DB_PATH=/opt/data/crowly.db \
CROWLY_PUBLIC_URL=https://<funnel-hostname> \
python3 -m companion    # from the repo root (needs companion/ + emitter/ on PYTHONPATH)
```

For an always-on host, wrap that in a **systemd unit** (or `nohup`) so it survives reboots. TLS still comes from the front (Funnel, or Caddy/existing proxy) — the bare process itself speaks HTTP on `127.0.0.1:8787`; it never terminates TLS. `docker compose` is just this same process, containerized with Caddy bundled in front.

*Verify:* `curl https://<hostname>/health` returns `ok` over valid HTTPS (no `-k`).

*Common failures:*
- **Cert didn't issue** — DNS not pointed at the VPS, or port 80 blocked (Let's Encrypt HTTP-01 challenge).
- **Companion exits at startup** — by design it **fails loud without valid TLS** (`docs/architecture.md` § Networking); it will not silently serve cleartext the app can't reach. Check Caddy logs for the ACME error.
- **`401` on every request** — `PAIRING_TOKEN` mismatch between `companion/.env` and what the client is sending.

---

## Step 3 — Pair the phone ✅ manual + QR

The companion exposes `GET /pair`, which returns `{companion_url, pairing_token}` (`docs/architecture.md` § Pairing). Two paths, both validate-before-persist: the app's `PairCompanionView` writes the URL+token into a throwaway slot, calls `/health` and `/list` to prove the combo really is a Crowly companion with this token, and only then persists them to the **Keychain** and swaps `DigestStore` from demo to live (`App/Views/PairCompanionView.swift`, `Shared/Net/CompanionClient.swift`, `Shared/Net/KeychainStore.swift` — the client + keychain moved to `Shared/` in Phase 1 so the widget shares the same pairing token).

- **QR scan** (M2 Phase 3b, 2026-07-02): "Scan QR" opens `QRPairScannerView` (VisionKit `DataScannerViewController`), reads the companion's `{companion_url, pairing_token}` QR, fills the fields, and auto-validates. On a device without a camera (Simulator / headless cloud device) it shows a "Camera unavailable → Enter manually" fallback.
- **Manual URL+token entry** — the always-works fallback, verified end-to-end from M1.

> **Today: both paths are wired end-to-end and validate-before-persist works.** QR scan shipped in M2 Phase 3b (was previously a reserved stub); manual entry remains the fallback and the only path where the camera is unavailable.

*Verify:* app leaves Demo Mode after pairing; the inbox auto-refreshes (on foreground; pull-to-refresh also forces it) to an **empty real inbox** ("No digests yet. Send your first one from Hermes." per `docs/ux.md`); the inline error path surfaces typed errors (unreachable / unauthorized / decode) without crashing back to demo.

*Common failures:*
- **Clock skew** — pairing token rejected if the phone or VPS clock is far off. Sync NTP on the VPS.
- **`401`** — pairing token wasn't actually typed correctly (no QR yet).
- **Cert untrusted** — the companion's cert chain is invalid; the iPhone won't connect. Re-check Step 2's verify.
- **Unreachable URL** — the app refuses `http://` (ATS); URL must be `https://` with valid TLS.

---

## Step 4 — Wire the emitter into Hermes ✅ helper + real companion + `setup-crowly` skill

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

*Verify:* helper exits `0`; the digest appears in the app's inbox on the next auto-refresh (within ~60s while foregrounded, or immediately via pull-to-refresh) and in the widget's "latest" row.

*Common failures:*
- **Exit `2` (validation error)** — required field missing or `urgency` not in `low|normal|high|urgent`. The error names the field; fix the LLM prompt, not the helper.
- **Exit `3` (transport error)** — wrong URL, cert untrusted, or `401`. Same diagnosis as Step 2/3.

> **Today: helper is verified against the real companion, and the `setup-crowly` skill automates this whole step.** The end-to-end test in `companion/test_end_to_end.py` exercises ingest → list → summary → state through the same wire contract the helper writes. Beyond that, the `setup-crowly` skill (`emitter/hermes-skill/setup-crowly/`) installs `emit-crowly-digest` from the Skills Hub (`hermes skills install DKulan/emit-crowly-digest`), sets the two env vars using the *internal* companion address, and offers a starter cron — so a stranger doesn't hand-wire this (`setup-crowly/SKILL.md` § Step 5). The `emit-crowly-digest` skill declares `CROWLY_COMPANION_URL`/`CROWLY_TOKEN` as `required_environment_variables`, so Hermes prompts for them and passes them into the sandbox on load. Per the security note above, both skills are pinned, reviewable, hub-scanned skills — never a live-URL fetch. What's still manual is content authorship (writing the cron's digest prompt).

---

## Step 5 — Steady state ✅ (the reading experience itself)

This is what the two-week test was designed to measure (`docs/validation.md`; the formal gate was **waived 2026-07-02**, but the steady-state loop below is the thing daily use exercises):

- Hermes cron emits → companion stores → app/widget pulls → user reads in the app → archives.
- Opening a digest marks it read; archive (with undo) is the only triage move (no "handled," no snooze — `CLAUDE.md` § Invariants).
- The home-screen widget is the steady-state cue: latest digests + unread count, `Link`-deeplink rows, **read-only** (no `Button(intent:)`). It is **live** once paired (Phase 1, 2026-07-02): the widget fetches `GET /summary` itself on its `TimelineProvider` (~15-minute floor) and shows the server's rows + authoritative unread count, with an App Group snapshot fallback when the fetch fails (offline / VPS asleep); before pairing it shows demo fixtures. The app auto-refreshes while open (foreground + ~60s interval poll), with pull-to-refresh as a manual override, and writes the App Group snapshot on refresh + read/archive so the widget's fallback stays current.

*Verify:* most days, the user opens the app **unprompted** after the seeding period; archive is the natural end-state, not a guilt pile (`docs/validation.md` § Success criteria).

*Common failures (test-level, not bug-level):* the designed kill signal was no unprompted opens in two weeks → **stop at M1**, do not build the public layer. That formal gate was **waived 2026-07-02** (M2 proceeds on daily use), so this is now the fallback trigger: if daily use lapses, run the kill criteria before widening the public layer (`docs/validation.md` § Kill criteria).

---

## What's real today

| Step | Status | Remaining work |
|---|---|---|
| 0. Prerequisites | 👤 | — |
| 1. Install the app | ✅ mechanism / 🔨 distribution | TestFlight + App Store (M2) |
| 2. Stand up the companion | ✅ built / 👤 deploy | Operator runs it on their host — `docker compose up` (VPS+Docker) *or* bare `python3 -m companion` (no-Docker VPS / personal computer); TLS from Funnel (default), bundled Caddy, or an existing proxy |
| 3. Pair the phone | ✅ manual entry + QR scan (QR shipped M2 Phase 3b) | — |
| 4. Wire the emitter | ✅ helper against real companion + `setup-crowly` skill built (`emitter/hermes-skill/setup-crowly/`), distributed via the Skills Hub (`hermes skills install DKulan/setup-crowly`, `docs/publishing-skills.md`) | Writing the cron's digest content (per-user) |
| 5. Steady state | ✅ app + **live widget** built (widget fetches `/summary` on its own timeline, App Group fallback — Phase 1, 2026-07-02); the live loop runs once Steps 2–4 are deployed | The two-week behavioral test — **waived 2026-07-02**; retained as fallback, not a remaining blocker (`docs/validation.md`) |

The gap at a glance: **the software is built** — including the live companion-backed widget (M1 Phase 1) and the `setup-crowly` installer that automates Steps 2–4 across all three topologies (`emitter/hermes-skill/setup-crowly/`). What remains is just running that install on the user's host (still needs the one auth click + QR scan). A **published companion image is not required** — the install ships as a repo checkout, which already provides the `companion/` + `emitter/` sibling layout the Docker build needs, and the two bare-process branches skip Docker entirely; it's deferred as an optional convenience, to revisit only if cloning the full repo proves to be real friction (`docs/roadmap.md` § M2 step 7). The M1 behavioral gate — the two-week validation test (`docs/validation.md`) — was **waived 2026-07-02** (owner decision; M2 proceeds on daily use), so it is no longer a remaining blocker; it stays on the shelf as the honest fallback if the reader stops earning its tap.
