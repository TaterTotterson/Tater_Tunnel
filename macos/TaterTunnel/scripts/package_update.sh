#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
APP_DIR="${PROJECT_DIR}/build/Tater Tunnel.app"
INFO_PLIST="${PROJECT_DIR}/Resources/Info.plist"
RELEASES_DIR="${PROJECT_DIR}/releases"
UPDATE_NOTES_FILE="${PROJECT_DIR}/Resources/UpdateNotes.txt"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
VERSION_TOKEN="$(printf '%s' "${VERSION}" | sed 's/^[vV]//')"
VERSION_LABEL="v${VERSION_TOKEN}"
BUILD_NUMBER="$(printf '%s' "${BUILD}" | sed 's/[^0-9].*$//')"
if [ -z "${BUILD_NUMBER}" ]; then
  BUILD_NUMBER="0"
fi
ZIP_NAME="TaterTunnel-${VERSION_LABEL}.zip"
ZIP_PATH="${PROJECT_DIR}/build/${ZIP_NAME}"
RELEASE_ZIP_PATH="${RELEASES_DIR}/${ZIP_NAME}"
MANIFEST_PATH="${PROJECT_DIR}/build/update-manifest.json"
REPO_MANIFEST_PATH="${PROJECT_DIR}/update-manifest.json"
DOWNLOAD_URL="${1:-https://github.com/TaterTotterson/Tater_Tunnel/releases/download/${VERSION_LABEL}/${ZIP_NAME}}"

"${SCRIPT_DIR}/build_app.sh"

mkdir -p "${RELEASES_DIR}"
rm -f "${ZIP_PATH}" "${MANIFEST_PATH}" "${RELEASE_ZIP_PATH}"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"
"${SCRIPT_DIR}/notarize_artifact.sh" "${ZIP_PATH}"
if [ "${TATER_TUNNEL_NOTARIZE:-0}" = "1" ]; then
  xcrun stapler staple "${APP_DIR}"
  xcrun stapler validate "${APP_DIR}"
  rm -f "${ZIP_PATH}"
  ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"
fi
cp "${ZIP_PATH}" "${RELEASE_ZIP_PATH}"
SHA256="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
UPDATE_NOTES="Tater Tunnel macOS update ${VERSION_LABEL}."
if [ -f "${UPDATE_NOTES_FILE}" ]; then
  UPDATE_NOTES="$(tr '\n' ' ' < "${UPDATE_NOTES_FILE}" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
fi
UPDATE_NOTES_JSON="$(printf '%s' "${UPDATE_NOTES}" | /usr/bin/python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))')"

{
  printf '{\n'
  printf '  "version": "%s",\n' "${VERSION_TOKEN}"
  printf '  "build": %s,\n' "${BUILD_NUMBER}"
  printf '  "url": "%s",\n' "${DOWNLOAD_URL}"
  printf '  "sha256": "%s",\n' "${SHA256}"
  printf '  "notes": %s\n' "${UPDATE_NOTES_JSON}"
  printf '}\n'
} > "${MANIFEST_PATH}"
cp "${MANIFEST_PATH}" "${REPO_MANIFEST_PATH}"

printf 'Packaged %s\n' "${ZIP_PATH}"
printf 'Copied %s\n' "${RELEASE_ZIP_PATH}"
printf 'Wrote %s\n' "${MANIFEST_PATH}"
printf 'Updated %s\n' "${REPO_MANIFEST_PATH}"
