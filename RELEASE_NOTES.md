# Tater Tunnel v0.3.0

This release turns the Home Agent into a private control center for the tunnel,
its VPS, connected devices, services, and optional apps.

## Control Center

- A redesigned dashboard shows tunnel health, VPS CPU, memory, storage,
  uptime, connected devices, service routes, and installed apps at a glance.
- SFTPGo and ZNC can be installed, configured, updated, restarted, or removed
  from guided app-management screens.
- SFTPGo controls cover SFTP, FTP, WebDAV, public or WireGuard-only access,
  storage limits, WebDAV HTTPS, and optional Cloudflare DNS setup.
- ZNC controls cover private IRC and WebAdmin listeners, administrator setup,
  service health, and WireGuard connection details.
- Installed apps show their private WireGuard addresses with one-click copy
  controls.
- Devices, service routes, software updates, and security checks now live in
  dedicated views with clearer status and actions.

## Secure Management

- VPS administration uses a new root-owned, allowlisted control helper over a
  local Unix socket; the unprivileged VPS Agent cannot execute arbitrary shell
  commands.
- Control requests continue through the private Home Agent WireGuard path and
  require the existing management token.
- The Home Agent accepts control operations only from the local machine, even
  when its web interface listens on a LAN address.
- App changes run as tracked jobs with bounded actions, concise logs, and no
  submitted secrets retained in job history.
- Cloudflare tokens are passed only to the requested operation, while temporary
  ZNC credentials use short-lived root-only files.

## Setup

- New VPS installs include and start the control helper automatically.
- Existing installations can gain Control Center management by running the VPS
  installer update path once.
- Uninstall now removes the helper service and its managed runtime files.
