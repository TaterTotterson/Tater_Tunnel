#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
RESOURCES_DIR="${PROJECT_DIR}/Resources"
SOURCE_IMAGE="${RESOURCES_DIR}/TaterTunnelIconSource.png"
ICONSET_DIR="${PROJECT_DIR}/build/TaterTunnelIcon.iconset"
OUTPUT_ICON="${RESOURCES_DIR}/TaterTunnelIcon.icns"

if [ ! -f "${SOURCE_IMAGE}" ]; then
  printf 'Missing icon source: %s\n' "${SOURCE_IMAGE}" >&2
  exit 1
fi

rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

sips -s format png -z 16 16 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -s format png -z 32 32 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -s format png -z 32 32 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -s format png -z 64 64 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -s format png -z 128 128 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -s format png -z 256 256 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -s format png -z 256 256 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -s format png -z 512 512 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -s format png -z 512 512 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -s format png -z 1024 1024 "${SOURCE_IMAGE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null

if ! iconutil -c icns "${ICONSET_DIR}" -o "${OUTPUT_ICON}"; then
  printf 'iconutil failed; writing %s with PNG-backed ICNS fallback.\n' "${OUTPUT_ICON}" >&2
  /usr/bin/python3 - "${ICONSET_DIR}" "${OUTPUT_ICON}" <<'PY'
import struct
import sys
from pathlib import Path

iconset = Path(sys.argv[1])
output = Path(sys.argv[2])
entries = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

chunks = []
for icon_type, filename in entries:
    data = (iconset / filename).read_bytes()
    chunks.append(icon_type.encode("ascii") + struct.pack(">I", len(data) + 8) + data)

payload = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY
fi
