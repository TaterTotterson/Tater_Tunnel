#!/bin/bash
set -euo pipefail

PROFILE_DIR="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
TEAM_ID="8BHV7Y2D9D"

validate_profile() {
  local plist_path="$1"
  local expected_name="$2"
  local expected_bundle_id="$3"
  local require_system_extension="$4"
  local profile_name
  local application_identifier

  profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "${plist_path}")"
  if [[ -n "${expected_name}" && "${profile_name}" != "${expected_name}" ]]; then
    printf 'Found profile %s, expected %s.\n' "${profile_name}" "${expected_name}" >&2
    return 1
  fi

  application_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "${plist_path}" 2>/dev/null ||
      /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "${plist_path}" 2>/dev/null ||
      true
  )"
  if [[ "${application_identifier}" != "${TEAM_ID}.${expected_bundle_id}" ]]; then
    printf 'Profile %s is for %s, expected %s.%s.\n' \
      "${profile_name}" "${application_identifier:-an unknown app}" "${TEAM_ID}" "${expected_bundle_id}" >&2
    return 1
  fi

  if ! /usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.networking.networkextension' \
    "${plist_path}" 2>/dev/null | grep -Fq 'packet-tunnel-provider-systemextension'; then
    printf 'Profile %s does not grant packet-tunnel-provider-systemextension.\n' "${profile_name}" >&2
    return 1
  fi

  if [[ "${require_system_extension}" == "1" ]] && \
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.system-extension.install' "${plist_path}" 2>/dev/null || true)" != "true" ]]; then
    printf 'Profile %s does not grant System Extension installation.\n' "${profile_name}" >&2
    return 1
  fi
}

validate_installed_profile() {
  local expected_name="$1"
  local expected_bundle_id="$2"
  local require_system_extension="$3"
  local search_dir
  local profile_path
  local plist_path
  local profile_name

  for search_dir in \
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "${HOME}/Library/MobileDevice/Provisioning Profiles"; do
    [[ -d "${search_dir}" ]] || continue
    while IFS= read -r -d '' profile_path; do
      plist_path="$(mktemp "${RUNNER_TEMP:-/tmp}/tater-profile-plist.XXXXXX")"
      /usr/bin/security cms -D -i "${profile_path}" > "${plist_path}" 2>/dev/null || continue
      profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "${plist_path}" 2>/dev/null || true)"
      [[ "${profile_name}" == "${expected_name}" ]] || continue
      validate_profile "${plist_path}" "${expected_name}" "${expected_bundle_id}" "${require_system_extension}"
      printf 'Validated installed profile %s for %s.\n' "${expected_name}" "${expected_bundle_id}"
      return 0
    done < <(find "${search_dir}" -maxdepth 1 -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print0)
  done

  printf 'Profile %s is not installed for the GitHub Actions runner user.\n' "${expected_name}" >&2
  return 1
}

install_profile() {
  local encoded="$1"
  local expected_bundle_id="$2"
  local environment_name="$3"
  local require_system_extension="$4"
  local source_path
  local plist_path
  local profile_name
  local profile_uuid
  local destination_path

  source_path="$(mktemp "${RUNNER_TEMP:-/tmp}/tater-profile.XXXXXX")"
  plist_path="$(mktemp "${RUNNER_TEMP:-/tmp}/tater-profile-plist.XXXXXX")"
  printf '%s' "${encoded}" | /usr/bin/base64 -D > "${source_path}"
  /usr/bin/security cms -D -i "${source_path}" > "${plist_path}"

  profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "${plist_path}")"
  profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "${plist_path}")"
  validate_profile "${plist_path}" '' "${expected_bundle_id}" "${require_system_extension}"

  mkdir -p "${PROFILE_DIR}"
  destination_path="${PROFILE_DIR}/${profile_uuid}.provisionprofile"
  cp "${source_path}" "${destination_path}"
  chmod 600 "${destination_path}"
  printf '%s=%s\n' "${environment_name}" "${profile_name}" >> "${GITHUB_ENV}"
  printf 'Installed %s for %s.\n' "${profile_name}" "${expected_bundle_id}"
}

if [[ -n "${TATER_TUNNEL_APP_PROFILE_BASE64:-}" || -n "${TATER_TUNNEL_EXTENSION_PROFILE_BASE64:-}" ]]; then
  if [[ -z "${TATER_TUNNEL_APP_PROFILE_BASE64:-}" || -z "${TATER_TUNNEL_EXTENSION_PROFILE_BASE64:-}" ]]; then
    printf 'Both TATER_TUNNEL_APP_PROFILE_BASE64 and TATER_TUNNEL_EXTENSION_PROFILE_BASE64 are required.\n' >&2
    exit 1
  fi

  install_profile \
    "${TATER_TUNNEL_APP_PROFILE_BASE64}" \
    'com.tatertotterson.tatertunnel' \
    'TATER_TUNNEL_APP_PROFILE' \
    '1'
  install_profile \
    "${TATER_TUNNEL_EXTENSION_PROFILE_BASE64}" \
    'com.tatertotterson.tatertunnel.network-extension' \
    'TATER_TUNNEL_EXTENSION_PROFILE' \
    '0'
elif [[ -z "${TATER_TUNNEL_APP_PROFILE:-}" || -z "${TATER_TUNNEL_EXTENSION_PROFILE:-}" ]]; then
  printf '%s\n' \
    'Network Extension signing profiles are not configured.' \
    'Add both base64-encoded profiles as GitHub Actions secrets:' \
    '  TATER_TUNNEL_APP_PROFILE_BASE64' \
    '  TATER_TUNNEL_EXTENSION_PROFILE_BASE64' >&2
  exit 1
else
  validate_installed_profile \
    "${TATER_TUNNEL_APP_PROFILE}" \
    'com.tatertotterson.tatertunnel' \
    '1'
  validate_installed_profile \
    "${TATER_TUNNEL_EXTENSION_PROFILE}" \
    'com.tatertotterson.tatertunnel.network-extension' \
    '0'
fi
