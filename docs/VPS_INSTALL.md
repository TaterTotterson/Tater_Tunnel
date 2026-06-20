# Tater Tunnel VPS Install

Tater Tunnel has two VPS setup paths.

## Recommended Interactive Setup

For users, the intended VPS flow is one command over SSH.

If you are already logged in as a normal sudo user:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh
```

If this is a brand-new VPS and you are logged in directly as `root`, run the
setup without `sudo` first:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && bash /tmp/tater-vps-setup.sh
```

When you choose `Blank VPS full install` from a root login, the setup pauses the
Tater install and offers to create a real sudo user first. It can copy root SSH
keys to the new account, then prints PC-side commands like:

```bash
VPS_HOST=your.vps.ip.or.domain
ssh-keygen -t ed25519 -C "tater-tunnel-vps"
ssh-copy-id -i ~/.ssh/id_ed25519.pub tater@$VPS_HOST
ssh tater@$VPS_HOST
```

After key login works, reconnect as the sudo user and rerun:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh
```

Then harden SSH from the new sudo session:

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
printf '%s\n' 'PubkeyAuthentication yes' 'PasswordAuthentication no' 'PermitRootLogin no' | sudo tee /etc/ssh/sshd_config.d/99-tater-hardening.conf
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl reload sshd
```

Keep the root session open until you have tested a second login as the new sudo
user, so you do not lock yourself out.

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
- `Optional ZNC install`
- `Uninstall VPS install`
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

## Optional ZNC Install

The guided menu can install ZNC as an optional user-owned IRC bouncer. Choose
`Optional ZNC install`.

The installer:

- Installs the Debian/Ubuntu `znc` package.
- Runs ZNC as the selected sudo user, not as root.
- Keeps ZNC config/data in that user's home folder, for example
  `/home/tater/.znc`.
- Writes a systemd service named `znc-USER.service`.
- Can run ZNC's interactive `--makeconf` wizard immediately.
- Can optionally open the selected TCP port in UFW.

Direct command:

```bash
sudo ./scripts/install-znc.sh --user tater --makeconf
```

If you skip the interactive config wizard during install, finish later with:

```bash
sudo -iu tater znc --makeconf --datadir /home/tater/.znc
sudo systemctl enable --now znc-tater
```

Replace `tater` with the sudo user that should own the ZNC config.

## Uninstall

Use the guided menu and choose `Uninstall VPS install`:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh
```

The uninstall path removes:

- `tater-tunnel-vps` systemd service.
- Installed app files in `/opt/tater-tunnel`.
- Live `tater0` WireGuard interface if it exists.
- Tater WireGuard UFW rules, unless you choose to keep them.
- The `tater-tunnel` service user/group if state/config data is purged.

It asks before deleting:

- Pairing/device state in `/var/lib/tater-tunnel`.
- WireGuard config in `/etc/tater-tunnel`.
- Downloaded source checkout in `/opt/tater-tunnel-src`.
- A Caddyfile proxy that points to the Tater VPS Agent.

It does not uninstall shared packages such as Python, Caddy, UFW, WireGuard, or
WireGuard tools.

Direct uninstall command:

```bash
sudo ./scripts/uninstall-vps.sh
```

Full purge:

```bash
sudo ./scripts/uninstall-vps.sh --purge-data --remove-source
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
