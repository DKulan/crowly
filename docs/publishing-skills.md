# Publishing the Crowly skills to the Hermes Skills Hub

How the two Crowly skills — `setup-crowly` and `emit-crowly-digest` — get onto
the Hermes Skills Hub so a stranger can `hermes skills install DKulan/setup-crowly`
and their agent takes it from there. This is the M2 distribution path
(`docs/roadmap.md` § M2 step 7); it replaces "clone the monorepo and copy the
folder in."

Reference: the Hermes skills-authoring guide,
<https://hermes-agent.nousresearch.com/docs/developer-guide/creating-skills>
(§ *Publishing Skills*, § *Security Scanning*).

## The distribution shape

A hub-published skill is **only the skill folder** — `SKILL.md` + `scripts/`.
It does **not** carry the companion service (`companion/`, `emitter/crowly_emit.py`).
So the two skills are published as standalone units, and `setup-crowly` fetches
the companion source itself at install-run time:

- **`setup-crowly`** → Step 0 runs `scripts/fetch_companion.py`, which clones the
  Crowly repo at a **pinned ref** into `$CROWLY_REPO`. `provision.py` builds the
  companion from that checkout. The clone is a pinned, reviewable commit — not a
  live-run of remote instructions.
- **`emit-crowly-digest`** → self-contained (its `scripts/crowly_emit.py` is
  stdlib-only and bundled). Its `CROWLY_COMPANION_URL` / `CROWLY_TOKEN` are
  declared as `required_environment_variables`, so Hermes prompts + passes them
  into the sandbox on load.

## Prerequisites (once)

- `hermes` CLI installed and authenticated to the account that will own the
  published skills.
- The Crowly repo **public** on GitHub (`github.com/DKulan/crowly`) — the hub
  install and `fetch_companion.py`'s clone both need public read.
- A **release tag cut** on the repo (see the pin step below) — hub installs
  should build a known commit, not a moving `main`.

## Step 1 — Pin the ref (do this BEFORE publishing)

`fetch_companion.py` defaults to `DEFAULT_REF = "main"`. Before publishing, cut a
release tag and make the skill install pin to it:

1. Tag the repo: `git tag v1.0.0 && git push origin v1.0.0`.
2. In `emitter/hermes-skill/setup-crowly/scripts/fetch_companion.py`, set
   `DEFAULT_REF = "v1.0.0"` (or ensure `SKILL.md`'s Step 0 passes
   `--ref v1.0.0`, which it does). Keep the tag and the SKILL.md example in sync.

Why: the whole "pinned + reviewable" promise (`docs/onboarding.md` security rule)
depends on a stranger's agent building a *specific* commit. An unpinned `main`
clone reintroduces the live-URL footgun the rule exists to prevent.

## Step 2 — Publish each skill

```bash
# from the repo root
hermes skills publish emitter/hermes-skill/setup-crowly       --to github --repo DKulan/crowly
hermes skills publish emitter/hermes-skill/emit-crowly-digest --to github --repo DKulan/crowly
```

(If publishing to a dedicated skills repo instead of the monorepo, point
`--repo` there and adjust the install identifiers below to match.)

Users then add the tap and install:

```bash
hermes skills tap add DKulan/crowly           # optional — makes them searchable
hermes skills install DKulan/setup-crowly
```

## Step 3 — Expect the security scan

Hub-installed skills run through Hermes's security scanner (data exfiltration,
prompt injection, **destructive commands, shell injection**). Our scripts were
built to pass it — this is *why* the design choices matter, not incidental:

- **No `shell=True`, no untrusted input on argv** — every subprocess call in
  `detect_host.py` / `provision.py` / `render_pairing.py` / `fetch_companion.py`
  uses a list argv (confirmed in the security review, `docs/deployment-learnings.md`
  § Pre-deploy gate).
- **`provision.py` is plan-first** — prints its plan, only mutates under
  `--apply`, never auto-runs human-in-the-loop steps.
- **No secret ever hits an argv or a network endpoint** — `render_pairing.py`
  keeps `CROWLY_PAIR_ENABLED` off and renders the QR locally; the token is
  written 0o600.
- **`fetch_companion.py` clones a pinned ref over HTTPS** and verifies the
  checkout before returning — no curl-pipe-to-shell.

Trust tier: a first publish lands as **community** (non-dangerous findings can be
`--force`'d; dangerous verdicts stay blocked). If a dangerous verdict fires,
that's a real finding — fix it, don't force it.

## Step 4 — Re-publish on change

Bump the skill `version:` in its `SKILL.md` frontmatter, cut a new repo tag if
the companion source changed, update `DEFAULT_REF`, and re-run the `publish`
commands. Keep the SKILL.md `--ref`, `fetch_companion.py`'s `DEFAULT_REF`, and
the git tag all pointing at the same release.

## Pre-publish checklist

- [ ] Repo is public.
- [ ] Release tag cut; `fetch_companion.py` `DEFAULT_REF` + SKILL.md `--ref` match it.
- [ ] `security-reviewer` run over both skills (process gate, `docs/deployment-learnings.md`).
- [ ] Both `SKILL.md` frontmatters valid (name, description ≤1024, `platforms: [macos, linux]`).
- [ ] `hermes chat --toolsets skills -q "use setup-crowly ..."` smoke-tested (the guide's Test-It step).
- [ ] A real fresh-host dry-run done at least once (the Tier-2 test) before the public "just tell your agent" claim.
