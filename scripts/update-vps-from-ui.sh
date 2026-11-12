#!/usr/bin/env bash
set -Eeuo pipefail

OFFICIAL_REPO="https://github.com/TaterTotterson/Tater_Tunnel.git"
INSTALL_DIR="/opt/tater-tunnel"
STATUS_FILE="/var/lib/tater-tunnel/update-status.json"
LATEST_TAG=""
TEMP_DIR=""

write_status() {
  local status="$1"
  local version="${2:-}"
  local message="$3"
  install -d -m 0700 "$(dirname "$STATUS_FILE")"
  python3 - "$STATUS_FILE" "$status" "$version" "$message" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

path, status, version, message = sys.argv[1:]
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".update-status.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "status": status,
                "latestVersion": version.removeprefix("v"),
                "message": message,
                "updatedAt": datetime.now(timezone.utc).isoformat(),
            },
            handle,
            separators=(",", ":"),
        )
        handle.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}

update_failed() {
  local status="$?"
  trap - ERR
  write_status "failed" "$LATEST_TAG" "The VPS update failed. Review the tater-tunnel-update journal." || true
  exit "$status"
}

trap cleanup EXIT
trap update_failed ERR

if [ "$(id -u)" -ne 0 ]; then
  echo "The managed VPS updater must run as root." >&2
  exit 1
fi

sleep 5
write_status "running" "" "Checking the official Tater Tunnel releases."

for command in git python3 systemctl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required for managed VPS updates." >&2
    exit 1
  fi
done

LATEST_TAG="$(
  git ls-remote --tags --refs "$OFFICIAL_REPO" 'refs/tags/v*' \
    | awk '{ sub("refs/tags/", "", $2); print $2 }' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n 1
)"
if ! [[ "$LATEST_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "No valid stable Tater Tunnel release tag was found." >&2
  exit 1
fi

CURRENT_VERSION="$(sed -n 's/^__version__ = "\([0-9][0-9.]*\)"/\1/p' "$INSTALL_DIR/tater_tunnel/__init__.py" | head -n 1)"
if [ "v$CURRENT_VERSION" = "$LATEST_TAG" ]; then
  write_status "current" "$LATEST_TAG" "The VPS Agent is already current."
  exit 0
fi

write_status "running" "$LATEST_TAG" "Downloading and verifying $LATEST_TAG."
TEMP_DIR="$(mktemp -d /tmp/tater-tunnel-update.XXXXXX)"
SOURCE_DIR="$TEMP_DIR/source"
git clone --quiet --depth 1 --branch "$LATEST_TAG" --single-branch "$OFFICIAL_REPO" "$SOURCE_DIR"

SOURCE_VERSION="$(sed -n 's/^__version__ = "\([0-9][0-9.]*\)"/\1/p' "$SOURCE_DIR/tater_tunnel/__init__.py" | head -n 1)"
if [ "v$SOURCE_VERSION" != "$LATEST_TAG" ]; then
  echo "Release tag and packaged version do not match." >&2
  exit 1
fi
if [ ! -f "$SOURCE_DIR/scripts/tater-vps-setup.sh" ] \
  || [ -L "$SOURCE_DIR/scripts/tater-vps-setup.sh" ]; then
  echo "The release does not contain a safe VPS updater." >&2
  exit 1
fi

write_status "running" "$LATEST_TAG" "Installing $LATEST_TAG and preserving tunnel state."
chmod +x "$SOURCE_DIR/scripts/"*.sh
"$SOURCE_DIR/scripts/tater-vps-setup.sh" --no-bootstrap --automatic-update

INSTALLED_VERSION="$(sed -n 's/^__version__ = "\([0-9][0-9.]*\)"/\1/p' "$INSTALL_DIR/tater_tunnel/__init__.py" | head -n 1)"
if [ "v$INSTALLED_VERSION" != "$LATEST_TAG" ]; then
  echo "The installed VPS version did not match the selected release." >&2
  exit 1
fi

write_status "complete" "$LATEST_TAG" "The VPS Agent was updated successfully."
