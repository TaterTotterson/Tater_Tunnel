#!/bin/sh
set -eu

ARTIFACT="${1:?Usage: notarize_artifact.sh /path/to/artifact}"

if [ "${TATER_TUNNEL_NOTARIZE:-0}" != "1" ]; then
  printf 'Skipping notarization for %s (set TATER_TUNNEL_NOTARIZE=1 to enable).\n' "${ARTIFACT}"
  exit 0
fi

if [ ! -e "${ARTIFACT}" ]; then
  printf 'Cannot notarize missing artifact: %s\n' "${ARTIFACT}" >&2
  exit 1
fi

if [ -z "${TATER_TUNNEL_NOTARY_PROFILE:-}" ]; then
  printf 'TATER_TUNNEL_NOTARIZE=1, but TATER_TUNNEL_NOTARY_PROFILE was not configured.\n' >&2
  exit 1
fi

xcrun notarytool submit "${ARTIFACT}" --wait --keychain-profile "${TATER_TUNNEL_NOTARY_PROFILE}"
