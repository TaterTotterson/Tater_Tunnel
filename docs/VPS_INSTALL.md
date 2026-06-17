# Tater Tunnel VPS Install

Tater Tunnel has two VPS setup paths.

## Recommended Interactive Setup

For users, the intended VPS flow is one command over SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh
```

To test a branch or fork, pass the repo explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && \
  sudo bash /tmp/tater-vps-setup.sh --repo https://github.com/TaterTotterson/Tater_Tunnel.git
```

The script downloads or updates Tater Tunnel when needed, then starts the menu
launcher from the downloaded source.

Use the same command for updates after Tater Tunnel is already installed. Pick
`Update existing install` in the menu. That path updates the app files, preserves
the existing pairing/state directory, keeps the current systemd host and port,
and restarts `tater-tunnel-vps`.

Pipe form, if preferred:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  | sudo bash
```

The downloaded temp-file form above is preferred for interactive terminals.

If the repo is already on the VPS, run the menu directly:

```bash
sudo ./scripts/tater-vps-setup.sh
```

Use the arrow keys to select:

- `Update existing install`
- `Blank VPS full install`
- `Advanced existing VPS install`
- `View setup notes`

The menu asks for the needed values, shows a setup summary, and then runs the
matching installer while the package and service progress prints below.

Download/update options:

```bash
sudo ./scripts/tater-vps-setup.sh --repo https://github.com/TaterTotterson/Tater_Tunnel.git
sudo ./scripts/tater-vps-setup.sh --branch main
sudo ./scripts/tater-vps-setup.sh --tarball https://example.com/tater-tunnel.tar.gz
sudo ./scripts/tater-vps-setup.sh --source-dir /opt/tater-tunnel-src
```

For repo testing with an explicit source URL, use:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && \
  sudo bash /tmp/tater-vps-setup.sh --repo https://github.com/TaterTotterson/Tater_Tunnel.git
```

## Blank VPS Full Install

Use this on a fresh Debian or Ubuntu VPS where Tater Tunnel can own the web
front door.

Requirements:

- A DNS `A` record pointed at the VPS, for example `tunnel.example.com`.
- Public ports `80/tcp`, `443/tcp`, and `51888/udp` available.
- `sudo` access over SSH.

Run from the repo on the VPS:

```bash
sudo ./scripts/install-vps-full.sh --domain tunnel.example.com
```

Optional ACME email:

```bash
sudo ./scripts/install-vps-full.sh \
  --domain tunnel.example.com \
  --email admin@example.com
```

The full installer:

- Installs the VPS Agent as `tater-tunnel-vps`.
- Runs the VPS Agent for localhost/Caddy and WireGuard clients.
- Installs Caddy as the public HTTPS reverse proxy.
- Writes a Caddy route from `https://tunnel.example.com` to `127.0.0.1:4174`.
- Opens `80/tcp`, `443/tcp`, `51888/udp`, and the configured SSH port in UFW.
- Allows `4174/tcp` only from the WireGuard interface for VPN clients.
- Keeps `4174/tcp` closed on the public internet.

Pair the Home Agent with:

```text
VPS IP or Domain: https://tunnel.example.com
Pairing Code: shown by the installer
```

After a phone connects to the WireGuard profile, the local Tater app relay is:

```text
http://10.88.0.1:4174/relay/
```

For example, the Home Agent API state route is:

```text
http://10.88.0.1:4174/relay/api/state
```

By default, `/relay/` points at the Home Agent / Tunnel UI. To add the main
Tater app as a named route, start the Home Agent with a route for the app's
local URL:

```bash
python3.11 -m tater_tunnel.home_agent \
  --host 0.0.0.0 \
  --port 4173 \
  --relay-target http://127.0.0.1:4173 \
  --relay-route tater=http://127.0.0.1:8000
```

Then from the phone on WireGuard:

```text
http://10.88.0.1:4174/relay/tater/
```

Replace `8000` with the actual local port for the main Tater app.

## Advanced Existing VPS Install

Use this when the VPS already has Webmin, Nginx, Caddy, Apache, or another
public web stack that Tater Tunnel should not modify.

```bash
sudo ./scripts/install-vps-agent.sh
```

The advanced installer:

- Installs only the VPS Agent service.
- Runs it on `127.0.0.1:4174`.
- Creates a pairing code.
- Does not install Caddy.
- Does not change firewall rules.

You must provide:

- HTTPS reverse proxy to `http://127.0.0.1:4174`.
- UDP `51888` open for WireGuard devices.
- TCP `4174` kept private unless doing a short direct test.

If you choose WireGuard relay access in the menu, the agent will listen for VPN
clients too. In that case, allow TCP `4174` from the `tater0` interface only,
not from the public internet.

Example Caddy route for an existing Caddy setup:

```caddyfile
tunnel.example.com {
  reverse_proxy 127.0.0.1:4174
}
```

Then pair the Home Agent with:

```text
VPS IP or Domain: https://tunnel.example.com
Pairing Code: sudo cat /var/lib/tater-tunnel/pairing-code
```

## Service Commands

```bash
sudo systemctl status tater-tunnel-vps
sudo journalctl -u tater-tunnel-vps -f
sudo systemctl restart tater-tunnel-vps
```

If the VPS is already claimed but you need to pair a fresh Home Agent, reopen
pairing without resetting approved device peers:

```bash
cd /opt/tater-tunnel
sudo -u tater-tunnel python3 -B -m tater_tunnel.vps_agent \
  --state-file /var/lib/tater-tunnel/vps-agent.json \
  --pairing-code-file /var/lib/tater-tunnel/pairing-code \
  --reopen-pairing
```

The running service will pick up the reopened pairing state on the next request.
The guided setup script's `Update existing install` path can do the same thing
by answering `yes` to `Reopen pairing after update`.

For full installs:

```bash
sudo systemctl status caddy
curl -fsS https://tunnel.example.com/api/health
```

For WireGuard live status:

```bash
sudo wg show tater0
```
