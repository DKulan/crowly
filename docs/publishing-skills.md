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
  install and `fetch_companion.py`'s clone both need public read. ✅ *(public as of 2026-07-03)*
- A **release tag cut** on the repo (see the pin step below) — hub installs
  should build a known commit, not a moving `main`. ✅ *(`v1.0.0` cut + set as latest release, 2026-07-03)*

## Step 1 — Pin the ref (do this BEFORE publishing) ✅ done for v1.0.0

Both the tag and the pin are in place for the first release:

1. Tag cut + pushed: `v1.0.0` → commit `e18eec9`, set as the latest release.
2. `emitter/hermes-skill/setup-crowly/scripts/fetch_companion.py` now sets
   `DEFAULT_REF = "v1.0.0"`, and `SKILL.md`'s Step 0 already passes
   `--ref v1.0.0` — tag, script default, and SKILL.md example are in sync.

   *(Note: this `DEFAULT_REF` edit landed just after the `v1.0.0` tag, so the
   tag's own copy still reads `main`. Harmless — SKILL.md Step 0 passes
   `--ref v1.0.0` explicitly, and the companion source at the tag is complete;
   the fix rides in the next release. Don't move a published tag over it.)*

For **future** releases, redo this step: cut the new tag, bump `DEFAULT_REF` +
the SKILL.md `--ref` to match (see § Step 4).

Why: the whole "pinned + reviewable" promise (`docs/onboarding.md` security rule)
depends on a stranger's agent building a *specific* commit. An unpinned `main`
clone reintroduces the live-URL footgun the rule exists to prevent.

## Step 2 — Publish each skill

```bash
# from the repo root
hermes skills publish emitter/hermes-skill/setup-crowly       --to github --repo DKulan/crowly
hermes skills publish emitter/hermes-skill/emit-crowly-digest --to github --repo DKulan/crowly
```

Use the **path form**, not the bare skill name — the bare name can resolve to a
previously-installed (stale) copy instead of the checkout.

The publish step also needs **GitHub write auth** on the host running `hermes`
(it pushes to `--repo`): either `gh auth login`, or `GITHUB_TOKEN` in the
`~/.env` the CLI names in its error. Use a **fine-grained PAT scoped to the one
repo, Contents: read+write** — it sits in a plaintext env file on that host, so
give it nothing more.

**What publish actually does (observed 2026-07-03):** it does *not* push to
`main` — it opens a **pull request** that adds the skill folder (verbatim copy)
under a top-level `skills/<name>/` directory, the layout the hub tap reads.
**Merging that PR is the publish.** Review it (should be additions-only,
byte-identical to the source folder) and merge as the personal account.
`setup-crowly` v1.0.0 landed via PR #1.

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

**The real v1.0.0 scan outcome (2026-07-03):** the first attempt hit
**DANGEROUS** on two CRITICALs — a commented `curl … | sh` install example and a
"persist `CROWLY_TOKEN` in `~/.hermes/.env`" instruction. Both were real
findings and were fixed (package-manager install guidance; Hermes's own
`required_environment_variables` secret flow), not forced. The re-scan verdict
is **CAUTION** with ~18 findings — all inherent to what an installer skill *is*
(list-argv `subprocess.run`, `127.0.0.1:8787` bind addresses, the systemd unit
path, prose that mentions `sudo` for user-run steps). That residue is the
expected steady state: publish with `--force`, and treat any **new** CRITICAL
or a DANGEROUS verdict as a regression to fix.

*(CLI nit: the scanner's "Use `--force` to override" hint is misleading —
`hermes skills publish` has no `--force` flag. On a CAUTION verdict the
publish proceeds anyway and opens the PR; the "BLOCKED" decision line applies
to install-time gating, not to publishing.)*

**`emit-crowly-digest`'s scans (2026-07-03)** hit DANGEROUS twice, on three
patterns: `echo "$json" | python3 …` examples (reads as piping content into an
interpreter — "obfuscation"), the `--token` argv flag ("exfiltration" — and a
fair cop: argv is visible in `ps`), and then `os.environ.get("CROWLY_TOKEN")`
itself. Fixed honestly, not forced: examples rewritten around
`--content-file digest.json` (stdin still supported), the token made env-only
with the `--token` flag removed, and the env read switched to subscript access
(both copies of `crowly_emit.py` kept identical). Expected residue: one HIGH
"accesses os.environ" on the token read + MEDIUM network findings on the
internal `127.0.0.1:8787` addresses → CAUTION.

**Scanner mechanics (from source — the scanner is `tools/skills_guard.py` in
the open-source `NousResearch/hermes-agent` repo):** pure per-line regex, no
dataflow. Verdict = any CRITICAL → DANGEROUS (unpublishable); any HIGH →
CAUTION (publishable, findings shown at install); MEDIUM/LOW alone → safe.
Notably, `os.environ.get()`/`os.getenv()` of **any** var whose name contains
KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL is a flat CRITICAL with *no exemption*
for vars the skill declares in `required_environment_variables` — so a
community skill's Python must read a declared secret via subscript
(`os.environ["…"]`, a HIGH) or it can never publish. Don't rename a secret
var to dodge the keyword list — the HIGH finding staying visible is the
honest outcome.

**Pre-flight the scan locally** (no publish round-trip needed): download
`tools/skills_guard.py` from the hermes-agent repo and run
`scan_skill(Path("emitter/hermes-skill/<name>"), "self/community")` — it's
stdlib-only and reproduces the publish verdict exactly.

## Step 4 — Re-publish on change

Bump the skill `version:` in its `SKILL.md` frontmatter, cut a new repo tag if
the companion source changed, update `DEFAULT_REF`, and re-run the `publish`
commands. Keep the SKILL.md `--ref`, `fetch_companion.py`'s `DEFAULT_REF`, and
the git tag all pointing at the same release.

## Pre-publish checklist

- [x] Repo is public. *(2026-07-03)*
- [x] Release tag cut; `fetch_companion.py` `DEFAULT_REF` + SKILL.md `--ref` match it. *(v1.0.0, 2026-07-03)*
- [x] `security-reviewer` run over both skills (process gate, `docs/deployment-learnings.md`). *(2026-07-03; no P0, P2/P3 fixed)*
- [x] Both `SKILL.md` frontmatters valid (name, description ≤1024, `platforms: [macos, linux]`).
- [x] `hermes skills publish` run for both skills. *(2026-07-03 — setup-crowly
  via PR #1, emit-crowly-digest via PR #2; both merged, published copies live
  under `skills/<name>/` and verified byte-identical to
  `emitter/hermes-skill/<name>/`. Install identifiers `DKulan/setup-crowly` /
  `DKulan/emit-crowly-digest` still to be confirmed by the install smoke test
  below.)*
- [ ] `hermes chat --toolsets skills -q "use setup-crowly ..."` smoke-tested (the guide's Test-It step).
- [ ] A real fresh-host dry-run done at least once (the Tier-2 test) before the public "just tell your agent" claim.
