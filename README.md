# Tater Tunnel

Website: [tatertunnel.com](https://tatertunnel.com)

Tater Tunnel gives approved phones and computers private access to selected
apps at home through a user-owned VPS. It works with Tater, Matrix, Emby, and
other TCP or UDP services without opening an inbound port on the home network.

Both sides of the private path use WireGuard:

```text
remote device -- WireGuard --> VPS -- WireGuard --> Home Agent --> selected app
```

The public HTTPS hostname is bootstrap-only. It serves a small landing page and
the one-time `POST /api/claim` endpoint. Health, peer management, local apps,
and the Home Agent UI are not exposed through public HTTPS.

## Clean-Start Upgrade

This release retires the old HTTPS application relay. Existing Home Agent and
VPS pairing state is intentionally reset the first time the new version runs.
Update the VPS, reopen pairing, and connect the Home Agent again. Re-enroll
remote devices and recreate private services afterward.

There is no fallback to the retired relay protocol.

## How It Works

- The Home Agent claims the VPS once over Caddy HTTPS with the installer code.
- Pairing creates a dedicated WireGuard peer at `10.88.0.2` for the Home Agent.
- All later VPS management uses `http://10.88.0.1:4174` inside WireGuard plus a
  random management token.
- Remote devices receive their own WireGuard keys and tunnel addresses.
- Each private service gets a TCP or UDP listener on
  `10.88.0.2:30000-30999` and forwards to one explicit local host and port.
- The Home Agent control panel remains local at `http://127.0.0.1:4173` and
  rejects requests arriving through the tunnel.

See [Trust Boundaries](docs/TRUST_BOUNDARIES.md) for the complete security
model.

## VPS Setup

On a normal sudo account, run:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o "$HOME/tater-vps-setup.sh" && sudo bash "$HOME/tater-vps-setup.sh"
```

Choose `Install on a blank VPS` on a fresh Debian or Ubuntu VPS. The guided
installer configures WireGuard, Caddy, UFW, automatic HTTPS, and the systemd
service. It can also install WireGuard-only ZNC and SFTPGo with selectable
SFTP, FTP, and WebDAV listeners. WebDAV can stay private or use a dedicated
Caddy HTTPS subdomain, while both browser admin pages remain private.

If logged in directly as root, run the command without `sudo` first. The menu
creates a normal sudo user and continues the full install in the same session.
After setup, add your computer's normal SSH key and test the new account from a
second terminal:

```bash
ssh-copy-id YOUR_USER@YOUR_VPS
ssh YOUR_USER@YOUR_VPS
```

Keep the original root session open until the new key login succeeds. From the
new sudo-user session, disable password and root SSH login:

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
printf '%s\n' \
  'PubkeyAuthentication yes' \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'PermitRootLogin no' \
  | sudo tee /etc/ssh/sshd_config.d/99-tater-hardening.conf
sudo sshd -t && (sudo systemctl reload ssh || sudo systemctl reload sshd)
```

Open one more terminal and confirm `ssh YOUR_USER@YOUR_VPS` still works before
closing the original session. See [VPS Install](docs/VPS_INSTALL.md) for the
full setup notes.

Use the same command later and choose `Update Tater Tunnel`. For this
WireGuard-only migration, the old tunnel identity is discarded and must be
paired again.

The first install ends on a focused screen containing only the VPS URL and
one-time pairing code. Keep that screen private and enter both values in the
Home Agent.

Useful VPS details:

- Public base ports: `80/tcp`, `443/tcp`, `51888/udp`, and the selected SSH port.
- SFTPGo can enable SFTP on `2022/tcp`, FTP on `2121/tcp` plus passive
  `50000-50100/tcp`, and WebDAV on local port `10080/tcp`. External WebDAV is
  served through Caddy on `443/tcp`; port `10080` stays blocked publicly.
  The guided setup can create its DNS-only Cloudflare record with the same
  one-time API-token helper used by the main VPS install.
  WebAdmin is always WireGuard-only at `http://10.88.0.1:8080/web/admin`.
- ZNC IRC stays behind WireGuard on its selected listener port, and its
  WebAdmin is available at `http://10.88.0.1:6698/`. First-time setup asks for
  an administrator login and creates the private ZNC configuration automatically.
- Service status: `sudo systemctl status tater-tunnel-vps`
- Live logs: `sudo journalctl -u tater-tunnel-vps -f`
- WireGuard peers: `sudo wg show tater0`
- Security audit: rerun setup and choose `Run security audit`. The guided audit
  can first repair stale Tater-managed Caddy, UFW, SFTPGo, and ZNC boundaries.

Full instructions are in [VPS Install](docs/VPS_INSTALL.md).

## Home Agent

### macOS App

[Download Tater Tunnel for macOS](https://github.com/TaterTotterson/Tater_Tunnel/releases/latest)

The menu bar app starts the local Home Agent and includes its WireGuard packet
tunnel. A separate WireGuard app is not required. macOS asks for system
extension and VPN approval the first time a tunnel is created.

Local state, logs, the generated tunnel configuration, and managed Python are
stored under:

```text
~/.tatertunnel/
```

### Docker

The container bundles `wireguard-tools` and `wireguard-go`. It needs the tunnel
device, network administration capability, and host networking so private
service listeners are reachable through the Home Agent peer:

```bash
docker run --rm \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  --network host \
  -v tater-tunnel-state:/data \
  -v tater-tunnel-config:/config \
  ghcr.io/tatertotterson/tater-tunnel:latest home
```

The included `compose.yaml` provides the same Linux host-network setup while
binding the local UI to `127.0.0.1:4173`.

### Linux Or Development

On Linux with WireGuard tools installed:

```bash
sudo python3 -B -m tater_tunnel.home_agent \
  --host 127.0.0.1 \
  --port 4173 \
  --wireguard-backend system
```

Open `http://127.0.0.1:4173/`, enter the VPS HTTPS URL and one-time pairing
code, approve devices, and add only the private services they need.

## Private Services

A service route is a raw TCP or UDP forward, so HTTP path rewriting is no
longer involved. For example, an Emby target at `10.4.20.204:8096` might be
assigned:

```text
10.88.0.2:30000
```

Use that private address from a WireGuard-connected device. HTTP, WebSockets,
Matrix, media streams, and other protocols pass through unchanged. The target
app still owns its login, session, and authorization rules.

## Security Audit

After a VPS install or update, run:

```bash
sudo /opt/tater-tunnel/scripts/audit-vps-security.sh \
  --domain tunnel.example.com
```

The audit verifies state permissions, systemd hardening, exact WireGuard peer
addresses, closed public management APIs, Caddy's bootstrap-only boundary, and
UFW routing rules.

## Build The macOS App

Install Xcode and XcodeGen, then run:

```bash
macos/TaterTunnel/scripts/build_app.sh
```

Release builds use the official WireGuardKit source pinned by the build script.
Developer ID distribution requires separate provisioning profiles for the app
and Network Extension targets:

```text
TATER_TUNNEL_APP_PROFILE
TATER_TUNNEL_EXTENSION_PROFILE
```

Tag builds use `.github/workflows/macos-release.yml` to package, sign, notarize,
and publish the app when the repository signing variables are configured.

## License And Trademarks

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).
The Tater name and logo are governed by the [Tater Trademark Policy](TRADEMARKS.md).
