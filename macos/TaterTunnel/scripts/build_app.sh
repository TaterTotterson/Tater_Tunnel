#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd "${PROJECT_DIR}/../.." && pwd -P)"
APP_NAME="Tater Tunnel"
APP_DIR="${PROJECT_DIR}/build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SOURCE_SNAPSHOT_DIR="${RESOURCES_DIR}/TaterTunnelSource"
CODESIGN_IDENTITY="${TATER_TUNNEL_CODESIGN_IDENTITY:-${TATER_CODESIGN_IDENTITY:--}}"
CODESIGN_ENTITLEMENTS="${TATER_TUNNEL_CODESIGN_ENTITLEMENTS:-${PROJECT_DIR}/Resources/TaterTunnel.entitlements}"

swift build -c release --package-path "${PROJECT_DIR}"
BIN_DIR="$(swift build -c release --package-path "${PROJECT_DIR}" --show-bin-path)"

"${SCRIPT_DIR}/generate_app_icon.sh"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_DIR}/TaterTunnel" "${MACOS_DIR}/TaterTunnel"
cp "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${PROJECT_DIR}/Resources/TaterTunnelIcon.icns" "${RESOURCES_DIR}/TaterTunnelIcon.icns"
rsync -a --delete \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='.agents/' \
  --exclude='.codex/' \
  --exclude='.tater_tunnel/' \
  --exclude='.venv/' \
  --exclude='venv/' \
  --exclude='macos/' \
  --exclude='tests/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.DS_Store' \
  "${REPO_ROOT}/" "${SOURCE_SNAPSHOT_DIR}/"

chmod +x "${MACOS_DIR}/TaterTunnel"

find "${APP_DIR}" -exec xattr -c {} +
if [ "${CODESIGN_IDENTITY}" = "-" ]; then
  codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${APP_DIR}"
else
  codesign --force \
    --deep \
    --options runtime \
    --timestamp \
    --entitlements "${CODESIGN_ENTITLEMENTS}" \
    --sign "${CODESIGN_IDENTITY}" \
    "${APP_DIR}"
fi
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

printf 'Built %s\n' "${APP_DIR}"
