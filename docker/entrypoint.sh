#!/bin/sh
set -eu

agent="${TATER_TUNNEL_AGENT:-home}"

if [ "$#" -gt 0 ]; then
    case "$1" in
        home|vps)
            agent="$1"
            shift
            ;;
        -*)
            ;;
        *)
            exec "$@"
            ;;
    esac
fi

case "$agent" in
    home)
        exec python -B -m tater_tunnel.home_agent \
            --host "${TATER_TUNNEL_HOST:-0.0.0.0}" \
            --port "${TATER_TUNNEL_PORT:-4173}" \
            --state-file "${TATER_TUNNEL_STATE_FILE:-/data/home-agent.json}" \
            --static-root "${TATER_TUNNEL_STATIC_ROOT:-/app}" \
            --wireguard-backend "${TATER_TUNNEL_WIREGUARD_BACKEND:-config}" \
            --wireguard-config "${TATER_TUNNEL_WIREGUARD_CONFIG:-/config/wireguard/tater-home.conf}" \
            --wireguard-interface "${TATER_TUNNEL_WIREGUARD_INTERFACE:-tater-home}" \
            --relay-target "${TATER_TUNNEL_RELAY_TARGET:-http://127.0.0.1:4173}" \
            --relay-workers "${TATER_TUNNEL_RELAY_WORKERS:-8}" \
            "$@"
        ;;
    vps)
        if [ -n "${TATER_TUNNEL_PAIRING_CODE_FILE:-}" ]; then
            set -- --pairing-code-file "$TATER_TUNNEL_PAIRING_CODE_FILE" "$@"
        elif [ -n "${TATER_TUNNEL_PAIRING_CODE:-}" ]; then
            set -- --pairing-code "$TATER_TUNNEL_PAIRING_CODE" "$@"
        fi

        exec python -B -m tater_tunnel.vps_agent \
            --host "${TATER_TUNNEL_HOST:-0.0.0.0}" \
            --port "${TATER_TUNNEL_PORT:-4174}" \
            --state-file "${TATER_TUNNEL_STATE_FILE:-/data/vps-agent.json}" \
            --wireguard-backend "${TATER_TUNNEL_WIREGUARD_BACKEND:-config}" \
            --wireguard-config "${TATER_TUNNEL_WIREGUARD_CONFIG:-/config/wireguard/tater0.conf}" \
            --wireguard-interface "${TATER_TUNNEL_WIREGUARD_INTERFACE:-tater0}" \
            "$@"
        ;;
    *)
        echo "Unknown Tater Tunnel agent: $agent" >&2
        echo "Use 'home', 'vps', or pass a command to run directly." >&2
        exit 64
        ;;
esac
