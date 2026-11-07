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

NOTARY_RESULT="$(xcrun notarytool submit \
  "${ARTIFACT}" \
  --wait \
  --output-format json \
  --keychain-profile "${TATER_TUNNEL_NOTARY_PROFILE}")"
printf '%s\n' "${NOTARY_RESULT}"

SUBMISSION_ID="$(printf '%s' "${NOTARY_RESULT}" | /usr/bin/python3 -c \
  'import json, sys; print(json.load(sys.stdin).get("id", ""))')"
SUBMISSION_STATUS="$(printf '%s' "${NOTARY_RESULT}" | /usr/bin/python3 -c \
  'import json, sys; print(json.load(sys.stdin).get("status", ""))')"

if [ "${SUBMISSION_STATUS}" != "Accepted" ]; then
  printf 'Apple notarization returned status %s for submission %s.\n' \
    "${SUBMISSION_STATUS:-unknown}" "${SUBMISSION_ID:-unknown}" >&2
  if [ -n "${SUBMISSION_ID}" ]; then
    xcrun notarytool log \
      "${SUBMISSION_ID}" \
      --keychain-profile "${TATER_TUNNEL_NOTARY_PROFILE}" || true
  fi
  exit 1
fi
