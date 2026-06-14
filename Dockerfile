FROM python:3.12-slim-bookworm

ARG DEBIAN_FRONTEND=noninteractive

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TATER_TUNNEL_AGENT=home

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        tini \
        wireguard-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY tater_tunnel ./tater_tunnel
COPY assets ./assets
COPY index.html app.js styles.css README.md ./
COPY docker/entrypoint.sh /usr/local/bin/tater-tunnel

RUN chmod +x /usr/local/bin/tater-tunnel \
    && mkdir -p /data /config/wireguard

VOLUME ["/data", "/config"]

EXPOSE 4173/tcp 4174/tcp 51888/udp

ENTRYPOINT ["/usr/bin/tini", "--", "tater-tunnel"]
CMD ["home"]
