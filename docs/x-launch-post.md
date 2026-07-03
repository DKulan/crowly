<!--
DRAFT X / Twitter copy targeting Hermes agent users (2026-07-03).
Two options: a single post and a thread. Pick one. Placeholders in «...».
Honest-status caveats at the bottom — read before posting.
-->

# Option A — Single post

Your Hermes agent already writes you a morning briefing, a weather note, a weekly
digest of *something*.

Then it dies in a Telegram scroll.

Crowly is a clean iOS inbox for it. And you don't install it — your agent does:

  hermes skills install DKulan/setup-crowly

then: "set up Crowly on this host."

Self-hosted. We never see your data. 🧵👇

---

# Option B — Thread

**1/**
If you run a Hermes agent, you have this problem:

it produces genuinely useful stuff on a schedule — briefings, weather, scrapes,
reminders — and all of it lands somewhere you've trained yourself to ignore.

Crowly gives that output a home. A quiet iOS inbox. 🧵

**2/**
It's a *reader*, not another chat surface.

Open it → read what came in → archive → done. A home-screen widget shows the
latest without opening anything.

No feed. No algorithm. No notifications yelling at you.

**3/**
The part that matters for you specifically:

**you don't set it up. Your agent does.**

    hermes skills install DKulan/setup-crowly

then just say: "set up Crowly on this host." It's a skill off the Hermes Skills
Hub — security-scanned, pinned, reviewable.

**4/**
Your agent then:

• looks at the host & picks the right approach (Docker or not, server or laptop)
• stands up a tiny companion service
• gives it HTTPS via Tailscale Funnel — no domain, no ports, no certs
• shows you a pairing QR
• wires your cron jobs to emit into it

**5/**
Your part is 3 things:

1. install the app
2. click the tailscale login link your agent prints
3. scan the QR

That's it. Then any scheduled job can drop a digest into your inbox.

**6/**
And it's *yours*.

There's no Crowly server. Digests live on your host. The app talks straight to
your box over HTTPS that terminates on your own machine — we never have anything
in the middle to see.

**7/**
The installer is a pinned, reviewable skill off the Skills Hub — Hermes
security-scans it, and you can read the code before your agent runs it. No
curl-pipe-to-shell mystery meat.

  hermes skills install DKulan/setup-crowly

«link» — give your agents an inbox.

---

# Suggested visual
- A screen recording: type the "set up Crowly" prompt to Hermes → plan prints →
  QR appears → phone scans → inbox goes live. The "my agent did the install" beat
  is the whole hook; show it.
- Or a simple before/after: buried Telegram scroll → clean Crowly inbox + widget.

<!--
STATUS / HONESTY CHECK before posting (blockers, roughly in order):
- `hermes skills install DKulan/setup-crowly` only works once the skills are
  PUBLISHED to the hub (docs/publishing-skills.md) AND the repo is PUBLIC — both
  the hub install and the skill's own companion-clone need public read. Neither
  is done yet. Until then this command 404s; don't post it.
- Pin the release tag first (docs/publishing-skills.md Step 1): fetch_companion.py
  must default to a real tag, not `main`, or the "pinned, reviewable" claim in
  tweet 7 is false.
- The app is on TestFlight, not a public App Store listing yet (roadmap M2 §10).
  "install the app" implies a public download — wait for the listing, add a
  TestFlight join link, or frame as early-access/waitlist.
- The full Docker+Funnel+crowly-net branch hasn't had a fresh-host stranger
  dry-run yet (Tier-2 test). Do it before the public "just tell your agent"
  claim, so the demo matches reality.
- Net: every claim is true-by-design today EXCEPT the three above (publish,
  public repo, TestFlight). Clear those, then post.
-->
