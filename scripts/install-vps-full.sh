#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN=""
EMAIL=""
SSH_PORT="22"
LISTEN_PORT="4174"
PAIRING_CODE=""
NO_FIREWALL="0"
ALLOW_ROOT_LOGIN="0"

usage() {
  cat <<'EOF'
Install the full Tater Tunnel VPS stack for a blank Debian/Ubuntu VPS.

This installs:
  - Tater Tunnel VPS Agent on 127.0.0.1:4174
  - WireGuard system backend
  - Caddy reverse proxy with automatic HTTPS
  - UFW rules for SSH, HTTP, HTTPS, and WireGuard

Usage:
  sudo ./scripts/install-vps-full.sh --domain tunnel.example.com [options]

Options:
  --domain DOMAIN         Public DNS name pointed at this VPS. Required.
  --email EMAIL           Optional ACME account email for Caddy.
  --ssh-port PORT         SSH port to keep open. Default: 22
  --listen-port PORT      Local VPS Agent port. Default: 4174
  --pairing-code CODE     Initial pairing code. Generated if omitted.
  --no-firewall           Do not configure UFW.
  --allow-root-login      Advanced: install even when logged in directly as root.
  -h, --help              Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain)
      DOMAIN="${2:?--domain requires a value}"
      shift 2
      ;;
    --email)
      EMAIL="${2:?--email requires a value}"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="${2:?--ssh-port requires a value}"
      shift 2
      ;;
    --listen-port)
      LISTEN_PORT="${2:?--listen-port requires a value}"
      shift 2
      ;;
    --pairing-code)
      PAIRING_CODE="${2:?--pairing-code requires a value}"
      shift 2
      ;;
    --no-firewall)
      NO_FIREWALL="1"
      shift
      ;;
    --allow-root-login)
      ALLOW_ROOT_LOGIN="1"
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

guard_root_login() {
  if [ "$ALLOW_ROOT_LOGIN" = "1" ]; then
    return
  fi

  if [ "$(id -u)" -eq 0 ] && { [ -z "${SUDO_USER:-}" ] || [ "${SUDO_USER:-}" = "root" ]; }; then
    cat <<'EOF' >&2
Root login detected.

For a blank VPS, create a normal sudo user before running the full installer.
Use the guided setup first:

  curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
    -o /tmp/tater-vps-setup.sh && bash /tmp/tater-vps-setup.sh

It can create the sudo user, show SSH key setup commands, and stop. Then log in
as the new user and rerun setup with sudo:

  curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
    -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh

Advanced override:
  ./scripts/install-vps-full.sh --allow-root-login --domain tunnel.example.com
EOF
    exit 1
  fi
}

normalize_domain() {
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%%/*}"
  if [ -z "$DOMAIN" ]; then
    echo "--domain is required." >&2
    usage >&2
    exit 2
  fi
  if printf '%s' "$DOMAIN" | grep -q ':'; then
    echo "Use a plain domain for --domain, not a host:port value." >&2
    exit 2
  fi
}

install_caddy() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This installer currently supports Debian/Ubuntu systems with apt-get." >&2
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl debian-archive-keyring debian-keyring gpg apt-transport-https

  install -d -m 0755 /usr/share/keyrings
  rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    -o /etc/apt/sources.list.d/caddy-stable.list

  apt-get update
  apt-get install -y caddy
}

install_agent() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  local args=(
    "$script_dir/install-vps-agent.sh"
    --listen-host 127.0.0.1
    --listen-port "$LISTEN_PORT"
    --wireguard-client-access
  )

  if [ -n "$PAIRING_CODE" ]; then
    args+=(--pairing-code "$PAIRING_CODE")
  fi

  "${args[@]}"
}

write_caddyfile() {
  local caddyfile="/etc/caddy/Caddyfile"
  if [ -f "$caddyfile" ]; then
    cp -a "$caddyfile" "$caddyfile.tater-backup-$(date +%Y%m%d%H%M%S)"
  fi

  if [ -n "$EMAIL" ]; then
    cat > "$caddyfile" <<EOF
{
  email $EMAIL
}

$DOMAIN {
  reverse_proxy 127.0.0.1:$LISTEN_PORT
}
EOF
  else
    cat > "$caddyfile" <<EOF
$DOMAIN {
  reverse_proxy 127.0.0.1:$LISTEN_PORT
}
EOF
  fi

  caddy fmt --overwrite "$caddyfile" >/dev/null
  systemctl enable --now caddy >/dev/null
  systemctl reload caddy || systemctl restart caddy
}

configure_firewall() {
  if [ "$NO_FIREWALL" = "1" ]; then
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y ufw

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$SSH_PORT/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'Caddy HTTP and ACME'
  ufw allow 443/tcp comment 'Caddy HTTPS'
  ufw allow in on tater0 to any port "$LISTEN_PORT" proto tcp comment 'Tater Tunnel WireGuard relay'
  ufw allow 51888/udp comment 'Tater Tunnel WireGuard'
  ufw --force enable
}

print_summary() {
  cat <<EOF

Tater Tunnel full VPS stack installed.

Pair the Home Agent with:
  VPS IP or Domain: https://$DOMAIN
  Pairing Code: $(cat /var/lib/tater-tunnel/pairing-code)

Public ports expected:
  80/tcp    Caddy HTTP and ACME
  443/tcp   Caddy HTTPS
  51888/udp WireGuard devices

WireGuard-only relay:
  http://10.88.0.1:$LISTEN_PORT/relay/

Private local service:
  http://127.0.0.1:$LISTEN_PORT

Useful checks:
  sudo systemctl status tater-tunnel-vps
  sudo systemctl status caddy
  curl -fsS https://$DOMAIN/api/health
  sudo wg show tater0
EOF
}

guard_root_login
require_root
normalize_domain
install_caddy
install_agent
write_caddyfile
configure_firewall
print_summary
