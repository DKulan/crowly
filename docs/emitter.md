# Emitter kit & the ingest wire contract

The **emitter kit** is the input side of Crowly (`docs/architecture.md` → component #1): a helper plus a Hermes skill that let any cron/agent emit schema-valid digests into a user's companion. This doc defines two things `docs/schema.md` deliberately left open:

1. **The ingest wire contract** — the HTTP shape an emitter POSTs to (the *transport*, vs. `schema.md`'s *payload*).
2. **The emitter kit** — the helper that builds the envelope and the Hermes skill that wraps it.

The split that makes this work: **the LLM writes content; the helper guarantees the envelope.** The model is good at prose and unreliable at stable ids, timestamps, and required-field discipline — so those are the helper's job, not the model's.

```
LLM (cron) fills   →  title, bottom_line, urgency, sources,
                      + body: content blocks (v2) OR summary/sections (v1)
helper guarantees  →  schema_version, id, created_at, validation, transport
```

---

## 1. Ingest wire contract

Additive to `docs/schema.md` (which defines the digest payload) and `docs/architecture.md` § Companion (which defines ingest behavior). The companion authenticates app *and* emitter requests with the same pairing token it already holds (`architecture.md` § Security), so the emitter reuses that mechanism rather than inventing a second one.

### `POST {companion_url}/ingest`

| | |
|---|---|
| **Auth** | `Authorization: Bearer <pairing_token>` |
| **Body** | `Content-Type: application/json` — one digest object per `docs/schema.md §1` |
| **Idempotency** | Keyed on `id`. Re-POSTing the same `id` **updates**, never duplicates. |
| **Schema version** | `SCHEMA_VERSION = 2` (helper stamps it). The companion accepts `1` and `2` (`SCHEMA_VERSIONS_SUPPORTED = (1, 2)`; `architecture.md` § Companion). |
| **Unknown fields** | Stored **verbatim** in the digest blob (`schema.md` § Versioning). Never stripped — this includes unknown `content` **block types**. |

### Responses

| Status | Meaning | Body |
|---|---|---|
| `201 Created` | New digest stored | `{"status":"stored","id":"…"}` |
| `200 OK` | Existing `id` updated | `{"status":"updated","id":"…"}` |
| `401 Unauthorized` | Missing/bad bearer token | `{"error":"…"}` |
| `422 Unprocessable` | Payload failed validation | `{"error":"<field-level detail>"}` |
| `400 Bad Request` | Malformed JSON | `{"error":"…"}` |

The companion **validates and rejects malformed digests with a clear 4xx** so the cron author sees what's wrong in their logs — a bad payload never crashes the store or reaches the app (`architecture.md` § Companion → Ingest). The companion validates *again* server-side: the emitter's client-side check is a fast-fail courtesy, not the trust boundary.

### Required vs. stamped fields

Required in the stored digest (matches the app's decoder, `Shared/Models/Schema.swift`): `schema_version`, `id`, `job_id`, `source`, `title`, `created_at`, `urgency`, `bottom_line`. Optional body: **`content[]` (v2)** *or* `summary` + `sections[]` (v1). Also optional: `sources[]`.

Of those, the **helper stamps** `schema_version` (`2`), `id`, `created_at` (and defaults `source`) — the caller/LLM must **not** set them. The caller supplies `job_id`, `title`, `bottom_line`, `urgency`, `sources`, and the body — either a `content` block array or the v1 `summary`/`sections` (pick one; see `schema.md` § Body relationship).

### Content-block validation

When the caller supplies `content`, the helper validates it client-side (`crowly_emit.py`; the companion re-validates server-side — the client check is a fast-fail courtesy, not the trust boundary):

- **Known block types** (`paragraph` / `heading` / `list` / `callout` / `metrics` / `divider`) are shape-checked — required fields present, `items` an array, etc. A malformed known block is a validation error (exit `2`), so the cron author sees it in their logs.
- **Unknown block types are passed through**, not rejected — the block-level analogue of unknown top-level fields (`schema.md` § Versioning). This is what lets a newer emitter emit a v3 block through an older validator; the companion stores it verbatim and an older reader degrades gracefully.
- **`summary`/`sections` remain valid** — a v1-shaped body still passes validation unchanged. The helper doesn't require `content`.

> **Not in scope for ingest:** read/archive **state writes** are a separate companion endpoint the *app* calls, not the emitter (`architecture.md` § Companion → Store). The emitter only ever creates/updates digest content. `urgency` is set by the emitter and drives in-app sort order + widget surfacing downstream (`schema.md` → Field notes); the emitter just needs to set it honestly.

---

## 2. The kit

Lives in `emitter/`:

- **`crowly_emit.py`** — single-file, stdlib-only Python helper. CLI **and** importable library. Builds the envelope, validates against the same required-field set as the app's decoder, POSTs to `/ingest`. `--dry-run` builds + validates + prints without posting. Exit codes: `0` ok, `2` validation error (fix the content/prompt), `3` transport error (network / non-2xx).
- **`companion_stub.py`** — a **minimal test companion** (in-memory, no TLS) implementing `/ingest` + `/list` + `/summary`. Not the production companion; it exists to exercise the wire contract end-to-end on a dev box.
- **`hermes-skill/`** — the Hermes skill wrapper: instructions + a `crowly-emit` recipe a Hermes cron uses to ship its output to Crowly.
- **`sample_content.json`** — example caller content (what the LLM produces).

### Quickstart (verified)

```bash
cd emitter

# 1. Dry-run: build + validate an envelope from content, print it, don't POST.
echo '{"job_id":"harmony-weekly","title":"Harmony Digest",
       "bottom_line":"Quiet week.","urgency":"low"}' \
  | python3 crowly_emit.py --dry-run

# 2. End-to-end against the test companion:
python3 companion_stub.py --port 8788 --token testtoken &        # terminal A
CROWLY_COMPANION_URL=http://127.0.0.1:8788 CROWLY_TOKEN=testtoken \
  python3 crowly_emit.py --content-file sample_content.json        # terminal B
curl -s http://127.0.0.1:8788/list | python3 -m json.tool          # see it stored
```

Against a **real** companion, set `CROWLY_COMPANION_URL` to the user's HTTPS companion URL and `CROWLY_TOKEN` to their pairing token (both from QR pairing; secrets live in the user's `/opt/data/.env`, never in this repo).
