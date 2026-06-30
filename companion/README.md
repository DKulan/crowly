# Crowly companion service

The per-user, self-hosted core of Crowly (`docs/architecture.md` § Companion).
The iOS app talks **directly** to this service over HTTPS for everything —
ingest, list, summary, per-digest state. Content stays on the user's VPS;
this directory is what they deploy.

This is the **production** companion. There is also a throwaway in-memory
test double at `emitter/companion_stub.py` referenced in `docs/emitter.md`
that exercises the wire contract without persistence — keep the two
distinct, the docs point at the stub.

## Hard invariants (from `CLAUDE.md` and `docs/schema.md`)

The companion is one piece of a versioned three-way contract (app +
companion + emitter, each shipping independently). These invariants are why
the service is the shape it is:

- **Ingest + store + serve, nothing more.** No callback execution, no agent
  integration, no external calls with digest content.
- **Unknown fields preserved verbatim.** A field a v2 app understands has to
  survive a round-trip through this v1 companion. The store keeps the
  *entire* JSON blob the emitter sent, byte-for-byte (canonicalised), and
  `/list` returns it unchanged.
- **Additive-only schema.** Never remove or repurpose fields.
- **Content never leaves the VPS.** No telemetry, no remote logging.

## Wire contract

Everything except `/health` and `/pair` requires `Authorization: Bearer
<pairing_token>`. Pairing token is the same one the app received during QR
pairing (`docs/architecture.md` § Pairing).

| Method | Path        | Auth | What |
|---|---|---|---|
| `GET`  | `/`         | no  | Pairing payload (alias for `/pair`). |
| `GET`  | `/pair`     | no  | `{companion_url, pairing_token}`. The operator copies this into the app, or the app scans a QR generated from it. |
| `GET`  | `/health`   | no  | `{"status":"ok","stored":N,"schema_versions_supported":[1]}`. |
| `POST` | `/ingest`   | yes | The emitter's only endpoint. See `docs/emitter.md` for the full contract. Validates + upserts on `digest.id`. `201` new / `200` updated / `401` bad token / `422` validation / `400` malformed JSON. |
| `GET`  | `/list`     | yes | All digests, newest-first. Each carries `_state` ∈ `unread`/`read`/`archived`. |
| `GET`  | `/summary`  | yes | `{unread_count, latest:[…]}` — cheap widget endpoint. |
| `POST` | `/state`    | yes | App mirrors a state change here. Body: `{id, state}` where `state ∈ unread|read|archived`. |

> **Why `_state` (leading underscore) on `/list`?** State is not part of the
> digest contract (`docs/schema.md`'s "What's deliberately not in the
> schema" — content-only). It lives on the companion next to the digest,
> and the app needs it inline to avoid a second round trip. The underscore
> keeps it visually distinct from contract fields.

## Configuration (env vars only)

| var | default | required | what |
|---|---|---|---|
| `CROWLY_PAIRING_TOKEN` | — | **yes** | Bearer token. Companion fails loud at startup if unset. |
| `CROWLY_DB_PATH` | `/opt/data/crowly.db` | no | SQLite file path. Parent dir is created if missing. |
| `CROWLY_HOST` | `0.0.0.0` | no | Bind host. |
| `CROWLY_PORT` | `8787` | no | Bind port. |
| `CROWLY_PUBLIC_URL` | `http://${HOST}:${PORT}` | no | URL the *app* dials (HTTPS through Caddy in production). Used in the pairing payload. |

Secrets — including `CROWLY_PAIRING_TOKEN` — live in the user's
`/opt/data/.env` on their VPS, never in this repo or any vault
(`docs/architecture.md` § Security). The Docker bundle's `.env.example`
template shows the operator what to fill in.

## Running

### Raw (dev, no TLS, no Docker)

```bash
# from the repo root
export CROWLY_PAIRING_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
export CROWLY_DB_PATH=$PWD/.local/crowly.db
python3 -m companion
```

Then point the emitter at it:

```bash
CROWLY_COMPANION_URL=http://127.0.0.1:8787 CROWLY_TOKEN="$CROWLY_PAIRING_TOKEN" \
  python3 emitter/crowly_emit.py --content-file emitter/sample_content.json
```

This is for hacking on the companion. The iOS app **cannot** talk to a plain
HTTP endpoint (App Transport Security) — for an actual paired install, use
the Docker bundle below.

### Docker (production — auto-HTTPS via Caddy)

The bundle is two services: this companion (HTTP, only reachable on the
docker network) and Caddy fronting it (HTTPS on :443, auto-renewing
Let's Encrypt cert).

```
internet ──▶ Caddy :443 ──▶ companion :8787 ──▶ /opt/data (SQLite)
```

```bash
cd companion
cp .env.example .env
# edit .env: set CROWLY_DOMAIN to your hostname (A record already pointing
# here) and CROWLY_PAIRING_TOKEN to a freshly-generated random token.
docker compose up -d
docker compose logs -f companion   # watch the pairing banner on startup
```

The pairing JSON is also served at `https://${CROWLY_DOMAIN}/pair` — open it
in a browser to copy/paste into the app's manual-pairing UI, or render a QR
from it client-side.

> **QR-image rendering is a noted follow-up.** Generating the QR pixels
> needs either a third-party Python dep or a custom encoder; for M1 we
> stayed dependency-free and emit the pairing JSON. The app's QR scanner
> will work against any QR an operator generates client-side from this
> JSON (any of the dozens of free `qr.example.com?text=…` services, or a
> local `qrencode <<<"$(curl -s …/pair)"`).

### Health check

```bash
curl -s https://${CROWLY_DOMAIN}/health
# {"status":"ok","stored":3,"schema_versions_supported":[1]}
```

## Testing

End-to-end + persistence test (boots the real companion on a temp DB, runs
the real emitter against it, kills + restarts to prove persistence):

```bash
python3 companion/test_end_to_end.py
```

Covers: liveness, pairing payload, auth gates, real emitter → companion
ingest, `/list` + `/summary`, idempotent re-POST, **unknown-field
passthrough** (the load-bearing invariant), state writes incl. error shapes,
malformed-JSON 400, schema-invalid 422, and a kill+restart with the same DB
file to prove digests, state, and unknown fields all survive.

## File layout

```
companion/
  __init__.py            package marker + the invariants in prose
  __main__.py            so `python3 -m companion` works
  server.py              HTTP handlers, Config (env-driven), main()
  store.py               SQLite store (digests + per-digest state)
  Dockerfile             slim Python 3.12 image; CMD: python -m companion
  docker-compose.yml     companion + Caddy reverse proxy
  Caddyfile              auto-HTTPS via Let's Encrypt
  .env.example           operator config template (DOMAIN, TOKEN)
  test_end_to_end.py     boot + emit + restart-persistence verification
  README.md              you are here
```
