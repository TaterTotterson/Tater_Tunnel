# Tater Tunnel

Tater Tunnel is a privacy-first secure networking layer for Tater. The user brings a VPS; Tater Tunnel pairs a Home Agent to that VPS over a simple outbound relay path, while remote phones and laptops can use WireGuard VPN mode against the VPS.

This repo currently contains the first product slices:

- A static Home Agent UI prototype in `index.html`
- A stdlib Home Agent API in `tater_tunnel/home_agent.py`
- MVP scope in `docs/MVP_SPEC.md`
- Trust boundaries in `docs/TRUST_BOUNDARIES.md`

## Run The Home Agent Prototype

```bash
python3.11 -m tater_tunnel.home_agent --host 127.0.0.1 --port 4173
```

Then open:

```text
http://127.0.0.1:4173/
```

State is stored at `.tater_tunnel/home-agent.json`.

## Run With Docker

Build the image locally:

```bash
docker build -t tater-tunnel:local .
```

Run the Home Agent UI/API:

```bash
docker run --rm \
  -p 4173:4173 \
  -v tater-tunnel-home-data:/data \
  -v tater-tunnel-home-config:/config \
  tater-tunnel:local home
```

Then open:

```text
http://127.0.0.1:4173/
```

Run the VPS Agent in safe config-rendering mode:

```bash
docker run --rm \
  -p 4174:4174 \
  -p 51888:51888/udp \
  -v tater-tunnel-vps-data:/data \
  -v tater-tunnel-vps-config:/config \
  -e TATER_TUNNEL_PAIRING_CODE=ABCD-1234 \
  tater-tunnel:local vps
```

For a live VPS container that should manage the WireGuard interface, run it on a
Linux host with network administration access:

```bash
docker run --rm \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  --network host \
  -v tater-tunnel-vps-data:/data \
  -v tater-tunnel-vps-config:/config \
  -e TATER_TUNNEL_PAIRING_CODE=ABCD-1234 \
  -e TATER_TUNNEL_WIREGUARD_BACKEND=system \
  tater-tunnel:local vps
```

Tagged releases publish a multi-architecture image to:

```text
ghcr.io/tatertotterson/tater-tunnel
```

Example release image:

```bash
docker run --rm -p 4173:4173 ghcr.io/tatertotterson/tater-tunnel:latest home
```

## macOS Home Agent App

The signed macOS app is available from the GitHub releases page:

[Download Tater Tunnel for macOS](https://github.com/TaterTotterson/Tater_Tunnel/releases/latest)

The app is a menu bar wrapper for the Home Agent. It starts the local Tunnel UI on:

```text
http://127.0.0.1:4173/
```

Local state, logs, WireGuard config files, managed Python, and app support files are stored under:

```text
~/.tatertunnel/
```

Build the app locally:

```bash
macos/TaterTunnel/scripts/build_app.sh
```

Build the update zip and DMG:

```bash
macos/TaterTunnel/scripts/package_update.sh
macos/TaterTunnel/scripts/build_dmg.sh
```

Pushing a matching version tag, for example `v0.1.2`, builds the macOS app,
signs and notarizes the release when repository variables are configured,
uploads workflow artifacts, publishes GitHub release assets, and commits the
generated updater files back to `main`.

## Run The Two-Agent Prototype

Start the VPS Agent in one terminal:

```bash
python3.11 -m tater_tunnel.vps_agent --host 127.0.0.1 --port 4174 --pairing-code ABCD-1234
```

Start the Home Agent in another terminal:

```bash
python3.11 -m tater_tunnel.home_agent --host 127.0.0.1 --port 4173
```

Then open:

```text
http://127.0.0.1:4173/
```

Use these pairing values:

- VPS IP or Domain: `http://127.0.0.1:4174`
- Pairing Code: `ABCD-1234`

In this local mode, the Home Agent claims the VPS Agent over HTTP as a relay client. Device enrollment pushes a WireGuard peer into the VPS Agent, and revocation removes that peer again.

By default, the VPS Agent uses the safe `config` WireGuard backend. It renders a server config at:

```text
.tater_tunnel/wireguard/tater0.conf
```

The generated config includes:

- The VPS WireGuard interface.
- One peer per approved device.

Revoking a device rewrites the config without that device peer.

The Home Agent does not run WireGuard in the default product path. It pairs as a relay client so macOS, Windows, Docker, and Linux users do not need to install WireGuard just to reach approved home app routes. WireGuard is used for remote device VPN mode: the phone or laptop gets a config/QR whose endpoint is the VPS public IP/domain.

If the `wg` command is available, key generation uses it. Otherwise the prototype uses mock-shaped key material so the control flow can be tested without changing network interfaces.

You can inspect the VPS WireGuard readiness and the Home Agent relay/device-VPN state:

```bash
curl http://127.0.0.1:4174/api/wireguard
curl http://127.0.0.1:4173/api/wireguard
```

The VPS diagnostics report the selected backend, config path, platform, available commands, whether the interface exists, and whether system apply is possible. The Home Agent diagnostics report that WireGuard is reserved for remote device VPN mode.

An explicit `wg` runtime backend exists for later VPS testing when the interface already exists:

```bash
python3.11 -m tater_tunnel.vps_agent \
  --host 127.0.0.1 \
  --port 4174 \
  --pairing-code ABCD-1234 \
  --wireguard-backend wg
```

That backend renders the config and then runs `wg setconf <interface> <config>`. Use it only on a host where the interface already exists and changing WireGuard state is intended.

A guarded `system` backend also exists. It is Linux-only, checks for `wg` and `ip`, creates the interface if it is missing, applies the config, assigns the tunnel address, and brings the interface up:

```bash
python3.11 -m tater_tunnel.vps_agent \
  --host 127.0.0.1 \
  --port 4174 \
  --pairing-code ABCD-1234 \
  --wireguard-backend system
```

The system backend is intentionally explicit. Resetting an agent removes the generated config but leaves any live interface unchanged.

If the VPS is already claimed and you need to pair a fresh Home Agent, reopen pairing explicitly:

```bash
python3.11 -m tater_tunnel.vps_agent \
  --pairing-code ABCD-1234 \
  --reopen-pairing
```

This maintenance command updates the VPS state file and exits. It keeps the VPS state and approved device peers, enables pairing for the supplied code, and turns pairing off again after the next successful claim. If the VPS Agent service is already running, it can keep running.

The Home Agent still accepts the WireGuard backend flags for development, but the default product flow no longer requires the Home Agent itself to become a WireGuard peer.

## VPS Installers

Recommended one-command VPS setup from a normal sudo user:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && sudo bash /tmp/tater-vps-setup.sh
```

On a brand-new VPS where you are logged in directly as `root`, run it without
`sudo` first:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && bash /tmp/tater-vps-setup.sh
```

The blank VPS path will create a sudo user first, print SSH key setup commands
for your PC, and ask you to reconnect as the new user before installing Tater
Tunnel. After key login works, disable password login and root SSH login.

Run the same command later to update an existing VPS install. The setup menu
has an `Update existing install` option that downloads the latest source,
preserves `/var/lib/tater-tunnel` state, keeps the current service host/port,
and restarts the VPS Agent.

To test a branch or fork, pass the repo explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o /tmp/tater-vps-setup.sh && \
  sudo bash /tmp/tater-vps-setup.sh --repo https://github.com/TaterTotterson/Tater_Tunnel.git
```

Pipe form, if preferred:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  | sudo bash
```

If the repo is already on the VPS, run the interactive menu directly:

```bash
sudo ./scripts/tater-vps-setup.sh
```

For a fresh Debian/Ubuntu VPS where Tater Tunnel can manage Caddy and the
firewall:

```bash
sudo ./scripts/install-vps-full.sh --domain tunnel.example.com
```

For an existing VPS where you already manage Webmin, Caddy, Nginx, Apache, or
firewall rules:

```bash
sudo ./scripts/install-vps-agent.sh
```

See `docs/VPS_INSTALL.md` for the full setup flow. The full installer keeps the
VPS Agent on `127.0.0.1:4174`, puts Caddy in front for automatic HTTPS, opens
`80/tcp`, `443/tcp`, and `51888/udp`, and keeps the raw agent port private.
It also allows WireGuard clients to reach the Home Relay on
`http://10.88.0.1:4174/relay/`, while keeping `4174/tcp` closed to the public
internet.

To expose another local app through the relay, add a named Home Agent route:

```bash
python3.11 -m tater_tunnel.home_agent \
  --host 0.0.0.0 \
  --port 4173 \
  --relay-target http://127.0.0.1:4173 \
  --relay-route tater=http://127.0.0.1:8000
```

Then open `http://10.88.0.1:4174/relay/tater/` from a WireGuard-connected
phone. Replace `8000` with the main Tater app's local port.

## Open The Static Prototype

You can also open `index.html` directly in a browser.

When opened directly, the UI falls back to browser-local state. When served by the Home Agent, it uses the local API for pairing, device enrollment, revocation, and tunnel health.

## Test

```bash
python3.11 -m unittest discover -s tests
```

## MVP Direction

The first useful version should let a user:

1. Install the VPS Agent.
2. Pair it from the Home Agent.
3. Add a phone or laptop with a QR code.
4. Reach approved Tater and local app routes through the Home Agent relay path.
5. Revoke a lost device.

Remote devices can use WireGuard VPN mode by scanning the generated WireGuard config/QR. A future native Tater app can wrap that flow the same way UniFi wraps WireGuard with Teleport/WiFiman.

Local network access, guest access, multi-home support, and site-to-site networking should stay out of the first build unless the enforcement model is complete.
