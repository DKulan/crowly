---
name: emit-crowly-digest
description: Send a recurring digest (AI news, weather, community update, briefing, reminder) to the user's Crowly inbox app. Use at the end of a scheduled/cron job when you have a summary the user should read in Crowly. You write the content; the helper stamps the id/timestamp/version and POSTs it.
---

# Emit a Crowly digest

Crowly is the user's iOS **inbox/reader** for recurring agent output. When a
scheduled job has produced something the user should read — a news roundup, a
weather alert, a weekly community digest, a reminder — emit it as a Crowly
**digest** so it lands in their inbox (and, if urgent, pushes to their phone).

Crowly is a **reader**: a digest is content the user *reads*, not a prompt to
act. No questions, no buttons, no callbacks. If you want the user to do
something, say so in the prose `bottom_line`/`summary` — they'll act in
whatever tool already owns that workflow.

## One-time setup

The helper is `emitter/crowly_emit.py` (single-file, Python 3, **no
dependencies** — stdlib only). Nothing to `pip install`. It needs two values,
from the user's Crowly companion (they get these once, via QR pairing in the
app):

```bash
export CROWLY_COMPANION_URL="https://inbox.example.com"   # their companion URL
export CROWLY_TOKEN="<pairing token>"                      # their pairing token
```

Keep the token in the cron's secret store / `/opt/data/.env` — never commit it.

## How to emit (the action)

1. **Write the content** as a JSON object. You fill these fields:

   | field | required | notes |
   |---|---|---|
   | `job_id` | ✅ | stable series id, e.g. `"ai-news-daily"` — groups + colors the digest |
   | `title` | ✅ | the header, e.g. `"AI news — Monday roundup"` |
   | `bottom_line` | ✅ | one-line TL;DR for the card face + widget |
   | `urgency` | ✅ | `low` \| `normal` \| `high` \| `urgent` — **be honest**: `high`/`urgent` *pushes to the phone*; `normal`/`low` wait to be pulled |
   | `summary` | optional | main prose body |
   | `sections` | optional | `[{"heading","body"}]` structured detail |
   | `sources` | optional | `[{"title","url"}]` tappable links |

   **Do not set** `id`, `created_at`, or `schema_version` — the helper stamps
   those (a stable id is the idempotency key; you'd get it wrong).

2. **Pipe it to the helper:**

   ```bash
   echo "$content_json" | python3 /path/to/emitter/crowly_emit.py
   ```

   or write it to a file and `--content-file digest.json`.

3. **Check the exit code:**
   - `0` — posted. You're done.
   - `2` — *your content* was invalid (helper prints which field). Fix the
     content and retry. This is your bug, not the user's.
   - `3` — transport error (companion unreachable / rejected). Surface it; the
     digest was not delivered. Safe to retry later — same content yields the
     same `id`, so a retry updates rather than duplicates.

## Example

```bash
content='{
  "job_id": "weather-local",
  "title": "Weather — severe thunderstorm watch",
  "urgency": "high",
  "bottom_line": "Severe thunderstorm watch 2 PM–9 PM. Gusts to 90 km/h.",
  "summary": "Environment Canada issued a watch for this afternoon.",
  "sections": [{"heading": "Timing", "body": "Cells fire mid-afternoon."}],
  "sources": [{"title": "Environment Canada", "url": "https://weather.gc.ca/warnings/"}]
}'
echo "$content" | python3 emitter/crowly_emit.py
```

## Before going live, dry-run it

`--dry-run` builds + validates + prints the full envelope without posting —
use it once while wiring up a new job to confirm your content is valid:

```bash
echo "$content" | python3 emitter/crowly_emit.py --dry-run
```

## Notes

- **Idempotent:** the `id` derives from `job_id` + date + a content hash, so an
  exact re-emit (a retry) updates the same digest; different content the same
  day creates a new one.
- **urgency drives everything downstream** — sort order, widget surfacing, and
  whether the phone buzzes. A job that's routine most days but occasionally
  critical (weather!) should set `urgency` per-emit, not once.
- Full wire contract and field reference: `docs/emitter.md` and
  `docs/schema.md` in the Crowly repo.
