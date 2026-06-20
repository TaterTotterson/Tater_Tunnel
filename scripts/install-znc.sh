#!/usr/bin/env bash
set -Eeuo pipefail

ZNC_USER=""
ZNC_PORT="6697"
DATA_DIR=""
RUN_MAKECONF="0"
OPEN_FIREWALL="0"
START_SERVICE="1"

usage() {
  cat <<'EOF'
Install ZNC as an optional user-owned VPS service.

This installs the znc package, creates a user-owned ~/.znc data directory,
and writes a systemd service that runs ZNC as that user. ZNC config stays in
the user's home folder.

Usage:
  sudo ./scripts/install-znc.sh --user tater [options]

Options:
  --user USER        Linux user that should own and run ZNC.
  --port PORT        ZNC listener port to mention/open. Default: 6697
  --data-dir PATH    ZNC data directory. Default: /home/USER/.znc
  --makeconf         Run ZNC's interactive config wizard during install.
  --open-firewall    Open PORT/tcp in UFW for ZNC.
  --no-start         Do not start/restart the systemd service.
  -h, --help         Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user)
      ZNC_USER="${2:?--user requires a value}"
      shift 2
      ;;
    --port)
      ZNC_PORT="${2:?--port requires a value}"
      shift 2
      ;;
    --data-dir)
      DATA_DIR="${2:?--data-dir requires a value}"
      shift 2
      ;;
    --makeconf)
      RUN_MAKECONF="1"
      shift
      ;;
    --open-firewall)
      OPEN_FIREWALL="1"
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

validate_user() {
  if [ -z "$ZNC_USER" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      ZNC_USER="$SUDO_USER"
    else
      echo "--user is required when the target sudo user cannot be detected." >&2
      exit 2
    fi
  fi

  if [ "$ZNC_USER" = "root" ]; then
    echo "Refusing to run ZNC as root. Choose a normal sudo user." >&2
    exit 2
  fi

  if ! [[ "$ZNC_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Use a Linux username like tater, admin, or tunnel-admin." >&2
    exit 2
  fi

  if ! id -u "$ZNC_USER" >/dev/null 2>&1; then
    echo "User $ZNC_USER does not exist." >&2
    exit 2
  fi
}

validate_port() {
  if ! [[ "$ZNC_PORT" =~ ^[0-9]+$ ]] || [ "$ZNC_PORT" -lt 1 ] || [ "$ZNC_PORT" -gt 65535 ]; then
    echo "Invalid ZNC port: $ZNC_PORT" >&2
    exit 2
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is required for this installer." >&2
    exit 1
  fi
}

install_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This installer currently supports Debian/Ubuntu systems with apt-get." >&2
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y znc
}

home_for_user() {
  getent passwd "$ZNC_USER" | awk -F: '{ print $6 }'
}

group_for_user() {
  id -gn "$ZNC_USER"
}

prepare_data_dir() {
  local home_dir
  local group

  home_dir="$(home_for_user)"
  if [ -z "$home_dir" ]; then
    echo "Could not find home directory for $ZNC_USER." >&2
    exit 1
  fi

  DATA_DIR="${DATA_DIR:-$home_dir/.znc}"
  group="$(group_for_user)"
  install -d -m 0700 -o "$ZNC_USER" -g "$group" "$DATA_DIR"
}

run_makeconf() {
  if [ "$RUN_MAKECONF" != "1" ]; then
    return
  fi

  if [ -f "$DATA_DIR/configs/znc.conf" ]; then
    echo "ZNC config already exists at $DATA_DIR/configs/znc.conf; skipping makeconf."
    return
  fi

  echo
  echo "Starting ZNC interactive config for $ZNC_USER."
  echo "Suggested listener port: $ZNC_PORT"
  echo
  runuser -u "$ZNC_USER" -- znc --makeconf --datadir "$DATA_DIR"
}

write_service() {
  local service_file="/etc/systemd/system/znc-$ZNC_USER.service"
  local home_dir
  local group
  local znc_bin

  home_dir="$(home_for_user)"
  group="$(group_for_user)"
  znc_bin="$(command -v znc)"

  cat > "$service_file" <<EOF
[Unit]
Description=ZNC IRC bouncer for $ZNC_USER
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ZNC_USER
Group=$group
WorkingDirectory=$home_dir
ExecStart=$znc_bin --foreground --datadir $DATA_DIR
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

configure_firewall() {
  if [ "$OPEN_FIREWALL" != "1" ]; then
    return
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW is not installed; skipping firewall rule for $ZNC_PORT/tcp."
    return
  fi

  ufw allow "$ZNC_PORT/tcp" comment 'ZNC IRC bouncer'
}

start_service_if_ready() {
  local service_name="znc-$ZNC_USER.service"

  if [ "$START_SERVICE" != "1" ]; then
    return
  fi

  if [ ! -f "$DATA_DIR/configs/znc.conf" ]; then
    return
  fi

  systemctl enable --now "$service_name"
}

print_summary() {
  local service_name="znc-$ZNC_USER"

  cat <<EOF

ZNC optional install complete.

User:
  $ZNC_USER

Config/data:
  $DATA_DIR

Service:
  sudo systemctl status $service_name
  sudo systemctl restart $service_name

EOF

  if [ -f "$DATA_DIR/configs/znc.conf" ]; then
    cat <<EOF
ZNC config exists and the service was $([ "$START_SERVICE" = "1" ] && printf 'started' || printf 'left stopped').

EOF
  else
    cat <<EOF
ZNC config has not been created yet. Finish setup with:

  sudo -iu $ZNC_USER znc --makeconf --datadir $DATA_DIR
  sudo systemctl enable --now $service_name

Use port $ZNC_PORT in the ZNC config if you want the firewall helper to match.

EOF
  fi

  if [ "$OPEN_FIREWALL" = "1" ]; then
    cat <<EOF
Firewall:
  Opened $ZNC_PORT/tcp for ZNC.

EOF
  else
    cat <<EOF
Firewall:
  No ZNC firewall rule was added. Open $ZNC_PORT/tcp later if clients should
  connect directly to this VPS.

EOF
  fi
}

require_root
validate_user
validate_port
require_systemd
install_packages
prepare_data_dir
run_makeconf
write_service
configure_firewall
start_service_if_ready
print_summary
