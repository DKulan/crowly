# Crowly push relay — the one piece users do NOT self-host.
#
# Stays as close to the companion's Dockerfile shape as possible (same base
# image, same hygiene flags) — the relay is in many ways a smaller cousin of
# the companion, and an operator reading the two side by side should see one
# pattern, not two.
#
# Dependency layout:
#   * The relay core (store, server, MockAPNsClient) is dependency-free —
#     Python 3 stdlib + sqlite3. That's all that runs in `mock` mode.
#   * `HTTP2APNsClient` (the real Apple-talking client) needs httpx[http2].
#     We install it eagerly here so the image is "real APNs ready" out of the
#     box — once the operator wires in the .p8, no rebuild is needed. If the
#     operator opts out of push entirely they can run the image with
#     APNS_ENV=mock and the dep is just unused weight (~7MB).

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Install httpx[http2] up front. We do NOT install this into the companion
# image — the companion never imports it. Keeping the dep here isolates the
# "talks to Apple over HTTP/2" surface to this one image.
RUN pip install --no-cache-dir 'httpx[http2]==0.27.*'

WORKDIR /app
COPY relay/ /app/relay/

ENV PYTHONPATH=/app

RUN mkdir -p /opt/data
VOLUME ["/opt/data"]

ENV RELAY_HOST=0.0.0.0 \
    RELAY_PORT=8788 \
    RELAY_DB_PATH=/opt/data/relay.db \
    RELAY_RATE_LIMIT_PER_MINUTE=30 \
    APNS_ENV=mock \
    APNS_TOPIC=dev.mock.crowly

EXPOSE 8788

HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=5s \
    CMD python -c "import urllib.request,sys; \
        r=urllib.request.urlopen('http://127.0.0.1:${RELAY_PORT}/health', timeout=3); \
        sys.exit(0 if r.status==200 else 1)" || exit 1

CMD ["python", "-m", "relay"]
