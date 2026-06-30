# Roadmap

Re-sequenced in the 2026-06-29 grilling session (PWA-first/single-user → native/public/self-hosted-companion), then **pivoted to reader-only** the same day. Three artifacts: the iOS app, the per-user companion service, and the emitter kit.

The organizing principle: **the single-user vertical slice (M1) is a strict subset of the public release and sits on its critical path.** So M1 is built first, doubles as the two-week behavioral test (`docs/validation.md`), and gates the public-only work in M2. The least-reversible work (privacy, demo polish, stranger onboarding) lands only after the reader is proven worth opening.

## Phase 0 — Schema (do regardless)

- [ ] Finalize the digest schema with `schema_version` and the additive-only versioning rule (`docs/schema.md`).
- [ ] Confirm the structured output is already useful in Telegram/Obsidian. **Pure win even if the app never ships.**

## M1 — "the reader works on my phone" (single-user)

Everything points at Daniel's own VPS. **This is the gate.**

1. [ ] **Companion core** — validating idempotent ingest + store + `GET /list` + `GET /summary`. The store **preserves unknown schema fields verbatim** from day one (full digest blob) — cheap now, a data migration later (`docs/schema.md` → Versioning). Read/archive state is a simple state-change write the app POSTs.
2. [ ] **Emitter kit** — helper + Hermes skill so the inbox is non-empty (Harmony, morning briefing, vendor/research watcher).
3. [ ] **iOS app core** — inbox list + detail view + archive flow + pull-to-refresh + search hitting the companion over TLS; token in the Keychain.
4. [ ] **Home-screen widget** (pull/timeline-refresh: latest digests + unread count; `Link`-deeplink rows, no buttons; ~15-minute reload floor against `GET /summary`).
5. [ ] **Run the two-week pull test** (`docs/validation.md`).

**Gate:** meet success criteria → M2. Otherwise keep it personal; do **not** widen inputs.

## M2 — "public-ready" (the layer M1 doesn't need but strangers do)

6. [ ] **Demo mode polish** — bundled canned digests across urgency tiers and shapes; first-run default, App-Review unblocker, and the marketing artifact. (Demo mode itself ships in M1; M2 is polishing it for strangers.)
7. [ ] **Stranger onboarding** — bundled Caddy auto-HTTPS (domain) + Cloudflare-Tunnel recipe (no-domain); QR pairing polish.
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
