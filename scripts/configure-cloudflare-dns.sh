#!/usr/bin/env bash
set -Eeuo pipefail

CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/v4"
CLOUDFLARE_ZONE=""
PUBLIC_IPV4=""
API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
TEMP_DIR=""
RECORDS=()

usage() {
  cat <<'EOF'
Create or update DNS-only Cloudflare A records for a Tater Tunnel VPS.

The API token is read from a hidden prompt and is never stored. For unattended
use, it may be supplied through CLOUDFLARE_API_TOKEN.

Usage:
  sudo ./scripts/configure-cloudflare-dns.sh \
    --zone example.com \
    --record tunnel.example.com \
    [--record sftp.example.com] \
    [--ipv4 203.0.113.10]

Options:
  --zone DOMAIN       Cloudflare zone containing the records. Required.
  --record HOSTNAME   DNS-only A record to create/update. Repeatable.
  --ipv4 ADDRESS      VPS public IPv4. Auto-detected when omitted.
  -h, --help          Show this help.

Required token permissions, limited to the selected zone:
  Zone > Zone > Read
  Zone > DNS > Edit
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --zone)
      CLOUDFLARE_ZONE="${2:?--zone requires a value}"
      shift 2
      ;;
    --record)
      RECORDS+=("${2:?--record requires a value}")
      shift 2
      ;;
    --ipv4)
      PUBLIC_IPV4="${2:?--ipv4 requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cleanup() {
  API_TOKEN=""
  unset CLOUDFLARE_API_TOKEN
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT

confirm() {
  local label="$1"
  local default="${2:-no}"
  local hint="[y/N]"
  local reply

  if [ "$default" = "yes" ]; then
    hint="[Y/n]"
  fi

  while true; do
    printf '%s %s: ' "$label" "$hint" >&2
    read -r reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Answer yes or no." >&2 ;;
    esac
  done
}

normalize_dns_name() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%.}"
  printf '%s' "${value,,}"
}

valid_dns_name() {
  local value="$1"
  [[ "$value" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && [[ "$value" == *.* ]] && [[ "$value" != *..* ]]
}

valid_ipv4() {
  local value="$1"
  local octet
  local octets

  if ! [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi

  IFS='.' read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
      return 1
    fi
  done
}

validate_inputs() {
  local index
  local record

  CLOUDFLARE_ZONE="$(normalize_dns_name "$CLOUDFLARE_ZONE")"
  if ! valid_dns_name "$CLOUDFLARE_ZONE"; then
    echo "Use a valid Cloudflare zone such as example.com." >&2
    exit 2
  fi
  if [ "${#RECORDS[@]}" -eq 0 ]; then
    echo "At least one --record hostname is required." >&2
    exit 2
  fi

  for index in "${!RECORDS[@]}"; do
    record="$(normalize_dns_name "${RECORDS[$index]}")"
    if ! valid_dns_name "$record"; then
      echo "Invalid DNS record hostname: ${RECORDS[$index]}" >&2
      exit 2
    fi
    case "$record" in
      "$CLOUDFLARE_ZONE"|*."$CLOUDFLARE_ZONE") ;;
      *)
        echo "$record is not inside the Cloudflare zone $CLOUDFLARE_ZONE." >&2
        exit 2
        ;;
    esac
    RECORDS[index]="$record"
  done

  if [ -n "$PUBLIC_IPV4" ] && ! valid_ipv4 "$PUBLIC_IPV4"; then
    echo "Invalid public IPv4 address: $PUBLIC_IPV4" >&2
    exit 2
  fi
}

install_dependencies() {
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    return
  fi

  if [ "$(id -u)" -ne 0 ] || ! command -v apt-get >/dev/null 2>&1; then
    echo "curl and jq are required. Install them and rerun this helper." >&2
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq
}

detect_public_ipv4() {
  if [ -n "$PUBLIC_IPV4" ]; then
    return
  fi

  PUBLIC_IPV4="$(
    curl -4 --fail --silent --show-error --max-time 15 \
      https://www.cloudflare.com/cdn-cgi/trace \
      | awk -F= '$1 == "ip" { print $2; exit }'
  )"
  if ! valid_ipv4 "$PUBLIC_IPV4"; then
    echo "Could not detect the VPS public IPv4 address." >&2
    echo "Rerun with --ipv4 ADDRESS." >&2
    exit 1
  fi
}

read_api_token() {
  if [ -n "$API_TOKEN" ]; then
    return
  fi

  cat >&2 <<'EOF'

Create a Cloudflare API token limited to this zone with:
  Zone > Zone > Read
  Zone > DNS > Edit

The token is used once and is not saved.
EOF
  printf 'Cloudflare API token: ' >&2
  IFS= read -rs API_TOKEN
  printf '\n' >&2

  if [ -z "$API_TOKEN" ]; then
    echo "Cloudflare API token is required." >&2
    exit 1
  fi
}

api_request() {
  local method="$1"
  local url="$2"
  local output_file="$3"
  local body="${4:-}"
  local http_code
  local args=(
    --silent
    --show-error
    --location
    --request "$method"
    --header 'Content-Type: application/json'
    --output "$output_file"
  )

  if [ -n "$body" ]; then
    args+=(--data "$body")
  fi

  if ! http_code="$(
    printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN" \
      | curl --config - "${args[@]}" --write-out '%{http_code}' "$url"
  )"; then
    if [ -s "$output_file" ]; then
      jq -r '.errors[]?.message // empty' "$output_file" >&2 || true
    fi
    return 1
  fi

  if [[ "$http_code" != 2* ]]; then
    jq -r '.errors[]?.message // "Cloudflare API request failed."' "$output_file" >&2 || true
    return 1
  fi

  if [ "$(jq -r '.success // false' "$output_file")" != "true" ]; then
    jq -r '.errors[]?.message // "Cloudflare API request failed."' "$output_file" >&2
    return 1
  fi
}

find_zone_id() {
  local response_file="$TEMP_DIR/zone.json"
  local zone_id
  local url

  url="$CLOUDFLARE_API_BASE/zones?name=$CLOUDFLARE_ZONE&per_page=2"
  if ! api_request GET "$url" "$response_file"; then
    exit 1
  fi
  zone_id="$(jq -r '
    if (.result | length) == 1 then .result[0].id else empty end
  ' "$response_file")"

  if [ -z "$zone_id" ]; then
    echo "Could not find one Cloudflare zone named $CLOUDFLARE_ZONE." >&2
    echo "Check the zone name and the token's Zone Read permission." >&2
    exit 1
  fi

  printf '%s' "$zone_id"
}

upsert_record() {
  local zone_id="$1"
  local record="$2"
  local record_slug
  local list_file
  local write_file
  local list_url="$CLOUDFLARE_API_BASE/zones/$zone_id/dns_records?type=A&name=$record&per_page=2"
  local record_count
  local record_id
  local existing_content
  local existing_proxied
  local body

  record_slug="$(printf '%s' "$record" | tr '.-' '__')"
  list_file="$TEMP_DIR/list-$record_slug.json"
  write_file="$TEMP_DIR/write-$record_slug.json"

  if ! api_request GET "$list_url" "$list_file"; then
    return 1
  fi
  record_count="$(jq -r '.result | length' "$list_file")"
  if [ "$record_count" -gt 1 ]; then
    echo "Multiple A records already exist for $record; leaving them unchanged." >&2
    return 1
  fi

  body="$(jq -cn \
    --arg name "$record" \
    --arg content "$PUBLIC_IPV4" \
    '{type:"A", name:$name, content:$content, ttl:1, proxied:false, comment:"Managed by Tater Tunnel VPS setup"}'
  )"

  if [ "$record_count" -eq 0 ]; then
    if ! api_request POST "$CLOUDFLARE_API_BASE/zones/$zone_id/dns_records" "$write_file" "$body"; then
      return 1
    fi
    echo "Created DNS-only A record: $record -> $PUBLIC_IPV4"
    return
  fi

  record_id="$(jq -r '.result[0].id' "$list_file")"
  existing_content="$(jq -r '.result[0].content' "$list_file")"
  existing_proxied="$(jq -r '.result[0].proxied' "$list_file")"
  if [ "$existing_content" = "$PUBLIC_IPV4" ] && [ "$existing_proxied" = "false" ]; then
    echo "DNS-only A record is already correct: $record -> $PUBLIC_IPV4"
    return
  fi

  if [ "$existing_content" != "$PUBLIC_IPV4" ]; then
    if ! confirm "Replace $record ($existing_content) with $PUBLIC_IPV4 and set DNS only" no; then
      echo "Left existing record unchanged: $record -> $existing_content"
      return
    fi
  elif ! confirm "Change $record from proxied to DNS only" yes; then
    echo "Left existing proxied record unchanged: $record"
    return
  fi

  if ! api_request PATCH "$CLOUDFLARE_API_BASE/zones/$zone_id/dns_records/$record_id" "$write_file" "$body"; then
    return 1
  fi
  echo "Updated DNS-only A record: $record -> $PUBLIC_IPV4"
}

main() {
  local zone_id
  local zone_status
  local record

  validate_inputs
  install_dependencies
  detect_public_ipv4
  read_api_token
  TEMP_DIR="$(mktemp -d /tmp/tater-cloudflare.XXXXXX)"
  zone_id="$(find_zone_id)"
  zone_status="$(jq -r '.result[0].status // "unknown"' "$TEMP_DIR/zone.json")"

  echo
  echo "Cloudflare zone: $CLOUDFLARE_ZONE"
  echo "Zone status: $zone_status"
  echo "Assigned Cloudflare nameservers:"
  jq -r '.result[0].name_servers[]? | "  " + .' "$TEMP_DIR/zone.json"
  echo "VPS public IPv4: $PUBLIC_IPV4"
  for record in "${RECORDS[@]}"; do
    upsert_record "$zone_id" "$record"
  done

  if [ "$zone_status" != "active" ]; then
    cat >&2 <<EOF

Cloudflare reports this zone as $zone_status. Update the domain's nameservers
at its registrar to the assigned Cloudflare nameservers shown above, wait for
the zone to become active, and rerun the Tater setup. Registrar nameservers
cannot be changed through the Cloudflare DNS API.
EOF
    exit 3
  fi
}

main
