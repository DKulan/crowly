# Crowly

**Crowly** is a native iOS **inbox and reader** for recurring AI-agent and automation outputs — AI news summaries, weather, local community updates, scheduled briefings, general reminders — so those digests live in a clean, scannable, dedicated home outside chat apps, with a home-screen widget that shows what just arrived.

Built first for [Hermes Agent](https://github.com/NousResearch/hermes) cron/digest outputs, for people who **self-host their own agent**: you run a small **companion service** on your own VPS, the app talks to it directly, and your content never leaves your server.

## The thesis (one line)

> Chat is a good delivery channel for agent output but a bad **review surface**. This is a dedicated surface where every recurring digest is grouped, archivable, searchable — and the home-screen widget shows what just landed without ever burying it under unrelated notifications.

## Why this, why now

- Cron/automation jobs only increase. At 3–4 jobs chat is annoying; at 15–20 it's broken — no grouping, no read/archived state, no archive, no search.
- A dedicated reader gives those scheduled digests a home that matches how they're consumed: glance the widget, open the app, read the latest, archive the rest.
- The rise of self-hosted agents means more people will hit this exact pain — and they already self-host data, so a companion-on-your-own-VPS model is a natural fit, not a sell.

## What makes it different (and not just another AI reader)

| Job | Chat/email | Other AI readers | Crowly |
|---|---|---|---|
| Deliver a digest | ✅ | ✅ | ✅ |
| Group by source/job | ❌ | partial | ✅ |
| Read / archived state, durable archive, search | ❌ | ✅ | ✅ |
| Glanceable "what just landed" on home screen | ❌ | rarely | ✅ widget-first |
| **Agent-agnostic** (any cron/agent that can POST JSON) | ❌ | ❌ (curated feeds) | ✅ |
| **Your content stays on your own server** | ❌ | ❌ (vendor cloud) | ✅ self-hosted companion |

**Agent-agnostic delivery**, **self-hosted data**, **widget-first**, and a **clean dedicated home for scheduled agent output** are the differentiation. The card list isn't the moat alone — the four together are.

## Architecture in one picture

Four parts — three run, one shipped:

- **iOS app** (App Store) — list, detail, **home-screen widget**, demo mode, QR pairing, Keychain.
- **Companion service** (Docker, on each user's VPS) — validates/stores digests and serves them (`GET /list`, `GET /summary`). Bundled auto-HTTPS.
- **Push relay** (tiny, central, operated by the project) — the only piece that can't be self-hosted (APNs is bound to the app's Apple credential). Holds only `routing_token → device_token`; **best-effort, never critical-path**.
- **Emitter kit** — a helper + Hermes skill that makes any agent emit schema-valid digests.

See [`docs/architecture.md`](docs/architecture.md) for the full diagram and flow.

## Build philosophy

1. **Schema first.** The digest contract is the real product and pays off in Telegram/Obsidian too. It's **versioned and additive-only**, because the app/companion/emitter deploy independently. See [`docs/schema.md`](docs/schema.md).
2. **M1 gates M2.** Build the single-user slice (companion + app + relay pointed at your own VPS), run the two-week pull test, and only then build the public-only layer (demo mode polish, stranger TLS/onboarding, privacy, relay-for-strangers). The single-user slice is on the public release's critical path anyway. See [`docs/roadmap.md`](docs/roadmap.md).
3. **Native, widget-first.** The home-screen widget showing the latest digests is the reason to be native and the marketing artifact.
4. **Personal validation gates expansion.** If Daniel doesn't reach for it unprompted within two weeks, stop at M1 — don't build the public layer or widen to generic webhooks.
5. **Content stays on the user's server.** The relay holds only a device token; data ownership is the lead differentiator, not an afterthought.

## Docs

- [`docs/concept.md`](docs/concept.md) — full concept, positioning, target users, competition, risks.
- [`docs/schema.md`](docs/schema.md) — the digest JSON schema and the versioning policy (the part that makes the contract survive drift between independently-deployed parts).
- [`docs/architecture.md`](docs/architecture.md) — app + companion + relay + emitter; TLS, pairing, push, privacy.
- [`docs/ux.md`](docs/ux.md) — the M1 iOS UI/UX: inbox, digest detail, the home-screen widget.
- [`docs/design-system.md`](docs/design-system.md) — tokens, components with SwiftUI sketches, FNV-1a job-color algo.
- [`docs/validation.md`](docs/validation.md) — the M1 two-week personal test, success criteria, kill criteria.
- [`docs/roadmap.md`](docs/roadmap.md) — M1 (single-user) → M2 (public-ready) build order.
- [`docs/naming.md`](docs/naming.md) — the name (**Crowly**), why it was chosen, and how to claim it on the App Store.

## Status

**Reader-only pivot** (2026-06-29). M1 demo-mode iOS app is built and verified on-device; the design docs were just rewritten away from the earlier "job-bound response loop" framing toward a clean reader. Origin: evaluated and refined from the second-brain project note `wiki/projects/agent-output-inbox.md` on 2026-06-29, then re-scoped from PWA-first/single-user to native/public/self-hosted-companion in a grilling session the same day, then pivoted from control-plane to reader-only. Named **Crowly** on 2026-06-29 (see [`docs/naming.md`](docs/naming.md)); the App Store name has not yet been claimed in App Store Connect.

## Related (in second-brain)

- `hermes-assistant` — the deployment producing the scheduled outputs (and one configuration of the companion).
- `harmony-community-digest-v2-improvements` — a concrete first digest source.
