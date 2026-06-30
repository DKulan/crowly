# Architecture

## Shape: two artifacts you run, one you ship

```
   USER'S VPS                                       ┌────────────────────┐
 ┌────────────────────────────────────┐             │   iOS app          │
 │  Hermes cron ─emitter kit─┐         │             │   + home-screen    │
 │                           ▼         │             │   widget           │
 │                 ┌─────────────────┐ │       HTTPS │                    │
 │                 │ Companion service│◀────────────▶│  list / detail /   │
 │                 │ • validate+store │ (TLS + token)│  archive /         │
 │                 │ • list / summary │              │  demo mode / QR    │
 │                 │                  │              │  pull-to-refresh / │
 │                 └─────────────────┘ │              │  widget timeline   │
 └────────────────────────────────────┘              └────────────────────┘
```

- The **app** talks **directly to the user's own companion** over HTTPS for all content. Pull-to-refresh in the app; the widget's `TimelineProvider` reloads on its own schedule.
- The **companion** stores everything on the user's own VPS — ingest, store, serve.
- No central service exists in the MVP. Content never leaves the user's infrastructure, by construction.

## Components

### 1. Emitter kit (input side)
- A helper script + a published **Hermes skill**. The cron's LLM writes the digest *content*; the helper **builds the envelope** (stable `id`, `created_at`, `schema_version`), validates required fields against `docs/schema.md`, and POSTs to the local companion.
- Ships with a copy-paste recipe so a new user's inbox is non-empty within minutes of pairing.

### 2. Companion service (per user, on their VPS)
The data-owning core. Self-hosted, typically a Docker bundle alongside Hermes.
- **Ingest:** receives digests, **validates and rejects malformed ones with a clear 4xx** (so the cron author sees what's wrong in their logs), stores idempotent on `digest.id`. A bad payload never crashes the store or reaches the app. **Unknown fields are preserved verbatim** in the stored blob (`docs/schema.md` § Versioning).
- **Serve:** `GET /list` (full cards, paginated) and `GET /summary` (cheap, latest few + unread count — for the widget).
- **Store:** flat JSON/SQLite. No heavy backend. State (read/archived) lives here too, mirrored from the app via simple state-change writes.
- Ships with **auto-HTTPS** (see Networking).

### 3. iOS app (App Store)
- Card list, detail view, archive flow (with undo), pull-to-refresh, search.
- **Home-screen widget** — latest digests + unread count; tap-through deeplinks open the app to that digest. No buttons. Refreshes on the widget's own `TimelineProvider` schedule, pulling `GET /summary`.
- **Demo mode** — bundled canned digests; first-run default and the only thing a non-self-hoster (incl. an App Reviewer) sees.
- **QR pairing**; companion URL + token in the **Keychain**.

## Networking & TLS

- A public iOS app must use **HTTPS with a publicly-trusted cert** (App Transport Security). Plain `http://<ip>` is blocked, and ATS exceptions draw review scrutiny — so the app ships **no ATS exceptions**.
- The companion therefore **requires valid TLS and fails loud at startup without it** — it will not silently serve cleartext the app can't reach.
- **Default:** bundled auto-HTTPS (Caddy + Let's Encrypt). User points a hostname at their VPS, sets one env var, `docker compose up`; certs auto-renew.
- **Escape hatch (no domain/DNS):** a tunnel (Cloudflare Tunnel / Tailscale Funnel) provides a public hostname with valid TLS; the companion stays private. Trade-off: a third party sits in front of the user's traffic.

## Pairing & trust

- Pairing is a **QR scan**: the companion (on deploy) exposes a QR encoding `{companion_url, pairing_token}`; the app scans it, validates by hitting the companion over HTTPS, and stores both in the **Keychain**. Manual URL+token entry is the fallback for the QR-averse.
- Result: the only credential in the loop is the pairing token, held by the user's companion and by their phone's Keychain. No third party participates in pairing.

## Refresh model

- **The app pulls.** Pull-to-refresh in the inbox; an `onAppear` refresh when the app foregrounds; a manual refresh from Settings. Everything in the app fetches `GET /list` (or `GET /summary` for the widget) over the user's companion HTTPS endpoint.
- **The widget refreshes itself.** Its `TimelineProvider` carries a **~15-minute reload floor** that re-fetches `GET /summary` independent of the app being open. This bounds widget staleness without any server-pushed wake-up: the widget is the marketing artifact, so this is a committed property, not an accident.
- There is no notification delivery in the MVP. New digests surface when the user next opens the app or the widget timeline next fires.

## Privacy & data

- **Content never leaves the user's VPS.** Digests and the user's read/archive state live on the companion the user owns. Erasure of the real data is the user's own.
- **No central service in the path.** Because the app pulls directly from the user's companion, no project-run service ever sees content, device identifiers, or even traffic metadata. This is the strongest possible privacy story — the *absence* of a middle-tier is the feature.
- The app ships a **privacy policy** ("your content stays on your server; the app talks only to the companion you configure") and honest **nutrition labels** (app-functionality, **not** tracking; no data collected by the developer).

## Security notes

- Companion secrets (the pairing token, any HTTPS cert material) live in `/opt/data/.env` on the user's VPS — plaintext-but-gitignored, never in any vault or this repo.
- The companion authenticates app requests by the pairing token; rate-limit on auth failures to deter token-guessing.

## Deliberately deferred

- Generic webhook / email / Zapier / n8n / Make / RSS ingest — only after personal pull is proven (see roadmap). Note: anyone can already POST a schema-valid digest from any tool today; "generic ingest" here means *first-party adapters and docs* for non-Hermes sources, not the wire format.
- Multi-tenant hosted backend — explicitly *not* this design; the companion model exists to avoid it.
- Full-text search on the server — M1 search is client-side over what's already loaded; server-side search is M2+ if the inbox grows past what one device wants to hold.
