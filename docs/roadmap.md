# Roadmap

Re-sequenced in the 2026-06-29 grilling session. The original plan (PWA-first, native-last, single-user) was replaced by a **native, public, self-hosted-companion** product — four artifacts: the iOS app, the per-user companion service, a small central push relay, and the emitter kit.

The organizing principle: **the single-user vertical slice (M1) is a strict subset of the public release and sits on its critical path.** So M1 is built first, doubles as the two-week behavioral test (`docs/validation.md`), and gates the public-only work in M2. The least-reversible work (relay, privacy, demo) lands only after the loop is proven worth using.

## Phase 0 — Schema (do regardless)

- [ ] Finalize the digest + callback schema with `schema_version`, intent routes, and `on_answer` (`docs/schema.md`).
- [ ] Confirm the structured output is already useful in Telegram/Obsidian. **Pure win even if the app never ships.**

## M1 — "the loop works on my phone" (single-user)

Everything points at Daniel's own VPS. **This is the gate.**

1. [ ] **Companion core** — validating idempotent ingest + store + `GET /list` + the `task`/`note`/`state` **executor** (against Daniel's real Todoist/vault). The store **preserves unknown schema fields verbatim** from day one (full digest blob) — cheap now, a data migration later (`docs/schema.md` → Versioning).
2. [ ] **Emitter kit** — helper + Hermes skill so the inbox is non-empty (Harmony, morning briefing, Todoist watcher).
3. [ ] **iOS app core** — list + detail + **bound answer buttons** hitting the companion over TLS; token in the Keychain.
4. [ ] **Relay + APNs push** (thin pointer, gated on open loops) + **`GET /summary`** + **interactive widget** (answer from the home screen; optimistic UI + reconciliation).
5. [ ] **Run the two-week pull test** (`docs/validation.md`).

**Gate:** meet success criteria → M2. Otherwise keep it personal; do **not** widen inputs.

## M2 — "public-ready" (the layer M1 doesn't need but strangers do)

6. [ ] **Demo mode** — bundled canned digests; first-run default, App-Review unblocker, and the marketing artifact.
7. [ ] **Stranger onboarding** — bundled Caddy auto-HTTPS (domain) + Cloudflare-Tunnel recipe (no-domain); QR pairing polish.
8. [ ] **Version negotiation hardening** — `GET /capabilities`, additive-only schema, degrade-and-warn / "update your companion" banner. (Unknown-field *passthrough* already shipped in M1; this phase adds the negotiation/UX on top.)
9. [ ] **Privacy & submission** — privacy policy URL, nutrition labels (Device ID, not tracking), relay token-purge path, in-app disconnect.
10. [ ] **Onboarding docs** — app + companion + emitter kit as one kit → **submit to the App Store.**

## Phase 3 — Generic input layer (only after public use sticks + external pull)

- [ ] Generic webhook endpoint + shared digest schema docs (the emitter kit generalizes this).
- [ ] Email ingest address.
- [ ] Zapier / n8n / Make templates.
- [ ] RSS digest import, markdown parser.

## Phase 4 — Action routing depth

- [ ] Richer Todoist routing (projects/labels/due from `hints`).
- [ ] Obsidian/Notion durable export (gated on `todoist-obsidian-action-layer-v1` v2).
- [ ] Weekly "what my agents found / what they need from me" recap.

## Guardrails carried across all phases

- M1 pull gates every expansion. Single-user pull is the real risk.
- Never become "another inbox": thin push gated on open loops, handled state, weekly cleanup as defaults.
- The bound loop + interactive widget are the product; the card list is table stakes.
- Content stays on the user's VPS; the relay holds only a device token and is best-effort. Secrets in `/opt/data/.env`, never in the vault or this repo.
- The schema is a versioned contract across independently-deployed parts — additive-only, degrade-and-warn.
