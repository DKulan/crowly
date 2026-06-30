# Validation

The point of validation is behavioral, not technical: **does a dedicated reader change whether and how Daniel reviews scheduled agent output?** A polished app he doesn't open is a failure regardless of how nice it looks.

The validation surface is **M1** — the single-user native slice (`docs/roadmap.md`), pointed at Daniel's own VPS. M1 is built first because it's on the public release's critical path anyway; running the two-week test on it means the heaviest, least-reversible public-only work (relay polish, privacy, demo, stranger onboarding) only happens **after** the reader proves itself worth opening.

## Two-week personal test

1. Define the digest schema (`docs/schema.md`).
2. Make 2–3 Hermes jobs emit it via the emitter kit — start with **Harmony digest** (clean, low-urgency, weekly), plus **morning briefing** (daily, longer-form) and one **vendor/research watcher** (irregular, occasionally high-urgency). The mix exercises chronological scan, urgency-gated push, and the widget.
3. Stand up the **companion + app + relay** (M1): inbox list + detail + archive + the **home-screen widget** + push gated on urgency.
4. For two weeks, track behavior:
   - Does Daniel open the app unprompted?
   - Does he read digests *in the app* (or off the widget) rather than scrolling past them in Telegram?
   - Does the home-screen widget surface what's new, or does he forget to look?
   - Which digest sources he reads, which he archives unread, which he wishes weren't there.

## The surface is the test — no parallel full-content channel

**Do not run Telegram as a parallel full-content channel during the test.** The earlier "keep Telegram live, apples-to-apples" framing was a trap: Telegram *pushes the full digest to the lock screen*, so the user reads it there and never opens a silent second app to re-read it. That isn't apples-to-apples — it's home-field advantage for the incumbent, and it guarantees a null result while leaving Crowly (which lives only in the app + widget) untested.

Instead:
- **The app is the sole surface for content.** The only notification is the app's own **thin push, gated on `urgency` ≥ high** — "an agent has something for you," never the digest body. Normal/low-urgency digests don't push; they wait to be pulled (cued by the widget, the icon, or routine check-ins).
- Telegram may keep firing for *unrelated* Hermes traffic, but the digests under test go to the app, not to a parallel full-content Telegram message.

### Seed the habit before measuring it

A brand-new app with no chat crutch needs a cue, and habits need a few days to form. So:
- **Add the app and the medium widget to the home screen on day one** — the widget is a deliberate, real cue.
- Treat the **first few days as a seeding period** (commit to opening it at a fixed daily moment). Start the "unprompted" measurement *after* seeding — otherwise you're measuring cold-start friction, not steady-state value.

## Success criteria (the M1 gate — proceed to M2 if ≥4 of 5)

- Daniel checks it most days without being reminded (after the seeding period).
- It reduces reliance on chat for reviewing agent output (digests get read in Crowly, not Telegram).
- It makes at least 3 recurring digests easier to scan/find than they were in chat.
- The widget gets glanced at (not just the app icon) — measured by Daniel's own report, since iOS doesn't expose widget impression counts.
- Archive is used as the natural end-state of a read digest, not "I'll get to it later" guilt — i.e., the inbox doesn't accumulate unread cruft.

## Kill / pause criteria (the honest gate)

- If after two weeks Daniel does **not** reach for the app or look at the widget unprompted, **stop at M1** — do not build the public layer (demo polish/TLS/privacy/relay-for-strangers) or widen to generic webhooks. Single-user pull is the real killer, and M1 is the cheapest place to learn it.
- If the dedicated reader feels redundant with chat — i.e., Daniel's honest answer to "would I rather just have these in Telegram?" is "yes" — the differentiation has collapsed. Pause and rethink before any public work. **This is the specific reader-shape kill criterion**: not "is the loop unused" (there's no loop), but "does a dedicated home for scheduled agent output earn its tap over leaving it in chat?"
- If the only value is "prettier digests" with no change in *whether* he reads them, same call: pause.

Because M1 gates M2, a null result costs M1, not the whole four-artifact public build.

## Public validation (only after M1 pull sticks)

- The built-in **demo mode** + the medium widget *are* the marketing artifacts: home-screen screenshot showing "latest from your agents" beats a card-list screenshot. Post to X / AI-builder communities once it's earned its place on Daniel's home screen for two weeks.
- Ask where people currently send recurring agent outputs.
- Collect example digests people want to ingest.
- Test willingness to self-host the companion (the audience already self-hosts Hermes) and interest in the emitter kit.
