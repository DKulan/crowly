---
name: emit-crowly-digest
description: Send a recurring digest (AI news, weather, community update, briefing, reminder) to Daniel's Crowly inbox app. Use at the end of a scheduled/cron job when you have a summary he should read in Crowly. You write the content; the bundled helper stamps the id/timestamp/version and POSTs it to the companion.
platforms: [linux]
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

## Setup (this deployment)

The companion runs as a sibling container on the shared `crowly-net` Docker
network. From inside Hermes it's reachable at **`http://crowly-companion:8787`**
(plain HTTP, internal — never the public Tailscale Funnel URL, which fails the
TLS check from inside the tailnet).

The helper `crowly_emit.py` is bundled with this skill (`scripts/crowly_emit.py`,
stdlib-only Python 3, no pip installs). It reads two values from the
environment — already set in Hermes's `/opt/data/.env`:

```
CROWLY_COMPANION_URL=http://crowly-companion:8787
CROWLY_TOKEN=<the companion's pairing token>
```

## How to emit (the action)

1. **Write the content** as a JSON object — you fill these fields:

   | field | required | notes |
   |---|---|---|
   | `job_id` | ✅ | stable series id, e.g. `"harmony-weekly"` — groups + colors the digest |
   | `title` | ✅ | the header, e.g. `"AI news — Monday roundup"` |
   | `bottom_line` | ✅ | one-line TL;DR for the card face + widget |
   | `urgency` | ✅ | `low`\|`normal`\|`high`\|`urgent` — drives in-app sort order + widget prominence; be honest |
   | `summary` | optional | main prose body |
   | `sections` | optional | `[{"heading","body"}]` structured detail |
   | `sources` | optional | `[{"title","url"}]` tappable links |

   **Do not set** `id`, `created_at`, or `schema_version` — the helper stamps
   those (the id is a content-derived idempotency key).

2. **Pipe it to the helper** (the env vars are already in the environment):

   ```bash
   echo "$content_json" | python3 ~/.../emit-crowly-digest/scripts/crowly_emit.py
   ```

   (Use the skill's actual installed path; in a cron `script` you can reference
   it relative to the skills dir.) Or write to a file and pass
   `--content-file digest.json`.

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
  "urgency": "low",
  "bottom_line": "Quiet week. Two bylaw drafts in public comment; Rec Society AGM Aug 12.",
  "summary": "...",
  "sections": [{"heading": "Bylaw watch", "body": "..."}],
  "sources": [{"title": "Rocky View County", "url": "https://www.rockyview.ca/..."}]
}'
echo "$content" | python3 scripts/crowly_emit.py
```

## Before going live, dry-run

`--dry-run` builds + validates + prints the envelope WITHOUT posting — use once
when wiring a new job to confirm the content validates:

```bash
echo "$content" | python3 scripts/crowly_emit.py --dry-run
```

## Notes

- **Idempotent:** the id derives from `job_id` + date + a content hash. An exact
  re-emit (retry) updates the same digest; different content the same day makes
  a new one.
- **urgency** is the only signal Crowly uses to surface a digest more
  prominently — set it per-emit (a weather job is routine most days, `high` on
  a storm day), not once.
- Full contract: `docs/emitter.md` and `docs/schema.md` in the Crowly repo.
