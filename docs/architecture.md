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
 │                 │                  │              │  auto-refresh /    │
 │                 └─────────────────┘ │              │  widget timeline   │
 └────────────────────────────────────┘              └────────────────────┘
```

- The **app** talks **directly to the user's own companion** over HTTPS for all content. The app auto-refreshes on foreground + interval poll (pull-to-refresh stays as a manual override); the widget's `TimelineProvider` reloads on its own schedule.
- The **companion** stores everything on the user's own VPS — ingest, store, serve.
- No central service exists in the MVP. Content never leaves the user's infrastructure, by construction.

## Components

### 1. Emitter kit (input side)
- A helper script + a published **Hermes skill**. The cron's LLM writes the digest *content*; the helper **builds the envelope** (stable `id`, `created_at`, `schema_version`), validates required fields against `docs/schema.md`, and POSTs to the local companion.
- Ships with a copy-paste recipe so a new user's inbox is non-empty within minutes of pairing.

### 2. Companion service (per user, on their VPS)
The data-owning core. Self-hosted, typically a Docker bundle alongside Hermes.
- **Ingest:** receives digests, **validates and rejects malformed ones with a clear 4xx** (so the cron author sees what's wrong in their logs), stores idempotent on `digest.id`. A bad payload never crashes the store or reaches the app. **Unknown fields are preserved verbatim** in the stored blob (`docs/schema.md` § Versioning).
- **Serve:** `GET /list` (full cards; pagination is *planned, not shipped* — M1 returns everything) and `GET /summary` (cheap, latest few + unread count — for the widget).
- **Store:** flat JSON/SQLite. No heavy backend. State (read/archived) lives here too, mirrored from the app via simple state-change writes.
- Ships with **auto-HTTPS** (see Networking).

### 3. iOS app (App Store)
- Card list, detail view, archive flow (with undo), pull-to-refresh, search.
- **Home-screen widget (live, shipped M1 Phase 1)** — latest digests + unread count; tap-through deeplinks open the app to that digest. No buttons. When **paired**, the widget's own `TimelineProvider` fetches `GET /summary` on a ~15-minute reload floor (independent of the app being open), rendering the server's rows + authoritative `unread_count`; on a failed fetch (offline / VPS asleep) it falls back to the last **App Group snapshot**. When **unpaired**, it shows demo fixtures with a `.never` reload. See § Widget data path for the cross-target credential/snapshot wiring.
- **Demo mode** — the **unpaired** path, not a separate build: bundled canned digests, the first-run default and the only thing a non-self-hoster (incl. an App Reviewer) sees. Both the app *and* the widget render fixtures until pairing.
- **Pairing** — manual companion URL + token entry today; QR scan is *planned, not shipped*. Either path stores companion URL + token in the **Keychain** (a fixed shared service, shared access group — see § Widget data path).

## Networking & TLS

- A public iOS app must use **HTTPS with a publicly-trusted cert** (App Transport Security). Plain `http://<ip>` is blocked, and ATS exceptions draw review scrutiny — so the app ships **no ATS exceptions**.
- The companion therefore **requires valid TLS and fails loud at startup without it** — it will not silently serve cleartext the app can't reach.
- **Default:** bundled auto-HTTPS (Caddy + Let's Encrypt). User points a hostname at their VPS, sets one env var, `docker compose up`; certs auto-renew.
- **Existing reverse proxy:** if the host already runs a proxy that owns :80/:443 (Traefik, nginx-proxy, etc. — common when other self-hosted services live on the box), the bundled Caddy would collide on those ports. Use `companion/docker-compose.traefik.yml` instead: it drops Caddy and exposes the companion to the existing proxy by label/host, so one proxy terminates TLS for everything. (Match the proxy's entrypoint/cert-resolver names to your existing services.)
- **Tunnel (no domain/DNS):** a tunnel (Tailscale Funnel / Cloudflare Tunnel) provides a public hostname with valid TLS and no open ports — the cleanest path when the user has no domain, and the mechanism a future agent-driven `setup-crowly` can automate (one auth step, no DNS/cert dance). Use `companion/docker-compose.local.yml`: it binds the companion to `127.0.0.1:8787` only and lets the tunnel front it; set `CROWLY_PUBLIC_URL` to the tunnel hostname. **Privacy note:** prefer **Tailscale Funnel** — TLS terminates on the user's own node, so the tunnel provider never sees digest plaintext ("content stays on your server" holds). Cloudflare Tunnel terminates TLS at Cloudflare, which can see content in principle — a weaker fit for the privacy thesis.

## Pairing & trust

- **Pairing endpoints are gated, default OFF.** `GET /` and `GET /pair` return `{companion_url, pairing_token}` — the credential itself, in the response body — so they must not be reachable in normal operation. They are gated behind the env flag **`CROWLY_PAIR_ENABLED`**, which defaults to false; when disabled both endpoints return **404**. Turn it on only for the brief initial-pairing window, pair the phone, turn it off, restart.
- **Why gated:** the companion is fronted by a public Tailscale Funnel hostname, and public HTTPS names are enumerated in **Certificate Transparency logs** — the Funnel URL is not a secret. An always-on unauthenticated pairing endpoint on a CT-discoverable hostname = a public token leak. The first-deploy leak that motivated this fix is captured in `docs/deployment-learnings.md`.
- **`/health` stays unauthenticated** as a liveness probe, but no longer includes the stored digest count when pairing is disabled (it was leaking activity metadata to anyone scanning the Funnel URL).
- **Pairing UX** — manual companion URL + token entry today; QR scan is *planned, not shipped*. Either way the app stores both in the phone **Keychain**; the only credential in the loop is the pairing token, held by the user's companion and by their phone's Keychain. No third party participates in pairing.
- **Token rotation** — because the Funnel URL is public, the pairing token must be rotatable, and any exposed token (e.g. one that lived behind an ungated pairing endpoint) is treated as compromised. The operator runbook is in `docs/deployment-learnings.md`.

## Refresh model

- **The app pulls, and pulls on its own.** While foregrounded the inbox auto-refreshes: an immediate pull whenever the app becomes active (launch or return from background), then a gentle interval poll (~60s) that a `scenePhase`-keyed task cancels on background and restarts on foreground. Pull-to-refresh remains as a manual override, but the user shouldn't need it. Everything in the app fetches `GET /list` (or `GET /summary` for the widget) over the user's companion HTTPS endpoint.
- **The widget refreshes itself.** When paired, its `TimelineProvider` carries a **~15-minute reload floor** that re-fetches `GET /summary` independent of the app being open (WidgetKit treats the floor as a request, not a guarantee — the OS may space reloads further apart under budget pressure). This bounds widget staleness without any server-pushed wake-up: the widget is the marketing artifact, so this is a committed property, not an accident. When unpaired the timeline is `.never` — there's no live data to chase.
- There is no notification delivery in the MVP. New digests surface when the user next opens the app or the widget timeline next fires.

## Widget data path (Phase 1 — shipped)

The widget extension is a separate process from the app, so making the widget live means giving it its own read path to the companion plus a fallback that survives an offline fetch.

- **The widget reads the companion directly.** The companion client and credential store (`Shared/Net/CompanionClient.swift`, `Shared/Net/KeychainStore.swift`) compile into **both** the app and the widget extension (`Shared/` is a shared source root). The widget builds its own `CompanionClient` and calls `GET /summary`; the server's `unread_count` is authoritative.
- **Shared Keychain (the pairing token).** Both targets store credentials in a keychain item under a **fixed shared service** (`SharedKeychain.service` = `com.crowly.shared`) — deliberately *not* the bundle id, since the app and widget have different bundle ids and a per-bundle service would give each target a different item. Item sharing is via the **default keychain access group**: both targets declare `keychain-access-groups: [$(AppIdentifierPrefix)com.crowly.shared]` in `project.yml`, and keychain services uses the *first* entry as the read/write group — so `KeychainStore` never passes an explicit `kSecAttrAccessGroup` (which would need the team-id prefix and trips `errSecMissingEntitlement` on the simulator). The widget reads the same token the app wrote, with no code coupling.
- **App Group snapshot (offline fallback / first-render seed).** App Group `group.com.crowly` (declared as `com.apple.security.application-groups` on both targets) backs a small `UserDefaults`-suite snapshot (`Shared/Widget/WidgetSnapshotStore.swift`: `WidgetDigestRow`, `WidgetSnapshot`, `WidgetSnapshotStore`). Two writers: the **widget** writes it after each successful `/summary` fetch (so a later failed fetch shows the last-known digests instead of a blank card), and the **app** writes it after every refresh and after read/archive mutations (seeding the widget's very first render and keeping the fallback's read-state current). On disconnect the app clears the snapshot so a disconnected widget can't keep showing a previous companion's digests.
- **Invariant unchanged:** the widget remains **read-only** — `Link`-deeplink rows only, never `Button(intent:)`. The live data path adds a fetch and a fallback; it does not add interactivity.

## Privacy & data

- **Content never leaves the user's VPS.** Digests and the user's read/archive state live on the companion the user owns. Erasure of the real data is the user's own.
- **No central service in the path.** Because the app pulls directly from the user's companion, no project-run service ever sees content, device identifiers, or even traffic metadata. This is the strongest possible privacy story — the *absence* of a middle-tier is the feature.
- The app ships a **privacy policy** ("your content stays on your server; the app talks only to the companion you configure") and honest **nutrition labels** (app-functionality, **not** tracking; no data collected by the developer).

## Security notes

- Companion secrets (the pairing token, any HTTPS cert material) live in `/opt/data/.env` on the user's VPS — plaintext-but-gitignored, never in any vault or this repo.
- The companion authenticates app requests by the pairing token. **Auth-failure rate limiting is *planned, not shipped*** — not yet in M1.
- Pairing exposure is default-off: see "Pairing & trust" for the `CROWLY_PAIR_ENABLED` gate and the token-rotation runbook in `docs/deployment-learnings.md`.

## Deliberately deferred

- Generic webhook / email / Zapier / n8n / Make / RSS ingest — only after personal pull is proven (see roadmap). Note: anyone can already POST a schema-valid digest from any tool today; "generic ingest" here means *first-party adapters and docs* for non-Hermes sources, not the wire format.
- Multi-tenant hosted backend — explicitly *not* this design; the companion model exists to avoid it.
- Full-text search on the server — M1 search is client-side over what's already loaded; server-side search is M2+ if the inbox grows past what one device wants to hold.
