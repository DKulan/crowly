# Roadmap

Re-sequenced in the 2026-06-29 grilling session (PWA-first/single-user → native/public/self-hosted-companion), then **pivoted to reader-only** the same day. Three artifacts: the iOS app, the per-user companion service, and the emitter kit.

The organizing principle: **the single-user vertical slice (M1) is a strict subset of the public release and sits on its critical path.** So M1 is built first, doubles as the two-week behavioral test (`docs/validation.md`), and gates the public-only work in M2. The least-reversible work (privacy, demo polish, stranger onboarding) lands only after the reader is proven worth opening.

## Phase 0 — Schema (do regardless)

- [ ] Finalize the digest schema with `schema_version` and the additive-only versioning rule (`docs/schema.md`).
- [ ] Confirm the structured output is already useful in Telegram/Obsidian. **Pure win even if the app never ships.**

## M1 — "the reader works on my phone" (single-user)

Everything points at Daniel's own VPS. **This is the gate.** Build items 1–4 are **done** (2026-07-02); item 5 — the two-week behavioral test — is the remaining gate.

1. [x] **Companion core** — validating idempotent ingest + store + `GET /list` + `GET /summary`. The store **preserves unknown schema fields verbatim** from day one (full digest blob) — cheap now, a data migration later (`docs/schema.md` → Versioning). Read/archive state is a simple state-change write the app POSTs. *(Shipped: `companion/`, end-to-end tested; `{digest, state}` envelope shape on `/list` + `/summary`.)*
2. [x] **Emitter kit** — helper + Hermes skill so the inbox is non-empty (Harmony, morning briefing, vendor/research watcher). *(Shipped: `emitter/`; helper verified against the real companion.)*
3. [x] **iOS app core** — inbox list + detail view + archive flow + auto-refresh (foreground + interval poll; pull-to-refresh kept as manual override) + search hitting the companion over TLS; token in the Keychain. *(Shipped; verified on device 2026-06-30.)*
4. [x] **Home-screen widget** — **live** (Phase 1, 2026-07-02): when paired, the widget's own `TimelineProvider` fetches `GET /summary` on a ~15-minute reload floor and renders the server's latest digests + authoritative unread count; `Link`-deeplink rows, no buttons; App Group (`group.com.crowly`) snapshot fallback for offline; shared Keychain access group so the widget reads the app's pairing token; unpaired = demo fixtures. See `docs/architecture.md` § Widget data path. **This item gated the validation clock — it is now closed, so the two-week test can start.**
5. [ ] **Run the two-week pull test** (`docs/validation.md`). ← the only open M1 item.

**Gate:** meet success criteria → M2. Otherwise keep it personal; do **not** widen inputs.

## M2 — "public-ready" (the layer M1 doesn't need but strangers do)

6. [ ] **Demo mode polish** — bundled canned digests across urgency tiers and shapes; first-run default, App-Review unblocker, and the marketing artifact. (Demo mode itself ships in M1; M2 is polishing it for strangers.)
7. [ ] **Stranger onboarding** — a published companion image + an agent-driven `setup-crowly` skill. **Default TLS strategy: Tailscale Funnel** (no domain/DNS/ACME; TLS terminates on the user's node so content stays private), with existing-proxy (Traefik labels) and bundled-Caddy as power-user options. QR pairing polish. **See `docs/deployment-learnings.md`** — the real first deploy, with every snag (packaging, proxy port conflict, LE rate-limit, tunnel-cert-from-inside-tailnet, container↔host networking) and the exact fix the installer must encode.
8. [ ] **Version negotiation hardening** — additive-only schema enforced in CI; degrade-and-warn / "update your companion" banner when the companion's `schema_version` falls outside `N`/`N-1`. (Unknown-field *passthrough* already shipped in M1; this phase adds the negotiation UX on top.)
9. [ ] **Privacy & submission** — privacy policy URL, nutrition labels (app-functionality, not tracking), in-app disconnect.
10. [ ] **Onboarding docs** — app + companion + emitter kit as one kit → **submit to the App Store.**

## Phase 3 — Generic input layer (only after public use sticks + external pull)

- [ ] First-party webhook adapter + shared digest schema docs for non-Hermes sources.
- [ ] Email ingest address (parses subject/body into a digest).
- [ ] Zapier / n8n / Make templates.
- [ ] RSS digest import, markdown parser.

## Phase 4 — Reader depth

- [ ] User-configurable job colors (overrides the FNV-1a default).
- [ ] Server-side search (if inbox grows past what one device wants to hold).
- [ ] Lock Screen widgets (read-only, same shape as home-screen small).
- [ ] Weekly "what your agents found this week" recap.
- [ ] **Push notifications** — deferred from MVP. Would need a central APNs relay (APNs is bound to the app's Apple credential and can't be self-hosted), which is a permanent single-operator dependency. Only revisit if two weeks of pull validation say the widget cue isn't enough.

## Guardrails carried across all phases

- M1 pull gates every expansion. Single-user pull is the real risk.
- Never become "another inbox" full of cruft: archive as the natural end-state, no read/handled/snoozed proliferation.
- The reader experience (clean cell + detail + widget) is the product; everything else exists to feed it digests.
- Content stays on the user's VPS; the app pulls directly from the user's companion and no central service is in the path. Secrets in `/opt/data/.env`, never in the vault or this repo.
- The schema is a versioned contract across independently-deployed parts — additive-only, unknown-fields-preserved, degrade-and-warn.
