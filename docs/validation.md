# Validation

The point of validation is behavioral, not technical: **does a dedicated surface change whether and how Daniel reviews and responds to agent output?** A polished app he doesn't open is a failure regardless of how nice it looks.

The validation surface is **M1** — the single-user native slice (`docs/roadmap.md`), pointed at Daniel's own VPS. M1 is built first because it's on the public release's critical path anyway; running the two-week test on it means the heaviest, least-reversible public-only work (relay, privacy, demo, stranger onboarding) only happens **after** the loop proves itself.

## Two-week personal test

1. Define the digest + callback schema (`docs/schema.md`).
2. Make 2–3 Hermes jobs emit it via the emitter kit — start with **Harmony digest** (clean, low-urgency) plus **morning briefing** and the **Todoist completion watcher** (these actually raise questions/actions, exercising the loop).
3. Stand up the **companion + app + relay** (M1): card list + detail + **bound answer buttons** + the **interactive widget** + push gated on open loops.
4. For two weeks, track behavior:
   - Does Daniel open the app unprompted?
   - Does he answer agent questions *in the app* (or the widget) rather than in Telegram?
   - Does the bound loop reduce missed items?
   - Which actions recur (Todoist routing, note-saving, follow-ups)?

## The surface is the test — no parallel full-content channel

**Do not run Telegram as a parallel full-content channel during the test.** The earlier "keep Telegram live, apples-to-apples" framing was a trap: Telegram *pushes the full digest to the lock screen*, so the user reads it there and never opens a silent second app to re-read it. That isn't apples-to-apples — it's home-field advantage for the incumbent, and it guarantees a null result while leaving the loop (which lives only in the app) untested.

Instead:
- **The app is the sole surface for content and answers.** The only notification is the app's own **thin push, gated on open loops** — "an agent needs you," never the digest body. Pure-information digests don't push; they wait to be pulled.
- Telegram may keep firing for *unrelated* Hermes traffic, but the digests under test go to the app, not to a parallel full-content Telegram message.

### Seed the habit before measuring it

A brand-new app with no chat crutch needs a cue, and habits need a few days to form. So:
- **Add the app to the home screen on day one** — the icon is a deliberate, real cue (and the seed of the widget).
- Treat the **first few days as a seeding period** (commit to opening it at a fixed daily moment). Start the "unprompted" measurement *after* seeding — otherwise you're measuring cold-start friction, not steady-state value.

## Success criteria (the M1 gate — proceed to M2 if ≥4 of 5)

- Daniel checks it most days without being reminded (after the seeding period).
- It reduces reliance on chat for reviewing agent output.
- It makes at least 3 recurring digests easier to review.
- It prevents missed action items/questions.
- He answers at least some agent questions through the bound loop (in-app or widget) instead of free-text chat.

## Kill / pause criteria (the honest gate)

- If after two weeks Daniel does **not** reach for the app unprompted, **stop at M1** — do not build the public layer (demo/TLS/privacy/relay-for-strangers) or widen to generic webhooks. Single-user pull is the real killer, and M1 is the cheapest place to learn it.
- If the only value is "prettier notifications" (no behavior change, loop unused), the differentiation has collapsed → pause and rethink.

Because M1 gates M2, a null result costs M1, not the whole four-artifact public build.

## Public validation (only after M1 pull sticks)

- The built-in **demo mode** *is* the loop-demo artifact: agent asks → tap answer on the home-screen widget → companion acts. Post it to X / AI-builder communities — far more compelling than a card-list screenshot.
- Ask where people currently send recurring agent outputs.
- Collect example digests people want to route in.
- Test willingness to self-host the companion (the audience already self-hosts Hermes) and interest in the emitter kit.
