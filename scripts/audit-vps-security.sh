#!/usr/bin/env bash
set -u

SERVICE_NAME="tater-tunnel-vps"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="/var/lib/tater-tunnel"
CONFIG_DIR="/etc/tater-tunnel"
CADDYFILE="/etc/caddy/Caddyfile"
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

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  added="$(ufw show added 2>/dev/null || true)"
  if grep -Fq "allow in on tater0 from 10.88.0.2 to 10.88.0.1 port ${LISTEN_PORT} proto tcp" <<< "$added"; then
    pass "UFW limits management to the Home Agent WireGuard address"
  else
    fail "UFW is missing the exact Home Agent management rule"
  fi
  if grep -Fq "deny in to any port ${LISTEN_PORT} proto tcp" <<< "$added"; then
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
