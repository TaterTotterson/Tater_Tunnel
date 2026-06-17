#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="tater-tunnel-vps"
SERVICE_USER="tater-tunnel"
INSTALL_DIR="/opt/tater-tunnel"
STATE_DIR="/var/lib/tater-tunnel"
CONFIG_DIR="/etc/tater-tunnel"
LISTEN_HOST="127.0.0.1"
LISTEN_PORT="4174"
WIREGUARD_INTERFACE="tater0"
PAIRING_CODE=""
SKIP_PACKAGES="0"
START_SERVICE="1"
WIREGUARD_CLIENT_ACCESS="0"
REOPEN_PAIRING="0"

usage() {
  cat <<'EOF'
Install only the Tater Tunnel VPS Agent.

This advanced installer does not install Caddy and does not change firewall
rules. Use it on an existing VPS where you manage HTTPS/reverse proxy/firewall
yourself.

Usage:
  sudo ./scripts/install-vps-agent.sh [options]

Options:
  --listen-host HOST       Agent bind host. Default: 127.0.0.1
  --listen-port PORT       Agent bind port. Default: 4174
  --install-dir PATH       App install directory. Default: /opt/tater-tunnel
  --state-dir PATH         State directory. Default: /var/lib/tater-tunnel
  --config-dir PATH        Config directory. Default: /etc/tater-tunnel
  --pairing-code CODE      Initial pairing code. Generated if omitted.
  --wireguard-interface NAME
                           WireGuard interface name. Default: tater0
  --wireguard-client-access
                           Also listen on VPN-facing interfaces so WireGuard
                           clients can reach /relay through the VPS firewall.
  --reopen-pairing        Re-enable pairing after install/update without
                           resetting approved peers.
  --skip-packages          Do not install OS packages.
  --no-start               Install service but do not start it.
  -h, --help               Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --listen-host)
      LISTEN_HOST="${2:?--listen-host requires a value}"
      shift 2
      ;;
    --listen-port)
      LISTEN_PORT="${2:?--listen-port requires a value}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:?--install-dir requires a value}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:?--state-dir requires a value}"
      shift 2
      ;;
    --config-dir)
      CONFIG_DIR="${2:?--config-dir requires a value}"
      shift 2
      ;;
    --pairing-code)
      PAIRING_CODE="${2:?--pairing-code requires a value}"
      shift 2
      ;;
    --wireguard-interface)
      WIREGUARD_INTERFACE="${2:?--wireguard-interface requires a value}"
      shift 2
      ;;
    --wireguard-client-access)
      WIREGUARD_CLIENT_ACCESS="1"
      shift
      ;;
    --reopen-pairing)
      REOPEN_PAIRING="1"
      shift
      ;;
    --skip-packages)
      SKIP_PACKAGES="1"
      shift
      ;;
    --no-start)
      START_SERVICE="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer with sudo." >&2
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is required for this installer." >&2
    exit 1
  fi
}

install_packages() {
  if [ "$SKIP_PACKAGES" = "1" ]; then
    return
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This installer currently supports Debian/Ubuntu systems with apt-get." >&2
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates iproute2 python3 wireguard wireguard-tools
}

create_service_user() {
  if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
    groupadd --system "$SERVICE_USER"
  fi

  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd \
      --system \
      --gid "$SERVICE_USER" \
      --home-dir "$STATE_DIR" \
      --create-home \
      --shell /usr/sbin/nologin \
      "$SERVICE_USER"
  fi
}

copy_app_files() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  local install_real
  install -d -m 0755 "$INSTALL_DIR"
  install_real="$(cd "$INSTALL_DIR" && pwd -P)"

  if [ "$source_dir" != "$install_real" ]; then
    tar \
      --exclude='.git' \
      --exclude='.tater_tunnel' \
      --exclude='__pycache__' \
      --exclude='*.pyc' \
      -C "$source_dir" \
      -cf - . | tar -C "$INSTALL_DIR" -xf -
  fi

  chown -R root:root "$INSTALL_DIR"
  find "$INSTALL_DIR" -type d -exec chmod 0755 {} +
  find "$INSTALL_DIR" -type f -exec chmod 0644 {} +
  find "$INSTALL_DIR/scripts" -type f -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true
}

prepare_state() {
  local wg_dir="$CONFIG_DIR/wireguard"
  install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 -d "$STATE_DIR"
  install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 -d "$CONFIG_DIR"
  install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 -d "$wg_dir"

  local pairing_file="$STATE_DIR/pairing-code"
  if [ -n "$PAIRING_CODE" ]; then
    printf '%s\n' "$PAIRING_CODE" > "$pairing_file"
  elif [ ! -s "$pairing_file" ]; then
    PAIRING_CODE="$(python3 -c 'import secrets; alphabet="ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; print("".join(secrets.choice(alphabet) for _ in range(4)) + "-" + "".join(secrets.choice(alphabet) for _ in range(4)))')"
    printf '%s\n' "$PAIRING_CODE" > "$pairing_file"
  else
    PAIRING_CODE="$(cat "$pairing_file")"
  fi

  chown "$SERVICE_USER:$SERVICE_USER" "$pairing_file"
  chmod 0600 "$pairing_file"
}

write_service() {
  local python_bin
  python_bin="$(command -v python3)"
  local pairing_file="$STATE_DIR/pairing-code"
  local state_file="$STATE_DIR/vps-agent.json"
  local wireguard_config="$CONFIG_DIR/wireguard/$WIREGUARD_INTERFACE.conf"
  local service_file="/etc/systemd/system/$SERVICE_NAME.service"
  local service_host="$LISTEN_HOST"

  if [ "$WIREGUARD_CLIENT_ACCESS" = "1" ] && [ "$service_host" = "127.0.0.1" ]; then
    service_host="0.0.0.0"
  fi

  cat > "$service_file" <<EOF
[Unit]
Description=Tater Tunnel VPS Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$python_bin -B -m tater_tunnel.vps_agent --host $service_host --port $LISTEN_PORT --state-file $state_file --pairing-code-file $pairing_file --wireguard-backend system --wireguard-config $wireguard_config --wireguard-interface $WIREGUARD_INTERFACE
Restart=on-failure
RestartSec=3
UMask=0077
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$STATE_DIR $CONFIG_DIR /run

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  if [ "$START_SERVICE" = "1" ]; then
    systemctl restart "$SERVICE_NAME"
  fi
}

reopen_pairing_if_requested() {
  if [ "$REOPEN_PAIRING" != "1" ]; then
    return 0
  fi

  local python_bin
  python_bin="$(command -v python3)"
  local state_file="$STATE_DIR/vps-agent.json"
  local pairing_file="$STATE_DIR/pairing-code"

  (
    cd "$INSTALL_DIR"
    runuser -u "$SERVICE_USER" -- "$python_bin" -B -m tater_tunnel.vps_agent \
      --state-file "$state_file" \
      --pairing-code-file "$pairing_file" \
      --reopen-pairing
  )
}

print_summary() {
  local service_host="$LISTEN_HOST"
  if [ "$WIREGUARD_CLIENT_ACCESS" = "1" ] && [ "$service_host" = "127.0.0.1" ]; then
    service_host="0.0.0.0"
  fi

  cat <<EOF

Tater Tunnel VPS Agent installed.

Service:
  sudo systemctl status $SERVICE_NAME
  sudo journalctl -u $SERVICE_NAME -f

Local agent URL:
  http://$service_host:$LISTEN_PORT

Pairing code:
  $(cat "$STATE_DIR/pairing-code")

Pairing mode:
  $([ "$REOPEN_PAIRING" = "1" ] && printf 'reopened' || printf 'unchanged')

Advanced setup reminders:
  - Put HTTPS/reverse proxy in front of http://127.0.0.1:$LISTEN_PORT
  - If using WireGuard client relay access, firewall TCP $LISTEN_PORT to tater0 only
  - Open UDP 51888 for WireGuard devices
  - Keep TCP $LISTEN_PORT private unless you are doing a short test
EOF
}

require_root
require_systemd
install_packages
create_service_user
copy_app_files
prepare_state
write_service
reopen_pairing_if_requested
print_summary
