#!/usr/bin/env bash
set -Eeuo pipefail

ZNC_USER=""
ZNC_PORT="6697"
DATA_DIR=""
RUN_MAKECONF="0"
OPEN_FIREWALL="0"
START_SERVICE="1"
WEB_LISTEN_PORT=""

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
  --web-listen-port PORT
                     Add a web-only listener on 127.0.0.1 for a local reverse
                     proxy. The port is not opened in UFW.
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
    --web-listen-port)
      WEB_LISTEN_PORT="${2:?--web-listen-port requires a value}"
      shift 2
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

  if [ -n "$WEB_LISTEN_PORT" ]; then
    if ! [[ "$WEB_LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$WEB_LISTEN_PORT" -lt 1 ] || [ "$WEB_LISTEN_PORT" -gt 65535 ]; then
      echo "Invalid ZNC web listener port: $WEB_LISTEN_PORT" >&2
      exit 2
    fi
    if [ "$WEB_LISTEN_PORT" = "$ZNC_PORT" ]; then
      echo "The ZNC IRC and private web listener ports must be different." >&2
      exit 2
    fi
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
  echo "Choose SSL for the public IRC listener and answer no if asked to launch ZNC."
  echo "The installer will start ZNC through systemd after setup."
  echo
  runuser -u "$ZNC_USER" -- znc --makeconf --datadir "$DATA_DIR"
}

configure_private_web_listener() {
  local config_file="$DATA_DIR/configs/znc.conf"
  local stripped_file
  local irc_only_file
  local updated_file
  local add_webadmin="0"
  local add_trusted_proxy="0"

  if [ -z "$WEB_LISTEN_PORT" ]; then
    return
  fi

  if [ ! -f "$config_file" ]; then
    cat <<EOF >&2
Cannot add the private ZNC WebAdmin listener because no config exists at:
  $config_file

Run the installer with --makeconf, or create the ZNC config first and rerun it.
EOF
    exit 1
  fi

  stripped_file="$(mktemp)"
  irc_only_file="$(mktemp)"
  updated_file="$(mktemp)"

  awk '
    /^[[:space:]]*<Listener[[:space:]]+tater-web[[:space:]]*>[[:space:]]*$/ {
      skipping = 1
      next
    }
    skipping {
      if ($0 ~ /^[[:space:]]*<\/Listener>[[:space:]]*$/) {
        skipping = 0
      }
      next
    }
    /^[[:space:]]*ProtectWebSessions[[:space:]]*=/ { next }
    /^[[:space:]]*HideVersion[[:space:]]*=/ { next }
    { print }
  ' "$config_file" > "$stripped_file"

  awk -v irc_port="$ZNC_PORT" '
    function flush_listener(    i, line) {
      for (i = 1; i <= line_count; i++) {
        line = listener_lines[i]
        if (target_listener && line ~ /^[[:space:]]*AllowWeb[[:space:]]*=/) {
          sub(/=.*/, "= false", line)
        }
        if (target_listener && !has_allow_web && line ~ /^[[:space:]]*<\/Listener>[[:space:]]*$/) {
          print "\tAllowWeb = false"
        }
        print line
      }
      delete listener_lines
      line_count = 0
      target_listener = 0
      has_allow_web = 0
      in_listener = 0
    }
    /^[[:space:]]*<Listener([[:space:]][^>]*)?>[[:space:]]*$/ {
      in_listener = 1
      listener_lines[++line_count] = $0
      next
    }
    in_listener {
      listener_lines[++line_count] = $0
      if ($0 ~ "^[[:space:]]*Port[[:space:]]*=[[:space:]]*" irc_port "[[:space:]]*$") {
        target_listener = 1
      }
      if ($0 ~ /^[[:space:]]*AllowWeb[[:space:]]*=/) {
        has_allow_web = 1
      }
      if ($0 ~ /^[[:space:]]*<\/Listener>[[:space:]]*$/) {
        flush_listener()
      }
      next
    }
    { print }
    END {
      if (in_listener) {
        flush_listener()
      }
    }
  ' "$stripped_file" > "$irc_only_file"

  if ! grep -Eq '^[[:space:]]*LoadModule[[:space:]]*=[[:space:]]*webadmin([[:space:]]|$)' "$irc_only_file"; then
    add_webadmin="1"
  fi
  if ! grep -Eq '^[[:space:]]*TrustedProxy[[:space:]]*=[[:space:]]*127\.0\.0\.1(/32)?[[:space:]]*$' "$irc_only_file"; then
    add_trusted_proxy="1"
  fi

  awk \
    -v web_port="$WEB_LISTEN_PORT" \
    -v add_webadmin="$add_webadmin" \
    -v add_trusted_proxy="$add_trusted_proxy" '
    function print_web_listener() {
      if (add_webadmin == "1") {
        print "LoadModule = webadmin"
        print ""
      }
      print "ProtectWebSessions = true"
      print "HideVersion = true"
      if (add_trusted_proxy == "1") {
        print "TrustedProxy = 127.0.0.1"
      }
      print ""
      print "<Listener tater-web>"
      print "\tAllowIRC = false"
      print "\tAllowWeb = true"
      print "\tHost = 127.0.0.1"
      print "\tIPv4 = true"
      print "\tIPv6 = false"
      print "\tPort = " web_port
      print "\tSSL = false"
      print "\tURIPrefix = /"
      print "</Listener>"
      print ""
    }
    !inserted && /^[[:space:]]*<User[[:space:]][^>]+>[[:space:]]*$/ {
      print_web_listener()
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        print ""
        print_web_listener()
      }
    }
  ' "$irc_only_file" > "$updated_file"

  cp -a "$config_file" "$config_file.tater-backup-$(date +%Y%m%d%H%M%S)"
  install -m 0600 -o "$ZNC_USER" -g "$(group_for_user)" "$updated_file" "$config_file"
  rm -f "$stripped_file" "$irc_only_file" "$updated_file"
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

  systemctl enable "$service_name"
  systemctl restart "$service_name"
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

  if [ -n "$WEB_LISTEN_PORT" ]; then
    cat <<EOF
Private WebAdmin listener:
  http://127.0.0.1:$WEB_LISTEN_PORT

This port is bound to localhost and was not opened in UFW. Put an HTTPS reverse
proxy such as Caddy in front of it instead of exposing the port directly.
The public listener on $ZNC_PORT was limited to IRC traffic only.
Web sessions are protected, the version is hidden, and only the local Caddy
proxy is trusted to supply the original client address.

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
configure_private_web_listener
write_service
configure_firewall
start_service_if_ready
print_summary
