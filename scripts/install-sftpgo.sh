#!/usr/bin/env bash
set -Eeuo pipefail

SFTPGO_VERSION=""
SFTP_ACCESS="private"
FTP_ACCESS="disabled"
WEBDAV_ACCESS="disabled"
WEBDAV_ACCESS_EXPLICIT="0"
WEBDAV_DOMAIN=""
ALLOW_INSECURE_PUBLIC_PROTOCOLS="0"
START_SERVICE="1"
SFTP_PORT="2022"
FTP_PORT="2121"
FTP_PASSIVE_START="50000"
FTP_PASSIVE_END="50100"
WEBDAV_PORT="10080"
WEB_PORT="8080"
PUBLIC_IPV4=""
CADDYFILE="/etc/caddy/Caddyfile"
WEBDAV_CADDY_SNIPPET="/etc/caddy/tater-sites/sftpgo-webdav.caddy"
TEMP_DIR=""
MAX_STORAGE_GB=""
STORAGE_DIR="/var/lib/sftpgo-storage"
STORAGE_IMAGE="$STORAGE_DIR/tater-data.img"
STORAGE_MOUNT="/srv/sftpgo/data"
MIN_HOST_FREE_GB="2"

usage() {
  cat <<'EOF'
Install or update the open-source SFTPGo package on a Debian/Ubuntu VPS.

The package is downloaded from the official SFTPGo GitHub release, verified
against the SHA-256 digest published by GitHub, and installed as a systemd
service. Existing SFTPGo configuration, users, and data are preserved.

Usage:
  sudo ./scripts/install-sftpgo.sh [options]

Options:
  --version VERSION          Install a specific release, for example 2.7.6.
                             Default: current stable release
  --sftp-access MODE         SFTP access: disabled, private, or public.
                             Default: private
  --ftp-access MODE          FTP access: disabled, private, or public.
                             Default: disabled
  --webdav-access MODE       WebDAV access: disabled, private, or https.
                             Default: disabled
  --webdav-domain DOMAIN     Dedicated HTTPS hostname for WebDAV, for example
                             files.example.com. Implies https access
  --public-sftp              Alias for --sftp-access public.
  --public-ip ADDRESS        Public IPv4 returned to passive FTP clients.
                             Default: detect automatically
  --allow-insecure-public-protocols
                             Required with public FTP. Direct FTP does not
                             provide TLS; prefer private mode or SFTP.
  --max-storage-gb SIZE      Cap total default local SFTPGo storage at SIZE GiB.
                             Creates a persistent fixed-size filesystem and
                             keeps at least 2 GiB outside the cap during setup.
  --no-start                 Do not enable or start the systemd service.
  -h, --help                 Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      SFTPGO_VERSION="${2:?--version requires a value}"
      shift 2
      ;;
    --public-sftp)
      SFTP_ACCESS="public"
      shift
      ;;
    --sftp-access)
      SFTP_ACCESS="${2:?--sftp-access requires a value}"
      shift 2
      ;;
    --ftp-access)
      FTP_ACCESS="${2:?--ftp-access requires a value}"
      shift 2
      ;;
    --webdav-access)
      WEBDAV_ACCESS="${2:?--webdav-access requires a value}"
      WEBDAV_ACCESS_EXPLICIT="1"
      shift 2
      ;;
    --webdav-domain)
      WEBDAV_DOMAIN="${2:?--webdav-domain requires a value}"
      shift 2
      ;;
    --public-ip)
      PUBLIC_IPV4="${2:?--public-ip requires a value}"
      shift 2
      ;;
    --allow-insecure-public-protocols)
      ALLOW_INSECURE_PUBLIC_PROTOCOLS="1"
      shift
      ;;
    --max-storage-gb)
      MAX_STORAGE_GB="${2:?--max-storage-gb requires a value}"
      shift 2
      ;;
    --no-start)
      START_SERVICE="0"
      shift
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
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer with sudo." >&2
    exit 1
  fi
}

require_supported_system() {
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    echo "This installer supports Debian/Ubuntu systems with apt-get and dpkg." >&2
    exit 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is required for this installer." >&2
    exit 1
  fi
}

validate_version() {
  if [ -z "$SFTPGO_VERSION" ]; then
    return
  fi

  if ! [[ "$SFTPGO_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9.]+)?$ ]]; then
    echo "Invalid SFTPGo version: $SFTPGO_VERSION" >&2
    echo "Use a release such as 2.7.6 or v2.7.6." >&2
    exit 2
  fi
}

validate_storage_size() {
  if [ -z "$MAX_STORAGE_GB" ]; then
    return
  fi

  if ! [[ "$MAX_STORAGE_GB" =~ ^[1-9][0-9]*$ ]] || [ "$MAX_STORAGE_GB" -gt 1048576 ]; then
    echo "Invalid storage cap: $MAX_STORAGE_GB" >&2
    echo "Use a whole number from 1 to 1048576 GiB, for example --max-storage-gb 20." >&2
    exit 2
  fi
}

validate_access_mode() {
  local label="$1"
  local value="$2"

  case "$value" in
    disabled|private|public) ;;
    *)
      echo "Invalid $label access mode: $value" >&2
      echo "Use disabled, private, or public." >&2
      exit 2
      ;;
  esac
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
  [[ "$value" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
    && [[ "$value" == *.* ]] \
    && [[ "$value" != *..* ]]
}

domain_used_by_other_caddy_site() {
  local file
  local candidate

  for file in "$CADDYFILE" /etc/caddy/tater-sites/*.caddy; do
    [ -f "$file" ] || continue
    [ "$file" = "$WEBDAV_CADDY_SNIPPET" ] && continue
    candidate="$(awk -v domain="$WEBDAV_DOMAIN" '$1 == domain && $2 == "{" { print "yes"; exit }' "$file")"
    [ "$candidate" != "yes" ] || return 0
  done
  return 1
}

normalize_webdav_options() {
  if [ -n "$WEBDAV_DOMAIN" ]; then
    WEBDAV_DOMAIN="$(normalize_dns_name "$WEBDAV_DOMAIN")"
    if [ "$WEBDAV_ACCESS_EXPLICIT" = "1" ] && [ "$WEBDAV_ACCESS" != "https" ]; then
      echo "--webdav-domain requires --webdav-access https." >&2
      exit 2
    fi
    WEBDAV_ACCESS="https"
  fi
}

validate_protocol_access() {
  validate_access_mode SFTP "$SFTP_ACCESS"
  validate_access_mode FTP "$FTP_ACCESS"
  case "$WEBDAV_ACCESS" in
    disabled|private|https) ;;
    *)
      echo "Invalid WebDAV access mode: $WEBDAV_ACCESS" >&2
      echo "Use disabled, private, or https." >&2
      exit 2
      ;;
  esac

  if [ "$SFTP_ACCESS" = "disabled" ] \
    && [ "$FTP_ACCESS" = "disabled" ] \
    && [ "$WEBDAV_ACCESS" = "disabled" ]; then
    echo "Enable at least one SFTPGo file protocol." >&2
    exit 2
  fi

  if [ "$FTP_ACCESS" = "public" ] && [ "$ALLOW_INSECURE_PUBLIC_PROTOCOLS" != "1" ]; then
    cat >&2 <<'EOF'
Public FTP is not encrypted by this installer.
Use private mode through WireGuard or SFTP, or repeat with
--allow-insecure-public-protocols after accepting that risk.
EOF
    exit 2
  fi

  if [ "$WEBDAV_ACCESS" = "https" ]; then
    if ! valid_dns_name "$WEBDAV_DOMAIN"; then
      echo "HTTPS WebDAV requires a valid --webdav-domain such as files.example.com." >&2
      exit 2
    fi
    if domain_used_by_other_caddy_site; then
      echo "$WEBDAV_DOMAIN is already used by another Caddy site." >&2
      echo "Choose a dedicated WebDAV subdomain." >&2
      exit 2
    fi
    if ! command -v caddy >/dev/null 2>&1 || [ ! -f "$CADDYFILE" ]; then
      echo "HTTPS WebDAV requires the Tater Tunnel Caddy installation." >&2
      exit 1
    fi
    if ! grep -Eq '^[[:space:]]*import[[:space:]]+tater-sites/\*\.caddy[[:space:]]*$' "$CADDYFILE"; then
      echo "$CADDYFILE does not import managed Tater site snippets." >&2
      exit 1
    fi
  fi
}

valid_ipv4() {
  local address="$1"
  local octet
  local -a octets

  IFS=. read -r -a octets <<< "$address"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    [ "$octet" -le 255 ] || return 1
  done
}

resolve_public_ipv4() {
  if [ "$FTP_ACCESS" != "public" ]; then
    PUBLIC_IPV4=""
    return
  fi
  if [ -z "$PUBLIC_IPV4" ]; then
    PUBLIC_IPV4="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  fi
  if ! valid_ipv4 "$PUBLIC_IPV4"; then
    echo "Could not determine a valid public IPv4 for passive FTP." >&2
    echo "Repeat with --public-ip ADDRESS." >&2
    exit 2
  fi
}

install_download_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl e2fsprogs jq libcap2-bin util-linux
}

release_api_url() {
  if [ -z "$SFTPGO_VERSION" ]; then
    printf '%s' "https://api.github.com/repos/drakkan/sftpgo/releases/latest"
  else
    printf '%s' "https://api.github.com/repos/drakkan/sftpgo/releases/tags/v${SFTPGO_VERSION#v}"
  fi
}

package_architecture() {
  case "$(dpkg --print-architecture)" in
    amd64) printf '%s' "amd64" ;;
    arm64) printf '%s' "arm64" ;;
    armhf) printf '%s' "armhf" ;;
    ppc64el) printf '%s' "ppc64el" ;;
    *)
      echo "SFTPGo does not publish a Debian package for architecture: $(dpkg --print-architecture)" >&2
      exit 1
      ;;
  esac
}

download_verified_package() {
  local api_url
  local architecture
  local asset_line
  local asset_name
  local asset_url
  local asset_digest
  local expected_sha256
  local package_path

  TEMP_DIR="$(mktemp -d /tmp/tater-sftpgo.XXXXXX)"
  chmod 0755 "$TEMP_DIR"
  api_url="$(release_api_url)"
  architecture="$(package_architecture)"

  echo "Reading SFTPGo release metadata..." >&2
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    -o "$TEMP_DIR/release.json" \
    "$api_url"

  asset_line="$(
    jq -r --arg suffix "_${architecture}.deb" '
      [.assets[] | select(.name | endswith($suffix))]
      | if length == 1 then
          .[0] | [.name, .browser_download_url, .digest] | @tsv
        else
          empty
        end
    ' "$TEMP_DIR/release.json"
  )"

  if [ -z "$asset_line" ]; then
    echo "Could not find one SFTPGo Debian package for $architecture in this release." >&2
    exit 1
  fi

  IFS=$'\t' read -r asset_name asset_url asset_digest <<< "$asset_line"
  if [[ "$asset_digest" != sha256:* ]]; then
    echo "The SFTPGo release did not provide a SHA-256 package digest." >&2
    exit 1
  fi

  package_path="$TEMP_DIR/$asset_name"
  echo "Downloading $asset_name..." >&2
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    -o "$package_path" \
    "$asset_url"

  expected_sha256="${asset_digest#sha256:}"
  printf '%s  %s\n' "$expected_sha256" "$package_path" | sha256sum --check --status
  chmod 0644 "$package_path"
  echo "Package SHA-256 verified." >&2
  printf '%s' "$package_path"
}

install_package() {
  local package_path

  package_path="$(download_verified_package)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "$package_path"
}

storage_mount_has_fstab_entry() {
  awk -v mountpoint="$STORAGE_MOUNT" '
    $0 !~ /^[[:space:]]*#/ && $2 == mountpoint { found = 1 }
    END { exit !found }
  ' /etc/fstab
}

storage_mount_uses_managed_image() {
  awk -v image="$STORAGE_IMAGE" -v mountpoint="$STORAGE_MOUNT" '
    $0 !~ /^[[:space:]]*#/ && $1 == image && $2 == mountpoint { found = 1 }
    END { exit !found }
  ' /etc/fstab
}

ext4_capacity_bytes() {
  local block_count
  local block_size

  block_count="$(dumpe2fs -h "$STORAGE_IMAGE" 2>/dev/null | awk -F: '/^Block count:/ { gsub(/[[:space:]]/, "", $2); print $2 }')"
  block_size="$(dumpe2fs -h "$STORAGE_IMAGE" 2>/dev/null | awk -F: '/^Block size:/ { gsub(/[[:space:]]/, "", $2); print $2 }')"
  if ! [[ "$block_count" =~ ^[0-9]+$ && "$block_size" =~ ^[0-9]+$ ]]; then
    echo "Could not read the SFTPGo storage filesystem capacity." >&2
    exit 1
  fi
  printf '%s' "$((block_count * block_size))"
}

ensure_storage_capacity_is_safe() {
  local requested_bytes="$1"
  local current_size_bytes="0"
  local allocated_bytes="0"
  local available_bytes
  local reserve_bytes=$((MIN_HOST_FREE_GB * 1024 * 1024 * 1024))
  local maximum_safe_bytes

  available_bytes="$(df -PB1 "$STORAGE_DIR" | awk 'NR == 2 { print $4 }')"
  if [ -f "$STORAGE_IMAGE" ]; then
    current_size_bytes="$(ext4_capacity_bytes)"
    allocated_bytes="$(du -B1 "$STORAGE_IMAGE" | awk '{ print $1 }')"
  fi

  if [ "$requested_bytes" -le "$current_size_bytes" ]; then
    return
  fi

  maximum_safe_bytes=$((allocated_bytes + available_bytes - reserve_bytes))
  if [ "$maximum_safe_bytes" -lt 0 ] || [ "$requested_bytes" -gt "$maximum_safe_bytes" ]; then
    echo "The requested SFTPGo storage cap would leave less than ${MIN_HOST_FREE_GB} GiB free." >&2
    echo "Choose a smaller --max-storage-gb value or add VPS disk space." >&2
    exit 1
  fi
}

write_storage_fstab_entry() {
  local temp_file

  if storage_mount_uses_managed_image; then
    return
  fi
  if storage_mount_has_fstab_entry; then
    echo "$STORAGE_MOUNT already has a different /etc/fstab entry; refusing to replace it." >&2
    exit 1
  fi

  temp_file="$(mktemp /tmp/tater-sftpgo-fstab.XXXXXX)"
  cp /etc/fstab "$temp_file"
  printf '\n%s %s ext4 loop,nosuid,nodev,noexec 0 0\n' \
    "$STORAGE_IMAGE" "$STORAGE_MOUNT" >> "$temp_file"
  install -m 0644 "$temp_file" /etc/fstab
  rm -f "$temp_file"
}

configure_storage_cap() {
  local requested_bytes
  local current_size_bytes="0"
  local was_mounted="0"
  local fsck_status="0"

  if [ -z "$MAX_STORAGE_GB" ]; then
    return
  fi

  requested_bytes=$((MAX_STORAGE_GB * 1024 * 1024 * 1024))
  install -d -m 0700 -o root -g root "$STORAGE_DIR"
  install -d -m 0750 -o sftpgo -g sftpgo "$STORAGE_MOUNT"

  if mountpoint -q "$STORAGE_MOUNT"; then
    if ! storage_mount_uses_managed_image; then
      echo "$STORAGE_MOUNT is already a mount point not managed by this installer." >&2
      exit 1
    fi
    was_mounted="1"
  elif [ -n "$(find "$STORAGE_MOUNT" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "$STORAGE_MOUNT already contains data; refusing to hide or move it automatically." >&2
    echo "Back up the data and configure a filesystem quota manually before retrying." >&2
    exit 1
  fi

  if [ -f "$STORAGE_IMAGE" ]; then
    if ! blkid -p -s TYPE -o value "$STORAGE_IMAGE" | grep -qx 'ext4'; then
      echo "$STORAGE_IMAGE exists but is not an ext4 filesystem; refusing to alter it." >&2
      exit 1
    fi
    current_size_bytes="$(ext4_capacity_bytes)"
    if [ "$requested_bytes" -lt "$current_size_bytes" ]; then
      echo "Shrinking the existing SFTPGo storage cap is not automatic." >&2
      echo "Keep the current size or migrate the data to a smaller filesystem manually." >&2
      exit 1
    fi
  fi

  ensure_storage_capacity_is_safe "$requested_bytes"
  systemctl stop sftpgo 2>/dev/null || true

  if [ -f "$STORAGE_IMAGE" ]; then
    if [ "$requested_bytes" -gt "$current_size_bytes" ]; then
      if [ "$was_mounted" = "1" ]; then
        umount "$STORAGE_MOUNT"
        was_mounted="0"
      fi
      truncate -s "${MAX_STORAGE_GB}G" "$STORAGE_IMAGE"
      set +e
      e2fsck -f -p "$STORAGE_IMAGE"
      fsck_status="$?"
      set -e
      if [ "$fsck_status" -gt 1 ]; then
        echo "Could not verify the existing SFTPGo storage filesystem." >&2
        exit 1
      fi
      resize2fs "$STORAGE_IMAGE"
    fi
  else
    truncate -s "${MAX_STORAGE_GB}G" "$STORAGE_IMAGE"
    chmod 0600 "$STORAGE_IMAGE"
    mkfs.ext4 -q -F -m 0 -L tater-sftpgo "$STORAGE_IMAGE"
  fi

  chmod 0600 "$STORAGE_IMAGE"
  write_storage_fstab_entry
  systemctl daemon-reload
  if ! mountpoint -q "$STORAGE_MOUNT"; then
    mount "$STORAGE_MOUNT"
  fi
  chown sftpgo:sftpgo "$STORAGE_MOUNT"
  chmod 0750 "$STORAGE_MOUNT"
}

configure_tater_defaults() {
  local env_dir="/etc/sftpgo/env.d"
  local env_file="$env_dir/tater-tunnel.env"
  local service_group="root"

  if getent group sftpgo >/dev/null 2>&1; then
    service_group="sftpgo"
  fi

  install -d -m 0750 -o root -g "$service_group" "$env_dir"
  local sftp_port="0"
  local ftp_port="0"
  local webdav_port="0"

  [ "$SFTP_ACCESS" != "disabled" ] && sftp_port="$SFTP_PORT"
  [ "$FTP_ACCESS" != "disabled" ] && ftp_port="$FTP_PORT"
  [ "$WEBDAV_ACCESS" != "disabled" ] && webdav_port="$WEBDAV_PORT"

  cat > "$env_file" <<EOF
# Managed by the Tater Tunnel SFTPGo installer.
# TATER_SFTPGO_SFTP_ACCESS=$SFTP_ACCESS
# TATER_SFTPGO_FTP_ACCESS=$FTP_ACCESS
# TATER_SFTPGO_WEBDAV_ACCESS=$WEBDAV_ACCESS
# TATER_SFTPGO_WEBDAV_DOMAIN=$WEBDAV_DOMAIN

# Explicit protocol listeners. Port 0 disables a protocol.
SFTPGO_SFTPD__BINDINGS__0__ADDRESS=0.0.0.0
SFTPGO_SFTPD__BINDINGS__0__PORT=$sftp_port
SFTPGO_FTPD__BINDINGS__0__ADDRESS=0.0.0.0
SFTPGO_FTPD__BINDINGS__0__PORT=$ftp_port
SFTPGO_FTPD__BINDINGS__0__TLS_MODE=0
SFTPGO_FTPD__BINDINGS__0__FORCE_PASSIVE_IP=$PUBLIC_IPV4
SFTPGO_FTPD__BINDINGS__0__PASSIVE_CONNECTIONS_SECURITY=0
SFTPGO_FTPD__PASSIVE_PORT_RANGE__START=$FTP_PASSIVE_START
SFTPGO_FTPD__PASSIVE_PORT_RANGE__END=$FTP_PASSIVE_END
SFTPGO_FTPD__DISABLE_ACTIVE_MODE=true
SFTPGO_WEBDAVD__BINDINGS__0__ADDRESS=0.0.0.0
SFTPGO_WEBDAVD__BINDINGS__0__PORT=$webdav_port
SFTPGO_WEBDAVD__BINDINGS__0__PROXY_ALLOWED=127.0.0.1/32,::1/128
SFTPGO_WEBDAVD__BINDINGS__0__CLIENT_IP_PROXY_HEADER=X-Forwarded-For

# Listen on the host while UFW limits WebAdmin to the Tater WireGuard interface.
SFTPGO_HTTPD__BINDINGS__0__ADDRESS=0.0.0.0
SFTPGO_HTTPD__BINDINGS__0__PROXY_ALLOWED=127.0.0.1/32,::1/128
SFTPGO_HTTPD__BINDINGS__0__CLIENT_IP_PROXY_HEADER=X-Forwarded-For
SFTPGO_HTTPD__BINDINGS__0__SECURITY__ENABLED=true
SFTPGO_HTTPD__BINDINGS__0__SECURITY__HTTPS_PROXY_HEADERS__0__KEY=X-Forwarded-Proto
SFTPGO_HTTPD__BINDINGS__0__SECURITY__HTTPS_PROXY_HEADERS__0__VALUE=https

# Harden SFTP and web logins without creating or storing credentials.
SFTPGO_COMMON__DEFENDER__ENABLED=true
SFTPGO_COMMON__SERVER_VERSION=short
SFTPGO_DATA_PROVIDER__USERS_BASE_DIR=/srv/sftpgo/data
SFTPGO_DATA_PROVIDER__TRACK_QUOTA=2
SFTPGO_DATA_PROVIDER__PASSWORD_VALIDATION__ADMINS__MIN_ENTROPY=60
SFTPGO_DATA_PROVIDER__PASSWORD_VALIDATION__USERS__MIN_ENTROPY=50
EOF
  chown root:"$service_group" "$env_file"
  chmod 0640 "$env_file"
}

remove_tcp_rules() {
  local port="$1"

  ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$port" >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$port" proto tcp >/dev/null 2>&1 || true
  ufw --force delete deny in to any port "$port" proto tcp >/dev/null 2>&1 || true
}

configure_tcp_access() {
  local access="$1"
  local port="$2"
  local label="$3"

  remove_tcp_rules "$port"
  case "$access" in
    public)
      ufw allow "$port/tcp" comment "SFTPGo $label"
      ;;
    private|https)
      ufw allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$port" proto tcp comment "SFTPGo $label private WireGuard"
      ufw deny in to any port "$port" proto tcp comment "Block public SFTPGo $label"
      ;;
    disabled)
      ufw deny in to any port "$port" proto tcp comment "Block disabled SFTPGo $label"
      ;;
  esac
}

reload_caddy() {
  caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null
  systemctl reload caddy || systemctl restart caddy
}

configure_webdav_proxy() {
  local snippet_dir
  local backup_file=""
  local temp_file

  snippet_dir="$(dirname "$WEBDAV_CADDY_SNIPPET")"

  if [ "$WEBDAV_ACCESS" != "https" ]; then
    if [ -f "$WEBDAV_CADDY_SNIPPET" ]; then
      backup_file="$(mktemp /tmp/tater-webdav-caddy-backup.XXXXXX)"
      cp -a "$WEBDAV_CADDY_SNIPPET" "$backup_file"
      rm -f "$WEBDAV_CADDY_SNIPPET"
      if ! reload_caddy; then
        install -m 0644 "$backup_file" "$WEBDAV_CADDY_SNIPPET"
        reload_caddy || true
        rm -f "$backup_file"
        echo "Could not remove the previous WebDAV HTTPS proxy." >&2
        exit 1
      fi
      rm -f "$backup_file"
    fi
    return
  fi

  install -d -m 0755 "$snippet_dir"
  temp_file="$(mktemp "$snippet_dir/.sftpgo-webdav.XXXXXX")"
  cat > "$temp_file" <<EOF
$WEBDAV_DOMAIN {
	reverse_proxy 127.0.0.1:$WEBDAV_PORT {
		header_up Host {host}
	}

	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}
}
EOF
  caddy fmt --overwrite "$temp_file" >/dev/null
  if [ -f "$WEBDAV_CADDY_SNIPPET" ]; then
    backup_file="$(mktemp /tmp/tater-webdav-caddy-backup.XXXXXX)"
    cp -a "$WEBDAV_CADDY_SNIPPET" "$backup_file"
  fi
  install -m 0644 "$temp_file" "$WEBDAV_CADDY_SNIPPET"
  rm -f "$temp_file"

  if ! reload_caddy; then
    if [ -n "$backup_file" ]; then
      install -m 0644 "$backup_file" "$WEBDAV_CADDY_SNIPPET"
    else
      rm -f "$WEBDAV_CADDY_SNIPPET"
    fi
    reload_caddy || true
    rm -f "$backup_file"
    echo "Could not enable the WebDAV HTTPS proxy; the previous Caddy configuration was restored." >&2
    exit 1
  fi
  rm -f "$backup_file"
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW is required to expose SFTPGo safely." >&2
    exit 1
  fi
  if ! ufw status | grep -q '^Status: active'; then
    echo "UFW must be active before SFTPGo can be exposed." >&2
    exit 1
  fi

  configure_tcp_access "$SFTP_ACCESS" "$SFTP_PORT" SFTP
  configure_tcp_access "$FTP_ACCESS" "$FTP_PORT" FTP
  configure_tcp_access "$FTP_ACCESS" "$FTP_PASSIVE_START:$FTP_PASSIVE_END" 'FTP passive data'
  configure_tcp_access "$WEBDAV_ACCESS" "$WEBDAV_PORT" WebDAV
  configure_tcp_access private "$WEB_PORT" WebAdmin
  ufw reload >/dev/null
}

start_service() {
  if [ "$START_SERVICE" != "1" ]; then
    return
  fi

  systemctl enable sftpgo
  systemctl restart sftpgo
}

print_summary() {
  local installed_version
  local storage_capacity_gb
  local storage_summary="No installer-managed total cap. Set per-user quotas in WebAdmin."

  installed_version="$(sftpgo --version 2>/dev/null | head -n 1 || true)"
  if [ -f "$STORAGE_IMAGE" ] && storage_mount_uses_managed_image; then
    storage_capacity_gb=$(( $(ext4_capacity_bytes) / 1024 / 1024 / 1024 ))
    if mountpoint -q "$STORAGE_MOUNT"; then
      storage_summary="$(du -sh "$STORAGE_MOUNT" | awk '{ print $1 }') used of ${storage_capacity_gb} GiB maximum"
    else
      storage_summary="${storage_capacity_gb} GiB maximum (storage filesystem is not mounted)"
    fi
  fi
  local public_host="your VPS public IP or your own DNS hostname"
  local private_host="10.88.0.1"
  local sftp_host="$private_host"
  local ftp_host="$private_host"
  local webdav_host="$private_host"
  local sftp_note=""
  local ftp_note=""
  local webdav_note=""
  local webdav_summary="disabled"

  [ "$SFTP_ACCESS" = "public" ] && sftp_host="$public_host"
  [ "$FTP_ACCESS" = "public" ] && ftp_host="$public_host"
  [ "$WEBDAV_ACCESS" = "https" ] && webdav_host="$WEBDAV_DOMAIN"
  [ "$SFTP_ACCESS" = "private" ] && sftp_note="; connect WireGuard first"
  [ "$FTP_ACCESS" = "private" ] && ftp_note="; connect WireGuard first"
  [ "$WEBDAV_ACCESS" = "private" ] && webdav_note="; connect WireGuard first"
  if [ "$WEBDAV_ACCESS" = "https" ]; then
    webdav_summary="https://$WEBDAV_DOMAIN/ (Caddy automatic HTTPS)"
  elif [ "$WEBDAV_ACCESS" = "private" ]; then
    webdav_summary="http://$webdav_host:$WEBDAV_PORT/ ($WEBDAV_ACCESS$webdav_note)"
  fi

  cat <<EOF

SFTPGo install/update complete.

Version:
  ${installed_version:-installed}

Service:
  sudo systemctl status sftpgo
  sudo journalctl -u sftpgo -f

File protocols:
  SFTP:  $([ "$SFTP_ACCESS" = "disabled" ] && printf 'disabled' || printf '%s:%s (%s%s)' "$sftp_host" "$SFTP_PORT" "$SFTP_ACCESS" "$sftp_note")
  FTP:   $([ "$FTP_ACCESS" = "disabled" ] && printf 'disabled' || printf '%s:%s, passive %s-%s (%s%s)' "$ftp_host" "$FTP_PORT" "$FTP_PASSIVE_START" "$FTP_PASSIVE_END" "$FTP_ACCESS" "$ftp_note")
  WebDAV: $webdav_summary

First WebAdmin setup:
  Connect Tater Tunnel WireGuard, then open:
  http://10.88.0.1:$WEB_PORT/web/admin

UFW keeps the unconfigured admin page off the public internet.

Login setup:
  - Create the first admin through the WireGuard-only WebAdmin page.
  - Use a unique strong password; the installer enforces a minimum strength.
  - Enable TOTP two-factor authentication from the admin profile after login.
  - Create separate users and prefer SFTP with SSH public keys where practical.

Recommended defaults:
  - WebAdmin is reachable only through Tater Tunnel WireGuard.
  - Defender automatically blocks repeated failed login attempts.
  - The server banner hides the exact SFTPGo version.
  - Local reverse proxies can pass the real client address safely.
  - Default local user storage is rooted under $STORAGE_MOUNT.

Total local storage cap:
  $storage_summary
  The cap covers default local user storage. External and virtual-folder
  storage configured elsewhere by an administrator is outside this limit.

SFTPGo paths:
  Config:    /etc/sftpgo
  Defaults:  /etc/sftpgo/env.d/tater-tunnel.env
  State:     /var/lib/sftpgo
  User data: /srv/sftpgo/data

Firewall:
  SFTP $SFTP_ACCESS on $SFTP_PORT/tcp.
  FTP $FTP_ACCESS on $FTP_PORT/tcp and $FTP_PASSIVE_START:$FTP_PASSIVE_END/tcp.
  WebDAV $WEBDAV_ACCESS on local port $WEBDAV_PORT/tcp.$([ "$WEBDAV_ACCESS" = "https" ] && printf ' Public access uses Caddy on 443/tcp.')
  Allowed WebAdmin on $WEB_PORT/tcp only through WireGuard and blocked it publicly.

$([ "$FTP_ACCESS" = "public" ] && cat <<'WARNING'
WARNING: Public FTP is unencrypted. Credentials and files can be observed in
transit. Prefer SFTP, or switch FTP to private mode.
WARNING
)

EOF
}

require_root
require_supported_system
validate_version
validate_storage_size
normalize_webdav_options
validate_protocol_access
install_download_tools
resolve_public_ipv4
configure_firewall
install_package
configure_storage_cap
configure_tater_defaults
start_service
configure_webdav_proxy
print_summary
