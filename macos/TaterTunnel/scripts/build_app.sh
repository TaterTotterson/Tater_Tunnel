#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
REPO_ROOT="$(cd "${PROJECT_DIR}/../.." && pwd -P)"
APP_NAME="Tater Tunnel"
APP_DIR="${PROJECT_DIR}/build/${APP_NAME}.app"
DERIVED_DATA="${PROJECT_DIR}/build/DerivedData"
GENERATED_SOURCE="${PROJECT_DIR}/Generated/TaterTunnelSource"
WIREGUARD_SOURCE="${PROJECT_DIR}/Generated/wireguard-apple"
WIREGUARD_REVISION="2fec12a6e1f6e3460b6ee483aa00ad29cddadab1"
PROJECT_FILE="${PROJECT_DIR}/TaterTunnel.xcodeproj"
SCHEME="TaterTunnel"
EXTENSION_ID="com.tatertotterson.tatertunnel.network-extension"
EXTENSION_DIR="${APP_DIR}/Contents/Library/SystemExtensions/${EXTENSION_ID}.systemextension"
APP_EXECUTABLE="${APP_DIR}/Contents/MacOS/TaterTunnel"
EXTENSION_EXECUTABLE="${EXTENSION_DIR}/Contents/MacOS/${EXTENSION_ID}"
CODESIGN_IDENTITY="${TATER_TUNNEL_CODESIGN_IDENTITY:-${TATER_CODESIGN_IDENTITY:--}}"
APP_PROFILE="${TATER_TUNNEL_APP_PROFILE:-}"
EXTENSION_PROFILE="${TATER_TUNNEL_EXTENSION_PROFILE:-}"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  export DEVELOPER_DIR
fi

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  printf 'Full Xcode is required; xcodebuild is unavailable through DEVELOPER_DIR=%s.\n' \
    "${DEVELOPER_DIR:-system default}" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  printf 'XcodeGen is required. Install it with: brew install xcodegen\n' >&2
  exit 1
fi

"${SCRIPT_DIR}/generate_app_icon.sh"

mkdir -p "${GENERATED_SOURCE}" "${PROJECT_DIR}/build"
if [ ! -d "${WIREGUARD_SOURCE}/.git" ]; then
  git clone --no-checkout https://git.zx2c4.com/wireguard-apple "${WIREGUARD_SOURCE}"
fi
git -C "${WIREGUARD_SOURCE}" fetch --depth 1 origin "${WIREGUARD_REVISION}"
git -C "${WIREGUARD_SOURCE}" checkout --detach --force "${WIREGUARD_REVISION}"
sed -i '' '1s/swift-tools-version:5.3/swift-tools-version:5.5/' "${WIREGUARD_SOURCE}/Package.swift"
sed -i '' '4i\
#include <sys/types.h>\
' "${WIREGUARD_SOURCE}/Sources/WireGuardKitC/WireGuardKitC.h"

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
  "${REPO_ROOT}/" "${GENERATED_SOURCE}/"

xcodegen generate --spec "${PROJECT_DIR}/project.yml" --project "${PROJECT_DIR}"

set -- xcodebuild \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  DEVELOPMENT_TEAM=8BHV7Y2D9D

if [ "${CODESIGN_IDENTITY}" = "-" ]; then
  "$@" CODE_SIGNING_ALLOWED=NO build
else
  if [ -z "${APP_PROFILE}" ] || [ -z "${EXTENSION_PROFILE}" ]; then
    printf '%s\n' \
      'Signed Tater Tunnel builds require both provisioning profile names:' \
      '  TATER_TUNNEL_APP_PROFILE' \
      '  TATER_TUNNEL_EXTENSION_PROFILE' \
      'Both profiles must grant the Network Extension capabilities used by their targets.' >&2
    exit 1
  fi
  "$@" \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=${CODESIGN_IDENTITY}" \
    "TATER_TUNNEL_APP_PROFILE=${APP_PROFILE}" \
    "TATER_TUNNEL_EXTENSION_PROFILE=${EXTENSION_PROFILE}" \
    build
fi

BUILT_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "${BUILT_APP}" ]; then
  printf 'Xcode did not produce the expected app: %s\n' "${BUILT_APP}" >&2
  exit 1
fi

rm -rf "${APP_DIR}"
ditto "${BUILT_APP}" "${APP_DIR}"
find "${APP_DIR}" -exec xattr -c {} +

if [ "${CODESIGN_IDENTITY}" = "-" ]; then
  if [ ! -d "${EXTENSION_DIR}" ]; then
    printf 'The WireGuard system extension was not embedded at %s\n' "${EXTENSION_DIR}" >&2
    exit 1
  fi
  codesign --force \
    --entitlements "${PROJECT_DIR}/Resources/TaterTunnelNetworkExtension.entitlements" \
    --sign - \
    "${EXTENSION_DIR}"
  codesign --force \
    --entitlements "${PROJECT_DIR}/Resources/TaterTunnel.entitlements" \
    --sign - \
    "${APP_DIR}"
fi

check_release_entitlements() {
  executable="$1"
  entitlements="$(codesign -d --entitlements :- "${executable}" 2>/dev/null || true)"
  if printf '%s' "${entitlements}" | plutil \
    -extract com.apple.security.get-task-allow raw - 2>/dev/null | grep -qx true; then
    printf 'Release executable contains the forbidden get-task-allow entitlement: %s\n' \
      "${executable}" >&2
    exit 1
  fi
}

check_release_entitlements "${APP_EXECUTABLE}"
check_release_entitlements "${EXTENSION_EXECUTABLE}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
printf 'Built %s\n' "${APP_DIR}"
