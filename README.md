<div align="center">
  <a href="https://tatertunnel.com">
    <img src="assets/tater-tunnel-repo-logo.png" alt="Tater Tunnel" width="620"/>
  </a>
</div>
<p align="center">
  <a href="https://tatertunnel.com">
    <img alt="Visit Tater Tunnel" src="https://img.shields.io/badge/Tater%20Tunnel-Visit%20Website-F28C28?style=for-the-badge&logo=googlechrome&logoColor=white" />
  </a>
</p>

Tater Tunnel gives approved phones and computers private access to selected
services on a home network through a user-owned VPS. The home network needs no
open inbound ports, and every forwarded home service remains behind WireGuard.

```text
remote device -- WireGuard --> VPS -- WireGuard --> Home Agent --> selected service
```

Tater Tunnel forwards raw TCP or UDP traffic, so it works with Tater, Emby,
Matrix, HTTP, WebSockets, media streams, and other network services. Each
service keeps its own login and authorization.

## Requirements

- A Debian or Ubuntu VPS with a public IPv4 address.
- A dedicated DNS hostname pointed directly at the VPS. Cloudflare records
  must be **DNS only**, not proxied.
- Public `80/tcp`, `443/tcp`, `51888/udp`, and the selected SSH port available
  on the VPS.
- A Home Agent running on macOS or Linux.
- The WireGuard app on each remote phone or computer.

## Quick Start

### 1. Install The VPS

Run this from a normal sudo account:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o "$HOME/tater-vps-setup.sh" && sudo bash "$HOME/tater-vps-setup.sh"
```

Choose **Install on a blank VPS**. The guided installer configures:

- WireGuard and the `tater0` interface.
- Caddy with automatic HTTPS.
- UFW with private management and service-routing rules.
- The `tater-tunnel-vps` systemd service.
- A local privileged helper for allow-listed app and audit actions.
- Optional Cloudflare DNS, ZNC, and SFTPGo setup.

When logged in directly as root, omit `sudo`. The installer creates a normal
sudo user and continues the installation in the same session.

The final screen shows the VPS URL and one-time pairing code. Keep the code
private. Unused codes expire after 15 minutes; use **Reopen pairing** for a
fresh code.

### 2. Start The Home Agent

#### macOS

[Download the latest Tater Tunnel release](https://github.com/TaterTotterson/Tater_Tunnel/releases/latest).

Open the menu bar app and approve the VPN configuration when macOS asks. The
app includes its own WireGuard tunnel; the separate WireGuard app is not
needed for the Home Agent.

Home Agent files and logs are stored under `~/.tatertunnel/`.

#### Linux

With WireGuard tools installed:

```bash
sudo python3 -B -m tater_tunnel.home_agent \
  --host 127.0.0.1 \
  --port 4173 \
  --wireguard-backend system
```

#### Docker On Linux

The image includes the Home Agent, Python runtime, `wireguard-tools`, and
`wireguard-go`. Do not install WireGuard tools or run the Linux/Python command
above when using Docker.

Run the image directly:

```bash
docker run -d \
  --name tater-tunnel-home \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  --network host \
  -e TATER_TUNNEL_HOST=127.0.0.1 \
  -e TATER_TUNNEL_WIREGUARD_BACKEND=system \
  -v tater-tunnel-state:/data \
  -v tater-tunnel-config:/config \
  ghcr.io/tatertotterson/tater-tunnel:latest home
```

Then open `http://127.0.0.1:4173` on the Linux host.

For a headless Home Agent, forward the dashboard over SSH and open the same
localhost URL on your computer:

```bash
ssh -L 4173:127.0.0.1:4173 YOUR_USER@HOME_AGENT_HOST
```

Or use the included Compose configuration from a repository checkout:

```bash
docker compose up -d
```

Common commands:

```bash
# Follow Home Agent logs
docker logs -f tater-tunnel-home

# Update a Compose installation
docker compose pull
docker compose up -d

# Stop or restart the container
docker stop tater-tunnel-home
docker start tater-tunnel-home
```

For a direct `docker run` installation, update by pulling the newest image,
removing the old container, and running the command above again. The named
`tater-tunnel-state` and `tater-tunnel-config` volumes preserve the setup.

The Linux host only needs Docker and a working `/dev/net/tun` device. Host
networking and the `NET_ADMIN` capability are supplied by the command above and
are already defined in `compose.yaml`. No separate WireGuard app or host
`wireguard-tools` installation is required. This mode is intended for a Linux
Docker host, not Docker Desktop on macOS or Windows.

### 3. Pair The Home Agent

Open [http://127.0.0.1:4173](http://127.0.0.1:4173), then enter the VPS HTTPS
URL and one-time pairing code.

Pairing creates the Home Agent peer at `10.88.0.2`. After the claim, management
moves inside WireGuard and the public pairing endpoint closes.

### 4. Add A Remote Device

1. Select **Add Device** in the Home Agent.
2. Name the device, select its home services, and generate its QR code.
3. Scan the QR code with the WireGuard app.
4. Activate the new WireGuard tunnel.

Use **Access** beside a device to change its home service permissions. New
devices default to selected services. **All current and future services** is
an explicit broader option. Existing devices retain their previous access.
Permission changes and revocation close existing forwarded connections.
These controls cover forwarded home services; VPS-hosted apps retain their own
WireGuard exposure and application login policies.

Remote devices receive an address in `10.88.0.0/24` and can reach only the
private tunnel network and configured services. Their normal internet traffic
does not pass through the VPS.

### 5. Add A Private Service

In **Private Services**, enter:

- A name.
- The local target host and port.
- TCP or UDP.
- An optional tunnel port, or let Tater Tunnel choose one from
  `30000-30999`.

Examples:

| Service | Local target | Private address from a connected device |
| --- | --- | --- |
| Tater on the Home Agent computer | `127.0.0.1:8501` | `http://10.88.0.2:30000` |
| Emby on another LAN computer | `10.4.20.204:8096` | `http://10.88.0.2:30001` |

Use the exact address shown by the Home Agent. Web services need the `http://`
or `https://` scheme. For example, Tater SpudLink can use
`http://10.88.0.2:30000` as its Away URL.

The forwarding layer does not rewrite paths, headers, or WebSocket traffic.

## Control Center

After pairing, the Home Agent becomes a private VPS control center. It shows
VPS CPU, memory, disk, uptime, devices, routes, app status, and WireGuard-only
app addresses.

The **Apps** view manages SFTPGo, ZNC, Uptime Kuma, ntfy, Forgejo, and Matrix
Synapse. SFTPGo protocol exposure, storage cap, WebDAV hostname, and optional
one-time Cloudflare DNS setup are available there. ZNC owner, listeners, and
initial administrator setup are available there as well.

Installed apps have **Enable**, **Disable**, and **Uninstall** controls.
Disabling keeps the app installed with its data and settings. Uninstalling
defaults to keeping data for a later **Reinstall**. Permanent deletion is a
separate choice that requires typing the app name and confirming. Only managed
local app data is deleted; external storage, shared Docker images, and system
dependencies are kept. Removing ZNC does not remove its Linux user.

Uptime Kuma, ntfy, Forgejo, and Matrix run in version-pinned Docker containers.
Docker is installed on demand. Their web ports always bind only to loopback and
`10.88.0.1`. Each app starts WireGuard-only; selecting public access creates a
dedicated Caddy HTTPS route while keeping the raw app port private.

App changes run as background jobs on the VPS. Passwords and Cloudflare tokens
are sent only through the private WireGuard management path and are not kept in
job history.

Managed defaults close self-registration, require an initial administrator
where supported, and avoid public database listeners. Forgejo Git SSH has its
own private/public choice. Matrix public mode enables federation; TURN for
reliable voice and video calls is not installed by this release.

The **Updates** view can install the newest official stable VPS release. The
managed updater accepts no repository, branch, package, or shell input. It
preserves pairing and service state, reapplies the managed security boundaries,
and reports completion after the VPS Agent restarts. VPS archives require an
Ed25519-signed manifest verified against the installed release key before any
downloaded code runs. Unsigned releases and downgrades are rejected.

**System > Recent activity** shows bounded security history for pairing,
devices, permissions, home services, app management, audits, and updates.
Passwords, pairing codes, and tokens are excluded.

## Tunnel Addresses

| Address | Purpose |
| --- | --- |
| `10.88.0.1` | VPS WireGuard interface and private VPS services |
| `10.88.0.2` | Home Agent and forwarded home services |
| `10.88.0.10` through `10.88.0.249` | Remote device peers |

Use `.1` for VPS-hosted tools such as SFTPGo WebAdmin. Use `.2` for services
added in the Home Agent.

## VPS Management

After installing a release with Control Center updates, later stable VPS
releases can be applied from the **Updates** view. The setup command remains
available for recovery and terminal maintenance. Its menu provides:

- **Update Tater Tunnel**: updates code while preserving current state.
- **Install agent only**: advanced path for an existing proxy and firewall.
- **Install ZNC** and **Install SFTPGo**: optional private services.
- **Run security audit**: checks or repairs Tater-managed boundaries.
- **Uninstall Tater Tunnel**: optionally retains or removes state.

Useful commands:

```bash
sudo systemctl status tater-tunnel-vps
sudo systemctl status tater-tunnel-control
sudo journalctl -u tater-tunnel-vps -f
sudo wg show tater0
```

Run the security audit after installation or firewall changes:

```bash
sudo /opt/tater-tunnel/scripts/audit-vps-security.sh \
  --domain tunnel.example.com
```

## Optional VPS Services

### ZNC

The installer creates a user-owned ZNC configuration and starts it with
systemd. By default both IRC and WebAdmin remain WireGuard-only:

- IRC: `10.88.0.1:6697`, or the selected listener port.
- WebAdmin: [http://10.88.0.1:6698](http://10.88.0.1:6698).

### SFTPGo

The installer can enable SFTP, FTP, WebDAV, or any combination. SFTP and FTP
may remain WireGuard-only or be explicitly opened. Public WebDAV uses a
dedicated Caddy HTTPS hostname; its local `10080/tcp` listener remains blocked
from the public network.

- WebAdmin: [http://10.88.0.1:8080/web/admin](http://10.88.0.1:8080/web/admin).
- SFTP: `2022/tcp` when enabled.
- FTP: `2121/tcp` and passive `50000-50100/tcp` when enabled.
- WebDAV: private `10080/tcp` or public HTTPS on `443/tcp`.

The setup also supports a total storage cap and a one-time Cloudflare API token
for DNS-only records. The token is not saved.

### Container Apps

Install these from **Apps** in the Home Agent:

| App | WireGuard address | Public option |
| --- | --- | --- |
| Uptime Kuma | `http://10.88.0.1:3001` | Dedicated Caddy HTTPS hostname after private first-run setup |
| ntfy | `http://10.88.0.1:2586` | Dedicated Caddy HTTPS hostname |
| Forgejo | `http://10.88.0.1:3000` | Caddy HTTPS; Git SSH is controlled separately on `2222/tcp` |
| Matrix Synapse | `http://10.88.0.1:8008` | Caddy HTTPS with federation on `443/tcp` |

Uptime Kuma must be installed privately first so its administrator can be
created before public access is enabled. ntfy denies anonymous topics and caps
attachments. Forgejo disables registration. Matrix uses an internal PostgreSQL
container, disables registration, and treats its server name as permanent.

## Ports

| Port | Exposure | Purpose |
| --- | --- | --- |
| Selected SSH port | Public | VPS administration |
| `80/tcp` | Public | ACME and Caddy HTTP |
| `443/tcp` | Public | Bootstrap HTTPS and optional WebDAV HTTPS |
| `51888/udp` | Public | WireGuard peers |
| `4174/tcp` | WireGuard only | Home Agent management of the VPS |
| `30000-30999` TCP/UDP | WireGuard only | Explicit private service forwards |
| `4173/tcp` | Localhost | Home Agent control panel |

Optional public SFTP or FTP ports are opened only when selected during SFTPGo
setup. Managed container web ports `2586`, `3000`, `3001`, and `8008` remain
WireGuard-only even when an app has a public Caddy hostname. Forgejo may open
`2222/tcp` only when public Git SSH is explicitly selected.

## SSH Hardening

For a VPS first accessed as root, add your local computer's SSH key after setup:

```bash
ssh-copy-id YOUR_USER@YOUR_VPS
ssh YOUR_USER@YOUR_VPS
```

After confirming key login in a second terminal, disable password and root SSH
login:

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

Keep the original root session open until the new key login succeeds.

## Security Model

- Public HTTPS exposes only the landing page, mascot asset, and one-time claim.
- Pairing disables itself after the Home Agent is claimed or the code expires.
- VPS management requires WireGuard source validation and a random management
  token.
- The Home Agent UI and APIs require a loopback connection on the Home Agent
  computer. Browser APIs use an eight-hour session, strict origin checks, and
  CSRF protection for changes. Only approved UI assets are served.
- Privileged app changes use a root-owned Unix socket and typed, allow-listed
  commands; there is no shell or arbitrary-command endpoint.
- Private listeners bind to `10.88.0.2` and forward only to explicit targets.
- UFW routes remote peers only to the Home Agent service range; unconfigured
  ports have no listener.
- Forwarded home services check each device's source address and permissions.
  API connections and forwarding workers are bounded; idle TCP forwards close
  after five minutes without traffic.
- Private Docker bindings have a persistent firewall guard independent of UFW.

The local audit is available from **System**. For independent public, device,
revocation, and reboot checks, see the commands in
[VPS Install](docs/VPS_INSTALL.md#independent-network-checks).

See [Trust Boundaries](docs/TRUST_BOUNDARIES.md) for the complete model and
[VPS Install](docs/VPS_INSTALL.md) for advanced setup details.

## Build The macOS App

Install Xcode and XcodeGen, then run:

```bash
macos/TaterTunnel/scripts/build_app.sh
```

Tag builds use `.github/workflows/macos-release.yml` to build, sign, notarize,
and publish the app. Docker images are published for `linux/amd64` and
`linux/arm64` by `.github/workflows/docker-image.yml`.

## License And Trademarks

Tater Tunnel is licensed under the [GNU Affero General Public License v3.0](LICENSE).
The Tater name and logo are governed by the [Tater Trademark Policy](TRADEMARKS.md).
