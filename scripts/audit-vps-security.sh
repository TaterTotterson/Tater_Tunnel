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
  --domain DOMAIN       Also test the local Caddy HTTPS route with this hostname.
  --listen-port PORT    VPS Agent port. Default: 4174
  --state-dir PATH      State directory. Default: /var/lib/tater-tunnel
  --config-dir PATH     Config directory. Default: /etc/tater-tunnel
  -h, --help            Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain)
      DOMAIN="${2:?--domain requires a value}"
      shift 2
      ;;
    --listen-port)
      LISTEN_PORT="${2:?--listen-port requires a value}"
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

pass() {
  printf '[PASS] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1"
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
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
  if grep -q -- '--allow-loopback-relay' "$SERVICE_FILE"; then
    fail "The removed loopback relay bypass is still present in ExecStart"
  else
    pass "No loopback relay bypass is configured"
  fi

  for setting in \
    'NoNewPrivileges=true' \
    'ProtectSystem=strict' \
    'ProtectHome=true' \
    'PrivateDevices=true' \
    'RestrictNamespaces=true' \
    'SocketBindDeny=any' \
    "SocketBindAllow=tcp:${LISTEN_PORT}"; do
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
interface = ipaddress.ip_interface(state["interface"]["address"]).ip
for peer in state.get("peers", []):
    try:
        public_key = base64.b64decode(str(peer.get("publicKey") or ""), validate=True)
    except (binascii.Error, ValueError):
        raise SystemExit(1)
    if len(public_key) != 32 or not any(public_key):
        raise SystemExit(1)
    allowed = ipaddress.ip_network(str(peer.get("allowedIp") or ""), strict=True)
    if allowed.version != network.version or allowed.prefixlen != allowed.max_prefixlen:
        raise SystemExit(1)
    if allowed.network_address not in network or allowed.network_address == interface:
        raise SystemExit(1)
PY
  then
    pass "Every stored peer has one exact WireGuard address"
  else
    fail "A stored peer has a broad or invalid Allowed IP"
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
  if [ "$state_status" = "claimed-pairing-open" ]; then
    warn "Pairing is open on a claimed VPS; close it after pairing completes"
  elif [ "$state_status" = "claimed-pairing-closed" ]; then
    pass "Pairing is not left open on a claimed VPS"
  elif [ "$state_status" = "unclaimed" ]; then
    warn "The VPS has not been claimed yet"
  else
    fail "The VPS state file could not be read"
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
    expected[str(home["publicKey"])] = str(home.get("allowedIp") or "10.88.0.2/32")
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
      fail "The claimed VPS does not have a live tater0 WireGuard interface"
    fi
  fi
fi

relay_status="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 5 \
  "http://127.0.0.1:${LISTEN_PORT}/relay/security-audit" 2>/dev/null || true)"
if [ "$relay_status" = "403" ]; then
  pass "The VPS Agent rejects relay traffic from loopback"
else
  fail "Loopback relay test returned HTTP ${relay_status:-unreachable}; expected 403"
fi

if [ -f "$CADDYFILE" ] && grep -Eq '^[[:space:]]*@public_relay[[:space:]]+path[[:space:]]+/relay[[:space:]]+/relay/\*[[:space:]]*$' "$CADDYFILE"; then
  pass "Caddy explicitly blocks public /relay paths"
else
  fail "Caddy does not contain the public /relay block"
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  added_rules="$(ufw show added 2>/dev/null || true)"
  if grep -Fq "allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port ${LISTEN_PORT} proto tcp" <<< "$added_rules"; then
    pass "UFW allows port $LISTEN_PORT only through tater0 for the tunnel network"
  else
    fail "UFW is missing the tater0-only allow for port $LISTEN_PORT"
  fi
  if grep -Fq "deny in to any port ${LISTEN_PORT} proto tcp" <<< "$added_rules"; then
    pass "UFW explicitly denies public TCP $LISTEN_PORT"
  else
    fail "UFW is missing the public deny for TCP $LISTEN_PORT"
  fi
  if awk -v port="$LISTEN_PORT" '
    $1 == "ufw" && $2 == "allow" && $0 !~ /on tater0 from 10\.88\.0\.0\/24 to 10\.88\.0\.1/ {
      for (index = 3; index <= NF; index++) {
        if ($index == port || $index == port "/tcp") {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<< "$added_rules"; then
    fail "UFW still contains a broad public allow for TCP $LISTEN_PORT"
  else
    pass "No broad UFW allow exists for TCP $LISTEN_PORT"
  fi
else
  fail "UFW is not active"
fi

if [ -n "$DOMAIN" ]; then
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%%/*}"
  public_status="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/relay/security-audit" 2>/dev/null || true)"
  if [ "$public_status" = "404" ]; then
    pass "Caddy returns 404 for public /relay paths"
  else
    fail "Caddy relay test returned HTTP ${public_status:-unreachable}; expected 404"
  fi
fi

echo
printf 'Result: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
