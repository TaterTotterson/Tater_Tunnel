#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOC_FILE="$SCRIPT_DIR/../docs/VPS_INSTALL.md"
DEFAULT_REPO_URL="https://github.com/TaterTotterson/Tater_Tunnel.git"
REPO_URL="${TATER_TUNNEL_REPO:-$DEFAULT_REPO_URL}"
TARBALL_URL="${TATER_TUNNEL_TARBALL:-}"
BRANCH="${TATER_TUNNEL_BRANCH:-main}"
SOURCE_DIR="${TATER_TUNNEL_SOURCE_DIR:-/opt/tater-tunnel-src}"
NO_BOOTSTRAP="0"
NO_RUN="0"
IN_REPO_SOURCE="0"
SERVICE_NAME="tater-tunnel-vps"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
ADMIN_USER="${TATER_TUNNEL_ADMIN_USER:-}"
CREATED_ADMIN_USER="0"
DIALOG_ENABLED="0"
DIALOG_HEIGHT="23"
DIALOG_WIDTH="79"
CURRENT_DIALOG_TITLE="Tater Tunnel VPS Setup"
DIALOG_THEME_FILE=""

if [ -f "$SCRIPT_DIR/install-vps-full.sh" ] && [ -f "$SCRIPT_DIR/install-vps-agent.sh" ] && [ -f "$SCRIPT_DIR/uninstall-vps.sh" ] && [ -f "$SCRIPT_DIR/install-znc.sh" ] && [ -f "$SCRIPT_DIR/install-sftpgo.sh" ] && [ -f "$SCRIPT_DIR/configure-cloudflare-dns.sh" ]; then
  IN_REPO_SOURCE="1"
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RESET="$(printf '\033[0m')"
  BOLD="$(printf '\033[1m')"
  DIM="$(printf '\033[2m')"
  REVERSE="$(printf '\033[7m')"
  ORANGE="$(printf '\033[38;5;208m')"
  GREEN="$(printf '\033[38;5;113m')"
  CYAN="$(printf '\033[38;5;45m')"
  RED="$(printf '\033[38;5;203m')"
else
  RESET=""
  BOLD=""
  DIM=""
  REVERSE=""
  ORANGE=""
  GREEN=""
  CYAN=""
  RED=""
fi

MENU_ITEMS=(
  "Update Tater Tunnel"
  "Install on a blank VPS"
  "Install agent only (advanced)"
  "Install ZNC (optional)"
  "Install SFTPGo (optional)"
  "Run security audit"
  "Uninstall Tater Tunnel"
  "View setup notes"
  "Exit"
)

MENU_HELP=(
  "Keep settings and pairing, install the newest code, then restart the service."
  "Guided setup for WireGuard, HTTPS, firewall, and optional services."
  "Install only the VPS Agent; you manage HTTPS, firewall, and proxy settings."
  "Run the IRC bouncer under a normal user with its config in that user's home."
  "Install or update the file server and configure its storage limit."
  "Check tunnel isolation, firewall rules, permissions, and service hardening."
  "Remove the VPS Agent, with clear choices for retaining or deleting its data."
  "Shows the install notes and port checklist."
  "Leaves setup without changing anything."
)

usage() {
  cat <<'EOF'
Tater Tunnel VPS Setup

Usage:
  sudo ./scripts/tater-vps-setup.sh [options]

One-command remote use as a sudo user:
  curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
    -o "$HOME/tater-vps-setup.sh" && sudo bash "$HOME/tater-vps-setup.sh"

Fresh VPS root login:
  curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
    -o "$HOME/tater-vps-setup.sh" && bash "$HOME/tater-vps-setup.sh"

The root-login flow creates a sudo user and then continues the same guided
install. System work stays privileged while user-owned services run under the
new account. Test the new SSH login after setup before disabling root access.

This interactive launcher provides:
  - Source download/update when launched standalone
  - First-run sudo user creation without interrupting the install
  - Safe update path for existing installs
  - Arrow-key setup menu
  - Guided blank VPS install path
  - Optional Cloudflare DNS-only record setup
  - Advanced agent-only install path
  - Optional ZNC and SFTPGo install paths
  - Read-only VPS security audit
  - Uninstall path with optional data purge
  - Setup summary and progress handoff

Options:
  --repo URL          Git repository URL to clone/update.
  --branch NAME       Git branch to use. Default: main
  --tarball URL       Download a tarball instead of using git.
  --source-dir PATH   Source checkout directory. Default: /opt/tater-tunnel-src
  --no-bootstrap      Do not download/update source first.
  --no-run            Download/update only; do not launch the setup menu.
  -h, --help          Show this help.

Environment:
  TATER_TUNNEL_REPO
  TATER_TUNNEL_BRANCH
  TATER_TUNNEL_TARBALL
  TATER_TUNNEL_SOURCE_DIR
EOF
}

clear_screen() {
  if [ -t 1 ]; then
    printf '\033[2J\033[H'
  fi
}

set_dialog_dimensions() {
  local lines="24"
  local columns="80"

  if command -v tput >/dev/null 2>&1; then
    lines="$(tput lines 2>/dev/null || printf '24')"
    columns="$(tput cols 2>/dev/null || printf '80')"
  fi
  [[ "$lines" =~ ^[0-9]+$ ]] || lines="24"
  [[ "$columns" =~ ^[0-9]+$ ]] || columns="80"
  [ "$lines" -ge 18 ] || lines="18"
  [ "$columns" -ge 60 ] || columns="60"
  DIALOG_HEIGHT=$((lines - 1))
  DIALOG_WIDTH=$((columns - 1))
}

cleanup_setup_ui() {
  if [ -n "$DIALOG_THEME_FILE" ] && [ -f "$DIALOG_THEME_FILE" ]; then
    rm -f "$DIALOG_THEME_FILE"
  fi
}

create_tater_dialog_theme() {
  DIALOG_THEME_FILE="$(mktemp /tmp/tater-tunnel-dialogrc.XXXXXX)"
  cat > "$DIALOG_THEME_FILE" <<'EOF'
aspect = 0
separate_widget = ""
tab_len = 0
visit_items = OFF
use_shadow = OFF
use_colors = ON

# Tater Tunnel: black canvas, amber-orange accents, soft gray text.
screen_color = (WHITE,BLACK,OFF)
shadow_color = (BLACK,BLACK,OFF)
dialog_color = (WHITE,BLACK,OFF)
title_color = (YELLOW,BLACK,ON)
border_color = (YELLOW,BLACK,ON)
border2_color = border_color
button_active_color = (BLACK,YELLOW,ON)
button_inactive_color = (WHITE,BLACK,OFF)
button_key_active_color = (BLACK,YELLOW,ON)
button_key_inactive_color = (YELLOW,BLACK,ON)
button_label_active_color = (BLACK,YELLOW,ON)
button_label_inactive_color = (WHITE,BLACK,OFF)
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (YELLOW,BLACK,ON)
inputbox_border2_color = inputbox_border_color
searchbox_color = (WHITE,BLACK,OFF)
searchbox_title_color = (YELLOW,BLACK,ON)
searchbox_border_color = (YELLOW,BLACK,ON)
searchbox_border2_color = searchbox_border_color
position_indicator_color = (YELLOW,BLACK,ON)
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (WHITE,BLACK,OFF)
menubox_border2_color = menubox_border_color
item_color = (WHITE,BLACK,OFF)
item_selected_color = (BLACK,YELLOW,ON)
tag_color = (YELLOW,BLACK,ON)
tag_selected_color = (BLACK,YELLOW,ON)
tag_key_color = (YELLOW,BLACK,ON)
tag_key_selected_color = (BLACK,YELLOW,ON)
check_color = (YELLOW,BLACK,ON)
check_selected_color = (BLACK,YELLOW,ON)
uarrow_color = (YELLOW,BLACK,ON)
darrow_color = (YELLOW,BLACK,ON)
itemhelp_color = (WHITE,BLACK,OFF)
form_active_text_color = (BLACK,YELLOW,ON)
form_text_color = (WHITE,BLACK,OFF)
form_item_readonly_color = (WHITE,BLACK,OFF)
gauge_color = (YELLOW,BLACK,ON)
EOF
  export DIALOGRC="$DIALOG_THEME_FILE"
}

enable_dialog_ui() {
  if [ "${TATER_TUNNEL_MENU:-}" = "numbered" ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    return
  fi
  if ! command -v dialog >/dev/null 2>&1 \
    && [ "$(id -u)" -eq 0 ] \
    && command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update >/dev/null || ! apt-get install -y dialog >/dev/null; then
      return
    fi
  fi
  if command -v dialog >/dev/null 2>&1; then
    create_tater_dialog_theme
    set_dialog_dimensions
    DIALOG_ENABLED="1"
  fi
}

trap cleanup_setup_ui EXIT

dialog_message() {
  local title="$1"
  local message="$2"

  set_dialog_dimensions
  dialog --clear \
    --backtitle "Tater Tunnel // VPS Setup Console" \
    --title "$title" \
    --msgbox "$message" "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
}

print_logo() {
  printf '%s+------------------------------------------------------------------------------+%s\n' "$ORANGE$BOLD" "$RESET"
  printf '%s|%s %-76s %s|%s\n' "$ORANGE$BOLD" "$RESET$BOLD" "TATER TUNNEL // VPS SETUP CONSOLE" "$RESET$ORANGE$BOLD" "$RESET"
  printf '%s+------------------------------------------------------------------------------+%s\n' "$ORANGE$BOLD" "$RESET"
}

recommended_menu_index() {
  if [ -f "$SERVICE_FILE" ]; then
    printf '0'
  else
    printf '1'
  fi
}

console_admin_user() {
  if [ -n "$ADMIN_USER" ]; then
    printf '%s' "$ADMIN_USER"
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    printf '%s' "$SUDO_USER"
  elif is_root_login; then
    printf 'create during setup'
  else
    id -un
  fi
}

print_console_context() {
  local host_name
  local install_state
  local admin_user

  host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'VPS')"
  admin_user="$(console_admin_user)"
  if [ -f "$SERVICE_FILE" ]; then
    install_state="installed"
  else
    install_state="not installed"
  fi

  printf '| %-76.76s |\n' "HOST: ${host_name:0:20}  USER: ${admin_user:0:20}  STATUS: $install_state"
}

wizard_header() {
  local step_number="$1"
  local step_total="$2"
  local title="$3"

  CURRENT_DIALOG_TITLE="Step $step_number of $step_total // $title"
  if [ "$DIALOG_ENABLED" = "1" ]; then
    clear_screen
    return
  fi
  clear_screen
  print_logo
  printf '| %-76.76s |\n' "STEP $step_number OF $step_total // ${title^^}"
  printf '+------------------------------------------------------------------------------+\n'
}

pause() {
  if [ "$DIALOG_ENABLED" = "1" ]; then
    dialog_message "Continue" "Press Enter to continue."
    return
  fi
  printf '\n%sPress Enter to continue...%s' "$DIM" "$RESET"
  read -r _ || true
}

stage() {
  printf '\n%s==>%s %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$1" "$RESET"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        REPO_URL="${2:?--repo requires a value}"
        shift 2
        ;;
      --branch)
        BRANCH="${2:?--branch requires a value}"
        shift 2
        ;;
      --tarball)
        TARBALL_URL="${2:?--tarball requires a value}"
        shift 2
        ;;
      --source-dir)
        SOURCE_DIR="${2:?--source-dir requires a value}"
        shift 2
        ;;
      --no-bootstrap)
        NO_BOOTSTRAP="1"
        shift
        ;;
      --no-run)
        NO_RUN="1"
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
}

require_root_for_bootstrap() {
  if [ "$(id -u)" -ne 0 ]; then
    clear_screen
    print_logo
    cat <<EOF

${RED}${BOLD}Root access is needed for VPS setup.${RESET}

Run:
  sudo ./scripts/tater-vps-setup.sh

EOF
    exit 1
  fi
}

require_root_for_install() {
  if [ "$(id -u)" -ne 0 ]; then
    clear_screen
    print_logo
    cat <<EOF

${RED}${BOLD}Root access is needed for setup changes.${RESET}

Run:
  sudo ./scripts/tater-vps-setup.sh

EOF
    exit 1
  fi
}

is_root_login() {
  [ "$(id -u)" -eq 0 ] && { [ -z "${SUDO_USER:-}" ] || [ "${SUDO_USER:-}" = "root" ]; }
}

valid_linux_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

prompt_sudo_username() {
  local username

  while true; do
    username="$(prompt_value "New sudo username" "tater" yes)"
    if valid_linux_username "$username"; then
      printf '%s' "$username"
      return
    fi
    printf '%sUse a Linux username like tater, admin, or tunnel-admin.%s\n' "$RED" "$RESET" >&2
  done
}

default_sudo_user() {
  if [ -n "$ADMIN_USER" ]; then
    printf '%s' "$ADMIN_USER"
    return
  fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    printf '%s' "$SUDO_USER"
    return
  fi

  printf 'tater'
}

prompt_port() {
  local label="$1"
  local default_value="$2"
  local port

  while true; do
    port="$(prompt_value "$label" "$default_value" yes)"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
      printf '%s' "$port"
      return
    fi
    printf '%sUse a TCP port from 1 to 65535.%s\n' "$RED" "$RESET" >&2
  done
}

prompt_positive_integer() {
  local label="$1"
  local default_value="$2"
  local value

  while true; do
    value="$(prompt_value "$label" "$default_value" yes)"
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "$value"
      return
    fi
    printf '%sEnter a whole number greater than zero.%s\n' "$RED" "$RESET" >&2
  done
}

suggest_sftpgo_storage_gb() {
  local free_kb
  local free_gb
  local maximum_safe
  local suggestion

  free_kb="$(df -Pk /srv 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if ! [[ "$free_kb" =~ ^[0-9]+$ ]]; then
    free_kb="$(df -Pk / | awk 'NR == 2 { print $4 }')"
  fi
  free_gb=$((free_kb / 1024 / 1024))
  maximum_safe=$((free_gb - 2))
  suggestion=$((free_gb * 70 / 100))
  if [ "$suggestion" -gt "$maximum_safe" ]; then
    suggestion="$maximum_safe"
  fi
  if [ "$suggestion" -lt 1 ]; then
    suggestion="1"
  fi
  printf '%s' "$suggestion"
}

select_sftpgo_protocols() {
  local selected=""
  local item
  local -a selected_items=()

  while true; do
    sftpgo_sftp_access="disabled"
    sftpgo_ftp_access="disabled"
    sftpgo_webdav_access="disabled"
    if [ "$DIALOG_ENABLED" = "1" ]; then
      set_dialog_dimensions
      if ! selected="$(dialog --stdout --clear --separate-output \
        --backtitle "Tater Tunnel // VPS Setup Console" \
        --title "$CURRENT_DIALOG_TITLE" \
        --checklist "Select every file protocol to configure. Setup will apply these choices to SFTPGo automatically.\n\nUse Space to toggle an item, then press Enter." \
        "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 8 \
        SFTP "Encrypted file transfer over SSH" off \
        FTP "Legacy FTP with passive-mode support" off \
        WebDAV "Finder and WebDAV-compatible file access" off)"; then
        return 130
      fi
      selected="${selected//\"/}"
      selected="${selected//$'\n'/ }"
      read -r -a selected_items <<< "$selected"
      for item in "${selected_items[@]}"; do
        case "$item" in
          SFTP) sftpgo_sftp_access="private" ;;
          FTP) sftpgo_ftp_access="private" ;;
          WebDAV) sftpgo_webdav_access="private" ;;
        esac
      done
    else
      confirm "Enable SFTP on 2022/tcp" no && sftpgo_sftp_access="private"
      confirm "Enable FTP on 2121/tcp with passive ports 50000-50100" no && sftpgo_ftp_access="private"
      confirm "Enable WebDAV on 10080/tcp" no && sftpgo_webdav_access="private"
    fi

    if [ "$sftpgo_sftp_access" != "disabled" ] \
      || [ "$sftpgo_ftp_access" != "disabled" ] \
      || [ "$sftpgo_webdav_access" != "disabled" ]; then
      return 0
    fi
    if [ "$DIALOG_ENABLED" = "1" ]; then
      dialog_message "Choose a protocol" "Enable at least one SFTPGo file protocol."
    else
      printf '%sEnable at least one file protocol.%s\n' "$RED" "$RESET" >&2
    fi
  done
}

choose_sftpgo_access() {
  local tunnel_domain="${1:-}"
  local webdav_default=""

  sftpgo_insecure_public="0"
  sftpgo_webdav_domain=""

  if [ "$sftpgo_sftp_access" != "disabled" ] \
    && confirm "Allow SFTP from the public internet on 2022/tcp" no \
      "SFTP is encrypted and can be safely exposed for accounts you create.\nPrivate mode requires Tater Tunnel WireGuard."; then
    sftpgo_sftp_access="public"
  fi

  if [ "$sftpgo_ftp_access" != "disabled" ] \
    && confirm "Allow FTP from the public internet" no \
      "Private mode opens TCP 2121 and passive TCP 50000-50100 only on WireGuard.\nPublic FTP sends passwords and files without encryption."; then
    if confirm "I understand public FTP is unencrypted" no \
      "Anyone able to observe the connection may read its credentials and files.\nSFTP is the safer public option."; then
      sftpgo_ftp_access="public"
      sftpgo_insecure_public="1"
    fi
  fi

  if [ "$sftpgo_webdav_access" != "disabled" ] \
    && confirm "Make WebDAV available externally with automatic HTTPS" no \
      "Caddy will issue the certificate and proxy a dedicated subdomain to SFTPGo.\nPort 10080 stays blocked publicly. The subdomain must point directly to this VPS."; then
    if [ -n "$tunnel_domain" ]; then
      webdav_default="files.$(guess_dns_zone "$tunnel_domain")"
    fi
    while true; do
      sftpgo_webdav_domain="$(prompt_value "Dedicated WebDAV subdomain" "$webdav_default" yes)"
      sftpgo_webdav_domain="$(normalize_hostname "$sftpgo_webdav_domain")"
      if valid_dns_name "$sftpgo_webdav_domain" \
        && { [ -z "$tunnel_domain" ] || [ "$sftpgo_webdav_domain" != "$(normalize_hostname "$tunnel_domain")" ]; }; then
        break
      fi
      if [ "$DIALOG_ENABLED" = "1" ]; then
        dialog_message "Invalid hostname" "Use a dedicated hostname such as files.example.com. It cannot be the tunnel hostname."
      else
        printf '%sUse a dedicated hostname such as files.example.com. It cannot be the tunnel hostname.%s\n' "$RED" "$RESET" >&2
      fi
    done
    sftpgo_webdav_access="https"
  fi
}

sftpgo_access_label() {
  local access="$1"
  local port="$2"
  local domain="${3:-}"

  case "$access" in
    public) printf 'public TCP %s' "$port" ;;
    private) printf 'WireGuard-only at 10.88.0.1:%s' "$port" ;;
    https) printf 'HTTPS at https://%s/' "$domain" ;;
    disabled) printf 'disabled' ;;
  esac
}

normalize_hostname() {
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

installed_tater_domain() {
  local caddyfile="/etc/caddy/Caddyfile"

  [ -f "$caddyfile" ] || return 0
  sed -nE 's/^([a-zA-Z0-9.-]+)[[:space:]]*\{[[:space:]]*$/\1/p' "$caddyfile" | head -n 1
}

guess_dns_zone() {
  local hostname="$1"

  hostname="${hostname#http://}"
  hostname="${hostname#https://}"
  hostname="${hostname%%/*}"
  hostname="${hostname%.}"
  awk -F. '{ if (NF >= 2) print $(NF-1) "." $NF; else print $0 }' <<< "$hostname"
}

remove_legacy_znc_web_proxy() {
  local caddyfile="/etc/caddy/Caddyfile"
  local snippet="/etc/caddy/tater-sites/znc-web.caddy"
  local backup_file

  if [ ! -f "$snippet" ]; then
    return 0
  fi

  backup_file="$snippet.tater-security-backup-$(date +%Y%m%d%H%M%S)"
  mv "$snippet" "$backup_file"
  if ! command -v caddy >/dev/null 2>&1 || [ ! -f "$caddyfile" ]; then
    printf '%sRemoved the legacy public ZNC Caddy route.%s\n' "$GREEN" "$RESET"
    return 0
  fi

  if ! caddy validate --adapter caddyfile --config "$caddyfile" >/dev/null; then
    mv "$backup_file" "$snippet"
    printf '%sCould not remove the legacy ZNC route because Caddy validation failed.%s\n' "$RED" "$RESET" >&2
    return 1
  fi

  if ! systemctl reload caddy; then
    mv "$backup_file" "$snippet"
    systemctl reload caddy || systemctl restart caddy
    printf '%sCould not reload Caddy without the legacy ZNC route; it was restored.%s\n' "$RED" "$RESET" >&2
    return 1
  fi
  printf '%sRemoved the legacy public ZNC Caddy route.%s\n' "$GREEN" "$RESET"
}

harden_optional_service_port() {
  local port="$1"
  local label="$2"

  ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$port" >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$port" proto tcp >/dev/null 2>&1 || true
  ufw --force delete deny in to any port "$port" proto tcp >/dev/null 2>&1 || true
  ufw allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$port" proto tcp comment "$label private WireGuard"
  ufw deny in to any port "$port" proto tcp comment "Block public $label"
}

configure_public_sftpgo_port() {
  configure_public_optional_service_port 2022 "SFTPGo SFTP"
}

configure_public_optional_service_port() {
  local port="$1"
  local label="$2"

  ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$port" >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$port" proto tcp >/dev/null 2>&1 || true
  ufw --force delete deny in to any port "$port" proto tcp >/dev/null 2>&1 || true
  ufw allow "$port/tcp" comment "$label"
}

block_optional_service_port() {
  local port="$1"
  local label="$2"

  ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$port" >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$port" proto tcp >/dev/null 2>&1 || true
  ufw --force delete deny in to any port "$port" proto tcp >/dev/null 2>&1 || true
  ufw deny in to any port "$port" proto tcp comment "Block disabled $label"
}

configure_managed_sftpgo_port() {
  local access="$1"
  local port="$2"
  local label="$3"

  case "$access" in
    public) configure_public_optional_service_port "$port" "$label" ;;
    private|https) harden_optional_service_port "$port" "$label" ;;
    disabled) block_optional_service_port "$port" "$label" ;;
    *)
      printf '%sUnknown managed SFTPGo access mode %s for %s; blocking it.%s\n' "$ORANGE" "$access" "$label" "$RESET" >&2
      block_optional_service_port "$port" "$label"
      ;;
  esac
}

managed_sftpgo_access() {
  local protocol="$1"
  local env_file="/etc/sftpgo/env.d/tater-tunnel.env"
  local value

  value="$(sed -nE "s/^# TATER_SFTPGO_${protocol}_ACCESS=(disabled|private|public|https)$/\\1/p" "$env_file" 2>/dev/null | tail -n 1)"
  printf '%s' "${value:-disabled}"
}

managed_sftpgo_webdav_domain() {
  local env_file="/etc/sftpgo/env.d/tater-tunnel.env"

  sed -n 's/^# TATER_SFTPGO_WEBDAV_DOMAIN=//p' "$env_file" 2>/dev/null | tail -n 1
}

verify_sftpgo_selection_applied() {
  local expected_sftp="$1"
  local expected_ftp="$2"
  local expected_webdav="$3"
  local expected_domain="${4:-}"
  local actual_sftp
  local actual_ftp
  local actual_webdav
  local actual_domain
  local message

  actual_sftp="$(managed_sftpgo_access SFTP)"
  actual_ftp="$(managed_sftpgo_access FTP)"
  actual_webdav="$(managed_sftpgo_access WEBDAV)"
  actual_domain="$(managed_sftpgo_webdav_domain)"

  if [ "$actual_sftp" = "$expected_sftp" ] \
    && [ "$actual_ftp" = "$expected_ftp" ] \
    && [ "$actual_webdav" = "$expected_webdav" ] \
    && { [ "$expected_webdav" != "https" ] || [ "$actual_domain" = "$expected_domain" ]; }; then
    return 0
  fi

  message="SFTPGo did not save the selected protocol configuration.

Selected: SFTP=$expected_sftp, FTP=$expected_ftp, WebDAV=$expected_webdav
Applied:  SFTP=$actual_sftp, FTP=$actual_ftp, WebDAV=$actual_webdav"
  if [ "$expected_webdav" = "https" ]; then
    message="$message
Selected WebDAV host: $expected_domain
Applied WebDAV host:  ${actual_domain:-none}"
  fi

  if [ "$DIALOG_ENABLED" = "1" ]; then
    dialog_message "SFTPGo configuration failed" "$message"
  else
    printf '\n%s%s%s\n' "$RED$BOLD" "$message" "$RESET" >&2
  fi
  return 1
}

configure_sftpgo_wireguard_webadmin() {
  local env_dir="/etc/sftpgo/env.d"
  local env_file="$env_dir/tater-tunnel.env"
  local service_group="root"

  if getent group sftpgo >/dev/null 2>&1; then
    service_group="sftpgo"
  fi
  install -d -m 0750 -o root -g "$service_group" "$env_dir"
  if [ -f "$env_file" ] && grep -q '^SFTPGO_HTTPD__BINDINGS__0__ADDRESS=' "$env_file"; then
    sed -i 's/^SFTPGO_HTTPD__BINDINGS__0__ADDRESS=.*/SFTPGO_HTTPD__BINDINGS__0__ADDRESS=0.0.0.0/' "$env_file"
  else
    printf '\n# Tater Tunnel WireGuard-only WebAdmin listener.\nSFTPGO_HTTPD__BINDINGS__0__ADDRESS=0.0.0.0\n' >> "$env_file"
  fi
  chown root:"$service_group" "$env_file"
  chmod 0640 "$env_file"
  harden_optional_service_port 8080 "SFTPGo WebAdmin"
  if systemctl is-active --quiet sftpgo.service; then
    systemctl restart sftpgo.service
  fi
}

installed_znc_ports() {
  local config
  local data_dir
  local service_file

  for config in /home/*/.znc/configs/znc.conf /root/.znc/configs/znc.conf; do
    [ -f "$config" ] || continue
    sed -nE 's/^[[:space:]]*Port[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$config"
  done
  for service_file in /etc/systemd/system/znc-*.service; do
    [ -f "$service_file" ] || continue
    data_dir="$(sed -nE 's|^ExecStart=.*--datadir[= ]([^ ]+).*$|\1|p' "$service_file" | head -n 1)"
    config="${data_dir%/}/configs/znc.conf"
    [ -f "$config" ] || continue
    sed -nE 's/^[[:space:]]*Port[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$config"
  done
}

migrate_installed_znc_webadmin() {
  local service_file
  local target_user
  local data_dir
  local config
  local irc_port

  for service_file in /etc/systemd/system/znc-*.service; do
    [ -f "$service_file" ] || continue
    target_user="$(sed -nE 's/^User=(.+)$/\1/p' "$service_file" | head -n 1)"
    data_dir="$(sed -nE 's|^ExecStart=.*--datadir[= ]([^ ]+).*$|\1|p' "$service_file" | head -n 1)"
    config="${data_dir%/}/configs/znc.conf"
    [ -n "$target_user" ] && [ -n "$data_dir" ] && [ -f "$config" ] || continue
    irc_port="$(awk '
      /^[[:space:]]*<Listener([[:space:]][^>]*)?>[[:space:]]*$/ {
        in_listener = 1
        is_web = ($0 ~ /[[:space:]]tater-web[[:space:]]*>/)
        allow_irc = 1
        port = ""
        next
      }
      in_listener && /^[[:space:]]*AllowIRC[[:space:]]*=[[:space:]]*false[[:space:]]*$/ { allow_irc = 0 }
      in_listener && /^[[:space:]]*Port[[:space:]]*=/ {
        line = $0
        sub(/^[^=]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]*$/, "", line)
        port = line
      }
      in_listener && /^[[:space:]]*<\/Listener>[[:space:]]*$/ {
        if (!is_web && allow_irc && port ~ /^[0-9]+$/) {
          print port
          exit
        }
        in_listener = 0
      }
    ' "$config")"
    irc_port="${irc_port:-6697}"
    "$SCRIPT_DIR/install-znc.sh" \
      --user "$target_user" \
      --data-dir "$data_dir" \
      --port "$irc_port" \
      --web-listen-port 6698 \
      --skip-packages
  done
}

harden_installed_optional_services() {
  local found_znc="0"
  local port
  local webdav_access
  local sftpgo_env_file="/etc/sftpgo/env.d/tater-tunnel.env"

  remove_legacy_znc_web_proxy
  if ! command -v ufw >/dev/null 2>&1 || ! ufw status | grep -q '^Status: active'; then
    printf '%sUFW is not active; optional-service firewall cleanup could not run.%s\n' "$ORANGE" "$RESET" >&2
    return 0
  fi

  if command -v sftpgo >/dev/null 2>&1 || systemctl cat sftpgo.service >/dev/null 2>&1; then
    if grep -q '^# TATER_SFTPGO_SFTP_ACCESS=' "$sftpgo_env_file" 2>/dev/null; then
      webdav_access="$(managed_sftpgo_access WEBDAV)"
      if [ "$webdav_access" = "public" ]; then
        sed -i 's/^# TATER_SFTPGO_WEBDAV_ACCESS=public$/# TATER_SFTPGO_WEBDAV_ACCESS=private/' "$sftpgo_env_file"
        webdav_access="private"
        printf '%sMigrated direct public WebDAV to WireGuard-only access. Re-run SFTPGo setup to add an HTTPS subdomain.%s\n' "$ORANGE" "$RESET"
      fi
      configure_managed_sftpgo_port "$(managed_sftpgo_access SFTP)" 2022 "SFTPGo SFTP"
      configure_managed_sftpgo_port "$(managed_sftpgo_access FTP)" 2121 "SFTPGo FTP"
      configure_managed_sftpgo_port "$(managed_sftpgo_access FTP)" 50000:50100 "SFTPGo FTP passive data"
      configure_managed_sftpgo_port "$webdav_access" 10080 "SFTPGo WebDAV"
    else
      if ufw show added 2>/dev/null | grep -Eq '^ufw allow (2022|2022/tcp)([[:space:]]|$)'; then
        configure_public_sftpgo_port
      else
        harden_optional_service_port 2022 "SFTPGo SFTP"
      fi
    fi
    configure_sftpgo_wireguard_webadmin
  fi
  migrate_installed_znc_webadmin
  while read -r port; do
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
      harden_optional_service_port "$port" ZNC
      found_znc="1"
    fi
  done < <(installed_znc_ports | sort -un)
  if [ "$found_znc" = "0" ] && compgen -G '/etc/systemd/system/znc-*.service' >/dev/null; then
    harden_optional_service_port 6697 ZNC
  fi
  ufw reload >/dev/null
}

harden_existing_tater_caddy() {
  local listen_port="$1"
  local caddyfile="/etc/caddy/Caddyfile"
  local backend="127.0.0.1:${listen_port}"
  local backup_file
  local temp_file
  local proxy_count
  local backend_regex="127\\.0\\.0\\.1:${listen_port}"

  if ! command -v caddy >/dev/null 2>&1 || [ ! -f "$caddyfile" ]; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*@bootstrap[[:space:]]+path[[:space:]]+/[[:space:]]+/assets/tater-vps-mascot\.png[[:space:]]+/api/claim[[:space:]]*$' "$caddyfile" \
    && grep -Eq "^[[:space:]]*reverse_proxy[[:space:]]+${backend_regex}[[:space:]]*$" "$caddyfile"; then
    return 0
  fi

  proxy_count="$(grep -Ec "^[[:space:]]*reverse_proxy[[:space:]]+${backend_regex}[[:space:]]*$" "$caddyfile" || true)"
  if [ "$proxy_count" != "1" ]; then
    printf '%sCould not safely edit the custom Caddyfile automatically.%s\n' "$ORANGE" "$RESET" >&2
    printf '%sExpose only /, the mascot asset, and /api/claim to this backend; keep every management API private.%s\n' "$DIM" "$RESET" >&2
    return 0
  fi

  backup_file="$caddyfile.tater-security-backup-$(date +%Y%m%d%H%M%S)"
  temp_file="$(mktemp /etc/caddy/.Caddyfile.tater-security.XXXXXX)"
  cp -a "$caddyfile" "$backup_file"
  python3 - "$caddyfile" "$temp_file" "$backend" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
destination = pathlib.Path(sys.argv[2])
backend = sys.argv[3]
depth = 0
blocks = []
start = None
for index, line in enumerate(source):
    opens = line.count("{")
    closes = line.count("}")
    if depth == 0 and opens:
        start = index
    depth += opens - closes
    if depth == 0 and start is not None:
        blocks.append((start, index))
        start = None

matches = [block for block in blocks if f"reverse_proxy {backend}" in "\n".join(source[block[0]:block[1] + 1])]
if len(matches) != 1:
    raise SystemExit("Could not locate one Tater Tunnel Caddy site block")
start, end = matches[0]
label = source[start].split("{", 1)[0].rstrip()
replacement = [
    f"{label} {{",
    "  @bootstrap path / /assets/tater-vps-mascot.png /api/claim",
    "  handle @bootstrap {",
    f"    reverse_proxy {backend}",
    "  }",
    "",
    "  handle {",
    "    respond 404",
    "  }",
    "",
    "  header {",
    "    -Server",
    '    X-Content-Type-Options "nosniff"',
    '    Referrer-Policy "no-referrer"',
    "  }",
    "}",
]
destination.write_text("\n".join(source[:start] + replacement + source[end + 1:]) + "\n", encoding="utf-8")
PY

  caddy fmt --overwrite "$temp_file" >/dev/null
  if ! caddy validate --adapter caddyfile --config "$temp_file" >/dev/null; then
    rm -f "$temp_file"
    printf '%sThe hardened Caddy configuration did not validate; the existing file was left unchanged.%s\n' "$RED" "$RESET" >&2
    return 1
  fi

  install -m 0644 "$temp_file" "$caddyfile"
  rm -f "$temp_file"
  if ! systemctl reload caddy; then
    install -m 0644 "$backup_file" "$caddyfile"
    systemctl reload caddy || systemctl restart caddy
    printf '%sCaddy reload failed; the previous configuration was restored.%s\n' "$RED" "$RESET" >&2
    return 1
  fi
  printf '%sCaddy now exposes only the landing page and one-time pairing endpoint.%s\n' "$GREEN" "$RESET"
}

harden_existing_tater_firewall() {
  local listen_port="$1"

  if ! command -v ufw >/dev/null 2>&1 || ! ufw status | grep -q '^Status: active'; then
    return 0
  fi

  ufw --force delete allow "$listen_port/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$listen_port" >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 to any port "$listen_port" proto tcp >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.0/24 to 10.88.0.1 port "$listen_port" proto tcp >/dev/null 2>&1 || true
  ufw --force delete allow in on tater0 from 10.88.0.2 to 10.88.0.1 port "$listen_port" proto tcp >/dev/null 2>&1 || true
  ufw --force delete deny in to any port "$listen_port" proto tcp >/dev/null 2>&1 || true
  ufw --force delete route allow in on tater0 out on tater0 from 10.88.0.0/24 to 10.88.0.2 port 30000:30999 proto tcp >/dev/null 2>&1 || true
  ufw --force delete route allow in on tater0 out on tater0 from 10.88.0.0/24 to 10.88.0.2 port 30000:30999 proto udp >/dev/null 2>&1 || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if grep -Eq '^[#[:space:]]*net/ipv4/ip_forward=' /etc/ufw/sysctl.conf; then
    sed -i 's|^[#[:space:]]*net/ipv4/ip_forward=.*|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf
  else
    printf '\nnet/ipv4/ip_forward=1\n' >> /etc/ufw/sysctl.conf
  fi
  ufw default deny routed
  ufw allow in on tater0 from 10.88.0.2 to 10.88.0.1 port "$listen_port" proto tcp comment 'Tater Home Agent management'
  ufw deny in to any port "$listen_port" proto tcp comment 'Block public Tater management'
  ufw route allow in on tater0 out on tater0 from 10.88.0.0/24 to 10.88.0.2 port 30000:30999 proto tcp comment 'Tater private TCP services'
  ufw route allow in on tater0 out on tater0 from 10.88.0.0/24 to 10.88.0.2 port 30000:30999 proto udp comment 'Tater private UDP services'
  ufw reload >/dev/null
  printf '%sPrivate management and service forwarding rules were updated.%s\n' "$GREEN" "$RESET"
}

apply_update_hardening() {
  local listen_port="$1"
  local wg_management_access="$2"

  harden_existing_tater_caddy "$listen_port"
  if [ "$wg_management_access" = "1" ]; then
    harden_existing_tater_firewall "$listen_port"
  fi
  harden_installed_optional_services
}

ensure_sudo_available() {
  if command -v sudo >/dev/null 2>&1; then
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    stage "Installing sudo"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y sudo
    return
  fi

  cat <<EOF >&2
sudo is not installed, and this setup only knows how to install it with apt-get.
Install sudo for your distro, create a sudo user, then rerun this setup.
EOF
  exit 1
}

create_sudo_user() {
  local username="$1"

  ensure_sudo_available

  if getent passwd "$username" >/dev/null 2>&1; then
    printf '%sUser %s already exists. Adding it to the sudo group.%s\n' "$DIM" "$username" "$RESET"
  else
    stage "Creating sudo user $username"
    if command -v adduser >/dev/null 2>&1; then
      adduser --gecos "" "$username"
    else
      useradd -m -s /bin/bash "$username"
      passwd "$username"
    fi
  fi

  usermod -aG sudo "$username"
  if ! id -nG "$username" | tr ' ' '\n' | grep -qx sudo; then
    printf 'Failed to add %s to the sudo group. No installation was started.\n' "$username" >&2
    exit 1
  fi
  printf '%sVerified: %s belongs to the sudo group (active on next login).%s\n' "$GREEN" "$username" "$RESET"
}

print_relogin_instructions() {
  local username="$1"
  local host_hint

  host_hint="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
  host_hint="${host_hint:-your.vps.ip.or.domain}"

  cat <<EOF

${GREEN}${BOLD}Sudo user is ready.${RESET}

The guided install continued in the original session. You do not need to run
the installer again.

Keep this root session open and test the new account from a second terminal on
your PC:

  VPS_HOST=$host_hint
  ssh $username@\$VPS_HOST

The README has the short SSH-key command and hardening steps. Keep the current
root session open until you have tested a second login as $username.
EOF
}

handle_root_login_for_blank_vps() {
  local username

  if [ "${TATER_TUNNEL_ALLOW_ROOT_LOGIN:-0}" = "1" ] || ! is_root_login; then
    return
  fi

  clear_screen
  print_logo
  cat <<EOF

${ORANGE}${BOLD}Root login detected.${RESET}

For a blank VPS, create a normal sudo user first. That keeps the Tater install
and future SSH access safer than doing day-to-day work as root.

This setup will create the user, add it to the sudo group, and continue in this
session. System changes still run as root; user-owned services run as the new
account.

EOF

  if ! confirm "Create a sudo user before installing Tater Tunnel" yes; then
    printf '\n%sA normal admin account is required for the guided blank-VPS install.%s\n' "$RED" "$RESET"
    exit 1
  fi

  username="$(prompt_sudo_username)"
  create_sudo_user "$username"
  ADMIN_USER="$username"
  CREATED_ADMIN_USER="1"
  printf '\n%sAdmin user %s is ready. Continuing setup now.%s\n' "$GREEN$BOLD" "$username" "$RESET"
}

handle_root_login_for_user_addon() {
  local username

  if [ "${TATER_TUNNEL_ALLOW_ROOT_LOGIN:-0}" = "1" ] || ! is_root_login; then
    return
  fi

  clear_screen
  print_logo
  cat <<EOF

${ORANGE}${BOLD}Root login detected.${RESET}

Optional user services like ZNC should run as a normal sudo user, with config
stored in that user's home folder.

This setup can create the sudo user and then continue while running ZNC itself
under that account.

EOF

  if ! confirm "Create a sudo user before installing ZNC" yes; then
    printf '\n%sZNC needs a normal user account and will not run as root.%s\n' "$RED" "$RESET"
    exit 1
  fi

  username="$(prompt_sudo_username)"
  create_sudo_user "$username"
  ADMIN_USER="$username"
  CREATED_ADMIN_USER="1"
  printf '\n%sAdmin user %s is ready. Continuing with ZNC setup.%s\n' "$GREEN$BOLD" "$username" "$RESET"
}

require_bootstrap_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if [ -n "$TARBALL_URL" ]; then
      apt-get install -y ca-certificates curl dialog tar
    else
      apt-get install -y ca-certificates dialog git
    fi
    return
  fi

  if [ -n "$TARBALL_URL" ]; then
    for command in curl tar; do
      if ! command -v "$command" >/dev/null 2>&1; then
        echo "$command is required. Install it and run setup again." >&2
        exit 1
      fi
    done
  elif ! command -v git >/dev/null 2>&1; then
    echo "git is required. Install git or rerun with --tarball." >&2
    exit 1
  fi
}

download_from_git() {
  local backup_dir

  install -d -m 0755 "$(dirname "$SOURCE_DIR")"

  if [ -d "$SOURCE_DIR/.git" ]; then
    if [ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all)" ]; then
      backup_dir="$SOURCE_DIR.backup.$(date +%Y%m%d%H%M%S).$$"
      mv "$SOURCE_DIR" "$backup_dir"
      git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SOURCE_DIR"
      printf '%sExisting modified source preserved at %s%s\n' "$DIM" "$backup_dir" "$RESET"
      return
    fi
    git -C "$SOURCE_DIR" remote set-url origin "$REPO_URL"
    git -C "$SOURCE_DIR" fetch --depth 1 origin "$BRANCH"
    git -C "$SOURCE_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
  elif [ -e "$SOURCE_DIR" ]; then
    backup_dir="$SOURCE_DIR.backup.$(date +%Y%m%d%H%M%S).$$"
    mv "$SOURCE_DIR" "$backup_dir"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SOURCE_DIR"
    printf '%sExisting non-git source moved to %s%s\n' "$DIM" "$backup_dir" "$RESET"
  else
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SOURCE_DIR"
  fi
}

download_from_tarball() {
  local temp_dir
  local archive
  local extracted

  temp_dir="$(mktemp -d)"
  archive="$temp_dir/tater-tunnel.tar.gz"

  curl -fsSL "$TARBALL_URL" -o "$archive"
  tar -xzf "$archive" -C "$temp_dir"
  extracted="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  if [ -z "$extracted" ]; then
    echo "Tarball did not contain a source directory." >&2
    exit 1
  fi

  if [ -e "$SOURCE_DIR" ]; then
    mv "$SOURCE_DIR" "$SOURCE_DIR.backup.$(date +%Y%m%d%H%M%S)"
  fi
  install -d -m 0755 "$(dirname "$SOURCE_DIR")"
  mv "$extracted" "$SOURCE_DIR"
  rm -rf "$temp_dir"
}

prepare_downloaded_scripts() {
  if [ ! -f "$SOURCE_DIR/scripts/tater-vps-setup.sh" ]; then
    echo "Downloaded source is missing scripts/tater-vps-setup.sh." >&2
    exit 1
  fi
  chmod +x "$SOURCE_DIR/scripts/"*.sh
}

bootstrap_source_if_needed() {
  if [ "$NO_BOOTSTRAP" = "1" ] || [ "$IN_REPO_SOURCE" = "1" ]; then
    return
  fi

  require_root_for_bootstrap
  clear_screen
  print_logo
  stage "Preparing bootstrap tools"
  require_bootstrap_packages

  if [ -n "$TARBALL_URL" ]; then
    stage "Downloading Tater Tunnel tarball"
    download_from_tarball
  else
    stage "Downloading Tater Tunnel source"
    download_from_git
  fi

  stage "Preparing setup scripts"
  prepare_downloaded_scripts
  printf '%sSource:%s %s\n' "$GREEN" "$RESET" "$SOURCE_DIR"

  if [ "$NO_RUN" = "1" ]; then
    printf '\n%sSource is ready. Re-run:%s sudo %s/scripts/tater-vps-setup.sh\n' "$GREEN" "$RESET" "$SOURCE_DIR"
    exit 0
  fi

  stage "Launching downloaded setup menu"
  if [ -r /dev/tty ]; then
    exec "$SOURCE_DIR/scripts/tater-vps-setup.sh" --no-bootstrap < /dev/tty
  fi
  exec "$SOURCE_DIR/scripts/tater-vps-setup.sh" --no-bootstrap
}

prompt_value() {
  local label="$1"
  local default_value="${2:-}"
  local required="${3:-no}"
  local value

  while true; do
    if [ "$DIALOG_ENABLED" = "1" ]; then
      set_dialog_dimensions
      if ! value="$(dialog --stdout --clear \
        --backtitle "Tater Tunnel // VPS Setup Console" \
        --title "$CURRENT_DIALOG_TITLE" \
        --inputbox "$label" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$default_value")"; then
        return 130
      fi
      if [ "$required" != "yes" ] || [ -n "$value" ]; then
        printf '%s' "$value"
        return
      fi
      dialog_message "Required value" "$label cannot be blank."
      continue
    fi
    if [ -n "$default_value" ]; then
      printf '\n%s%s%s [%s]\n> ' "$BOLD" "$label" "$RESET" "$default_value" >&2
    else
      printf '\n%s%s%s\n> ' "$BOLD" "$label" "$RESET" >&2
    fi

    read -r value
    value="${value:-$default_value}"
    if [ "$required" != "yes" ] || [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
    printf '%sThis value is required.%s\n' "$RED" "$RESET" >&2
  done
}

prompt_secret() {
  local label="$1"
  local required="${2:-yes}"
  local value

  while true; do
    if [ "$DIALOG_ENABLED" = "1" ]; then
      set_dialog_dimensions
      if ! value="$(dialog --stdout --clear \
        --backtitle "Tater Tunnel // VPS Setup Console" \
        --title "$CURRENT_DIALOG_TITLE" \
        --insecure \
        --passwordbox "$label" "$DIALOG_HEIGHT" "$DIALOG_WIDTH")"; then
        return 130
      fi
    else
      printf '\n%s%s%s\n> ' "$BOLD" "$label" "$RESET" >&2
      IFS= read -rs value
      printf '\n' >&2
    fi

    if [ "$required" != "yes" ] || [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
    if [ "$DIALOG_ENABLED" = "1" ]; then
      dialog_message "Required value" "$label cannot be blank."
    else
      printf '%sThis value is required.%s\n' "$RED" "$RESET" >&2
    fi
  done
}

confirm() {
  local label="$1"
  local default="${2:-yes}"
  local details="${3:-}"
  local message="$label"
  local hint="[Y/n]"
  local reply

  if [ "$DIALOG_ENABLED" = "1" ]; then
    local -a default_option=()
    if [ "$default" = "no" ]; then
      default_option=(--defaultno)
    fi
    if [ -n "$details" ]; then
      message="$details

$label"
    fi
    set_dialog_dimensions
    dialog --clear \
      --backtitle "Tater Tunnel // VPS Setup Console" \
      --title "$CURRENT_DIALOG_TITLE" \
      "${default_option[@]}" \
      --yesno "$message" "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
    return $?
  fi

  if [ "$default" = "no" ]; then
    hint="[y/N]"
  fi

  while true; do
    printf '\n%s%s%s %s\n> ' "$BOLD" "$label" "$RESET" "$hint" >&2
    read -r reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf '%sAnswer yes or no.%s\n' "$RED" "$RESET" >&2 ;;
    esac
  done
}

print_stage() {
  local number="$1"
  local total="$2"
  local message="$3"
  printf '\n%s[%s/%s]%s %s%s%s\n' "$CYAN" "$number" "$total" "$RESET" "$BOLD" "$message" "$RESET"
}

show_progress_handoff() {
  local title="$1"
  local status
  local command_pid
  local failure_details
  local log_file
  shift

  if [ "$DIALOG_ENABLED" = "1" ]; then
    set_dialog_dimensions
    log_file="$(mktemp /tmp/tater-tunnel-progress.XXXXXX)"
    "$@" </dev/tty >"$log_file" 2>&1 &
    command_pid="$!"
    set +e
    tail --pid="$command_pid" -n +1 -f "$log_file" | dialog --clear \
      --backtitle "Tater Tunnel // VPS Setup Console" \
      --title "$title" \
      --programbox "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
    wait "$command_pid"
    status="$?"
    set -e
    if [ "$status" = "0" ]; then
      rm -f "$log_file"
      return 0
    fi
    failure_details="$(tail -n 12 "$log_file" 2>/dev/null || true)"
    rm -f "$log_file"
    dialog_message "Action failed" "The action returned exit code $status. Some earlier changes may have completed.

Last output:

$failure_details"
    return "$status"
  fi

  clear_screen
  print_logo
  printf '| %-76s |\n' 'INSTALL LOG'
  printf '+------------------------------------------------------------------------------+\n'
  printf '| %-76.76s |\n' '[OK] SETUP CHOICES VALIDATED'
  printf '| %-76.76s |\n' "[..] ${title^^}"
  printf '+------------------------------------------------------------------------------+\n'
  if "$@"; then
    status="0"
  else
    status="$?"
  fi
  printf '+------------------------------------------------------------------------------+\n'
  if [ "$status" = "0" ]; then
    printf '| %-76s |\n' '[OK] ACTION COMPLETED SUCCESSFULLY'
    printf '+------------------------------------------------------------------------------+\n'
    return 0
  fi
  printf '\n  %s[failed]%s Action stopped with exit code %s\n' "$RED$BOLD" "$RESET" "$status" >&2
  return "$status"
}

show_cloudflare_progress() (
  local title="$1"
  local token="$2"
  shift 2

  export CLOUDFLARE_API_TOKEN="$token"
  show_progress_handoff "$title" "$@"
)

show_pairing_completion() {
  local domain="$1"
  local pairing_code="$2"

  if [ "$DIALOG_ENABLED" = "1" ]; then
    dialog_message "Install complete" "VPS URL

https://$domain

ONE-TIME PAIRING CODE

${pairing_code:-UNAVAILABLE}

Open Tater Tunnel on your computer and enter the URL and code above.

Keep this screen private. The code closes after the first successful pairing."
    return
  fi

  clear_screen
  print_logo
  printf '| %-76s |\n' 'INSTALL COMPLETE'
  printf '+------------------------------------------------------------------------------+\n'
  printf '| %-76s |\n' ''
  printf '| %-76s |\n' 'VPS URL'
  printf '| %-76.76s |\n' "https://$domain"
  printf '| %-76s |\n' ''
  printf '| %-76s |\n' 'ONE-TIME PAIRING CODE'
  printf '| %s%-76.76s%s |\n' "$GREEN$BOLD" "${pairing_code:-UNAVAILABLE}" "$RESET"
  printf '| %-76s |\n' ''
  printf '+------------------------------------------------------------------------------+\n'
  printf '| %-76.76s |\n' 'Open Tater Tunnel on your computer and enter the URL and code above.'
  printf '| %-76.76s |\n' 'Keep this screen private. The code closes after the first successful pairing.'
  printf '+------------------------------------------------------------------------------+\n'
}

service_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$SERVICE_FILE" 2>/dev/null || true
}

service_arg() {
  local line="$1"
  local flag="$2"
  local default_value="$3"
  local -a arguments

  read -r -a arguments <<< "$line"
  set -- "${arguments[@]}"
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$flag" ]; then
      shift
      printf '%s' "${1:-$default_value}"
      return
    fi
    shift
  done

  printf '%s' "$default_value"
}

render_menu() {
  local selected="$1"
  local index
  local recommended
  local label

  clear_screen
  print_logo
  print_console_context
  recommended="$(recommended_menu_index)"
  printf '+------------------------------------------------------------------------------+\n'
  printf '| %-76s |\n' 'MAIN MENU'
  printf '+------------------------------------------------------------------------------+\n'

  for index in "${!MENU_ITEMS[@]}"; do
    label="  $((index + 1)). ${MENU_ITEMS[$index]}"
    if [ "$index" -eq "$recommended" ]; then
      label="$label  [RECOMMENDED]"
    fi
    if [ "$index" -eq "$selected" ]; then
      printf '|%s %-76.76s %s|\n' "$REVERSE$BOLD" "> $label" "$RESET"
    else
      printf '| %-76.76s |\n' "  $label"
    fi
  done
  printf '+------------------------------------------------------------------------------+\n'
  printf '| %-76.76s |\n' "${MENU_HELP[$selected]}"
  printf '| %-76s |\n' 'UP/DOWN: MOVE   ENTER: SELECT   1-9: QUICK SELECT   Q: EXIT'
  printf '+------------------------------------------------------------------------------+\n'
}

interactive_menu() {
  local selected
  local key
  local escape_sequence

  selected="$(recommended_menu_index)"

  while true; do
    render_menu "$selected"
    IFS= read -rsn1 key || exit 0
    if [ "$key" = $'\x1b' ]; then
      escape_sequence=""
      IFS= read -rsn2 -t 0.15 escape_sequence || true
      case "$escape_sequence" in
        "[A"*|"OA"*)
          selected=$(( (selected + ${#MENU_ITEMS[@]} - 1) % ${#MENU_ITEMS[@]} ))
          ;;
        "[B"*|"OB"*)
          selected=$(( (selected + 1) % ${#MENU_ITEMS[@]} ))
          ;;
      esac
    elif [ -z "$key" ]; then
      return "$selected"
    elif [ "$key" = "k" ] || [ "$key" = "K" ] || [ "$key" = "w" ] || [ "$key" = "W" ]; then
      selected=$(( (selected + ${#MENU_ITEMS[@]} - 1) % ${#MENU_ITEMS[@]} ))
    elif [ "$key" = "j" ] || [ "$key" = "J" ] || [ "$key" = "s" ] || [ "$key" = "S" ]; then
      selected=$(( (selected + 1) % ${#MENU_ITEMS[@]} ))
    elif [[ "$key" =~ ^[0-9]$ ]] && [ "$key" -ge 1 ] && [ "$key" -le "${#MENU_ITEMS[@]}" ]; then
      return "$((key - 1))"
    elif [ "$key" = "q" ] || [ "$key" = "Q" ]; then
      return "$((${#MENU_ITEMS[@]} - 1))"
    fi
  done
}

numbered_menu() {
  local choice
  local index
  local recommended
  local badge

  clear_screen
  print_logo
  print_console_context
  recommended="$(recommended_menu_index)"
  printf '+------------------------------------------------------------------------------+\n'
  printf '| %-76s |\n' 'MAIN MENU'
  printf '+------------------------------------------------------------------------------+\n'
  for index in "${!MENU_ITEMS[@]}"; do
    badge=""
    if [ "$index" -eq "$recommended" ]; then
      badge=" [RECOMMENDED]"
    fi
    printf '| %-76.76s |\n' "$((index + 1)). ${MENU_ITEMS[$index]}$badge"
  done
  printf '+------------------------------------------------------------------------------+\n'

  while true; do
    printf '\nSelect 1-%s: ' "${#MENU_ITEMS[@]}" >&2
    if ! read -r choice; then
      exit 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MENU_ITEMS[@]}" ]; then
      return "$((choice - 1))"
    fi
    printf '%sChoose a listed number.%s\n' "$RED" "$RESET" >&2
  done
}

dialog_menu() {
  local choice
  local host_name
  local install_state
  local admin_user
  local recommended
  local index
  local badge
  local -a menu_args=()

  host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'VPS')"
  admin_user="$(console_admin_user)"
  if [ -f "$SERVICE_FILE" ]; then
    install_state="installed"
  else
    install_state="not installed"
  fi
  recommended="$(recommended_menu_index)"
  for index in "${!MENU_ITEMS[@]}"; do
    badge=""
    if [ "$index" -eq "$recommended" ]; then
      badge=" [recommended]"
    fi
    menu_args+=("$index" "${MENU_ITEMS[$index]}$badge" "${MENU_HELP[$index]}")
  done

  set_dialog_dimensions
  if choice="$(dialog --stdout --clear \
    --backtitle "Tater Tunnel // VPS Setup Console" \
    --title "Main menu" \
    --item-help \
    --default-item "$recommended" \
    --menu "Host: $host_name    Admin: $admin_user    Status: $install_state

Use the arrow keys to choose an action, then press Enter." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 12 \
    "${menu_args[@]}")"; then
    return "$choice"
  fi
  return "$((${#MENU_ITEMS[@]} - 1))"
}

choose_menu() {
  if [ "$DIALOG_ENABLED" = "1" ]; then
    dialog_menu
  elif [ "${TATER_TUNNEL_MENU:-}" = "numbered" ]; then
    numbered_menu
  elif [ -t 0 ]; then
    interactive_menu
  else
    numbered_menu
  fi
}

run_update_install() {
  local exec_start
  local working_dir
  local listen_host
  local listen_port
  local state_file
  local config_file
  local install_dir
  local state_dir
  local config_dir
  local wireguard_interface
  local args
  local wg_management_access="0"

  CURRENT_DIALOG_TITLE="Update Tater Tunnel"
  require_root_for_install
  clear_screen
  print_logo

  if [ ! -f "$SERVICE_FILE" ]; then
    cat <<EOF

${RED}${BOLD}No existing Tater VPS service was found.${RESET}

Expected:
  $SERVICE_FILE

Choose a fresh install path first, then use this update path later.
EOF
    pause
    return 0
  fi

  exec_start="$(service_value "ExecStart")"
  working_dir="$(service_value "WorkingDirectory")"
  listen_host="$(service_arg "$exec_start" "--host" "127.0.0.1")"
  listen_port="$(service_arg "$exec_start" "--port" "4174")"
  state_file="$(service_arg "$exec_start" "--state-file" "/var/lib/tater-tunnel/vps-agent.json")"
  config_file="$(service_arg "$exec_start" "--wireguard-config" "/etc/tater-tunnel/wireguard/tater0.conf")"
  install_dir="${working_dir:-/opt/tater-tunnel}"
  state_dir="$(dirname "$state_file")"
  config_dir="$(dirname "$(dirname "$config_file")")"
  wireguard_interface="$(basename "$config_file" .conf)"

  if [ "$listen_host" = "0.0.0.0" ]; then
    wg_management_access="1"
  fi

  cat <<EOF

${BOLD}Update Tater Tunnel${RESET}
This updates the app files and systemd unit while preserving:
  - Current WireGuard-only pairing state in $state_dir
  - WireGuard config in $config_dir
  - Existing bind host/port from systemd

Older HTTPS relay state is intentionally replaced with a clean pairing state
when the updated VPS Agent starts.

Detected:
  Install dir:  $install_dir
  Agent:        http://$listen_host:$listen_port
  Private WG:   $([ "$wg_management_access" = "1" ] && printf 'management enabled' || printf 'localhost/proxy only')

EOF

  args=(
    "$SCRIPT_DIR/install-vps-agent.sh"
    --listen-host "$listen_host"
    --listen-port "$listen_port"
    --install-dir "$install_dir"
    --state-dir "$state_dir"
    --config-dir "$config_dir"
    --wireguard-interface "$wireguard_interface"
  )

  if [ "$wg_management_access" = "1" ]; then
    args+=(--wireguard-management-access)
  fi
  if ! confirm "Install/refresh OS packages during update" no; then
    args+=(--skip-packages)
  fi
  if ! confirm "Restart service after update" yes; then
    args+=(--no-start)
  fi
  if confirm "Reopen pairing after update" yes; then
    args+=(--reopen-pairing)
  fi

  if ! confirm "Start update now" yes "Install directory: $install_dir
Agent: http://$listen_host:$listen_port
Pairing and WireGuard state: preserved
Optional private services: checked and migrated"; then
    return 0
  fi

  show_progress_handoff "Update progress will appear below." "${args[@]}"
  show_progress_handoff "Applying private-service migrations." apply_update_hardening "$listen_port" "$wg_management_access"
}

run_full_install() {
  local domain
  local email
  local ssh_port
  local listen_port
  local pairing_code
  local args
  local configure_firewall="1"
  local install_znc="0"
  local znc_user=""
  local znc_port="6697"
  local znc_web_port="6698"
  local znc_makeconf="0"
  local znc_args
  local install_sftpgo="0"
  local sftpgo_sftp_access="private"
  local sftpgo_ftp_access="disabled"
  local sftpgo_webdav_access="disabled"
  local sftpgo_webdav_domain=""
  local sftpgo_insecure_public="0"
  local sftpgo_storage_cap_gb=""
  local sftpgo_args
  local configure_cloudflare="0"
  local cloudflare_zone=""
  local cloudflare_ipv4=""
  local cloudflare_api_token=""
  local cloudflare_args
  local cloudflare_summary
  local final_pairing_code

  CURRENT_DIALOG_TITLE="Install on a blank VPS"
  handle_root_login_for_blank_vps
  require_root_for_install
  wizard_header "1" "4" "Core VPS settings"
  cat <<EOF

${BOLD}Install on a blank VPS${RESET}
This path installs Tater Tunnel, Caddy automatic HTTPS, WireGuard, and UFW.
Caddy will route HTTPS traffic to the local Tater service on 127.0.0.1.
Optional ZNC and SFTPGo services can be included in the same setup.

EOF

  domain="$(prompt_value "Dedicated Tater Tunnel HTTPS domain pointed at this VPS" "" yes)"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  domain="${domain%.}"
  email="$(prompt_value "ACME email (blank is ok)" "" no)"
  ssh_port="$(prompt_value "SSH port to keep open" "22" yes)"
  listen_port="$(prompt_value "Local Tater VPS Agent port" "4174" yes)"
  pairing_code="$(prompt_value "Pairing code (blank to generate)" "" no)"

  args=("$SCRIPT_DIR/install-vps-full.sh" --domain "$domain" --ssh-port "$ssh_port" --listen-port "$listen_port")
  if is_root_login; then
    args+=(--allow-root-login)
  fi
  if [ -n "$email" ]; then
    args+=(--email "$email")
  fi
  if [ -n "$pairing_code" ]; then
    args+=(--pairing-code "$pairing_code")
  fi
  if ! confirm "Configure UFW firewall for 80/tcp, 443/tcp, 51888/udp, and SSH" yes; then
    args+=(--no-firewall)
    configure_firewall="0"
  fi

  wizard_header "2" "4" "Optional services"

  if [ "$configure_firewall" = "1" ] && confirm "Install optional ZNC IRC bouncer" no; then
    install_znc="1"
    while true; do
      znc_user="$(prompt_value "Linux user to run ZNC" "$(default_sudo_user)" yes)"
      if ! valid_linux_username "$znc_user"; then
        printf '%sUse a Linux username like tater, admin, or tunnel-admin.%s\n' "$RED" "$RESET" >&2
        continue
      fi
      if [ "$znc_user" = "root" ]; then
        printf '%sZNC should not run as root. Choose a normal sudo user.%s\n' "$RED" "$RESET" >&2
        continue
      fi
      break
    done
    if ! id -u "$znc_user" >/dev/null 2>&1; then
      if confirm "User $znc_user does not exist. Create it as a sudo user" yes; then
        create_sudo_user "$znc_user"
      else
        install_znc="0"
      fi
    fi
    if [ "$install_znc" = "1" ]; then
      znc_port="$(prompt_port "ZNC listener port" "6697")"
      if confirm "Run ZNC interactive config wizard during install" yes; then
        znc_makeconf="1"
      fi
    fi
  fi

  if [ "$configure_firewall" = "1" ] && confirm "Install optional SFTPGo file server" no; then
    install_sftpgo="1"
    select_sftpgo_protocols
    choose_sftpgo_access "$domain"
    if confirm "Set a total cap for SFTPGo's default local storage" yes; then
      sftpgo_storage_cap_gb="$(prompt_positive_integer "Maximum SFTPGo storage in GiB" "$(suggest_sftpgo_storage_gb)")"
    fi
  fi

  if [ "$configure_firewall" != "1" ]; then
    printf '%sOptional ZNC and SFTPGo setup is skipped without managed UFW rules.%s\n' "$ORANGE" "$RESET"
  fi

  if confirm "Create DNS-only records with a Cloudflare API token" no; then
    configure_cloudflare="1"
    cloudflare_zone="$(prompt_value "Cloudflare zone" "$(guess_dns_zone "$domain")" yes)"
    cloudflare_ipv4="$(prompt_value "VPS public IPv4 (blank to auto-detect)" "" no)"
  fi

  if [ "$configure_cloudflare" = "1" ]; then
    cloudflare_summary="create the tunnel DNS record in $cloudflare_zone"
    if [ "$sftpgo_webdav_access" = "https" ]; then
      cloudflare_summary="create tunnel + WebDAV DNS records in $cloudflare_zone"
    fi
  else
    cloudflare_summary="manual DNS setup"
    if [ "$sftpgo_webdav_access" = "https" ]; then
      cloudflare_summary="manual DNS for tunnel + WebDAV hostnames"
    fi
  fi

  wizard_header "3" "4" "Review installation"
  cat <<EOF

${BOLD}Ready to install:${RESET}
  Path:        Guided blank VPS install
  Domain:      $domain
  HTTPS:       Caddy automatic certificates on 443/tcp
  Agent:       http://127.0.0.1:$listen_port
  WireGuard:   51888/udp
  Firewall:    $([ "$configure_firewall" = "1" ] && printf 'enabled' || printf 'unchanged')
  ZNC:         $([ "$install_znc" = "1" ] && printf '10.88.0.1:%s through WireGuard' "$znc_port" || printf 'not installed')
  SFTPGo:      $([ "$install_sftpgo" = "1" ] && printf 'selected protocols below' || printf 'not installed')
$([ "$install_sftpgo" = "1" ] && printf '    SFTP:      %s\n    FTP:       %s\n    WebDAV:    %s\n' "$(sftpgo_access_label "$sftpgo_sftp_access" 2022)" "$(sftpgo_access_label "$sftpgo_ftp_access" 2121)" "$(sftpgo_access_label "$sftpgo_webdav_access" 10080 "$sftpgo_webdav_domain")")
$([ -n "$sftpgo_storage_cap_gb" ] && printf '  SFTP storage: %s GiB total cap\n' "$sftpgo_storage_cap_gb")
  Cloudflare:  $cloudflare_summary

EOF
  if ! confirm "Start install now" yes "Domain: $domain
HTTPS: automatic Caddy certificate
WireGuard: UDP 51888
Firewall: $([ "$configure_firewall" = "1" ] && printf 'managed by setup' || printf 'unchanged')
ZNC: $([ "$install_znc" = "1" ] && printf 'IRC %s and WebAdmin %s through WireGuard' "$znc_port" "$znc_web_port" || printf 'not installed')
SFTPGo: $([ "$install_sftpgo" = "1" ] && printf 'SFTP %s, FTP %s, WebDAV %s' "$sftpgo_sftp_access" "$sftpgo_ftp_access" "$sftpgo_webdav_access" || printf 'not installed')
WebAdmin: $([ "$install_sftpgo" = "1" ] && printf 'WireGuard-only at 10.88.0.1:8080' || printf 'not installed')"; then
    if [ "$CREATED_ADMIN_USER" = "1" ]; then
      print_relogin_instructions "$ADMIN_USER"
    fi
    return 0
  fi

  if [ "$configure_cloudflare" = "1" ]; then
    cloudflare_args=(
      "$SCRIPT_DIR/configure-cloudflare-dns.sh"
      --zone "$cloudflare_zone"
      --record "$domain"
    )
    if [ -n "$cloudflare_ipv4" ]; then
      cloudflare_args+=(--ipv4 "$cloudflare_ipv4")
    fi
    if [ "$sftpgo_webdav_access" = "https" ]; then
      cloudflare_args+=(--record "$sftpgo_webdav_domain")
    fi
    cloudflare_api_token="$(prompt_secret "Cloudflare API token

Required permissions: Zone Read and DNS Edit.
The token is used once and is not saved." yes)"
    show_cloudflare_progress \
      "Cloudflare DNS progress will appear below." \
      "$cloudflare_api_token" \
      "${cloudflare_args[@]}"
    cloudflare_api_token=""
  fi

  show_progress_handoff "Package/service progress will appear below." "${args[@]}"

  if [ "$install_znc" = "1" ]; then
    znc_args=("$SCRIPT_DIR/install-znc.sh" --user "$znc_user" --port "$znc_port" --web-listen-port "$znc_web_port")
    if [ "$znc_makeconf" = "1" ]; then
      znc_args+=(--makeconf)
    fi
    show_progress_handoff "ZNC install progress will appear below." "${znc_args[@]}"
    cat <<EOF

ZNC connection:
  Connect WireGuard first.
  IRC:      10.88.0.1:$znc_port
  WebAdmin: http://10.88.0.1:$znc_web_port/

EOF
  fi

  if [ "$install_sftpgo" = "1" ]; then
    sftpgo_args=(
      "$SCRIPT_DIR/install-sftpgo.sh"
      --sftp-access "$sftpgo_sftp_access"
      --ftp-access "$sftpgo_ftp_access"
      --webdav-access "$sftpgo_webdav_access"
    )
    if [ "$sftpgo_webdav_access" = "https" ]; then
      sftpgo_args+=(--webdav-domain "$sftpgo_webdav_domain")
    fi
    if [ "$sftpgo_insecure_public" = "1" ]; then
      sftpgo_args+=(--allow-insecure-public-protocols)
    fi
    if [ -n "$sftpgo_storage_cap_gb" ]; then
      sftpgo_args+=(--max-storage-gb "$sftpgo_storage_cap_gb")
    fi
    show_progress_handoff "SFTPGo install progress will appear below." "${sftpgo_args[@]}"
    verify_sftpgo_selection_applied \
      "$sftpgo_sftp_access" \
      "$sftpgo_ftp_access" \
      "$sftpgo_webdav_access" \
      "$sftpgo_webdav_domain"
    cat <<EOF

SFTPGo connection:
  SFTP: $(sftpgo_access_label "$sftpgo_sftp_access" 2022)
  FTP: $(sftpgo_access_label "$sftpgo_ftp_access" 2121)$([ "$sftpgo_ftp_access" != "disabled" ] && printf ' (passive 50000-50100)')
  WebDAV: $(sftpgo_access_label "$sftpgo_webdav_access" 10080 "$sftpgo_webdav_domain")
  WebAdmin: http://10.88.0.1:8080/web/admin

EOF
  fi

  final_pairing_code="$(cat /var/lib/tater-tunnel/pairing-code 2>/dev/null || true)"
  show_pairing_completion "$domain" "$final_pairing_code"
}

run_advanced_install() {
  local listen_host
  local listen_port
  local pairing_code
  local args
  local wireguard_management_access="0"

  CURRENT_DIALOG_TITLE="Advanced agent install"
  require_root_for_install
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Install agent only (advanced)${RESET}
This path installs only the Tater VPS Agent service.
It will not install Caddy and will not change firewall rules.

EOF

  listen_host="$(prompt_value "Local listen host" "127.0.0.1" yes)"
  listen_port="$(prompt_value "Local listen port" "4174" yes)"
  pairing_code="$(prompt_value "Pairing code (blank to generate)" "" no)"

  args=("$SCRIPT_DIR/install-vps-agent.sh" --listen-host "$listen_host" --listen-port "$listen_port")
  if [ -n "$pairing_code" ]; then
    args+=(--pairing-code "$pairing_code")
  fi
  if confirm "Allow the Home Agent to manage the VPS through WireGuard" yes; then
    args+=(--wireguard-management-access)
    wireguard_management_access="1"
  fi
  if ! confirm "Install OS packages if missing" yes; then
    args+=(--skip-packages)
  fi
  if ! confirm "Start/restart service after install" yes; then
    args+=(--no-start)
  fi

  clear_screen
  print_logo
  cat <<EOF

${BOLD}Ready to install:${RESET}
  Path:        Agent-only advanced install
  Agent:       http://$listen_host:$listen_port
  Caddy/HTTPS: unchanged
  Firewall:    unchanged
  Private WG:  $([ "$wireguard_management_access" = "1" ] && printf 'Home Agent management enabled' || printf 'not enabled')

After install, point your reverse proxy at http://$listen_host:$listen_port
and open 51888/udp for WireGuard devices.
$([ "$wireguard_management_access" = "1" ] && printf 'Allow TCP %s only from 10.88.0.2 on the tater0 interface.\n' "$listen_port")

EOF
  if ! confirm "Start install now" yes "Agent: http://$listen_host:$listen_port
Caddy and firewall: unchanged
WireGuard management: $([ "$wireguard_management_access" = "1" ] && printf 'enabled' || printf 'disabled')"; then
    return 0
  fi
  show_progress_handoff "Agent install progress will appear below." "${args[@]}"
}

run_znc_install() {
  local target_user
  local znc_port
  local znc_web_port="6698"
  local run_makeconf="0"
  local args

  CURRENT_DIALOG_TITLE="Install ZNC"
  handle_root_login_for_user_addon
  require_root_for_install
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Install ZNC${RESET}
This installs ZNC as a user-owned IRC bouncer. The config/data directory stays
in the user's home folder, for example /home/tater/.znc. Clients can reach it
only through Tater Tunnel WireGuard.

EOF

  while true; do
    target_user="$(prompt_value "Linux user to run ZNC" "$(default_sudo_user)" yes)"
    if ! valid_linux_username "$target_user"; then
      printf '%sUse a Linux username like tater, admin, or tunnel-admin.%s\n' "$RED" "$RESET" >&2
      continue
    fi
    if [ "$target_user" = "root" ]; then
      printf '%sZNC should not run as root. Choose a normal sudo user.%s\n' "$RED" "$RESET" >&2
      continue
    fi
    break
  done
  if ! id -u "$target_user" >/dev/null 2>&1; then
    if confirm "User $target_user does not exist. Create it as a sudo user" yes; then
      create_sudo_user "$target_user"
    else
      return 1
    fi
  fi

  znc_port="$(prompt_port "ZNC listener port" "6697")"
  if confirm "Run ZNC interactive config wizard now" yes; then
    run_makeconf="1"
  fi
  args=("$SCRIPT_DIR/install-znc.sh" --user "$target_user" --port "$znc_port" --web-listen-port "$znc_web_port")
  if [ "$run_makeconf" = "1" ]; then
    args+=(--makeconf)
  fi
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Ready to install ZNC:${RESET}
  User:        $target_user
  Config:      ~${target_user}/.znc
  Port:        $znc_port/tcp
  WebAdmin:    http://10.88.0.1:$znc_web_port/
  Make config: $([ "$run_makeconf" = "1" ] && printf 'run now' || printf 'print command for later')
  Access:      10.88.0.1:$znc_port through WireGuard only

EOF

  if ! confirm "Install ZNC now" yes "User: $target_user
IRC: 10.88.0.1:$znc_port
WebAdmin: http://10.88.0.1:$znc_web_port/
Public access: blocked"; then
    if [ "$CREATED_ADMIN_USER" = "1" ]; then
      print_relogin_instructions "$ADMIN_USER"
    fi
    return 0
  fi

  show_progress_handoff "ZNC install progress will appear below." "${args[@]}"
  remove_legacy_znc_web_proxy
  if [ "$CREATED_ADMIN_USER" = "1" ]; then
    print_relogin_instructions "$ADMIN_USER"
  fi
}

run_sftpgo_install() {
  local sftpgo_sftp_access="private"
  local sftpgo_ftp_access="disabled"
  local sftpgo_webdav_access="disabled"
  local sftpgo_webdav_domain=""
  local sftpgo_insecure_public="0"
  local tunnel_domain=""
  local storage_cap_gb=""
  local configure_cloudflare="0"
  local cloudflare_zone=""
  local cloudflare_ipv4=""
  local cloudflare_api_token=""
  local cloudflare_summary="not needed"
  local cloudflare_args
  local args

  CURRENT_DIALOG_TITLE="Install or update SFTPGo"
  require_root_for_install
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Install or update SFTPGo${RESET}
This installs the current open-source SFTPGo release and enables its systemd
service at boot. Running it again updates SFTPGo while preserving its existing
configuration, users, and files.

Choose SFTP, FTP, WebDAV, or any combination. SFTP and FTP can stay private or
be opened directly. External WebDAV uses a dedicated Caddy HTTPS subdomain.
WebAdmin always remains available only while connected through WireGuard.

EOF

  select_sftpgo_protocols
  tunnel_domain="$(installed_tater_domain)"
  choose_sftpgo_access "$tunnel_domain"
  if [ "$sftpgo_webdav_access" = "https" ]; then
    cloudflare_summary="manual DNS-only A record"
    if confirm "Create or update the WebDAV DNS record with a Cloudflare API token" no \
      "This creates a DNS-only A record pointing $sftpgo_webdav_domain to this VPS.\nThe token is used once and is not saved. Choose No if DNS is hosted elsewhere."; then
      configure_cloudflare="1"
      cloudflare_zone="$(prompt_value "Cloudflare zone" "$(guess_dns_zone "$sftpgo_webdav_domain")" yes)"
      cloudflare_ipv4="$(prompt_value "VPS public IPv4 (blank to auto-detect)" "" no)"
      cloudflare_summary="create DNS-only $sftpgo_webdav_domain in $cloudflare_zone"
    fi
  fi
  if confirm "Set a total cap for SFTPGo's default local storage" yes; then
    storage_cap_gb="$(prompt_positive_integer "Maximum SFTPGo storage in GiB" "$(suggest_sftpgo_storage_gb)")"
  fi

  args=(
    "$SCRIPT_DIR/install-sftpgo.sh"
    --sftp-access "$sftpgo_sftp_access"
    --ftp-access "$sftpgo_ftp_access"
    --webdav-access "$sftpgo_webdav_access"
  )
  if [ "$sftpgo_webdav_access" = "https" ]; then
    args+=(--webdav-domain "$sftpgo_webdav_domain")
  fi
  if [ "$sftpgo_insecure_public" = "1" ]; then
    args+=(--allow-insecure-public-protocols)
  fi
  if [ -n "$storage_cap_gb" ]; then
    args+=(--max-storage-gb "$storage_cap_gb")
  fi

  clear_screen
  print_logo
  cat <<EOF

${BOLD}Ready to install or update SFTPGo:${RESET}
  Edition:     Open source (current stable release)
  Service:     enabled at boot
  SFTP:        $(sftpgo_access_label "$sftpgo_sftp_access" 2022)
  FTP:         $(sftpgo_access_label "$sftpgo_ftp_access" 2121)$([ "$sftpgo_ftp_access" != "disabled" ] && printf ' plus passive TCP 50000-50100')
  WebDAV:      $(sftpgo_access_label "$sftpgo_webdav_access" 10080 "$sftpgo_webdav_domain")
  WebAdmin:    http://10.88.0.1:8080/web/admin (WireGuard only)
  Firewall:    matched to each selected access mode; disabled ports are blocked
  Login:       connect WireGuard, create the first admin, then enable TOTP
  Hardening:   defender enabled, strong passwords, exact version hidden
  Storage:     $([ -n "$storage_cap_gb" ] && printf '%s GiB total cap' "$storage_cap_gb" || printf 'no installer-managed total cap')
  Cloudflare:  $cloudflare_summary

EOF

  if ! confirm "Install or update SFTPGo now" yes "SFTP: $(sftpgo_access_label "$sftpgo_sftp_access" 2022)
FTP: $(sftpgo_access_label "$sftpgo_ftp_access" 2121)
WebDAV: $(sftpgo_access_label "$sftpgo_webdav_access" 10080 "$sftpgo_webdav_domain")
WebAdmin: http://10.88.0.1:8080/web/admin
WebAdmin public access: blocked
Cloudflare DNS: $cloudflare_summary
Storage cap: $([ -n "$storage_cap_gb" ] && printf '%s GiB' "$storage_cap_gb" || printf 'not installer-managed')"; then
    return 0
  fi

  if [ "$configure_cloudflare" = "1" ]; then
    cloudflare_args=(
      "$SCRIPT_DIR/configure-cloudflare-dns.sh"
      --zone "$cloudflare_zone"
      --record "$sftpgo_webdav_domain"
    )
    if [ -n "$cloudflare_ipv4" ]; then
      cloudflare_args+=(--ipv4 "$cloudflare_ipv4")
    fi
    cloudflare_api_token="$(prompt_secret "Cloudflare API token

Required permissions: Zone Read and DNS Edit.
The token is used once and is not saved." yes)"
    show_cloudflare_progress \
      "Cloudflare DNS progress will appear below." \
      "$cloudflare_api_token" \
      "${cloudflare_args[@]}"
    cloudflare_api_token=""
  fi

  show_progress_handoff "SFTPGo install progress will appear below." "${args[@]}"
  verify_sftpgo_selection_applied \
    "$sftpgo_sftp_access" \
    "$sftpgo_ftp_access" \
    "$sftpgo_webdav_access" \
    "$sftpgo_webdav_domain"
  if [ "$DIALOG_ENABLED" = "1" ]; then
    dialog_message "SFTPGo ready" "Applied configuration

SFTP: $(sftpgo_access_label "$sftpgo_sftp_access" 2022)
FTP: $(sftpgo_access_label "$sftpgo_ftp_access" 2121)
WebDAV: $(sftpgo_access_label "$sftpgo_webdav_access" 10080 "$sftpgo_webdav_domain")

SFTPGo restarted successfully and every selected listener was verified."
  fi
}

run_uninstall() {
  local args
  local purge_data="0"
  local remove_source="0"
  local remove_ufw_rules="1"
  local disable_caddy_proxy="0"

  CURRENT_DIALOG_TITLE="Uninstall Tater Tunnel"
  require_root_for_install
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Uninstall Tater Tunnel${RESET}
This removes the Tater Tunnel VPS Agent service and installed app files.
It keeps pairing/device state and WireGuard config unless you choose to purge.

EOF

  if confirm "Purge pairing/device state and WireGuard config" no; then
    purge_data="1"
  fi
  if confirm "Remove downloaded setup source at $SOURCE_DIR" no; then
    remove_source="1"
  fi
  if ! confirm "Remove Tater WireGuard UFW rules" yes; then
    remove_ufw_rules="0"
  fi
  if confirm "Disable Caddy proxy if it points to Tater Tunnel" no; then
    disable_caddy_proxy="1"
  fi

  args=("$SCRIPT_DIR/uninstall-vps.sh" --yes)
  if [ "$purge_data" = "1" ]; then
    args+=(--purge-data)
  fi
  if [ "$remove_source" = "1" ]; then
    args+=(--remove-source)
  fi
  if [ "$remove_ufw_rules" != "1" ]; then
    args+=(--keep-ufw-rules)
  fi
  if [ "$disable_caddy_proxy" = "1" ]; then
    args+=(--disable-caddy-proxy)
  fi

  clear_screen
  print_logo
  cat <<EOF

${BOLD}Ready to uninstall:${RESET}
  Service/app:  removed
  State/config: $([ "$purge_data" = "1" ] && printf 'purged' || printf 'kept')
  Source dir:   $([ "$remove_source" = "1" ] && printf 'removed' || printf 'kept')
  UFW rules:    $([ "$remove_ufw_rules" = "1" ] && printf 'Tater WireGuard rules removed' || printf 'unchanged')
  Caddy proxy:  $([ "$disable_caddy_proxy" = "1" ] && printf 'disabled if it points to Tater' || printf 'unchanged')

Shared packages like Python, Caddy, UFW, and WireGuard tools will not be
uninstalled automatically.

EOF

  if ! confirm "Uninstall now" no "Service and app: removed
State and config: $([ "$purge_data" = "1" ] && printf 'purged' || printf 'kept')
Downloaded source: $([ "$remove_source" = "1" ] && printf 'removed' || printf 'kept')
Firewall: $([ "$remove_ufw_rules" = "1" ] && printf 'Tater rules removed' || printf 'unchanged')"; then
    return 0
  fi

  show_progress_handoff "Uninstall progress will appear below." "${args[@]}"
}

run_security_audit() {
  local exec_start
  local listen_host="127.0.0.1"
  local listen_port="4174"
  local state_file="/var/lib/tater-tunnel/vps-agent.json"
  local config_file="/etc/tater-tunnel/wireguard/tater0.conf"
  local state_dir="/var/lib/tater-tunnel"
  local config_dir="/etc/tater-tunnel"
  local domain
  local args
  local wg_management_access="0"

  CURRENT_DIALOG_TITLE="VPS security audit"
  clear_screen
  print_logo
  printf '\n%sVPS security audit%s\n\n' "$BOLD" "$RESET"

  if [ -f "$SERVICE_FILE" ]; then
    exec_start="$(service_value "ExecStart")"
    listen_host="$(service_arg "$exec_start" "--host" "$listen_host")"
    listen_port="$(service_arg "$exec_start" "--port" "$listen_port")"
    state_file="$(service_arg "$exec_start" "--state-file" "$state_file")"
    config_file="$(service_arg "$exec_start" "--wireguard-config" "$config_file")"
    state_dir="$(dirname "$state_file")"
    config_dir="$(dirname "$(dirname "$config_file")")"
  fi

  if [ "$listen_host" = "0.0.0.0" ]; then
    wg_management_access="1"
  fi

  if confirm "Repair Tater-managed security rules before auditing" yes \
    "This reapplies the private Caddy, UFW, SFTPGo, and ZNC boundaries from the current installed settings.\nPairing, devices, service users, and stored files are preserved."; then
    show_progress_handoff \
      "Security repair progress will appear below." \
      apply_update_hardening "$listen_port" "$wg_management_access"
  fi

  domain="$(prompt_value "Public Tater hostname (blank skips HTTPS test)" "" no)"
  args=(
    "$SCRIPT_DIR/audit-vps-security.sh"
    --listen-port "$listen_port"
    --state-dir "$state_dir"
    --config-dir "$config_dir"
  )
  if [ -n "$domain" ]; then
    args+=(--domain "$domain")
  fi

  if [ "$DIALOG_ENABLED" = "1" ]; then
    show_progress_handoff "VPS security audit" "${args[@]}" || true
  else
    printf '\n'
    if ! "${args[@]}"; then
      printf '\n%sOne or more required security checks failed.%s\n' "$RED$BOLD" "$RESET"
    fi
    pause
  fi
}

view_notes() {
  if [ "$DIALOG_ENABLED" = "1" ]; then
    set_dialog_dimensions
    dialog --clear \
      --backtitle "Tater Tunnel // VPS Setup Console" \
      --title "VPS setup notes" \
      --textbox "$DOC_FILE" "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
    return
  fi
  clear_screen
  print_logo
  printf '\n'
  if command -v less >/dev/null 2>&1 && [ -t 0 ]; then
    less "$DOC_FILE"
  else
    cat "$DOC_FILE"
  fi
  pause
}

run_menu_action() {
  local status

  # Keep errexit active inside the action while preventing one failed action
  # from closing the setup console itself.
  set +e
  (
    set -e
    "$@"
  )
  status="$?"
  set -e

  if [ "$status" != "0" ] && [ "$status" != "130" ] && [ "$DIALOG_ENABLED" != "1" ]; then
    printf '\n%sAction stopped with exit code %s. Returning to the main menu.%s\n' \
      "$RED$BOLD" "$status" "$RESET" >&2
    pause
  fi
  return 0
}

main() {
  local selected

  parse_args "$@"
  bootstrap_source_if_needed
  enable_dialog_ui

  if [ "$NO_RUN" = "1" ]; then
    printf '%sSetup menu is ready at:%s %s\n' "$GREEN" "$RESET" "$SCRIPT_DIR/tater-vps-setup.sh"
    exit 0
  fi

  while true; do
    set +e
    choose_menu
    selected="$?"
    set -e
    case "$selected" in
      0) run_menu_action run_update_install ;;
      1) run_menu_action run_full_install ;;
      2) run_menu_action run_advanced_install ;;
      3) run_menu_action run_znc_install ;;
      4) run_menu_action run_sftpgo_install ;;
      5) run_menu_action run_security_audit ;;
      6) run_menu_action run_uninstall ;;
      7) view_notes ;;
      8)
        clear_screen
        print_logo
        printf '\n%sSetup console closed.%s\n' "$DIM" "$RESET"
        exit 0
        ;;
    esac
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
