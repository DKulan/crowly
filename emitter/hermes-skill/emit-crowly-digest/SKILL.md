---
name: emit-crowly-digest
description: Send a recurring digest (AI news, weather, community update, briefing, reminder) to the user's Crowly inbox app. Use at the end of a scheduled/cron job when you have a summary they should read in Crowly. You write the content; the bundled helper stamps the id/timestamp/version and POSTs it to the companion.
version: 1.0.0
license: MIT
platforms: [macos, linux]   # valid values: macos, linux, windows (per Hermes skills spec)
metadata:
  hermes:
    tags: [Crowly, Digest, Notification, Self-hosting]
    related_skills: [setup-crowly]
required_environment_variables:
  - name: CROWLY_COMPANION_URL
    prompt: "Crowly companion URL (internal address the emitter POSTs to)"
    help: "Docker: http://crowly-companion:8787 · bare process: http://127.0.0.1:8787 — NOT the public Funnel URL (that fails TLS from inside the tailnet)."
    required_for: "posting digests to the companion"
  - name: CROWLY_TOKEN
    prompt: "Crowly pairing token"
    help: "The same token the app paired with — setup-crowly minted it into the companion's .env."
    required_for: "authenticating to the companion"
---

# Emit a Crowly digest

Crowly is Daniel's iOS **inbox/reader** for recurring agent output. When a
scheduled job has produced something he should read — a news roundup, a weather
note, a weekly community digest, a reminder — emit it as a Crowly **digest** so
it lands in his inbox; he'll see it next time he opens the app or glances at
the home-screen widget.

Crowly is a **reader**: a digest is content he *reads*, not a prompt to act. No
questions, no buttons, no callbacks. If you want him to do something, say so in
the prose `bottom_line`/`summary` — he acts in whatever tool owns that workflow.

## Setup

This skill needs two environment variables, declared in the frontmatter as
`required_environment_variables` — so Hermes prompts for them on first load and
passes them through to the sandbox automatically (`setup-crowly` sets them for
you if you installed via that skill):

```
CROWLY_COMPANION_URL   the INTERNAL companion address the emitter POSTs to
CROWLY_TOKEN           the companion's pairing token
```

**`CROWLY_COMPANION_URL` is the *internal* address, never the public Funnel URL:**
`http://crowly-companion:8787` when the companion is a sibling container on the
shared `crowly-net` Docker network, or `http://127.0.0.1:8787` when it runs as a
bare process on the same host. The public Tailscale Funnel URL fails the TLS
check from inside the tailnet — that URL is only for the phone.

The helper `crowly_emit.py` is bundled with this skill
(`${HERMES_SKILL_DIR}/scripts/crowly_emit.py`, stdlib-only Python 3, no pip
installs) and reads those two vars from the environment.

## How to emit (the action)

1. **Write the content** as a JSON object — you fill these fields:

   | field | required | notes |
   |---|---|---|
   | `job_id` | ✅ | stable series id, e.g. `"harmony-weekly"` — groups + colors the digest |
   | `title` | ✅ | the header, e.g. `"AI news — Monday roundup"` |
   | `bottom_line` | ✅ | one-line TL;DR for the card face + widget |
   | `urgency` | ✅ | `low`\|`normal`\|`high`\|`urgent` — drives in-app sort order + widget prominence; be honest |
   | `content` | optional | **preferred (v2)** — ordered array of typed blocks (see below) for anything structured |
   | `summary` | optional | main prose body — fine for a *simple* digest with no structure |
   | `sections` | optional | `[{"heading","body"}]` — the v1 fallback for structured detail |
   | `sources` | optional | `[{"title","url"}]` tappable links |

   **Do not set** `id`, `created_at`, or `schema_version` — the helper stamps
   those (the id is a content-derived idempotency key).

### Structured content: the `content` blocks (v2, preferred)

`content` is an **ordered array of typed blocks** — this is how you give a
digest real structure the app renders natively. Prefer it over one long
`summary` paragraph whenever the digest has more than a couple of sentences.
`summary`/`sections` are still valid for a genuinely simple digest, but reach
for `content` for anything structured. Use `content` **or** `summary`/`sections`,
not both (the app prefers `content` when present).

Six block types:

| type | shape | when to use |
|---|---|---|
| `paragraph` | `{"type":"paragraph","text":"…"}` | ordinary prose |
| `heading` | `{"type":"heading","text":"…"}` | group the blocks below it |
| `list` | `{"type":"list","style":"bullet"\|"ordered","items":["…","…"]}` | instead of a long paragraph of enumerated items; `style` optional (default bullet) |
| `callout` | `{"type":"callout","variant":"info"\|"warning"\|"success"\|"critical","title":"…?","text":"…"}` | the single most important thing; a `warning`/`critical` variant for anything tied to `urgency` (keep the two honest and consistent) |
| `metrics` | `{"type":"metrics","items":[{"label":"…","value":"…"}]}` | numbers — temperatures, counts, prices, deltas |
| `divider` | `{"type":"divider"}` | a visual break between groups |

**Inline text** inside any `text` field takes a restricted Markdown subset:
`**bold**`, `*italic*`, `` `code` ``, and `[label](https://url)` links. Use
`**bold**` to draw the eye and `[links](url)` for references inline (this is in
addition to the tappable `sources` array).

Rules of thumb:
- Lead with a **`callout`** for the one thing he must not miss. If `urgency` is
  `high`/`urgent`, back it with a `warning`/`critical` callout — don't bury the
  reason in prose.
- Put every number in a **`metrics`** block, not inside a sentence.
- Turn "three things happened…" prose into a **`list`**.
- Use **`heading`** + `divider` to group when a digest covers multiple topics.

2. **Pipe it to the helper** (the env vars are already in the environment):

   ```bash
   echo "$content_json" | python3 ${HERMES_SKILL_DIR}/scripts/crowly_emit.py
   ```

   (`${HERMES_SKILL_DIR}` is substituted with this skill's absolute directory
   when the skill loads.) Or write to a file and pass `--content-file digest.json`.

3. **Check the exit code:**
   - `0` — posted. Done. (stdout shows `{"status":"stored"|"updated","id":...}`)
   - `2` — *your content* was invalid (it prints which field). Fix and retry.
   - `3` — transport error (companion unreachable / rejected). The digest was
     NOT delivered. Safe to retry — same content → same id, so a retry updates
     rather than duplicates. Do not silently swallow this; surface it.

## Example

```bash
content='{
  "job_id": "harmony-weekly",
  "title": "Harmony Community — weekly digest",
  "urgency": "high",
  "bottom_line": "Boil-water advisory in effect until Fri; two bylaw drafts in public comment; Rec Society AGM Aug 12.",
  "content": [
    {"type": "callout", "variant": "warning", "title": "Boil-water advisory",
     "text": "In effect for the **north zone** until Fri Aug 8. Boil all drinking water 1 min. [Details](https://www.rockyview.ca/advisory)."},
    {"type": "metrics", "items": [
      {"label": "Bylaw drafts open", "value": "2"},
      {"label": "Comment closes", "value": "Aug 20"},
      {"label": "Reservoir level", "value": "-12%"}
    ]},
    {"type": "heading", "text": "Bylaw watch"},
    {"type": "paragraph", "text": "Two drafts are in public comment. Both touch *short-term rentals*; the second also revises setback rules."},
    {"type": "list", "style": "bullet", "items": [
      "Draft 14-2026 — STR licensing caps",
      "Draft 15-2026 — rear-lot setback minimums"
    ]},
    {"type": "divider"},
    {"type": "paragraph", "text": "**Rec Society AGM** is Aug 12, 7pm at the community hall."}
  ],
  "sources": [{"title": "Rocky View County", "url": "https://www.rockyview.ca/..."}]
}'
echo "$content" | python3 ${HERMES_SKILL_DIR}/scripts/crowly_emit.py
```

A *simple* digest can still use plain prose instead of `content`:

```bash
content='{
  "job_id": "harmony-weekly",
  "title": "Harmony Community — weekly digest",
  "urgency": "low",
  "bottom_line": "Quiet week.",
  "summary": "Nothing notable this week. Next council meeting Aug 19."
}'
echo "$content" | python3 ${HERMES_SKILL_DIR}/scripts/crowly_emit.py
```

## Before going live, dry-run

`--dry-run` builds + validates + prints the envelope WITHOUT posting — use once
when wiring a new job to confirm the content validates:

```bash
echo "$content" | python3 ${HERMES_SKILL_DIR}/scripts/crowly_emit.py --dry-run
```

## Notes

- **Idempotent:** the id derives from `job_id` + date + a content hash. An exact
  re-emit (retry) updates the same digest; different content the same day makes
  a new one.
- **urgency** is the only signal Crowly uses to surface a digest more
  prominently — set it per-emit (a weather job is routine most days, `high` on
  a storm day), not once.
- Full contract: `docs/emitter.md` and `docs/schema.md` in the Crowly repo.
