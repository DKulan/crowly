# Crowly companion — the per-user, self-hosted core.
#
# Dependency-free Python 3 + sqlite3. No requirements.txt because there are no
# third-party deps; the only stdlib pieces are http.server, sqlite3, json,
# argparse. `python:3.12-slim` is the smallest base image with a recent
# sqlite3 — going further (alpine, distroless) buys little and costs build
# headaches for one user's homelab. Reassess if the image bloats past ~80MB.

FROM python:3.12-slim

# Belt-and-braces hygiene flags:
#   PYTHONDONTWRITEBYTECODE=1 — no .pyc clutter in the writable layer.
#   PYTHONUNBUFFERED=1        — stdout flushes immediately so `docker logs`
#                               shows the operator's pairing banner without
#                               waiting on the buffer.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# The companion imports `crowly_emit.validate` as its single source of truth
# for digest validation, so the emitter directory has to be on PYTHONPATH at
# runtime too. We copy both packages in side by side.
WORKDIR /app
COPY companion/ /app/companion/
COPY emitter/   /app/emitter/

# /app + /app/emitter on PYTHONPATH lets both `python3 -m companion` and the
# `from crowly_emit import validate` resolve cleanly.
ENV PYTHONPATH=/app:/app/emitter

# Persistent data lives here. docker-compose mounts a named volume on top of
# this directory so the SQLite DB survives `docker compose down`. The image
# itself ships the directory pre-created so the first start doesn't race.
RUN mkdir -p /opt/data
VOLUME ["/opt/data"]

# Default config — the operator overrides via docker-compose env. The pairing
# token MUST be set; the companion fails loud at startup if it isn't.
ENV CROWLY_HOST=0.0.0.0 \
    CROWLY_PORT=8787 \
    CROWLY_DB_PATH=/opt/data/crowly.db

EXPOSE 8787

# /health is unauthenticated and cheap, perfect for Docker's healthcheck.
# 5s timeout, 10s interval — fast enough to surface a hung start, slow enough
# not to chew CPU. Healthcheck uses `python` so we don't have to install curl.
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=5s \
    CMD python -c "import urllib.request,sys; \
        r=urllib.request.urlopen('http://127.0.0.1:${CROWLY_PORT}/health', timeout=3); \
        sys.exit(0 if r.status==200 else 1)" || exit 1

CMD ["python", "-m", "companion"]
