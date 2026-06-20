#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="tater-tunnel-vps"
SERVICE_USER="tater-tunnel"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
INSTALL_DIR="/opt/tater-tunnel"
STATE_DIR="/var/lib/tater-tunnel"
CONFIG_DIR="/etc/tater-tunnel"
SOURCE_DIR="${TATER_TUNNEL_SOURCE_DIR:-/opt/tater-tunnel-src}"
LISTEN_PORT="4174"
WIREGUARD_INTERFACE="tater0"
ASSUME_YES="0"
PURGE_DATA="0"
REMOVE_SOURCE="0"
REMOVE_UFW_RULES="1"
DISABLE_CADDY_PROXY="0"

usage() {
  cat <<'EOF'
Uninstall the Tater Tunnel VPS Agent from a Debian/Ubuntu VPS.

This removes the Tater systemd service, installed app files, and live
WireGuard interface. It keeps state/config data unless --purge-data is used.
It does not uninstall shared OS packages such as Python, Caddy, UFW, or
WireGuard tools.

Usage:
  sudo ./scripts/uninstall-vps.sh [options]

Options:
  --purge-data            Delete /var/lib/tater-tunnel and /etc/tater-tunnel.
  --remove-source         Delete the downloaded setup source checkout.
  --keep-ufw-rules        Leave Tater WireGuard UFW rules unchanged.
  --disable-caddy-proxy   Move a Caddyfile that proxies to the Tater agent out
                          of the way, then reload Caddy. Off by default.
  --yes                   Do not prompt; use selected options.
  -h, --help              Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge-data)
      PURGE_DATA="1"
      shift
      ;;
    --remove-source)
      REMOVE_SOURCE="1"
      shift
      ;;
    --keep-ufw-rules)
      REMOVE_UFW_RULES="0"
      shift
      ;;
    --disable-caddy-proxy)
      DISABLE_CADDY_PROXY="1"
      shift
      ;;
    --yes)
      ASSUME_YES="1"
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

confirm() {
  local label="$1"
  local default="${2:-yes}"
  local hint="[Y/n]"
  local reply

  if [ "$ASSUME_YES" = "1" ]; then
    [ "$default" = "yes" ]
    return
  fi

  if [ "$default" = "no" ]; then
    hint="[y/N]"
  fi

  while true; do
    printf '%s %s: ' "$label" "$hint" >&2
    read -r reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Answer yes or no." >&2 ;;
    esac
  done
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this uninstaller with sudo." >&2
    exit 1
  fi
}

service_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$SERVICE_FILE" 2>/dev/null || true
}

service_arg() {
  local line="$1"
  local flag="$2"
  local default_value="$3"

  set -- $line
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$flag" ]; then
      shift
      printf '%s' "${1:-$default_value}"
      return
    fi
    shift
  done

  printf '%s' "$default_value"
}

detect_existing_install() {
  local exec_start
  local working_dir
  local state_file
  local wireguard_config

  if [ ! -f "$SERVICE_FILE" ]; then
    return
  fi

  exec_start="$(service_value "ExecStart")"
  working_dir="$(service_value "WorkingDirectory")"
  state_file="$(service_arg "$exec_start" "--state-file" "$STATE_DIR/vps-agent.json")"
  wireguard_config="$(service_arg "$exec_start" "--wireguard-config" "$CONFIG_DIR/wireguard/$WIREGUARD_INTERFACE.conf")"

  INSTALL_DIR="${working_dir:-$INSTALL_DIR}"
  STATE_DIR="$(dirname "$state_file")"
  CONFIG_DIR="$(dirname "$(dirname "$wireguard_config")")"
  LISTEN_PORT="$(service_arg "$exec_start" "--port" "$LISTEN_PORT")"
  WIREGUARD_INTERFACE="$(service_arg "$exec_start" "--wireguard-interface" "$WIREGUARD_INTERFACE")"
}

print_plan() {
  cat <<EOF

Tater Tunnel VPS uninstall plan:

  Service:        $SERVICE_NAME
  Install dir:    $INSTALL_DIR
  State dir:      $STATE_DIR
  Config dir:     $CONFIG_DIR
  Source dir:     $SOURCE_DIR
  WireGuard:      $WIREGUARD_INTERFACE
  Agent port:     $LISTEN_PORT

Will remove:
  - Tater Tunnel systemd service
  - Installed app files
  - Live WireGuard interface if it exists
  - Tater service user/group if state/config data is purged

Will keep unless selected:
  - Pairing/device state and WireGuard config
  - Downloaded source checkout
  - Caddy package and general Caddy configuration
  - Shared OS packages

EOF
}

stop_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
}

remove_wireguard_interface() {
  if command -v ip >/dev/null 2>&1 && ip link show "$WIREGUARD_INTERFACE" >/dev/null 2>&1; then
    ip link delete "$WIREGUARD_INTERFACE" >/dev/null 2>&1 || true
  fi
}

remove_ufw_rules() {
  if [ "$REMOVE_UFW_RULES" != "1" ] || ! command -v ufw >/dev/null 2>&1; then
    return
  fi

  ufw --force delete allow 51888/udp >/dev/null 2>&1 || true
  ufw --force delete allow in on "$WIREGUARD_INTERFACE" to any port "$LISTEN_PORT" proto tcp >/dev/null 2>&1 || true
}

disable_caddy_proxy() {
  local caddyfile="/etc/caddy/Caddyfile"
  local backup

  if [ "$DISABLE_CADDY_PROXY" != "1" ] || [ ! -f "$caddyfile" ]; then
    return
  fi

  if ! grep -q "127.0.0.1:$LISTEN_PORT" "$caddyfile"; then
    echo "Caddyfile does not appear to proxy to 127.0.0.1:$LISTEN_PORT; leaving it unchanged."
    return
  fi

  backup="$caddyfile.tater-uninstalled-$(date +%Y%m%d%H%M%S)"
  cp -a "$caddyfile" "$backup"
  cat > "$caddyfile" <<EOF
# Tater Tunnel proxy disabled by uninstall.
# Previous Caddyfile backup:
# $backup
EOF

  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
  fi
}

safe_remove_tree() {
  local path="$1"

  case "$path" in
    ""|"/"|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/sys"|"/tmp"|"/usr"|"/var"|"/var/lib")
      echo "Refusing to remove unsafe path: ${path:-<empty>}" >&2
      return 1
      ;;
  esac

  rm -rf "$path"
}

remove_paths() {
  safe_remove_tree "$INSTALL_DIR"

  if [ "$PURGE_DATA" = "1" ]; then
    safe_remove_tree "$STATE_DIR"
    safe_remove_tree "$CONFIG_DIR"
  fi

  if [ "$REMOVE_SOURCE" = "1" ]; then
    safe_remove_tree "$SOURCE_DIR"
  fi
}

remove_service_user() {
  if [ "$PURGE_DATA" != "1" ]; then
    return
  fi

  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    userdel "$SERVICE_USER" >/dev/null 2>&1 || true
  fi
  if getent group "$SERVICE_USER" >/dev/null 2>&1; then
    groupdel "$SERVICE_USER" >/dev/null 2>&1 || true
  fi
}

print_summary() {
  cat <<EOF

Tater Tunnel VPS uninstall complete.

Data:
  $([ "$PURGE_DATA" = "1" ] && printf 'State/config data was purged.' || printf 'Kept %s and %s' "$STATE_DIR" "$CONFIG_DIR")
  $([ "$REMOVE_SOURCE" = "1" ] && printf 'Source checkout was removed.' || printf 'Kept %s' "$SOURCE_DIR")

Notes:
  - Caddy, UFW, WireGuard tools, and Python packages were not uninstalled.
  - Public 80/443 firewall rules were left unchanged.
  - If this VPS was only for Tater Tunnel, you can remove unused packages later.

EOF
}

require_root
detect_existing_install
print_plan

if [ "$ASSUME_YES" != "1" ]; then
  confirm "Remove Tater Tunnel service, app files, and live WireGuard interface" yes || exit 0
  if confirm "Purge pairing/device state and WireGuard config" no; then
    PURGE_DATA="1"
  fi
  if confirm "Remove downloaded setup source at $SOURCE_DIR" no; then
    REMOVE_SOURCE="1"
  fi
  if ! confirm "Remove Tater WireGuard UFW rules" yes; then
    REMOVE_UFW_RULES="0"
  fi
  if confirm "Disable Caddy proxy if it points to Tater Tunnel" no; then
    DISABLE_CADDY_PROXY="1"
  fi
fi

stop_service
remove_wireguard_interface
remove_ufw_rules
disable_caddy_proxy
remove_paths
remove_service_user
print_summary
