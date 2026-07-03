# Deployment learnings — the first real single-user deploy

This doc captures the **actual, end-to-end deploy** of the M1 stack onto a real
VPS + real iPhone (2026-06-30), done by hand. It exists for one reason: the M2
goal is a **seamless "download the app, ask Hermes to set up Crowly" install**
(`docs/roadmap.md` M2 §7, "stranger onboarding"), and this is the ground-truth
runbook + the catalog of every snag that install flow must handle. **The
`setup-crowly` skill should encode the fixes below, not rediscover them.**

Companion of `docs/onboarding.md` (the clean per-step runbook). This doc is the
*war story* — what actually happened, why, and the fix.

> **This is ONE topology, not the only one.** Everything below is accurate for
> the setup it describes: a **VPS + Docker + existing proxy**, deployed by hand.
> But future users run **heterogeneous** setups — some on a personal computer,
> some on a VPS *without* Docker, some (like this one) on a VPS with Docker. The
> companion is dependency-free Python 3 + sqlite3 and runs as a bare process via
> `python3 -m companion` (`companion/server.py`); **Docker is a packaging
> convenience, not a requirement**, and the `crowly-net` / container-networking
> material below is one topology's problem, not a universal one. The
> `setup-crowly` installer must **detect the host shape and adapt** (see § *What
> the setup-crowly skill must do*), not hard-code this path. Keep the war story
> as-is — it's the ground truth for its topology — but read it as *one branch*
> the installer must handle, alongside the no-Docker and laptop branches. The
> topology matrix lives in `docs/onboarding.md` § *Where the companion can run*.

## The environment we deployed into (a realistic target)

- **VPS:** Hostinger VPS, root SSH. Already ran **Traefik** (owning :80/:443) and a
  **Hostinger-managed Hermes agent** (which is **Claude Code in a container**,
  image `ghcr.io/hostinger/hvps-hermes-agent`, data at `/docker/hermes-agent-gfvn/data` → `/opt/data`).
- **Phone:** real iPhone, app delivered via **TestFlight** (paid Apple Developer account).
- **Domain:** user owned `knight.email` but we ended up **not** using it (see TLS pivot).

This matters: the target user is a **self-hoster who already runs other
dockerized services behind a proxy**. That means port conflicts and
container-to-container networking are the *norm*, not the exception. An installer
that assumes a bare VPS will fail on contact.

## The path that actually worked (final state)

```
iPhone (TestFlight) ──HTTPS──▶ Tailscale Funnel ──▶ companion :8787 (VPS)
Hermes container ──http://crowly-companion:8787──▶ companion   (shared docker net)
```

1. **Companion** runs via `companion/docker-compose.local.yml` — binds
   `127.0.0.1:8787`, joined to an external shared network `crowly-net`.
2. **TLS for the phone**: **Tailscale Funnel** (`tailscale funnel --bg 8787`) →
   public `https://<node>.<tailnet>.ts.net`. No domain, no DNS, no Let's Encrypt.
3. **Pairing**: manual URL + token entry in the app → Keychain.
4. **Emit**: Hermes runs the bundled **`emit-crowly-digest` skill** →
   `scripts/crowly_emit.py` → `http://crowly-companion:8787/ingest` over the
   shared docker network. Env vars in Hermes's compose `.env`.
5. **Recurring**: `hermes cron create` jobs (Harmony weekly, morning briefing),
   `skills: ["emit-crowly-digest"]`, delivery = Crowly only (not Telegram).

## The snags, in order — each is an M2 installer requirement

### 1. Companion isn't a single self-contained folder
The Dockerfile does `COPY companion/ … COPY emitter/ …` — the companion imports
`crowly_emit.validate` from the emitter as its single source of truth. So you
**cannot `scp` just `companion/`**; the build needs the repo layout (`companion/`
+ `emitter/` under a shared parent). We ended up with `/docker/crowly/{companion,emitter}`.
- **M2 status:** *largely moot for the chosen install model.* `setup-crowly`
  ships as a **repo checkout**, which already puts `companion/` + `emitter/`
  under a shared parent — the exact layout the build needs. So the two-folder
  dependency doesn't bite the automated install. A **published image**
  (`docker pull`) or a self-contained tarball is deferred as an *optional*
  convenience — worth it only if cloning the full monorepo proves to be real
  friction for strangers, and even then a sparse tarball beats an image +
  registry + signing pipeline. Note the coupling is intentional: the companion
  imports `crowly_emit.validate` so validation has one source of truth —
  "fixing" it by making `companion/` standalone would fork the validator.

### 2. Port 80/443 already taken (Traefik)
The bundled Caddy compose (`docker-compose.yml`) binds :80/:443 →
`address already in use` because Traefik owned them.
- **Fix used:** `docker-compose.traefik.yml` (drop Caddy, route via existing
  Traefik labels) — but we then abandoned it for the tunnel (see #3).
- **M2 requirement:** the installer must **detect an existing reverse proxy**
  and pick a TLS strategy accordingly (Traefik labels / tunnel / bundled Caddy).

### 3. Domain + Let's Encrypt is the biggest friction — the tunnel removes it
The domain path (`crowly.knight.email` → Traefik → LE) got stuck on a
transient **Let's Encrypt `503 rateLimited`**, and more fundamentally required
owning + pointing a domain. **Pivoting to Tailscale Funnel eliminated the entire
class of problem**: no domain, no DNS A record, no ACME, no open ports.
- **M2 decision (important):** **Tailscale Funnel should be the default TLS
  strategy for the agent-driven install.** It's the one path an agent can
  realistically drive (one `tailscale up` auth), and its privacy profile is
  *better* than Cloudflare Tunnel — TLS terminates on the user's own node, so
  the provider never sees digest plaintext ("content stays on your server"
  holds). Domain+proxy stays the power-user option.

### 4. `.ts.net` URL fails TLS from *inside* the tailnet
The **emitter on the VPS** (and Hermes) hitting the public Funnel URL got
`SSL: CERTIFICATE_VERIFY_FAILED: self-signed certificate` — because from inside
the tailnet, MagicDNS resolves the name to the node's *internal* cert, not the
public Funnel cert.
- **Fix:** local/co-located emitters must use **plain HTTP to the companion
  directly** (`127.0.0.1:8787` from the host; `http://crowly-companion:8787`
  from a sibling container) — never the Funnel URL. The Funnel URL is **only**
  for the external phone.
- **M2 requirement:** the installer must configure the emitter with the
  *internal* address, and the *app* with the *external* Funnel URL. Two
  different addresses for the same companion.

### 5. Container can't reach host loopback (the networking crux)
Hermes runs in its own container. `127.0.0.1:8787` there = Hermes, not the host.
`host.docker.internal` / the bridge gateway didn't resolve/route either. Hermes
has **no Docker socket**, so it can't fix its own networking.
- **Fix:** an **external shared Docker network `crowly-net`**, joined by BOTH
  the companion compose and the Hermes compose. Then Hermes reaches the
  companion by service name: `http://crowly-companion:8787`.
- **Hermes compose is Hostinger-managed** → don't edit it directly (updates
  overwrite it); use a **`docker-compose.override.yml`** to add the network,
  and **preserve `default`** (Traefik routes over it — dropping it breaks Hermes).
- **M2 requirement:** the installer must create the shared network and attach
  both containers, via an override for any managed compose. This is the single
  hardest step and the one most likely to need host-level (not in-container) action.

### 6. App Store archive validation (one-time, per the app not per user)
First TestFlight upload failed validation: missing app icon (empty AppIcon
catalog → no 120×120, no `CFBundleIconName`), plus iPad icon/orientation errors
because the app defaulted to universal.
- **Fix:** added a real 1024×1024 icon; set `TARGETED_DEVICE_FAMILY=1`
  (iPhone-only). Also `DEVELOPMENT_TEAM` + automatic signing in `project.yml`
  (not Xcode GUI — xcodegen regenerates the project). Bumped
  `CURRENT_PROJECT_VERSION` per re-upload.
- **Not a per-user step** — this is app-distribution, handled once by us. Noted
  so the App-Store-submission checklist (M2 §10) doesn't re-trip it.

### 6b. TestFlight upload path — App Store Connect API key, not the Xcode GUI
Uploads are CLI-driven (scriptable, no Organizer). Each upload:
1. Bump `CURRENT_PROJECT_VERSION` in `project.yml` (`MARKETING_VERSION` stays), `xcodegen generate`.
2. `xcodebuild … -destination 'generic/platform=iOS' -archivePath build/Crowly.xcarchive -allowProvisioningUpdates archive`
   (the App Group + keychain-access-group entitlements auto-register on archive).
3. `xcodebuild -exportArchive -archivePath build/Crowly.xcarchive -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates -authenticationKeyPath <p8> -authenticationKeyID <id> -authenticationKeyIssuerID <issuer>`
   (`ExportOptions.plist`: method `app-store-connect`, destination `upload`, signingStyle `automatic`).
- The ASC API key `.p8` is **downloaded-once and lives outside the repo** (never committed; `.gitignore` already covers `*.key`/`.env`, but the `.p8` must not land in the tree either). Key ID + Issuer ID are account-level.
- Post-upload is manual in the ASC web UI: add the build to the internal tester group (no App Review needed for internal testing); answer the one-time export-compliance prompt (HTTPS-only → exempt).

### 6c. Companion redeploy — the VPS is now a git checkout (was scp)
`/docker/crowly` on the VPS is a **git checkout of the monorepo** (converted from
the earlier scp copy). Redeploy is:
```
cd /docker/crowly && git pull origin main
cd /docker/crowly/companion && docker compose -f docker-compose.local.yml up -d --build
```
Three traps this fixes vs. the old scp flow: (1) compose files live under
`companion/` (build `context: ..` needs the repo root with both `companion/` +
`emitter/`); (2) the code is `COPY`'d into the image, so `--build` is required —
a plain `restart` reruns stale code; (3) you MUST pass
`-f docker-compose.local.yml` (the Tailscale-Funnel variant) — a bare
`docker compose` picks the Caddy `docker-compose.yml` and dies on the unset
`CROWLY_DOMAIN`. `.env` is gitignored, so pulls never touch the pairing token.

## What the `setup-crowly` skill must do (derived requirements)

> **Built (2026-07-03).** The skill now exists at
> `emitter/hermes-skill/setup-crowly/` and encodes the fixes below rather than
> rediscovering them.
>
> **Distribution is Skills-Hub-based, not "clone + copy."** Both skills are
> published to the Hermes Skills Hub (`hermes skills publish … --to github
> --repo DKulan/crowly`) and installed with `hermes skills install
> DKulan/setup-crowly` / `DKulan/emit-crowly-digest`; hub installs are
> security-scanned by Hermes. A hub-published skill is only `SKILL.md` +
> `scripts/` — it does *not* carry the companion service — so `setup-crowly` now
> fetches the companion source itself via a **pinned clone** (`scripts/fetch_companion.py`
> checks out a release tag; snag #1's repo-checkout layout is satisfied by that
> clone). Full publish runbook: **`docs/publishing-skills.md`**.
>
> Map of derived-requirement → where it's satisfied:
> - **Detect the host shape / branch** → `scripts/detect_host.py` (read-only JSON
>   verdict: docker daemon reachable, VPS-vs-laptop guess, :80/:443 contention,
>   tailscale logged-in, python/sqlite3) → `recommendation.run_mode` + `tls` +
>   `always_on_caveat`. Answers exactly the questions this section enumerates.
> - **Three run branches (snags #1, #5)** → `scripts/provision.py`:
>   `docker` (creates `crowly-net`, brings up `docker-compose.local.yml`, and
>   writes a `docker-compose.override.yml` that attaches the agent container
>   **preserving the `default` network** — snag #5), `bare-systemd` (a boot +
>   restart-on-failure unit for a no-Docker VPS/desktop), and `bare-foreground`
>   (ad-hoc laptop). Plan-first: prints the plan, only mutates under `--apply`.
> - **Tailscale Funnel as default TLS (snag #3)** → SKILL.md Step 3; provision.py
>   defaults `tls: funnel`.
> - **Internal vs. external address (snag #4)** → provision.py + SKILL.md wire the
>   emitter/agent to `http://crowly-companion:8787` (docker) / `127.0.0.1:8787`
>   (bare) and the phone to the external Funnel URL; the plan print warns loudly
>   about mixing them.
> - **Always-on caveat (laptop branch)** → surfaced by detect_host.py's
>   `always_on_caveat` and repeated in the bare-foreground plan.
> - **Install `emit-crowly-digest` + starter cron** → SKILL.md Step 5.
>
> **Security improvement over this war story's pairing flow.** The manual runbook
> below (§ *Runbook: rotate the pairing token*) flips the network `/pair`
> endpoint **on**, pairs, then relies on the operator to flip it back **off** —
> and any window it's open leaks full read+ingest access, because the public
> Funnel hostname is discoverable in Certificate Transparency logs (the P0 in
> § *Pre-deploy gate*). `scripts/render_pairing.py` **sidesteps that entire
> class**: it mints the token (idempotently), writes it + the public URL to the
> companion env file, **forces `CROWLY_PAIR_ENABLED` off**, and renders the
> `{companion_url, pairing_token}` QR **locally on the host** (qrencode, with a
> URL+token manual fallback). The secret moves host → phone via the scanned QR;
> the unauthenticated `/pair` endpoint never has to open. Prefer this to the
> flip-on/flip-off dance whenever the skill is available.
>
> Deferred, not blocking (not the skill's job): a **published companion image**
> (snag #1). The install works off a repo/git checkout, which already supplies
> the `companion/` + `emitter/` sibling layout — so the image is an *optional*
> convenience, revisited only if the full-monorepo clone becomes real friction
> (then a sparse tarball is the likelier fix than an image + registry pipeline).

**First requirement: detect the host shape and branch — don't assume this
topology.** The steps below are the VPS+Docker branch (the one deployed); the
installer must first figure out which world it's in and adapt. It must **not** be
built VPS+Docker-only:

- **Docker present?** If yes, the containerized path below. If no (a no-Docker
  VPS or a personal computer), run the companion as a **bare process** —
  `python3 -m companion`, env-var configured — behind a systemd unit for an
  always-on host. Docker is a packaging convenience, not a requirement; the
  container-networking snags (#5, `crowly-net`) simply don't exist on the bare
  path.
- **VPS or laptop?** If the host is a **personal computer that sleeps**, the
  installer must **surface the always-on caveat** (pull-only → a sleeping
  companion can't be pulled; the app/widget show the last snapshot until it
  wakes — `docs/onboarding.md` § *Where the companion can run*). It must not
  silently hand the user a companion that's unreachable half the day. Push is
  deferred (`docs/roadmap.md` Phase 4); it is **not** the fix to offer here.
- **Existing reverse proxy?** As in #2 — Traefik/nginx owning :80/:443 → route
  via labels rather than colliding with a bundled Caddy.
- **Cross-topology TLS default: Tailscale Funnel.** It's the one path that
  spans a VPS, a no-Docker VPS, and a NAT'd home machine (no domain/DNS/ACME/open
  ports), and the one an agent can realistically drive with a single auth click.

Given host Docker access, an agent *can* automate most of the **VPS+Docker
branch**:
1. Get the companion code onto the host — the skill's Step 0
   (`scripts/fetch_companion.py`) clones the repo at a **pinned ref**, which
   supplies the `companion/` + `emitter/` layout — snag #1 doesn't bite; no
   published image needed.
2. **Detect the environment**: Docker present? existing proxy? Tailscale present?
   VPS vs. laptop? → pick the run mode + TLS strategy per the branching above.
3. **Default to Tailscale Funnel** (#3): install tailscale, `tailscale up` (one
   human auth click), `tailscale funnel --bg 8787`, capture the public URL.
4. Create `crowly-net`, run the companion on it, attach the agent container via
   an override (#5). *(Docker branch only — the bare-process branch skips this;
   a co-located emitter just POSTs to `127.0.0.1:8787`.)*
5. Generate the pairing token; write the **internal** address to the agent's
   emit env (#4) and surface the **external** Funnel URL + token as the pairing
   QR.
6. Install the `emit-crowly-digest` skill (already built, self-contained). The
   emitter is stdlib-only Python (`emitter/crowly_emit.py`) — it runs anywhere
   Python runs (container-Hermes, a laptop cron, a systemd timer, any script);
   all it needs is the companion URL + bearer token.

**The irreducibly-human steps** (even at M2, cannot be automated away):
- Install the app (App Store tap).
- The **one tunnel auth click** (`tailscale up` / provider login).
- The **pairing scan** — a secret moving server→phone; the agent can present
  the QR but can't write it into the phone Keychain. Deliberate security boundary.

Realistic M2 ceiling: **"download app → ask Hermes → click one auth → scan one
QR."** Not zero-touch, but a world away from the manual path in this doc.

## Security rule carried from earlier

The `setup-crowly` skill must be a **pinned, reviewable skill** — never "tell
the agent to fetch and run instructions from a live URL." A compromised/spoofed
page would run arbitrary commands on the user's VPS. Pin it, review the diff, run it.

## Pre-deploy gate: run the security reviewer

**Before any companion deploy or redeploy, run the `security-reviewer` teammate
over the companion + emitter changes.** This is a process gate, not automation —
kept deliberately low-noise. It exists because the first deploy shipped a live
credential leak: `GET /` and `GET /pair` returned the bearer token
unauthenticated, reachable over the public Tailscale Funnel hostname (public
HTTPS names appear in Certificate Transparency logs, so the URL is not secret).
The reviewer's job is to confirm no unauthenticated endpoint returns a secret,
pairing exposure is default-off (`CROWLY_PAIR_ENABLED`) and gated, and the
pairing token has a rotation story. Don't deploy with unresolved P0/P1 findings.

## Runbook: rotate the pairing token

The token that lived behind the ungated `/pair` on the first deploy must be
treated as **compromised** (public Funnel URL → CT logs → anyone could have
pulled it). This is the concrete rotation procedure; run it once now to burn the
exposed token, and again anytime a token has been exposed (log paste, screenshot,
misfired curl, suspected compromise).

1. **Generate a new token** on the VPS and put it in `/opt/data/.env`:
   ```
   CROWLY_PAIRING_TOKEN=<paste of `openssl rand -hex 32`>
   ```
   Same file for `CROWLY_PAIR_ENABLED` — leave it **unset (or false)** for
   normal operation. Only flip it to `true` for the brief pairing window below,
   then unset it again.
2. **Restart the companion** so it picks up the new token:
   `docker compose -f docker-compose.local.yml up -d --force-recreate`.
   Confirm: `curl -s <funnel-url>/pair` should return **404** (pairing disabled).
3. **Open the pairing window, re-pair the phone, close it.** Set
   `CROWLY_PAIR_ENABLED=true` in `/opt/data/.env`, restart the companion,
   fetch `<funnel-url>/pair` once to get `{companion_url, pairing_token}`, enter
   them in the app (Keychain overwrites the old token). Then **unset
   `CROWLY_PAIR_ENABLED` and restart again** — leaving it on is the same leak
   we just fixed.
4. **Update the emitter's env** so cron emits keep working: `CROWLY_TOKEN` in
   the Hermes compose `.env` (or wherever the `emit-crowly-digest` skill reads
   its token). Restart/redeploy Hermes so the skill picks it up.
5. **Verify end-to-end:**
   - `curl -s <funnel-url>/pair` → non-200 (404) — pairing is off.
   - Paired app can read `/list` — old token is dead, new token works.
   - Trigger a Hermes emit (or wait for the next cron) — the digest lands in
     the app inbox, proving the emitter has the new token too.

Any step that 401s is the signal: something is still holding the old token.
Track it down before re-enabling pairing.
