#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "The container network guard requires root." >&2
  exit 1
fi

command -v nft >/dev/null
guard_file="$(mktemp /run/tater-container-guard.XXXXXX)"
trap 'rm -f "$guard_file"' EXIT
chmod 0600 "$guard_file"
if nft list table inet tater_apps_guard >/dev/null 2>&1; then
  printf 'delete table inet tater_apps_guard\n' > "$guard_file"
fi
cat >> "$guard_file" <<'EOF'
table inet tater_apps_guard {
  chain private_containers {
    type filter hook forward priority -20; policy accept;
    iifname != "tater0" ct original ip daddr 10.88.0.1 counter drop
  }
}
EOF
nft --check --file "$guard_file"
nft --file "$guard_file"
