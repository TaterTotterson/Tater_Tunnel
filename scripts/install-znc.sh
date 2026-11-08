#!/usr/bin/env bash
set -Eeuo pipefail

ZNC_USER=""
ZNC_PORT="6697"
DATA_DIR=""
RUN_MAKECONF="0"
START_SERVICE="1"
WEB_LISTEN_PORT="6698"
SKIP_PACKAGES="0"
ADMIN_USER=""
ADMIN_PASSWORD_FILE=""

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
  --port PORT        ZNC listener port to allow through WireGuard. Default: 6697
  --data-dir PATH    ZNC data directory. Default: /home/USER/.znc
  --makeconf         Run ZNC's interactive config wizard during install.
  --admin-user USER  Create the first managed ZNC administrator when no config
                     exists. Requires --admin-password-file.
  --admin-password-file PATH
                     Read the initial administrator password from PATH. The
                     password is hashed and is never stored in znc.conf.
  --web-listen-port PORT
                     Private WireGuard-only WebAdmin port. Default: 6698
  --skip-packages    Do not run apt; use the currently installed ZNC package.
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
    --admin-user)
      ADMIN_USER="${2:?--admin-user requires a value}"
      shift 2
      ;;
    --admin-password-file)
      ADMIN_PASSWORD_FILE="${2:?--admin-password-file requires a value}"
      shift 2
      ;;
    --web-listen-port)
      WEB_LISTEN_PORT="${2:?--web-listen-port requires a value}"
      shift 2
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

validate_managed_admin() {
  if [ -z "$ADMIN_USER" ] && [ -z "$ADMIN_PASSWORD_FILE" ]; then
    return
  fi
  if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASSWORD_FILE" ]; then
    echo "--admin-user and --admin-password-file must be used together." >&2
    exit 2
  fi
  if ! [[ "$ADMIN_USER" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]]; then
    echo "Use a ZNC administrator name containing letters, numbers, underscores, or hyphens." >&2
    exit 2
  fi
  if [ ! -f "$ADMIN_PASSWORD_FILE" ] || [ ! -r "$ADMIN_PASSWORD_FILE" ]; then
    echo "Cannot read the ZNC administrator password file." >&2
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
  if [ "$SKIP_PACKAGES" = "1" ]; then
    if ! command -v znc >/dev/null 2>&1; then
      echo "ZNC is not installed; rerun without --skip-packages." >&2
      exit 1
    fi
    return
  fi
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
  echo "Choose SSL for the private IRC listener and answer no if asked to launch ZNC."
  echo "The installer will start ZNC through systemd after setup."
  echo
  runuser -u "$ZNC_USER" -- znc --makeconf --datadir "$DATA_DIR"
}

create_managed_config() {
  local config_dir="$DATA_DIR/configs"
  local config_file="$config_dir/znc.conf"
  local group
  local password
  local salt
  local password_hash
  local version
  local temp_file

  if [ -f "$config_file" ] || [ -z "$ADMIN_USER" ]; then
    return
  fi

  IFS= read -r password < "$ADMIN_PASSWORD_FILE" || true
  if [ "${#password}" -lt 12 ]; then
    echo "The initial ZNC administrator password must contain at least 12 characters." >&2
    exit 2
  fi

  salt="$(od -An -N10 -tx1 /dev/urandom | tr -d '[:space:]')"
  password_hash="$(printf '%s' "${password}${salt}" | sha256sum | awk '{ print $1 }')"
  password=""
  version="$(znc --version 2>/dev/null | sed -nE 's/^ZNC[[:space:]]+([^[:space:]]+).*/\1/p' | head -n 1)"
  version="${version:-1.10}"
  group="$(group_for_user)"

  install -d -m 0700 -o "$ZNC_USER" -g "$group" "$config_dir"
  temp_file="$(mktemp)"
  cat > "$temp_file" <<EOF
Version = $version
ProtectWebSessions = true
HideVersion = true

<Listener tater-irc>
	AllowIRC = true
	AllowWeb = false
	Host = 0.0.0.0
	IPv4 = true
	IPv6 = false
	Port = $ZNC_PORT
	SSL = false
</Listener>

<User $ADMIN_USER>
	<Pass password>
		Method = SHA256
		Hash = $password_hash
		Salt = $salt
	</Pass>
	Admin = true
	Nick = $ADMIN_USER
	AltNick = ${ADMIN_USER}_
	Ident = $ADMIN_USER
	RealName = $ADMIN_USER
	Buffer = 50
	AutoClearChanBuffer = true
	MultiClients = true
	LoadModule = chansaver
	LoadModule = controlpanel
</User>
EOF
  install -m 0600 -o "$ZNC_USER" -g "$group" "$temp_file" "$config_file"
  rm -f "$temp_file"
  echo "Created a managed ZNC configuration for administrator $ADMIN_USER."
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
    cat <<EOF
The private ZNC WebAdmin listener will be added after a config exists at:
  $config_file

Create the ZNC config, then rerun this installer.
EOF
    return
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

  awk '
    function flush_listener(    i, line) {
      for (i = 1; i <= line_count; i++) {
        line = listener_lines[i]
        if (line ~ /^[[:space:]]*AllowWeb[[:space:]]*=/) {
          sub(/=.*/, "= false", line)
        }
        if (!has_allow_web && line ~ /^[[:space:]]*<\/Listener>[[:space:]]*$/) {
          print "\tAllowWeb = false"
        }
        print line
      }
      delete listener_lines
      line_count = 0
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
      print "\tHost = 0.0.0.0"
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
  if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW is required to keep ZNC private to Tater Tunnel." >&2
    exit 1
  fi
  if ! ufw status | grep -q '^Status: active'; then
    echo "UFW must be active before ZNC can be exposed through Tater Tunnel." >&2
    exit 1
  fi

  ufw --force delete allow "$ZNC_PORT/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$ZNC_PORT" >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$ZNC_PORT" proto tcp >/dev/null 2>&1 || true
  ufw --force delete deny in to any port "$ZNC_PORT" proto tcp >/dev/null 2>&1 || true
  ufw allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$ZNC_PORT" proto tcp comment 'ZNC private WireGuard'
  ufw deny in to any port "$ZNC_PORT" proto tcp comment 'Block public ZNC'
  ufw --force delete allow "$WEB_LISTEN_PORT/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$WEB_LISTEN_PORT" >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$WEB_LISTEN_PORT" proto tcp >/dev/null 2>&1 || true
  ufw --force delete deny in to any port "$WEB_LISTEN_PORT" proto tcp >/dev/null 2>&1 || true
  ufw allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$WEB_LISTEN_PORT" proto tcp comment 'ZNC WebAdmin private WireGuard'
  ufw deny in to any port "$WEB_LISTEN_PORT" proto tcp comment 'Block public ZNC WebAdmin'
  ufw reload >/dev/null
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
    if [ -n "$ADMIN_USER" ]; then
      printf 'Initial administrator:\n  %s\n\n' "$ADMIN_USER"
    fi
  else
    cat <<EOF
ZNC config has not been created yet. Finish setup with:

  sudo -iu $ZNC_USER znc --makeconf --datadir $DATA_DIR
  sudo systemctl enable --now $service_name

Use port $ZNC_PORT in the ZNC config if you want the firewall helper to match.

EOF
  fi

  if [ -f "$DATA_DIR/configs/znc.conf" ]; then
    cat <<EOF
Private WebAdmin listener:
  http://10.88.0.1:$WEB_LISTEN_PORT/

Connect Tater Tunnel WireGuard before opening WebAdmin. The listener on
$ZNC_PORT is limited to IRC traffic only. Web sessions are protected and the
version is hidden.

EOF
  fi

  cat <<EOF
Firewall:
  Allowed $ZNC_PORT/tcp only from 10.88.0.0/24 on tater0.
  Blocked public access to $ZNC_PORT/tcp.
  Allowed $WEB_LISTEN_PORT/tcp only through WireGuard for WebAdmin.
  Blocked public access to $WEB_LISTEN_PORT/tcp.

EOF
}

main() {
  require_root
  validate_user
  validate_port
  validate_managed_admin
  require_systemd
  configure_firewall
  install_packages
  prepare_data_dir
  run_makeconf
  create_managed_config
  configure_private_web_listener
  write_service
  start_service_if_ready
  print_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
