FROM python:3.12-slim-bookworm

ARG DEBIAN_FRONTEND=noninteractive

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TATER_TUNNEL_AGENT=home

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iptables \
        iproute2 \
        tini \
        wireguard-go \
        wireguard-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY tater_tunnel ./tater_tunnel
COPY assets ./assets
COPY index.html app.js qr.js styles.css README.md ./
COPY docker/entrypoint.sh /usr/local/bin/tater-tunnel

RUN chmod +x /usr/local/bin/tater-tunnel \
    && mkdir -p /data /config/wireguard

VOLUME ["/data", "/config"]

EXPOSE 4173/tcp

HEALTHCHECK --interval=20s --timeout=3s --start-period=15s --retries=3 \
    CMD curl -fsS http://127.0.0.1:4173/api/state >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "tater-tunnel"]
CMD ["home"]
