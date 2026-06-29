# Crowly

**Crowly** is a native iOS inbox and **control surface** for recurring AI-agent and automation outputs — so scheduled digests don't get buried in Telegram, email, or notification summaries, and so the questions/actions an agent raises can be **answered in context** (from a home-screen widget) rather than as loose chat replies.

Built first for [Hermes Agent](https://github.com/NousResearch/hermes) cron/digest outputs, for people who **self-host their own agent**: you run a small **companion service** on your own VPS, the app talks to it directly, and your content never leaves your server.

## The thesis (one line)

> Chat is a good delivery channel for agent output but a bad **review and response** surface. This is a dedicated surface where every recurring digest is grouped, archived, searchable — and every question or action an agent raises is **structurally bound to its job**, so a tap-to-answer reply resolves against that question's own routing instead of becoming ambiguous text in a stream.

## Why this, why now

- Cron/automation jobs only increase. At 3–4 jobs chat is annoying; at 15–20 it's broken — no grouping, no read/handled state, no archive, no search.
- The harder problem isn't reading. It's **closing the loop**: when an agent asks "what's the drop-off window?", the reply must be unambiguous. Bound to `job_id` + `question_id` and a declared `on_answer` route, the answer is executed deterministically — no disambiguation.
- The rise of self-hosted agents means more people will hit this exact pain. Good showcase material once the loop demo works.

## What makes it different (and not just a prettier chat)

| Job | Chat/email | This |
|---|---|---|
| Deliver a digest | ✅ | ✅ |
| Group by source/job | ❌ | ✅ |
| Read / handled state, durable archive, search | ❌ | ✅ |
| Glanceable "what needs me today" | ❌ | ✅ interactive widget |
| **Answer an agent's question in context** | ❌ (ambiguous reply) | ✅ bound to `job_id`+`question_id` |
| Route action item → Todoist / note | ❌ | ✅ intent-routed, capability-aware |
| **Your content stays on your own server** | ❌ | ✅ self-hosted companion |

The **bound response loop**, the **interactive widget**, and **self-hosted data** are the moat. The card list alone is not enough.

## Architecture in one picture

Four parts — three run, one shipped:

- **iOS app** (App Store) — list, detail, bound answer buttons, **interactive widget**, demo mode, QR pairing, Keychain.
- **Companion service** (Docker, on each user's VPS) — validates/stores digests, serves them, and **executes callbacks locally** (Todoist/notes/state) against that user's own integrations. Bundled auto-HTTPS.
- **Push relay** (tiny, central, operated by the project) — the only piece that can't be self-hosted (APNs is bound to the app's Apple credential). Holds only `routing_token → device_token`; **best-effort, never critical-path**.
- **Emitter kit** — a helper + Hermes skill that makes any agent emit schema-valid digests.

See [`docs/architecture.md`](docs/architecture.md) for the full diagram and flow.

## Build philosophy

1. **Schema first.** The digest + callback contract is the real product and pays off in Telegram/Obsidian too. It's **versioned and additive-only**, because the app/companion/emitter deploy independently. See [`docs/schema.md`](docs/schema.md).
2. **M1 gates M2.** Build the single-user slice (companion + app + relay pointed at your own VPS), run the two-week pull test, and only then build the public-only layer (demo mode, stranger TLS/onboarding, privacy, relay-for-strangers). The single-user slice is on the public release's critical path anyway. See [`docs/roadmap.md`](docs/roadmap.md).
3. **Native, widget-first.** The interactive home-screen answer is the reason to be native and the marketing artifact.
4. **Personal validation gates expansion.** If Daniel doesn't reach for it unprompted within two weeks, stop at M1 — don't build the public layer or widen to generic webhooks.
5. **Content stays on the user's server.** The relay holds only a device token; data ownership is the lead differentiator, not an afterthought.

## Docs

- [`docs/concept.md`](docs/concept.md) — full concept, positioning, target users, competition, risks.
- [`docs/schema.md`](docs/schema.md) — digest JSON schema, the callback contract, and the versioning policy (the part that makes the loop work and survive drift).
- [`docs/architecture.md`](docs/architecture.md) — app + companion + relay + emitter; routing, TLS, pairing, push, privacy.
- [`docs/ux.md`](docs/ux.md) — the M1 iOS UI/UX: inbox, digest detail with bound answers, the interactive widget, and the intent→visual lexicon.
- [`docs/validation.md`](docs/validation.md) — the M1 two-week personal test, success criteria, kill criteria.
- [`docs/roadmap.md`](docs/roadmap.md) — M1 (single-user) → M2 (public-ready) build order.
- [`docs/naming.md`](docs/naming.md) — the name (**Crowly**), why it was chosen, and how to claim it on the App Store.

## Status

`idea` → scaffolding. No code yet. Origin: evaluated and refined from the second-brain project note `wiki/projects/agent-output-inbox.md` on 2026-06-29, then re-scoped from PWA-first/single-user to native/public/self-hosted-companion in a grilling session the same day. Named **Crowly** on 2026-06-29 (see [`docs/naming.md`](docs/naming.md)); the App Store name has not yet been claimed in App Store Connect.

## Related (in second-brain)

- `hermes-assistant` — the deployment producing the scheduled outputs (and one configuration of the companion).
- `todoist-obsidian-action-layer-v1` — the action/context loop the `task`/`note` routes build on.
- `harmony-community-digest-v2-improvements` — a concrete first digest source.
