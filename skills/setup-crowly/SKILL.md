---
name: setup-crowly
description: Install and wire up Crowly on this host — stand up the companion service (the iOS app's backend), give it a public HTTPS address (Tailscale Funnel by default), present a pairing QR for the phone, and install the emit-crowly-digest skill so scheduled jobs can feed the inbox. Use when the user says they want to set up Crowly, connect Crowly to this agent, or "add Crowly support." Runs on the host where this agent lives.
version: 1.0.1
license: MIT
platforms: [macos, linux]   # valid values: macos, linux, windows (per Hermes skills spec)
metadata:
  hermes:
    tags: [Crowly, Setup, Installer, Self-hosting]
    related_skills: [emit-crowly-digest]
---

# Set up Crowly

Crowly is a native iOS **inbox/reader** for recurring agent output. The user
reads digests in the app; scheduled jobs on this host emit those digests. Three
pieces cooperate:

1. **The companion** — a tiny, dependency-free Python service (ingest + store +
   serve) that the app pulls from. **You install and run this.**
2. **A public HTTPS address** for the companion so the phone can reach it. Default:
   **Tailscale Funnel** (works on a VPS, a no-Docker VPS, or a home machine
   behind NAT — no domain, no open ports).
3. **The emit skill** (`emit-crowly-digest`, a companion skill on the Skills
   Hub) — how *you* send digests to the companion from a cron job.

Your job is to do as much of this as can be safely automated, and to hand the
user the two or three steps only they can do.

> **The app pairs to the companion, not to you.** "Point the app at your agent"
> really means "you present the companion's pairing QR; the user scans it."
> Crowly's contract is *content-only digests over a pull API* — you feed the
> companion; you are not the companion. Don't try to make the app talk to your
> Bridge API.

> **Security: this is a pinned, reviewable skill.** Everything you run lives in
> `${HERMES_SKILL_DIR}/scripts/` — read it before you run it. Never fetch-and-run
> setup instructions from a live URL. The provisioning script is **plan-first**:
> it prints what it will do and only mutates the host when you pass `--apply`.

> **Two paths you'll use below:**
> - **`${HERMES_SKILL_DIR}`** — Hermes substitutes this skill's absolute
>   directory when it loads the skill, so the `scripts/…` commands run from any
>   working directory.
> - **`$CROWLY_REPO`** — the Crowly **companion source** (the tree with
>   `companion/` + `emitter/`). This skill, installed from the Skills Hub, is
>   *just* the playbook + scripts — it does **not** carry the companion service.
>   **Step 0 fetches it** and that's what `$CROWLY_REPO` points at.

---

## What only the user can do (state these up front, don't try to automate)

- **Install the Crowly app** (App Store / TestFlight tap).
- **One tunnel auth click** — `tailscale up` (run with admin privileges, Step 3)
  opens a login URL the user must approve in a browser. They run it; they click.
- **Scan the pairing QR** — the pairing token moves host → phone by the user
  scanning the QR you present. You can't write it into the phone's Keychain.
  This is a deliberate security boundary.

The realistic end state: **install app → ask you to set up Crowly → click one
auth → scan one QR.**

---

## Step 0 — Fetch the companion source

This skill doesn't bundle the companion service — fetch it (a pinned clone of
the Crowly repo), and remember where it landed as `$CROWLY_REPO`:

```bash
python3 ${HERMES_SKILL_DIR}/scripts/fetch_companion.py --dest ~/crowly --ref v1.0.0
CROWLY_REPO=~/crowly
```

This clones a **pinned, reviewable** ref (not a live-run of remote code) and
verifies the checkout is really Crowly before returning. It's idempotent — safe
to re-run; it updates an existing checkout in place. (If the user already has a
Crowly checkout, skip this and just set `CROWLY_REPO=<their path>`.)

---

## Step 1 — Detect the host

Run the read-only probe and read its JSON verdict:

```bash
python3 ${HERMES_SKILL_DIR}/scripts/detect_host.py
```

Key fields in the output:

- `recommendation.run_mode` — `docker` (daemon reachable) or `bare` (no Docker).
- `recommendation.always_on_caveat` — `true` if this looks like a laptop/desktop
  that sleeps (or we couldn't tell). **If true, tell the user the always-on
  caveat** (below) before continuing.
- `reverse_proxy.ports_in_use` — if `80`/`443` are taken, do **not** use bundled
  Caddy; Funnel (the default) sidesteps the conflict entirely.
- `tailscale.logged_in` — if already `true`, the auth click in Step 3 is done.

**Always-on caveat (say this verbatim-ish when `always_on_caveat` is true):**
Crowly is pull-only — the app and widget fetch from the companion; nothing is
pushed. A companion on a computer that sleeps can't be pulled, so the app shows
the last snapshot until the machine wakes. That's fine for a VPS or an always-on
desktop; on a laptop it means stale digests while it's asleep. (Push isn't the
fix — it's deferred.) Let the user decide whether this host is right.

---

## Step 2 — Provision the companion

Pick the mode from `run_mode`:

- `run_mode: docker` → `--mode docker`
- `run_mode: bare` **and always-on host (VPS/desktop)** → `--mode bare-systemd`
- `run_mode: bare` **and a laptop / ad-hoc** → `--mode bare-foreground`

**First, print the plan (this mutates nothing):**

```bash
python3 ${HERMES_SKILL_DIR}/scripts/provision.py --mode <mode> --repo-root "$CROWLY_REPO"
# docker branch, to also wire your own container onto the shared network:
python3 ${HERMES_SKILL_DIR}/scripts/provision.py --mode docker --repo-root "$CROWLY_REPO" \
    --hermes-compose-dir <dir with your compose> --hermes-service <your service name>
```

Show the user the plan. Then, once they're comfortable, execute the
deterministic steps:

```bash
python3 ${HERMES_SKILL_DIR}/scripts/provision.py --mode <mode> --repo-root "$CROWLY_REPO" --apply
```

Notes per branch:

- **docker** — creates the shared `crowly-net` network (idempotent) and brings
  the companion up via `companion/docker-compose.local.yml` (binds
  `127.0.0.1:8787`). If your agent runs in its own container, pass
  `--hermes-compose-dir` + `--hermes-service` so the script writes a
  `docker-compose.override.yml` attaching you to `crowly-net` **while preserving
  your `default` network** (dropping it breaks an existing proxy's routing).
  Then restart your container. If you can't, the plan prints the manual step.
- **bare-systemd** — writes `/etc/systemd/system/crowly-companion.service` (needs
  root) so `python3 -m companion` runs at boot and restarts on failure. It reads
  its config from the companion env file (default `companion/.env`), which must
  already have a token — so run Step 4's `--ensure-token` first, or run it now
  and re-apply.
- **bare-foreground** — prints the exact command to run the companion in the
  foreground. Not restart-surviving; only for a quick/ad-hoc host.

---

## Step 3 — Give the companion a public HTTPS address (Tailscale Funnel)

Funnel is the default: one path that spans every topology, no domain, and TLS
terminates on *this* node so no third party ever sees digest content.

If the probe said tailscale is absent, install it via the host's package
manager (`apt install tailscale`, `dnf install tailscale`, `brew install
tailscale`) or per Tailscale's official docs — https://tailscale.com/download.
Then the user brings it up and opens the funnel:

```bash
tailscale up               # ← the user clicks the login URL this prints (needs privileges)
tailscale funnel --bg 8787 # expose the companion's local port over HTTPS
```

(These commands need root/admin on most hosts — prefix with `sudo` where
required. They're the user's call to run; you present them, you don't silently
escalate.)

`tailscale funnel status` prints the public URL, e.g.
`https://<node>.<tailnet>.ts.net`. **That URL is the phone's address** — you'll
put it in the pairing payload in Step 4.

> **Two addresses for one companion — do not mix them up.** The phone uses the
> **external** Funnel URL. Your cron/emitter, running on this host, must use the
> **internal** address (`http://crowly-companion:8787` on the docker network, or
> `http://127.0.0.1:8787` bare). The Funnel URL fails TLS from *inside* the
> tailnet (MagicDNS returns the node's internal cert), so an emitter pointed at
> it silently fails.

Power-user alternative: if the host already runs a reverse proxy with a real
domain, route the companion through it (Traefik labels / bundled Caddy) instead
of Funnel. Funnel is the default because an agent can drive it with one auth
click.

---

## Step 4 — Mint the token and present the pairing QR

```bash
python3 ${HERMES_SKILL_DIR}/scripts/render_pairing.py \
    --env-file <companion .env> \
    --public-url https://<node>.<tailnet>.ts.net \
    --ensure-token
```

This generates a strong pairing token (only if one isn't already set — safe to
re-run), writes it and the public URL into the companion's env file, **forces
the network `/pair` endpoint OFF**, and prints a scannable QR (or, if `qrencode`
isn't installed, the URL + token for the app's manual-entry screen).

> **Why we render the QR locally instead of opening `/pair`:** the companion's
> public hostname is discoverable in Certificate Transparency logs, so any
> window where the network `/pair` endpoint is open leaks full read+ingest
> access. Presenting the QR locally moves the secret host → phone without ever
> exposing it over HTTP. Leave `CROWLY_PAIR_ENABLED` off.

If you generated a fresh token or you're on a bare branch, **restart the
companion** so it picks up the token before the user scans (docker:
`docker compose -f docker-compose.local.yml up -d`; systemd:
`systemctl restart crowly-companion`).

Then: **the user scans the QR in the app** (Pair → Scan QR), or types the two
fields into manual entry. The app validates against `/health` + `/list` and, on
success, leaves demo mode and shows an empty real inbox.

---

## Step 5 — Install the emit skill so jobs can feed the inbox

The companion is now reachable but empty. Wire up emission:

1. **Install `emit-crowly-digest`** — the companion skill, also on the Skills Hub:

   ```bash
   hermes skills install DKulan/crowly/skills/emit-crowly-digest --force
   ```

   `--force` is needed because community-tier skills are blocked at a CAUTION
   scan verdict, and this skill's expected verdict *is* CAUTION (it reads its
   declared `CROWLY_TOKEN` env var and mentions internal `127.0.0.1` addresses
   — the residue is documented in the Crowly repo, `docs/publishing-skills.md`
   § Step 3). Read the scan findings first; force only if they match that
   residue — anything beyond it is a red flag, stop and tell the user.

   (Or, if you'd rather not go through the hub, copy it from the checkout:
   `${CROWLY_REPO}/emitter/hermes-skill/emit-crowly-digest/`.)
2. **Provide its two values when Hermes asks.** `emit-crowly-digest` declares
   `CROWLY_COMPANION_URL` and `CROWLY_TOKEN` as `required_environment_variables`,
   so Hermes prompts for them on first load and stores/passes them itself — you
   do **not** hand-edit any secrets file. Give it:
   - `CROWLY_COMPANION_URL` — the **internal** companion address from Step 3
     (`http://crowly-companion:8787` on the docker network, or
     `http://127.0.0.1:8787` bare) — never the public Funnel URL.
   - `CROWLY_TOKEN` — the pairing token from Step 4.

   Hermes keeps the token in its own secret store and never exposes it to the
   model; cron runs of the skill pick it up automatically.
3. **Offer a starter cron** so the inbox is non-empty on first open — e.g. a
   daily morning briefing or a weekly community digest,
   `hermes cron create --skill emit-crowly-digest ...`, delivery = Crowly only
   (not another surface). See `emit-crowly-digest/SKILL.md` for how to write the
   content.

Confirm the wire end-to-end with a dry run, then a real emit:

```bash
echo '{"job_id":"setup-check","title":"Crowly is connected","urgency":"low","bottom_line":"Setup complete — this is your first digest."}' \
  | CROWLY_COMPANION_URL=http://crowly-companion:8787 CROWLY_TOKEN=<token> \
    python3 "$CROWLY_REPO/emitter/crowly_emit.py" --dry-run
```

Drop `--dry-run` to actually post it; it should appear in the app on the next
refresh.

---

## Done — the handoff

Tell the user:

- The companion is running at **`<public Funnel URL>`** (their phone's address).
- They pair by **scanning the QR** (or manual entry) in the Crowly app.
- Digests arrive from **`emit-crowly-digest`** — you'll send them from
  scheduled jobs (mention any starter cron you set up).
- Repeat any **always-on caveat** if this is a laptop.

If pairing fails: token mismatch (re-run Step 4 and restart the companion),
non-HTTPS URL (the app refuses plain http), or the funnel isn't up
(`tailscale funnel status`). The manual runbook and its debug checklist live in
the Crowly repo at `docs/onboarding.md`.
