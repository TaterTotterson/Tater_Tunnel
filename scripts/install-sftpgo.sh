#!/usr/bin/env bash
set -Eeuo pipefail

SFTPGO_VERSION=""
START_SERVICE="1"
SFTP_PORT="2022"
WEB_PORT="8080"
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
  cat > "$env_file" <<'EOF'
# Managed by the Tater Tunnel SFTPGo installer.
# Keep WebAdmin private and make a future localhost reverse proxy client-aware.
SFTPGO_HTTPD__BINDINGS__0__ADDRESS=127.0.0.1
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

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW is required to expose SFTPGo safely." >&2
    exit 1
  fi
  if ! ufw status | grep -q '^Status: active'; then
    echo "UFW must be active before SFTPGo can be exposed." >&2
    exit 1
  fi

  ufw --force delete allow "$SFTP_PORT/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$SFTP_PORT" >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$SFTP_PORT" proto tcp >/dev/null 2>&1 || true
  ufw --force delete deny in to any port "$SFTP_PORT" proto tcp >/dev/null 2>&1 || true
  ufw allow "$SFTP_PORT/tcp" comment 'SFTPGo SFTP'
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
  cat <<EOF

SFTPGo install/update complete.

Version:
  ${installed_version:-installed}

Service:
  sudo systemctl status sftpgo
  sudo journalctl -u sftpgo -f

SFTP clients:
  Host: your VPS public IP or your own DNS hostname
  Port: $SFTP_PORT

First WebAdmin setup from your PC:
  ssh -L $WEB_PORT:127.0.0.1:$WEB_PORT YOUR_SUDO_USER@YOUR_VPS
  Open http://127.0.0.1:$WEB_PORT/web/admin

The SSH-forward command keeps the unconfigured admin page off the public
internet. Keep that SSH session open while using WebAdmin.

Login setup:
  - Create the first admin through the SSH-forwarded WebAdmin page.
  - Use a unique strong password; the installer enforces a minimum strength.
  - Enable TOTP two-factor authentication from the admin profile after login.
  - Create separate SFTP users and prefer SSH public keys where practical.

Recommended defaults:
  - WebAdmin is bound to 127.0.0.1:$WEB_PORT only.
  - Defender automatically blocks repeated failed login attempts.
  - The SFTP banner hides the exact SFTPGo version.
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
  Allowed public $SFTP_PORT/tcp for SFTP clients.
  Kept the web interface private; no rule was added for $WEB_PORT/tcp.

EOF
}

require_root
require_supported_system
validate_version
validate_storage_size
configure_firewall
install_download_tools
install_package
configure_storage_cap
configure_tater_defaults
start_service
print_summary
