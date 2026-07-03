<!--
DRAFT blog post / public getting-started guide (2026-07-03).
Not a design doc — this is the friendly public version of docs/onboarding.md.
Written to match what the setup-crowly skill actually does today. Placeholders
marked with «...». Honest-status note at the bottom (TestFlight, repo URL).
-->

# Give your agents an inbox: setting up Crowly

Your agents already do useful work on a schedule. A morning news roundup. The
weekend weather. A weekly scrape of your town's council minutes. A reminder that
a domain is about to expire. The problem isn't producing that — it's *where it
lands*. Right now it's probably buried in a Telegram scroll or a folder of emails
you've trained yourself to ignore.

**Crowly is a quiet inbox for the things your agents produce.** A clean iOS
reader — open it, read what came in, archive it, done. A home-screen widget shows
the latest without you even opening the app. No feed, no algorithm, no
notifications screaming for a tap.

And it's **yours**. Crowly doesn't have a server. Your digests live on a small
service you run on your own host — the same host your agent already lives on.
Nothing we operate ever sees your content. The app talks *directly* to your box.

Here's how to set it up. If you already run a [Hermes](https://get-hermes.ai)
agent, it's about five minutes, most of which is your agent doing the work.

---

## What you're setting up

Three pieces, and you only touch two of them:

1. **The Crowly app** on your iPhone — the reader.
2. **The companion** — a tiny, dependency-free Python service (ingest + store +
   serve) that the app pulls from. *Your agent installs and runs this for you.*
3. **Your Hermes agent** — which you already have. It stands the companion up,
   gives it a public address, and starts feeding it digests from your scheduled
   jobs.

The whole trick is that **you point your agent at a skill, and the agent does the
plumbing.** You don't hand-edit config files or wrangle TLS certificates.

---

## Before you start

- A **Hermes agent** running on a host you control — a VPS, or a machine at home.
  (Crowly is pull-only, so if it's a laptop that sleeps, your digests pause while
  it's asleep. A VPS or an always-on desktop is the happy path.)
- An **iPhone** running iOS 26 or later.
- Five minutes.

---

## Step 1 — Install the app

Get Crowly from the App Store and open it once. It starts in **demo mode** — a
few canned digests so you can see the shape before you connect anything. Have a
look around; we'll connect it to your own agent in a moment.

## Step 2 — Install the setup skill

Crowly ships an installer as a **Hermes skill** on the Skills Hub. Install it the
way you install any skill:

```bash
hermes skills install DKulan/setup-crowly
```

It's pinned and reviewable — Hermes security-scans it on install, and you can
read `SKILL.md` and every script before your agent runs a thing. There's no
"curl this URL and hope."

*(Prefer to inspect it first from source? `git clone
«https://github.com/DKulan/crowly» ~/crowly` and read
`emitter/hermes-skill/setup-crowly/` — same code.)*

## Step 3 — Ask your agent to set it up

Now just tell Hermes:

> **"Set up Crowly on this host using the setup-crowly skill."**

Your agent will:

- **Look at the host** — is Docker here? Is this a server or a laptop? Is
  anything already using ports 80/443? — and pick the right approach. It'll show
  you its plan before it changes anything.
- **Stand up the companion** — as a Docker container if you run Docker, or as a
  plain background service if you don't.
- **Give it a public HTTPS address** using [Tailscale
  Funnel](https://tailscale.com/kb/1223/funnel) — no domain, no port-forwarding,
  no certificate wrangling. This is the one spot you step in: the agent runs
  `tailscale up`, and **you click the login link it prints**. The address it
  gets is HTTPS with a real certificate that terminates *on your own machine* —
  so even Tailscale never sees your digests.
- **Show you a pairing QR code** — right there in your terminal.
- **Wire up emission** — install the `emit-crowly-digest` skill and offer to set
  up a starter scheduled job so your inbox isn't empty on day one.

## Step 4 — Scan the QR

Open the Crowly app, tap **Pair → Scan QR**, and point it at the code in your
terminal. (No camera handy? The agent also prints the address and a pairing token
you can type into the app's manual screen.)

The app checks the connection, leaves demo mode, and shows your real inbox —
empty for now, waiting for your first digest.

## Step 5 — Watch it arrive

If you let the agent set up a starter job, your first real digest shows up on the
next run. Otherwise, ask Hermes to send a test:

> **"Emit a test Crowly digest."**

Within a refresh it'll appear in your inbox and on the widget. From here, point
any of your scheduled jobs at the `emit-crowly-digest` skill — a news job, a
weather job, whatever you already run — and it starts landing in Crowly.

---

## What just happened (and why it's private)

You now have a personal digest service running on your own host, reachable from
your phone over HTTPS, fed by your own agent. The pairing token that secures it
moved from your terminal to your phone by a QR you scanned — it never traveled
over an open endpoint. The certificate terminates on your machine. **We never
had a server in the middle, so there was never anything for us to see.**

Crowly is deliberately a *reader*. A digest is something you read, not a prompt
to act — no buttons, no callbacks. If a digest wants you to do something, it says
so in plain language, and you go do it wherever that work lives. Opening a digest
marks it read; archiving is the only other move. That's the whole app, on
purpose.

---

## If something goes sideways

- **The app won't pair.** Make sure the address is `https://…` (the app refuses
  plain HTTP for anything but localhost) and that the token matches. Re-running
  the pairing step regenerates the QR.
- **Digests aren't arriving.** Check that your scheduled job actually calls the
  `emit-crowly-digest` skill, and that it points at the *internal* address of the
  companion (your agent sets this up — it's not the public URL your phone uses).
- **Your host is a laptop.** Crowly can only show what it can reach. While the
  machine sleeps, the app shows the last digests it pulled and catches up when
  the machine wakes.

Your agent has the full runbook; if you get stuck, ask it to walk through the
setup again — it's the same skill either way.

---

<!--
STATUS NOTE (remove before publishing, or keep as a "beta" banner):

- `hermes skills install DKulan/setup-crowly` (Step 2) requires the skills to be
  PUBLISHED to the hub (docs/publishing-skills.md) and the repo PUBLIC. Neither
  done yet — the command 404s until then, and the skill's own companion-clone
  also needs public read.
- Pin the release tag first (docs/publishing-skills.md Step 1) so the "pinned"
  claim in Step 2 is true (fetch_companion.py must default to a tag, not `main`).
- The app is on TestFlight, not yet a public App Store listing (docs/roadmap.md
  § M2 step 10). Update Step 1 when the listing is live.
- Repo URL in Step 2's "inspect from source" aside is «...» → github.com/DKulan/crowly
  once public.
- Everything else matches what emitter/hermes-skill/setup-crowly/ actually does
  as of 2026-07-03.
-->
