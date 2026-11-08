#!/usr/bin/env bash
set -u

SERVICE_NAME="tater-tunnel-vps"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="/var/lib/tater-tunnel"
CONFIG_DIR="/etc/tater-tunnel"
CADDYFILE="/etc/caddy/Caddyfile"
ZNC_CADDY_SNIPPET="/etc/caddy/tater-sites/znc-web.caddy"
WEBDAV_CADDY_SNIPPET="/etc/caddy/tater-sites/sftpgo-webdav.caddy"
LISTEN_PORT="4174"
DOMAIN=""
FAILURES=0
WARNINGS=0

usage() {
  cat <<'EOF'
Audit the security boundary of a Tater Tunnel VPS install.

Usage:
  sudo ./scripts/audit-vps-security.sh [options]

Options:
  --domain DOMAIN       Test the public Caddy boundary for this hostname.
  --listen-port PORT    VPS Agent port. Default: 4174
  --state-dir PATH      State directory. Default: /var/lib/tater-tunnel
  --config-dir PATH     Config directory. Default: /etc/tater-tunnel
  -h, --help            Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:?--domain requires a value}"; shift 2 ;;
    --listen-port) LISTEN_PORT="${2:?--listen-port requires a value}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:?--state-dir requires a value}"; shift 2 ;;
    --config-dir) CONFIG_DIR="${2:?--config-dir requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

pass() { printf '[PASS] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

has_tcp_deny_rule() {
  local added="$1"
  local port="$2"

  grep -Eq "^ufw deny( in)? (${port}|${port}/tcp)([[:space:]]|$)" <<< "$added" \
    || grep -Fq "ufw deny in to any port ${port} proto tcp" <<< "$added"
}

has_broad_tcp_allow_rule() {
  local added="$1"
  local port="$2"

  grep -Eq "^ufw allow( in)? (${port}|${port}/tcp)([[:space:]]|$)" <<< "$added" \
    || grep -Fq "ufw allow in to any port ${port} proto tcp" <<< "$added"
}

check_private_optional_port() {
  local added="$1"
  local port="$2"
  local label="$3"

  if grep -Fq "allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port ${port} proto tcp" <<< "$added"; then
    pass "$label is allowed through WireGuard on TCP $port"
  else
    fail "$label is missing its WireGuard-only TCP $port allow rule"
  fi
  if has_tcp_deny_rule "$added" "$port"; then
    pass "$label TCP $port is denied on public interfaces"
  else
    fail "$label is missing its public TCP $port deny rule"
  fi
  if has_broad_tcp_allow_rule "$added" "$port"; then
    fail "$label still has a broad public TCP $port allow rule"
  else
    pass "$label has no broad public TCP $port allow rule"
  fi
}

check_public_optional_port() {
  local added="$1"
  local port="$2"
  local label="$3"

  if has_broad_tcp_allow_rule "$added" "$port"; then
    pass "$label is allowed publicly on TCP $port"
  else
    fail "$label is missing its public TCP $port allow rule"
  fi
  if has_tcp_deny_rule "$added" "$port"; then
    fail "$label TCP $port is still blocked on public interfaces"
  else
    pass "$label TCP $port has no conflicting public deny rule"
  fi
}

check_disabled_optional_port() {
  local added="$1"
  local port="$2"
  local label="$3"

  if has_broad_tcp_allow_rule "$added" "$port" \
    || grep -Fq "allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port ${port} proto tcp" <<< "$added"; then
    fail "$label is disabled but still has an allow rule on TCP $port"
  else
    pass "$label is disabled with no TCP $port allow rule"
  fi
  if has_tcp_deny_rule "$added" "$port"; then
    pass "$label disabled TCP $port is denied"
  else
    fail "$label disabled TCP $port is missing its deny rule"
  fi
}

check_sftpgo_access() {
  local added="$1"
  local access="$2"
  local port="$3"
  local label="$4"

  case "$access" in
    public) check_public_optional_port "$added" "$port" "$label" ;;
    private) check_private_optional_port "$added" "$port" "$label" ;;
    https) check_private_optional_port "$added" "$port" "$label backend" ;;
    disabled) check_disabled_optional_port "$added" "$port" "$label" ;;
    *) fail "$label has an unknown managed access mode: $access" ;;
  esac
}

managed_sftpgo_access() {
  local protocol="$1"
  local env_file="/etc/sftpgo/env.d/tater-tunnel.env"
  local value

  value="$(sed -nE "s/^# TATER_SFTPGO_${protocol}_ACCESS=(disabled|private|public|https)$/\\1/p" "$env_file" 2>/dev/null | tail -n 1)"
  printf '%s' "${value:-disabled}"
}

check_sftpgo_port() {
  local added="$1"
  local env_file="/etc/sftpgo/env.d/tater-tunnel.env"
  local ftp_access
  local webdav_access
  local webdav_domain

  if grep -q '^# TATER_SFTPGO_SFTP_ACCESS=' "$env_file" 2>/dev/null; then
    ftp_access="$(managed_sftpgo_access FTP)"
    webdav_access="$(managed_sftpgo_access WEBDAV)"
    webdav_domain="$(sed -nE 's/^# TATER_SFTPGO_WEBDAV_DOMAIN=([a-zA-Z0-9.-]+)$/\1/p' "$env_file" | tail -n 1)"
    check_sftpgo_access "$added" "$(managed_sftpgo_access SFTP)" 2022 "SFTPGo SFTP"
    check_sftpgo_access "$added" "$ftp_access" 2121 "SFTPGo FTP"
    check_sftpgo_access "$added" "$ftp_access" 50000:50100 "SFTPGo FTP passive data"
    check_sftpgo_access "$added" "$webdav_access" 10080 "SFTPGo WebDAV"
    if [ "$ftp_access" = "public" ]; then
      warn "Public FTP is unencrypted; prefer SFTP or WireGuard-only access"
    fi
    if [ "$webdav_access" = "https" ]; then
      if [ -n "$webdav_domain" ] \
        && [ -f "$WEBDAV_CADDY_SNIPPET" ] \
        && grep -Fqx "$webdav_domain {" "$WEBDAV_CADDY_SNIPPET" \
        && grep -Eq '^[[:space:]]*reverse_proxy[[:space:]]+127\.0\.0\.1:10080([[:space:]]+\{)?[[:space:]]*$' "$WEBDAV_CADDY_SNIPPET" \
        && grep -Eq '^[[:space:]]*header_up[[:space:]]+Host[[:space:]]+\{host\}[[:space:]]*$' "$WEBDAV_CADDY_SNIPPET"; then
        pass "SFTPGo WebDAV HTTPS proxy is configured for $webdav_domain"
      else
        fail "SFTPGo WebDAV HTTPS proxy is missing or does not match its managed domain"
      fi
    elif [ -f "$WEBDAV_CADDY_SNIPPET" ]; then
      fail "SFTPGo WebDAV HTTPS proxy remains enabled while external WebDAV is off"
    fi
  elif has_broad_tcp_allow_rule "$added" 2022; then
    check_public_optional_port "$added" 2022 "SFTPGo SFTP"
  else
    check_private_optional_port "$added" 2022 "SFTPGo SFTP"
  fi
  check_private_optional_port "$added" 8080 "SFTPGo WebAdmin"
}

installed_znc_ports() {
  local config
  local data_dir
  local service_file

  for config in /home/*/.znc/configs/znc.conf /root/.znc/configs/znc.conf; do
    [ -f "$config" ] || continue
    sed -nE 's/^[[:space:]]*Port[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$config"
  done
  for service_file in /etc/systemd/system/znc-*.service; do
    [ -f "$service_file" ] || continue
    data_dir="$(sed -nE 's|^ExecStart=.*--datadir[= ]([^ ]+).*$|\1|p' "$service_file" | head -n 1)"
    config="${data_dir%/}/configs/znc.conf"
    [ -f "$config" ] || continue
    sed -nE 's/^[[:space:]]*Port[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$config"
  done
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

check_private_mode() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local mode
  if [ ! -e "$path" ]; then
    warn "$label does not exist yet: $path"
    return
  fi
  mode="$(file_mode "$path")"
  if [ "$mode" = "$expected" ]; then
    pass "$label permissions are $expected"
  else
    fail "$label permissions are ${mode:-unknown}; expected $expected"
  fi
}

echo "Tater Tunnel VPS security audit"
echo

if [ "$(id -u)" -ne 0 ]; then
  warn "Run with sudo for complete firewall, service, and state checks"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME"; then
  pass "$SERVICE_NAME is active"
else
  fail "$SERVICE_NAME is not active"
fi

if [ -f "$SERVICE_FILE" ]; then
  for setting in \
    'NoNewPrivileges=true' \
    'ProtectSystem=strict' \
    'ProtectHome=true' \
    'PrivateDevices=true' \
    'RestrictNamespaces=true' \
    'SocketBindDeny=any' \
    "SocketBindAllow=tcp:${LISTEN_PORT}" \
    'SocketBindAllow=udp:51888'; do
    if grep -Fxq "$setting" "$SERVICE_FILE"; then
      pass "systemd has $setting"
    else
      fail "systemd is missing $setting"
    fi
  done
else
  fail "Service unit is missing: $SERVICE_FILE"
fi

check_private_mode "$STATE_DIR" "700" "State directory"
check_private_mode "$CONFIG_DIR" "700" "Config directory"
check_private_mode "$CONFIG_DIR/wireguard" "700" "WireGuard config directory"
check_private_mode "$STATE_DIR/pairing-code" "600" "Pairing code"
check_private_mode "$STATE_DIR/vps-agent.json" "600" "VPS state"
check_private_mode "$CONFIG_DIR/wireguard/tater0.conf" "600" "WireGuard server config"

state_file="$STATE_DIR/vps-agent.json"
if [ -f "$state_file" ] && command -v python3 >/dev/null 2>&1; then
  if python3 - "$state_file" <<'PY'
import base64
import binascii
import ipaddress
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
network = ipaddress.ip_network(state["interface"]["network"], strict=True)
server = ipaddress.ip_interface(state["interface"]["address"]).ip
home_address = ipaddress.ip_address("10.88.0.2")
home = state.get("homeAgent") or {}
if state.get("claimed"):
    if home.get("transport") != "wireguard" or home.get("allowedIp") != "10.88.0.2/32":
        raise SystemExit(1)
    if not home.get("managementToken"):
        raise SystemExit(1)
for peer in state.get("peers", []):
    try:
        public_key = base64.b64decode(str(peer.get("publicKey") or ""), validate=True)
    except (binascii.Error, ValueError):
        raise SystemExit(1)
    if len(public_key) != 32 or not any(public_key):
        raise SystemExit(1)
    allowed = ipaddress.ip_network(str(peer.get("allowedIp") or ""), strict=True)
    if allowed.prefixlen != allowed.max_prefixlen:
        raise SystemExit(1)
    if allowed.network_address not in network or allowed.network_address in {server, home_address}:
        raise SystemExit(1)
PY
  then
    pass "Stored Home Agent and device peers use exact WireGuard addresses"
  else
    fail "Stored tunnel identities or peer Allowed IPs are invalid"
  fi

  state_status="$(python3 - "$state_file" <<'PY'
import json
import sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
if not state.get("claimed"):
    print("unclaimed")
elif (state.get("pairing") or {}).get("enabled"):
    print("claimed-pairing-open")
else:
    print("claimed-pairing-closed")
PY
)"
  if [ "$state_status" = "claimed-pairing-closed" ]; then
    pass "One-time pairing is closed"
  elif [ "$state_status" = "claimed-pairing-open" ]; then
    warn "Pairing is open on a claimed VPS"
  else
    warn "The VPS has not been claimed yet"
  fi

  if [[ "$state_status" == claimed-* ]]; then
    if command -v wg >/dev/null 2>&1 && wg show tater0 >/dev/null 2>&1; then
      allowed_ips="$(wg show tater0 allowed-ips 2>/dev/null || true)"
      if WG_ALLOWED_IPS="$allowed_ips" python3 - "$state_file" <<'PY'
import json
import os
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
expected = {}
home = state.get("homeAgent") or {}
if home.get("publicKey"):
    expected[str(home["publicKey"])] = "10.88.0.2/32"
for peer in state.get("peers", []):
    if str(peer.get("status") or "active").lower() == "active":
        expected[str(peer.get("publicKey") or "")] = str(peer.get("allowedIp") or "")
actual = {}
for line in os.environ.get("WG_ALLOWED_IPS", "").splitlines():
    key, _, allowed = line.partition("\t")
    if key:
        actual[key] = allowed
raise SystemExit(0 if actual == expected else 1)
PY
      then
        pass "Live WireGuard peers exactly match active stored peers"
      else
        fail "Live WireGuard peers differ from active stored peers"
      fi
    else
      fail "The claimed VPS does not have a live tater0 interface"
    fi
  fi
fi

private_api_status="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 5 \
  "http://127.0.0.1:${LISTEN_PORT}/api/state" 2>/dev/null || true)"
if [ "$private_api_status" = "403" ] || [ "$private_api_status" = "409" ]; then
  pass "Private management API rejects unauthenticated loopback requests"
else
  fail "Private management API returned HTTP ${private_api_status:-unreachable} without a token"
fi

removed_path_status="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 5 \
  "http://127.0.0.1:${LISTEN_PORT}/relay/security-audit" 2>/dev/null || true)"
if [ "$removed_path_status" = "404" ]; then
  pass "Legacy HTTP application forwarding endpoint is absent"
else
  fail "Removed forwarding path returned HTTP ${removed_path_status:-unreachable}; expected 404"
fi

if [ -f "$CADDYFILE" ] \
  && grep -Eq '^[[:space:]]*@bootstrap[[:space:]]+path[[:space:]]+/[[:space:]]+/assets/tater-vps-mascot\.png[[:space:]]+/api/claim' "$CADDYFILE" \
  && grep -Eq '^[[:space:]]*respond[[:space:]]+404[[:space:]]*$' "$CADDYFILE"; then
  pass "Caddy exposes only the landing page and one-time pairing endpoint"
else
  fail "Caddy bootstrap-only boundary is missing"
fi
if [ -f "$ZNC_CADDY_SNIPPET" ]; then
  fail "Legacy public ZNC Caddy route is still installed"
else
  pass "No public ZNC Caddy route is installed"
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  added="$(ufw show added 2>/dev/null || true)"
  if grep -Fq "allow in on tater0 from 10.88.0.2 to 10.88.0.1 port ${LISTEN_PORT} proto tcp" <<< "$added"; then
    pass "UFW limits management to the Home Agent WireGuard address"
  else
    fail "UFW is missing the exact Home Agent management rule"
  fi
  if has_tcp_deny_rule "$added" "$LISTEN_PORT"; then
    pass "UFW denies public TCP $LISTEN_PORT"
  else
    fail "UFW is missing the public management-port deny"
  fi
  for protocol in tcp udp; do
    if grep -Fq "route allow in on tater0 out on tater0 from 10.88.0.0/24 to 10.88.0.2 port 30000:30999 proto ${protocol}" <<< "$added"; then
      pass "UFW allows private ${protocol^^} service forwarding only to 10.88.0.2"
    else
      fail "UFW is missing the private ${protocol^^} service-forward rule"
    fi
  done
  if grep -Fq "allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port ${LISTEN_PORT}" <<< "$added"; then
    fail "UFW still has a broad device-network management rule"
  else
    pass "No broad device-network management rule remains"
  fi
  if command -v sftpgo >/dev/null 2>&1 || systemctl cat sftpgo.service >/dev/null 2>&1; then
    check_sftpgo_port "$added"
  fi
  found_znc="0"
  while read -r port; do
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
      check_private_optional_port "$added" "$port" ZNC
      found_znc="1"
    fi
  done < <(installed_znc_ports | sort -un)
  if [ "$found_znc" = "0" ] && compgen -G '/etc/systemd/system/znc-*.service' >/dev/null; then
    check_private_optional_port "$added" 6697 ZNC
  fi
else
  fail "UFW is not active"
fi

if [ -n "$DOMAIN" ]; then
  health_status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMAIN}/api/health" 2>/dev/null || true)"
  if [ "$health_status" = "404" ]; then
    pass "Public HTTPS hides the health and management APIs"
  else
    fail "Public /api/health returned HTTP ${health_status:-unreachable}; expected 404"
  fi
fi

echo
printf 'Failures: %s  Warnings: %s\n' "$FAILURES" "$WARNINGS"
[ "$FAILURES" -eq 0 ]
