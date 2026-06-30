# Crowly emitter kit

The **input side** of Crowly (`docs/architecture.md` → component #1): how a
cron/agent gets its output into a user's Crowly inbox. The agent writes the
*content*; the helper guarantees the *envelope* (stable `id`, `created_at`,
`schema_version`) and POSTs it to the user's companion.

Design intent lives in **`docs/emitter.md`** (the `POST /ingest` wire contract)
and **`docs/schema.md`** (the digest payload). This dir is the implementation.

## Files

| file | what |
|---|---|
| `crowly_emit.py` | The helper. Single-file, **stdlib-only** Python 3. CLI + importable lib. Builds + validates the envelope, POSTs to `/ingest`. `--dry-run` to build without posting. |
| `companion_stub.py` | A **minimal test companion** (in-memory, no TLS) — `/ingest` + `/list` + `/summary`. Not production; exists to exercise the wire contract on a dev box. |
| `hermes-skill/SKILL.md` | The Hermes skill: how a cron's LLM calls the helper to ship its output to Crowly. |
| `sample_content.json` | Example caller content (what the LLM produces, pre-envelope). |
| `test_crowly_emit.py` | Unit tests for the helper's envelope/validation logic (no network). |

## Quickstart (all verified)

```bash
# Helper unit tests (no network):
python3 test_crowly_emit.py

# Dry-run: build + validate + print an envelope, don't POST:
python3 crowly_emit.py --content-file sample_content.json --dry-run

# End-to-end against the test companion:
python3 companion_stub.py --port 8788 --token testtoken &        # terminal A
CROWLY_COMPANION_URL=http://127.0.0.1:8788 CROWLY_TOKEN=testtoken \
  python3 crowly_emit.py --content-file sample_content.json        # terminal B
curl -s http://127.0.0.1:8788/list | python3 -m json.tool          # confirm stored
```

The shape `crowly_emit.py` emits is covered by an app-side decode test
(`emitterOutputShapeDecodes` in `Tests/CrowlyTests.swift`) — if the emitter and
the iOS decoder ever drift, that test fails.

## Against a real companion

Set `CROWLY_COMPANION_URL` to the user's HTTPS companion URL and `CROWLY_TOKEN`
to their pairing token (both obtained once via QR pairing in the app). Secrets
live in the user's `/opt/data/.env`, never in this repo.
