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

if [ -f "$SCRIPT_DIR/install-vps-full.sh" ] && [ -f "$SCRIPT_DIR/install-vps-agent.sh" ] && [ -f "$SCRIPT_DIR/uninstall-vps.sh" ] && [ -f "$SCRIPT_DIR/install-znc.sh" ]; then
  IN_REPO_SOURCE="1"
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RESET="$(printf '\033[0m')"
  BOLD="$(printf '\033[1m')"
  DIM="$(printf '\033[2m')"
  ORANGE="$(printf '\033[38;5;208m')"
  GREEN="$(printf '\033[38;5;113m')"
  CYAN="$(printf '\033[38;5;45m')"
  RED="$(printf '\033[38;5;203m')"
else
  RESET=""
  BOLD=""
  DIM=""
  ORANGE=""
  GREEN=""
  CYAN=""
  RED=""
fi

MENU_ITEMS=(
  "Update existing install"
  "Blank VPS full install"
  "Advanced existing VPS install"
  "Optional ZNC install"
  "Uninstall VPS install"
  "View setup notes"
  "Exit"
)

MENU_HELP=(
  "Updates code, preserves pairing/state/service settings, and restarts the VPS Agent."
  "Installs Tater VPS Agent, Caddy automatic HTTPS, WireGuard, and UFW rules."
  "Installs only the Tater VPS Agent. You manage HTTPS, firewall, and proxy."
  "Installs ZNC for the sudo user with config stored in that user's home."
  "Removes the VPS Agent and app files, with optional state/config purge."
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
    -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh

Fresh VPS root login:
  curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
    -o /tmp/tater-vps-setup.sh && bash /tmp/tater-vps-setup.sh

The root-login flow creates a sudo user first, prints SSH key hardening steps,
and asks you to reconnect as that user before installing Tater Tunnel.

This interactive launcher provides:
  - Source download/update when launched standalone
  - First-run sudo user creation when launched from a root login
  - Safe update path for existing installs
  - Arrow-key setup menu
  - Blank VPS full install path
  - Advanced existing VPS install path
  - Optional ZNC install path
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

print_logo() {
  printf '%s+------------------------------------------------------------+%s\n' "$ORANGE$BOLD" "$RESET"
  printf '%s|%s %-58s %s|%s\n' "$ORANGE$BOLD" "$RESET$BOLD" "Tater Tunnel VPS Setup" "$RESET$ORANGE$BOLD" "$RESET"
  printf '%s|%s %-58s %s|%s\n' "$ORANGE$BOLD" "$RESET$DIM" "Secure relay + WireGuard device VPN" "$RESET$ORANGE$BOLD" "$RESET"
  printf '%s+------------------------------------------------------------+%s\n' "$ORANGE$BOLD" "$RESET"
}

pause() {
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
  local home_dir
  local primary_group

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

  home_dir="$(getent passwd "$username" | awk -F: '{ print $6 }')"
  home_dir="${home_dir:-/home/$username}"
  primary_group="$(id -gn "$username")"

  if [ -s /root/.ssh/authorized_keys ]; then
    if confirm "Copy root SSH authorized_keys to $username" yes; then
      install -d -m 0700 -o "$username" -g "$primary_group" "$home_dir/.ssh"
      install -m 0600 -o "$username" -g "$primary_group" /root/.ssh/authorized_keys "$home_dir/.ssh/authorized_keys"
    fi
  fi
}

print_relogin_instructions() {
  local username="$1"
  local host_hint

  host_hint="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
  host_hint="${host_hint:-your.vps.ip.or.domain}"

  cat <<EOF

${GREEN}${BOLD}Sudo user is ready.${RESET}

Stop here, open a terminal on your PC, and log back in as the new user before
installing Tater Tunnel:

  VPS_HOST=$host_hint
  ssh $username@\$VPS_HOST

If you do not already use an SSH key for this VPS, run these from your PC:

  ssh-keygen -t ed25519 -C "tater-tunnel-vps"
  ssh-copy-id -i ~/.ssh/id_ed25519.pub $username@\$VPS_HOST
  ssh $username@\$VPS_HOST

Then rerun the Tater Tunnel setup as the sudo user:

  curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \\
    -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh

After you confirm key-based login works, you can harden SSH with:

  sudo install -d -m 0755 /etc/ssh/sshd_config.d
  printf '%s\\n' 'PubkeyAuthentication yes' 'PasswordAuthentication no' 'PermitRootLogin no' | sudo tee /etc/ssh/sshd_config.d/99-tater-hardening.conf
  sudo sshd -t
  sudo systemctl reload ssh || sudo systemctl reload sshd

Keep the current root SSH session open until you have tested a second login as
$username. That avoids locking yourself out.
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

This setup can create the user, add it to the sudo group, optionally copy your
root SSH keys, and then stop so you can reconnect as the new user.

EOF

  if ! confirm "Create a sudo user before installing Tater Tunnel" yes; then
    cat <<EOF

No install was started. Reconnect as a non-root sudo user, then rerun setup:

  curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \\
    -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh
EOF
    exit 1
  fi

  username="$(prompt_sudo_username)"
  create_sudo_user "$username"
  print_relogin_instructions "$username"
  exit 0
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

This setup can create the sudo user, optionally copy root SSH keys, and then
stop so you can reconnect as that user before installing ZNC.

EOF

  if ! confirm "Create a sudo user before installing ZNC" yes; then
    cat <<EOF

No ZNC install was started. Reconnect as a non-root sudo user, then rerun setup:

  curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \\
    -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh
EOF
    exit 1
  fi

  username="$(prompt_sudo_username)"
  create_sudo_user "$username"
  print_relogin_instructions "$username"
  exit 0
}

require_bootstrap_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if [ -n "$TARBALL_URL" ]; then
      apt-get install -y ca-certificates curl tar
    else
      apt-get install -y ca-certificates git
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
  install -d -m 0755 "$(dirname "$SOURCE_DIR")"

  if [ -d "$SOURCE_DIR/.git" ]; then
    git -C "$SOURCE_DIR" remote set-url origin "$REPO_URL"
    git -C "$SOURCE_DIR" fetch --depth 1 origin "$BRANCH"
    git -C "$SOURCE_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
  elif [ -e "$SOURCE_DIR" ]; then
    local backup_dir
    backup_dir="$SOURCE_DIR.backup.$(date +%Y%m%d%H%M%S)"
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
    if [ -n "$default_value" ]; then
      printf '%s%s%s [%s]: ' "$BOLD" "$label" "$RESET" "$default_value" >&2
    else
      printf '%s%s%s: ' "$BOLD" "$label" "$RESET" >&2
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

confirm() {
  local label="$1"
  local default="${2:-yes}"
  local hint="[Y/n]"
  local reply

  if [ "$default" = "no" ]; then
    hint="[y/N]"
  fi

  while true; do
    printf '%s%s%s %s: ' "$BOLD" "$label" "$RESET" "$hint" >&2
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
  shift

  clear_screen
  print_logo
  print_stage "1" "3" "Validated setup choices"
  print_stage "2" "3" "Running selected action"
  printf '%s%s%s\n' "$DIM" "$title" "$RESET"
  print_stage "3" "3" "Installer output"
  "$@"
}

service_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$SERVICE_FILE" 2>/dev/null || true
}

service_arg() {
  local line="$1"
  local flag="$2"
  local default_value="$3"

  set -- $line
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
  local number

  clear_screen
  print_logo
  printf '\n%sUse Up/Down arrows, Enter to select, q to quit.%s\n' "$DIM" "$RESET"
  printf '%sCurrent source:%s %s\n\n' "$DIM" "$RESET" "$SCRIPT_DIR"

  for index in "${!MENU_ITEMS[@]}"; do
    number="$(printf '%02d' "$((index + 1))")"
    if [ "$index" -eq "$selected" ]; then
      printf '  %s> [%s] %-31s%s\n' "$GREEN$BOLD" "$number" "${MENU_ITEMS[$index]}" "$RESET"
      printf '       %s%s%s\n' "$DIM" "${MENU_HELP[$index]}" "$RESET"
    else
      printf '    [%s] %s\n' "$number" "${MENU_ITEMS[$index]}"
    fi
  done
}

interactive_menu() {
  local selected=0
  local key

  while true; do
    render_menu "$selected"
    IFS= read -rsn1 key || exit 0
    if [ "$key" = $'\x1b' ]; then
      IFS= read -rsn2 -t 0.2 key || true
      case "$key" in
        "[A")
          selected=$(( (selected + ${#MENU_ITEMS[@]} - 1) % ${#MENU_ITEMS[@]} ))
          ;;
        "[B")
          selected=$(( (selected + 1) % ${#MENU_ITEMS[@]} ))
          ;;
      esac
    elif [ -z "$key" ]; then
      return "$selected"
    elif [ "$key" = "q" ] || [ "$key" = "Q" ]; then
      return "$((${#MENU_ITEMS[@]} - 1))"
    fi
  done
}

numbered_menu() {
  local choice
  local index

  clear_screen
  print_logo
  printf '\n'
  for index in "${!MENU_ITEMS[@]}"; do
    printf '  %s. %s\n' "$((index + 1))" "${MENU_ITEMS[$index]}"
    printf '     %s%s%s\n' "$DIM" "${MENU_HELP[$index]}" "$RESET"
  done

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

choose_menu() {
  if [ -t 0 ]; then
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
  local wg_relay_access="0"

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
    wg_relay_access="1"
  fi

  cat <<EOF

${BOLD}Update existing install${RESET}
This updates the app files and systemd unit while preserving:
  - VPS pairing state in $state_dir
  - WireGuard config in $config_dir
  - Existing bind host/port from systemd

Detected:
  Install dir:  $install_dir
  Agent:        http://$listen_host:$listen_port
  WG relay:     $([ "$wg_relay_access" = "1" ] && printf 'enabled' || printf 'localhost/proxy only')

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

  if [ "$wg_relay_access" = "1" ]; then
    args+=(--wireguard-client-access)
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

  if ! confirm "Start update now" yes; then
    return 0
  fi

  show_progress_handoff "Update progress will appear below." "${args[@]}"
}

run_full_install() {
  local domain
  local email
  local ssh_port
  local listen_port
  local pairing_code
  local args

  handle_root_login_for_blank_vps
  require_root_for_install
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Blank VPS full install${RESET}
This path installs Tater Tunnel, Caddy automatic HTTPS, WireGuard, and UFW.
Caddy will route HTTPS traffic to the local Tater service on 127.0.0.1.

EOF

  domain="$(prompt_value "Domain pointed at this VPS" "" yes)"
  email="$(prompt_value "ACME email (blank is ok)" "" no)"
  ssh_port="$(prompt_value "SSH port to keep open" "22" yes)"
  listen_port="$(prompt_value "Local Tater VPS Agent port" "4174" yes)"
  pairing_code="$(prompt_value "Pairing code (blank to generate)" "" no)"

  args=("$SCRIPT_DIR/install-vps-full.sh" --domain "$domain" --ssh-port "$ssh_port" --listen-port "$listen_port")
  if [ -n "$email" ]; then
    args+=(--email "$email")
  fi
  if [ -n "$pairing_code" ]; then
    args+=(--pairing-code "$pairing_code")
  fi
  if ! confirm "Configure UFW firewall for 80/tcp, 443/tcp, 51888/udp, and SSH" yes; then
    args+=(--no-firewall)
  fi

  clear_screen
  print_logo
  cat <<EOF

${BOLD}Ready to install:${RESET}
  Path:        Blank VPS full install
  Domain:      $domain
  HTTPS:       Caddy automatic certificates on 443/tcp
  Agent:       http://127.0.0.1:$listen_port
  WireGuard:   51888/udp
  Firewall:    $([ "${args[*]}" = "${args[*]//--no-firewall/}" ] && printf 'enabled' || printf 'unchanged')

EOF
  if ! confirm "Start install now" yes; then
    return 0
  fi
  show_progress_handoff "Package/service progress will appear below." "${args[@]}"
}

run_advanced_install() {
  local listen_host
  local listen_port
  local pairing_code
  local args
  local wireguard_relay_access="0"

  require_root_for_install
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Advanced existing VPS install${RESET}
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
  if confirm "Allow WireGuard devices to reach /relay on 10.88.0.1:$listen_port" no; then
    args+=(--wireguard-client-access)
    wireguard_relay_access="1"
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
  Path:        Advanced existing VPS install
  Agent:       http://$listen_host:$listen_port
  Caddy/HTTPS: unchanged
  Firewall:    unchanged
  WG relay:    $([ "$wireguard_relay_access" = "1" ] && printf 'agent listens for VPN clients' || printf 'not enabled')

After install, point your reverse proxy at http://$listen_host:$listen_port
and open 51888/udp for WireGuard devices.
$([ "$wireguard_relay_access" = "1" ] && printf 'Also allow TCP %s only from the tater0 interface.\n' "$listen_port")

EOF
  if ! confirm "Start install now" yes; then
    return 0
  fi
  show_progress_handoff "Agent install progress will appear below." "${args[@]}"
}

run_znc_install() {
  local target_user
  local znc_port
  local run_makeconf="0"
  local open_firewall="0"
  local args

  handle_root_login_for_user_addon
  require_root_for_install
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Optional ZNC install${RESET}
This installs ZNC as a user-owned IRC bouncer. The config/data directory stays
in the user's home folder, for example /home/tater/.znc.

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
  if confirm "Open $znc_port/tcp in UFW for ZNC clients" no; then
    open_firewall="1"
  fi

  args=("$SCRIPT_DIR/install-znc.sh" --user "$target_user" --port "$znc_port")
  if [ "$run_makeconf" = "1" ]; then
    args+=(--makeconf)
  fi
  if [ "$open_firewall" = "1" ]; then
    args+=(--open-firewall)
  fi

  clear_screen
  print_logo
  cat <<EOF

${BOLD}Ready to install ZNC:${RESET}
  User:        $target_user
  Config:      ~${target_user}/.znc
  Port:        $znc_port/tcp
  Make config: $([ "$run_makeconf" = "1" ] && printf 'run now' || printf 'print command for later')
  Firewall:    $([ "$open_firewall" = "1" ] && printf 'open %s/tcp' "$znc_port" || printf 'unchanged')

EOF

  if ! confirm "Install ZNC now" yes; then
    return 0
  fi

  show_progress_handoff "ZNC install progress will appear below." "${args[@]}"
}

run_uninstall() {
  local args
  local purge_data="0"
  local remove_source="0"
  local remove_ufw_rules="1"
  local disable_caddy_proxy="0"

  require_root_for_install
  clear_screen
  print_logo
  cat <<EOF

${BOLD}Uninstall VPS install${RESET}
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

  if ! confirm "Uninstall now" no; then
    return 0
  fi

  show_progress_handoff "Uninstall progress will appear below." "${args[@]}"
}

view_notes() {
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

main() {
  local selected

  parse_args "$@"
  bootstrap_source_if_needed

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
      0)
        run_update_install
        exit 0
        ;;
      1)
        run_full_install
        exit 0
        ;;
      2)
        run_advanced_install
        exit 0
        ;;
      3)
        run_znc_install
        exit 0
        ;;
      4)
        run_uninstall
        exit 0
        ;;
      5) view_notes ;;
      6)
        clear_screen
        print_logo
        printf '\n%sNo changes made.%s\n' "$DIM" "$RESET"
        exit 0
        ;;
    esac
  done
}

main "$@"
