#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
INFO_PLIST="${PROJECT_DIR}/Resources/Info.plist"
APP_DIR="${PROJECT_DIR}/build/Tater Tunnel.app"
RELEASES_DIR="${PROJECT_DIR}/releases"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
VERSION_TOKEN="$(printf '%s' "${VERSION}" | sed 's/^[vV]//')"
VERSION_LABEL="v${VERSION_TOKEN}"
VOLUME_NAME="Install Tater Tunnel ${VERSION_LABEL}"
DMG_NAME="TaterTunnel-${VERSION_LABEL}.dmg"
FINAL_DMG="${PROJECT_DIR}/build/${DMG_NAME}"
RELEASE_DMG="${RELEASES_DIR}/${DMG_NAME}"
STAGING_DIR="${PROJECT_DIR}/build/dmg-staging"

"${SCRIPT_DIR}/build_app.sh"

rm -rf "${STAGING_DIR}" "${FINAL_DMG}"
mkdir -p "${STAGING_DIR}"

ditto "${APP_DIR}" "${STAGING_DIR}/Tater Tunnel.app"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "${FINAL_DMG}" >/dev/null

hdiutil verify "${FINAL_DMG}" >/dev/null

mkdir -p "${RELEASES_DIR}"
cp "${FINAL_DMG}" "${RELEASE_DMG}"

printf 'Built %s\n' "${FINAL_DMG}"
printf 'Copied %s\n' "${RELEASE_DMG}"
