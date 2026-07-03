# Architecture

## Shape: two artifacts you run, one you ship

```
   USER'S HOST (VPS or personal computer)           ┌────────────────────┐
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

### 2. Companion service (per user, on their own host)
The data-owning core. Self-hosted and **packaging-agnostic**: it is dependency-free Python 3 + sqlite3 (`companion/server.py`, env-var configured) and **runs as a bare `python3 -m companion` process or via Docker** — the container is a convenience, not a requirement. The host is the user's choice: a VPS (with or without Docker) or a personal computer. It typically sits alongside the emitting agent (Hermes) but doesn't have to.
- **Ingest:** receives digests, **validates and rejects malformed ones with a clear 4xx** (so the cron author sees what's wrong in their logs), stores idempotent on `digest.id`. A bad payload never crashes the store or reaches the app. It accepts **`SCHEMA_VERSIONS_SUPPORTED = (1, 2)`** — v2 adds the optional `content` block array (`docs/schema.md` § 1.3). **Unknown fields are preserved verbatim** in the stored blob — and, since the blob is stored whole, that verbatim preservation extends *inside* `content` to **unknown block types** too; there is **no per-block server logic** (`docs/schema.md` § Versioning).
- **Serve:** `GET /list` (full cards; pagination is *planned, not shipped* — M1 returns everything) and `GET /summary` (cheap — for the widget). `/summary` returns `{unread_count, total, latest:[{digest,state}]}`: the authoritative `unread_count`, the **latest 5 non-archived** digests, and `total` = the count of **non-archived** digests (backs the large widget's "View all N →" footer). Archived digests are excluded from both `latest` and `total` — archive is triage, so a triaged digest must not resurface on the widget; this matches the app-side snapshot writer, which already filters `!= archived`. (`total` is additive — an older companion that omits it is fine; the app reads it as optional and the footer just hides.)
- **Store:** flat JSON/SQLite. No heavy backend. State (read/archived) lives here too, mirrored from the app via simple state-change writes.
- Ships with **auto-HTTPS** (see Networking).

### 3. iOS app (App Store)
- Card list, detail view, archive flow (with undo), pull-to-refresh, search. The detail view renders **v2 `content` blocks** with bespoke SwiftUI when present, falling back to the v1 `summary`/`sections` prose otherwise (`docs/schema.md` § 1.3, `docs/ux.md` § Digest detail).
- **Home-screen widget (live, shipped M1 Phase 1)** — latest digests + unread count; tap-through deeplinks open the app to that digest. No buttons. When **paired**, the widget's own `TimelineProvider` fetches `GET /summary` on a ~15-minute reload floor (independent of the app being open), rendering the server's rows + authoritative `unread_count`; on a failed fetch (offline / VPS asleep) it falls back to the last **App Group snapshot**. When **unpaired**, it shows demo fixtures with a `.never` reload. See § Widget data path for the cross-target credential/snapshot wiring.
- **Demo mode** — the **unpaired** path, not a separate build: bundled canned digests, the first-run default and the only thing a non-self-hoster (incl. an App Reviewer) sees. Both the app *and* the widget render fixtures until pairing.
- **First-run onboarding** — a 4-screen carousel (`App/Views/Onboarding/`) shown once on first launch (gated by `@AppStorage("hasOnboarded")`), then handing off to pairing or dismissing into demo mode (`docs/ux.md` § Onboarding). Onboarding art is the bundled `crow` PNG (transparent right-facing crow with orange speed-lines, extracted from the app icon at `App/Assets.xcassets/crow.imageset`), rendered by `CrowAnimationView` with a code-driven bob — no Lottie, no third-party animation library.
- **Pairing** — **QR scan (shipped, M2 Phase 3b)** or manual companion URL + token entry. QR scan wraps VisionKit's `DataScannerViewController` and degrades to manual entry where there's no camera (Simulator / headless); manual entry remains the always-works fallback. Either path stores companion URL + token in the **Keychain** (a fixed shared service, shared access group — see § Widget data path).
- **Third-party dependencies** — Apple's **VisionKit** framework only (QR pairing scanner; needs `NSCameraUsageDescription`, declared in `project.yml`). The onboarding crow is a static asset, so no animation library is needed. The widget and test targets pull in nothing extra.
- **App URL scheme (`crowly://`) deeplinks:** `crowly://digest/<id>` (open a digest), `crowly://inbox` (pop to inbox root — the large widget's "View all →"), `crowly://pair` (open the pair sheet — testing surface), `crowly://onboarding` (replay the first-run carousel — testing surface). Routed through `DeepLinkRouter` (`App/Store/DeepLinkRouter.swift`).

## Networking & TLS

- A public iOS app must use **HTTPS with a publicly-trusted cert** (App Transport Security). Plain `http://<ip>` is blocked, and ATS exceptions draw review scrutiny — so the app ships **no ATS exceptions**.
- The companion therefore **requires valid TLS and fails loud at startup without it** — it will not silently serve cleartext the app can't reach.
- **Default:** bundled auto-HTTPS (Caddy + Let's Encrypt). User points a hostname at their VPS, sets one env var, `docker compose up`; certs auto-renew.
- **Existing reverse proxy:** if the host already runs a proxy that owns :80/:443 (Traefik, nginx-proxy, etc. — common when other self-hosted services live on the box), the bundled Caddy would collide on those ports. Use `companion/docker-compose.traefik.yml` instead: it drops Caddy and exposes the companion to the existing proxy by label/host, so one proxy terminates TLS for everything. (Match the proxy's entrypoint/cert-resolver names to your existing services.)
- **Tunnel (no domain/DNS):** a tunnel (Tailscale Funnel / Cloudflare Tunnel) provides a public hostname with valid TLS and no open ports — the cleanest path when the user has no domain, and the mechanism a future agent-driven `setup-crowly` can automate (one auth step, no DNS/cert dance). With Docker, use `companion/docker-compose.local.yml` (binds `127.0.0.1:8787`, tunnel fronts it); on a bare host, run `python3 -m companion` (listens on `127.0.0.1:8787`) and point the tunnel at it. Either way set `CROWLY_PUBLIC_URL` to the tunnel hostname. **Tailscale Funnel is the cross-topology default** — it works on a VPS, a no-Docker VPS, **and a NAT'd home machine** (no public IP or port-forward), which is why it's the one path the docs recommend across setups (topology matrix: `docs/onboarding.md` § Where the companion can run). **Privacy note:** prefer **Tailscale Funnel** — TLS terminates on the user's own node, so the tunnel provider never sees digest plaintext ("content stays on your server" holds). Cloudflare Tunnel terminates TLS at Cloudflare, which can see content in principle — a weaker fit for the privacy thesis.

## Pairing & trust

- **Pairing endpoints are gated, default OFF.** `GET /` and `GET /pair` return `{companion_url, pairing_token}` — the credential itself, in the response body — so they must not be reachable in normal operation. They are gated behind the env flag **`CROWLY_PAIR_ENABLED`**, which defaults to false; when disabled both endpoints return **404**. Turn it on only for the brief initial-pairing window, pair the phone, turn it off, restart.
- **Why gated:** the companion is fronted by a public Tailscale Funnel hostname, and public HTTPS names are enumerated in **Certificate Transparency logs** — the Funnel URL is not a secret. An always-on unauthenticated pairing endpoint on a CT-discoverable hostname = a public token leak. The first-deploy leak that motivated this fix is captured in `docs/deployment-learnings.md`.
- **`/health` stays unauthenticated** as a liveness probe, but no longer includes the stored digest count when pairing is disabled (it was leaking activity metadata to anyone scanning the Funnel URL).
- **Pairing UX** — **QR scan (shipped, M2 Phase 3b) or manual companion URL + token entry**. The QR encodes the same `{companion_url, pairing_token}` the `/pair` endpoint returns; the scanner (VisionKit `DataScannerViewController`) parses it, fills the pair form, and auto-validates over HTTPS before persisting — the secret flows scan → form → validate → Keychain, never off the device. Manual entry stays the always-works fallback (and the only path where the camera is unavailable). Either way the app stores both in the phone **Keychain**; the only credential in the loop is the pairing token, held by the user's companion and by their phone's Keychain. No third party participates in pairing.
- **Token rotation** — because the Funnel URL is public, the pairing token must be rotatable, and any exposed token (e.g. one that lived behind an ungated pairing endpoint) is treated as compromised. The operator runbook is in `docs/deployment-learnings.md`.

## Refresh model

- **The app pulls, and pulls on its own.** While foregrounded the inbox auto-refreshes: an immediate pull whenever the app becomes active (launch or return from background), then a gentle interval poll (~60s) that a `scenePhase`-keyed task cancels on background and restarts on foreground. Pull-to-refresh remains as a manual override, but the user shouldn't need it. Everything in the app fetches `GET /list` (or `GET /summary` for the widget) over the user's companion HTTPS endpoint.
- **The widget refreshes itself.** When paired, its `TimelineProvider` carries a **~15-minute reload floor** that re-fetches `GET /summary` independent of the app being open (WidgetKit treats the floor as a request, not a guarantee — the OS may space reloads further apart under budget pressure). This bounds widget staleness without any server-pushed wake-up: the widget is the marketing artifact, so this is a committed property, not an accident. When unpaired the timeline is `.never` — there's no live data to chase.
- There is no notification delivery in the MVP. New digests surface when the user next opens the app or the widget timeline next fires.
- **Always-on caveat (a property of the pull model, not a bug).** Because the app and widget *pull*, a companion on a host that sleeps — a personal computer — **can't be pulled while it's asleep**; the app and widget show the last snapshot until the machine wakes and the next fetch lands. A VPS or an always-on desktop avoids this. Push would fix it but is deferred (`docs/roadmap.md` Phase 4, needs a central APNs relay) — so this is surfaced honestly to laptop users (`docs/onboarding.md` § Where the companion can run; in-app onboarding screen 4), not engineered away.

## Widget data path (Phase 1 — shipped)

The widget extension is a separate process from the app, so making the widget live means giving it its own read path to the companion plus a fallback that survives an offline fetch.

- **The widget reads the companion directly.** The companion client and credential store (`Shared/Net/CompanionClient.swift`, `Shared/Net/KeychainStore.swift`) compile into **both** the app and the widget extension (`Shared/` is a shared source root). The widget builds its own `CompanionClient` and calls `GET /summary`; the server's `unread_count` (and `total`, for the large widget's footer) is authoritative. All three families — `.systemSmall`, `.systemMedium`, `.systemLarge` — render from the same `/summary` payload; large shows up to 5 rows + the "View all N →" footer.
- **Shared Keychain (the pairing token).** Both targets store credentials in a keychain item under a **fixed shared service** (`SharedKeychain.service` = `com.crowly.shared`) — deliberately *not* the bundle id, since the app and widget have different bundle ids and a per-bundle service would give each target a different item. Item sharing is via the **default keychain access group**: both targets declare `keychain-access-groups: [$(AppIdentifierPrefix)com.crowly.shared]` in `project.yml`, and keychain services uses the *first* entry as the read/write group — so `KeychainStore` never passes an explicit `kSecAttrAccessGroup` (which would need the team-id prefix and trips `errSecMissingEntitlement` on the simulator). The widget reads the same token the app wrote, with no code coupling.
- **App Group snapshot (offline fallback / first-render seed).** App Group `group.com.crowly` (declared as `com.apple.security.application-groups` on both targets) backs a small `UserDefaults`-suite snapshot (`Shared/Widget/WidgetSnapshotStore.swift`: `WidgetDigestRow`, `WidgetSnapshot`, `WidgetSnapshotStore`). The snapshot carries up to 5 rows (`maxRows`, enough to fill the large widget), the `unreadCount`, and the non-archived `total` (for the large widget's footer). Two writers: the **widget** writes it after each successful `/summary` fetch (so a later failed fetch shows the last-known digests instead of a blank card), and the **app** writes it after every refresh and after read/archive mutations (seeding the widget's very first render and keeping the fallback's read-state current) — both filter out archived digests so the snapshot agrees with `/summary`. On disconnect the app clears the snapshot so a disconnected widget can't keep showing a previous companion's digests. (The snapshot's App Group key is `widget_snapshot_v2`; the shape gained `total` over v1, so a stale v1 blob is simply ignored.)
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
