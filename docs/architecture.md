# Architecture

## Shape: three artifacts you run, one you ship

```
                                    ┌────────────────────────────┐
                                    │  Push relay (central)       │
                                    │  routing_token → device_tok │
                                    │  holds no content / creds   │
                                    └────────────▲───────┬────────┘
                       "ping rt_…"               │       │ APNs push
                                                 │       │ (thin pointer)
   USER'S VPS                                    │       ▼
 ┌────────────────────────────────────┐         │   ┌────────────────────┐
 │  Hermes cron ─emitter kit─┐         │         │   │   iOS app          │
 │                           ▼         │         │   │   + interactive    │
 │                 ┌─────────────────┐ │         └───│   widget           │
 │                 │ Companion service│         HTTPS │                    │
 │  todoist/notes ◀┤ • validate+store │◀─────────────▶│  list / detail /   │
 │  (user's own) ◀─┤ • list/summary/  │ (TLS + token) │  bound answers /   │
 │                 │   capabilities   │              │  demo mode / QR     │
 │                 │ • execute callbacks│            └─────────────────────┘
 │                 └─────────────────┘ │
 └────────────────────────────────────┘
```

- The **app** talks **directly to the user's own companion** over HTTPS for all content and callbacks.
- The **companion** holds and executes everything sensitive — on the user's own VPS.
- The **relay** exists only because APNs push is bound to the app's Apple credential and can't be self-hosted. It fans out a "you're needed" pointer and nothing else.

## Components

### 1. Emitter kit (input side)
- A helper script + a published **Hermes skill**. The cron's LLM writes the digest *content*; the helper **builds the envelope** (stable `id`, `created_at`, `schema_version`), validates required fields against `docs/schema.md`, and POSTs to the local companion.
- Ships with a copy-paste recipe so a new user's inbox is non-empty within minutes of pairing.
- Telegram delivery can stay live in parallel during early personal use, but is **not** the product's notification path (see Push).

### 2. Companion service (per user, on their VPS)
The data-owning core. Self-hosted, typically a Docker bundle alongside Hermes.
- **Ingest:** receives digests, **validates and rejects malformed ones with a clear 4xx** (so the cron author sees what's wrong in their logs), stores idempotent on `digest.id`. A bad payload never crashes the store or reaches the app.
- **Serve:** `GET /list` (full cards), `GET /summary` (cheap, binding-carrying — for the widget), `GET /capabilities` (version + supported routes/reply_kinds).
- **Execute callbacks:** resolves `route`/`on_answer` intents and performs the action itself — `task`/`note`/`state` never involve the agent. Only `followup` is handed back to Hermes.
- **Store:** flat JSON/SQLite. No heavy backend.
- Ships with **auto-HTTPS** (see Networking).

### 3. Push relay (central, operated by the project)
- Holds the APNs auth key (`.p8`) — bound to the app's Apple Team + bundle id, so it **cannot** be self-hosted by users.
- Stores only `routing_token → apns_device_token`. **No digests, no Todoist keys, no notes, no URLs.**
- On request from a companion (`rt_…` + thin pointer), looks up the device token and sends the APNs push. Rate-limited per `routing_token`.
- **Best-effort, never critical-path** (see Push). A relay outage degrades the product to pull, not to broken.

### 4. iOS app (App Store)
- Card list, detail, **bound answer buttons** that POST callbacks to the user's companion.
- **Interactive widget** — answer `yes_no`/`choice` from the home screen.
- **Demo mode** — bundled canned digests; first-run default and the only thing a non-self-hoster (incl. an App Reviewer) sees.
- **QR pairing**; companion URL + token in the **Keychain**.

## Routing & capabilities

Routes in the schema are **intents** (`task | note | followup | none`), resolved by the companion against what it's configured for:

| Intent | Resolution chain (first available wins) |
|---|---|
| `task` | Todoist (token configured) → companion-local markdown → in-inbox "saved", logged |
| `note` | Obsidian-git vault (configured) → companion-local markdown → in-inbox "saved", logged |
| `followup` | Hermes intake URL (wired) → in-inbox "needs Hermes" item |
| `none` | no-op |

- The companion declares its real capabilities via `GET /capabilities`; the **app renders only resolvable actions** (no Todoist → no "Add to Todoist" button).
- The **terminal sink is always the inbox itself** — an answer/action is recorded somewhere, never dropped.
- Daniel's setup (the `/opt/data/scripts/todoist_task.py` helper, an Obsidian-git vault, a Hermes coordination-bus intake) is **one configuration** of the companion, not the baseline. A stock install guarantees `task` + `note`-to-local + bound state; Obsidian and Hermes-followup are power-user upgrades.

## Networking & TLS

- A public iOS app must use **HTTPS with a publicly-trusted cert** (App Transport Security). Plain `http://<ip>` is blocked, and ATS exceptions draw review scrutiny — so the app ships **no ATS exceptions**.
- The companion therefore **requires valid TLS and fails loud at startup without it** — it will not silently serve cleartext the app can't reach.
- **Default:** bundled auto-HTTPS (Caddy + Let's Encrypt). User points a hostname at their VPS, sets one env var, `docker compose up`; certs auto-renew.
- **Escape hatch (no domain/DNS):** a tunnel (Cloudflare Tunnel / Tailscale Funnel) provides a public hostname with valid TLS; the companion stays private. Trade-off: a third party sits in front of the user's traffic.

## Pairing & trust

- On first launch the app gets its APNs **device token** and registers it **with the relay**, which mints an opaque **`routing_token`** and stores only `routing_token → device_token`.
- Pairing is a **QR scan**: the companion (on deploy) exposes a QR encoding `{companion_url, pairing_token}`; the app scans it, stores both in the **Keychain**, then hands the companion its **`routing_token`** (never the raw device token). Manual URL+token entry is the fallback for the QR-averse.
- Result: the relay holds no content/credentials; a companion can only push to devices that paired with it (it has their `routing_token`) and never learns the raw device token; and the relay can't be driven by anyone lacking a real device-minted `routing_token`.

## Push

- Delivered via **APNs**, sent by the relay. Requires a paid Apple Developer account (free provisioning can't enable push and expires weekly).
- **Thin pointer, gated on open loops.** A push fires only when a digest arrives with ≥1 unanswered question or unhandled action, and carries no answer-bearing content (`"Harmony: 1 question →"`). Pure-information digests **don't push** — they wait to be pulled (cued by the home-screen icon).
- `urgency` ranks *among* push-worthy items and drives widget surfacing; it does not by itself cause a push.
- The push also triggers a **widget timeline reload**, so the home screen updates exactly when something needs attention (widgets can't poll within iOS's background budget).
- **Best-effort, never critical-path.** The inbox is fully usable by pull + a modest periodic refresh. A missed push or relay outage degrades to "you'll see it next time you open the app / the widget refreshes" — never to a broken product. The UX never reports "answered" based on a push round-trip.
- **The widget's own degradation path is explicit, because the widget can't poll.** Push is what reloads the widget timeline promptly; with the relay down there's no ping, so the widget would silently go stale until the app is next opened. To bound that, the widget's `TimelineProvider` carries a **~15-minute reload floor** (refreshing from `GET /summary`) independent of push. Push makes the widget feel instant; the floor guarantees it's never more than ~15 min stale even with the relay fully offline. The widget is the marketing artifact, so this staleness window is a committed property, not an accident.

## Privacy & data

- **Content never leaves the user's VPS.** Digests, answers, Todoist key, and notes live on the companion the user owns. Erasure of the real data is the user's own — the strongest differentiator, not just a compliance line.
- The **relay is a declared data processor**: a device token is personal data. It stores only the token + routing, **does not log** push-pointer metadata (fan out and forget), and supports purge (auto on APNs "unregistered" feedback, plus an in-app "disconnect" that hits the relay).
- The app ships a **privacy policy** ("your content stays on your server; the relay stores a device token to deliver notifications") and honest **nutrition labels** (Device ID, linked, app-functionality — **not** tracking).

## Security notes

- Companion secrets (Todoist API key, Hermes-intake URL, pairing token) live in `/opt/data/.env` on the user's VPS — plaintext-but-gitignored, never in any vault or this repo.
- The relay holds the APNs `.p8`; rotate per Apple's lifecycle. It is the one credential that cannot be distributed to users.
- The companion validates `digest_id`/`job_id` against known digests before executing any callback.

## Deliberately deferred

- Generic webhook / email / Zapier / n8n / Make / RSS ingest — only after personal pull is proven (see roadmap).
- Multi-tenant hosted backend — explicitly *not* this design; the companion model exists to avoid it.
- A real `create_watch` route (agent editing its own cron) — collapsed into a `task` for v1; revisit behind a confirmation gate only if the manual version chafes.
- Two-way Obsidian checkbox sync — gated on the `todoist-obsidian-action-layer-v1` v2 work.
