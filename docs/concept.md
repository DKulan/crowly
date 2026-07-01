# Concept

## One-line idea

**Crowly** — a native iOS app + home-screen widget that acts as a **dedicated reader** for recurring AI-agent and automation outputs — so scheduled digests (AI news summaries, weather, local community updates, briefings, reminders) don't get buried in chat, email, or notification summaries. Built for people who self-host their own agent (Hermes first): they run a small **companion service** on their own VPS, and the app pulls from it directly. No central service sits in the path.

## The pattern this serves

1. User creates agents/automations that produce scheduled outputs.
2. Outputs accumulate: a morning briefing, a weather summary, a community digest, an AI news roundup, a watcher, a reminder.
3. They all land in chat/email/Slack/Discord/Telegram.
4. The channel becomes notification sludge — no grouping, no read/archived state, no archive, no search. The most recent one buries the rest within hours.
5. User needs a clean review layer **purpose-built for scheduled agent output**, separate from interpersonal chat.

## Framing

**The product is an inbox/reader for scheduled agent output, on the user's own infrastructure.** Owning the framing matters: there's no shame in being a reader for this niche, because the niche is real, growing, and structurally underserved by general-purpose readers (which curate feeds) and chat apps (which drown scheduled content in unrelated messages).

The job is **reading, scanning, archiving, searching** recurring agent output without it competing with messages from humans. Four things differentiate:

1. **Agent-agnostic delivery.** Any cron/agent/script that can POST a schema-valid JSON digest is a first-class source — not a curated feed list, not one platform's outputs.
2. **Self-hosted data.** Digests live on the user's own VPS via the companion. The app pulls directly; no central service is in the path.
3. **Widget-first.** The home-screen widget shows the latest digests + unread count at a glance — the way scheduled output actually wants to be consumed.
4. **A dedicated home for scheduled agent output.** Not the same surface as work chat or social feeds. The audience self-selects: if you have ≥3 recurring agent jobs, this is for you; if you don't, you don't need it.

## Positioning lines (for X/article later)

- "Your daily/weekly AI briefings, organized outside your chat apps."
- "A dedicated reader for your agents' recurring reports — your data, your server."
- "What did my agents bring back for me today?"
- "An inbox for scheduled AI work — running on your own VPS."

## Target users

- **First:** Daniel himself (Hermes deployment) — the M1 validation.
- **Then:** other **Hermes self-hosters**, who already run a VPS and can deploy the companion the same way they deployed Hermes.
- Broader self-hosted AI/automation users later. Not a mainstream consumer app: the public App Store listing is mostly a **demo + a funnel to the self-hosting docs** for the few who self-host. That's consistent with the power-user audience.

## Adjacent products / competition

| Category | Examples | Gap |
|---|---|---|
| AI RSS/news readers | Bulletin, TodayRSS, Feedly AI | Curated content feeds, not arbitrary agent outputs. Vendor-hosted. |
| Read-it-later | Readwise Reader, Matter | Great for articles you save, weak for *scheduled output* a system produces for you. |
| Automation digests | Zapier Digest, Make/n8n email | Backend batching exists; review surface is email/chat. |
| Notification summaries | Apple Intelligence | Ephemeral, tied to alerts, not a durable archive. |
| Chat surfaces | Telegram, Slack, Discord, email | Easy delivery, poor triage; scheduled output competes with human messages. |
| Agent consoles | Platform dashboards | Tied to one platform, rarely widget-glanceable on the home screen, never self-hosted-data. |

Closest neighbours are AI readers — but they curate feeds for you (one vendor decides what's worth reading) and host your data on their servers. Crowly is **agent-agnostic in delivery** (your agent decides what's worth digesting; the app just renders it), **self-hosted in data**, and **widget-first** for the home screen. None of those alone are unique; the combination is.

## Risks

1. **Niche timing.** Few people run recurring agent jobs *and* self-host. Audience is small/technical now. Mitigation: built for the Daniel-of-6-months and the showcase power-user; the niche is growing as agent frameworks mature.
2. **Reader commoditization.** If general-purpose AI readers add self-hosting and arbitrary-source ingest, differentiation narrows. Defense: be best-in-class at the agent-output reader shape (widget, schema, cron-native ergonomics) and ship the emitter kit so any agent can target Crowly in one drop-in.
3. **Platform capture.** Agent platforms may build their own inboxes. Defense: cross-agent delivery, self-hosted data, widget-first.
4. **Overbuilding.** The public scope is still meaningful. Defense: **M1 gates M2** — build and behaviorally validate the single-user slice before the public-only layer.
5. **Notification sludge.** Not an MVP concern — the app doesn't send notifications. The widget and a manual app-open are the only surfaces for "what's new"; archive-and-undo is the primary triage; no notification-stacking by construction.
6. **(The real one) Single-user pull.** Personal-first projects die when the builder stops reaching for it. Validation must be ruthless: no unprompted use in two weeks → stop at M1.

## Resolved decisions (2026-06-29)

- Is the core a reader, an inbox, a control plane? → **A reader/inbox.** (Earlier draft tried "control plane with a bound response loop"; pivoted out — the loop was speculative for the audience, and the reader job is the durable one.)
- Concrete tools or intents in the schema? → **Neither.** The schema describes content shape only (title, bottom line, summary, sections, sources). No routes, no callbacks, no per-tool fields.
- Who reads digests, who acts on them? → **The user reads. Acting is out of scope for Crowly** — if a digest tells you to do something, you do it wherever you already do things. Crowly's job ends at "you saw it."
- Single-user or public? → **Public**, for Hermes self-hosters, via the companion model (not a hosted SaaS).
- What's the cue? → **The home-screen widget** (refreshing on its own timeline) is the steady-state surface; the app icon is the backstop. The app refreshes itself — it pulls on open and polls on an interval while foregrounded, so the inbox stays current without a manual pull.

## Still-open questions

- What's the first widget layout Daniel keeps on his home screen?
- Which outputs are most valuable: morning briefings, community updates, vendor/research watches, weather, news summaries?
- Would anyone self-host the companion without already running Hermes?
