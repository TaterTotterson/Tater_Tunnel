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
- `Optional SFTPGo install/update`
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

- A dedicated hostname, for example `tunnel.example.com`. Its DNS `A` record
  can already point at the VPS, or the guided installer can create it through
  the optional Cloudflare API path.
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
- Writes a Caddy route from `https://tunnel.example.com` to `127.0.0.1:4174`
  while explicitly rejecting public `/relay` paths.
- Opens `80/tcp`, `443/tcp`, `51888/udp`, and the configured SSH port in UFW.
- Allows `4174/tcp` only from the WireGuard interface for VPN clients.
- Keeps `4174/tcp` closed on the public internet.
- Optionally installs ZNC and SFTPGo during the same guided setup.
- Optionally creates DNS-only Cloudflare records for the selected service
  hostnames before Caddy requests its certificate.

### Optional Cloudflare DNS Setup

The blank VPS questionnaire can configure Cloudflare DNS automatically. Create
an API token limited to the intended zone with only:

- `Zone > Zone > Read`
- `Zone > DNS > Edit`

The token is entered through a hidden prompt, used only for the current run,
and never written to disk or passed on the command line. The helper creates or
updates DNS-only `A` records and asks before replacing a record that points to
a different address.

Cloudflare assigns nameservers, but changing a domain's authoritative
nameservers generally happens at the registrar. The helper displays the exact
assigned nameservers. If the Cloudflare zone is still pending, setup stops
before installing Caddy so the nameservers can be updated safely. Rerun the
same setup command after Cloudflare reports the zone as active.

The DNS helper can also be run directly:

```bash
sudo ./scripts/configure-cloudflare-dns.sh \
  --zone example.com \
  --record tunnel.example.com \
  --record sftp.example.com
```

It auto-detects the VPS public IPv4 address, or accepts `--ipv4 ADDRESS`.

Pair the Home Agent with:

```text
VPS IP or Domain: https://tunnel.example.com
Pairing Code: shown by the installer
```

Opening `https://tunnel.example.com/` in a browser shows a small Tater Tunnel
status page. API and pairing endpoints remain under `/api/*`.

After a phone connects to the WireGuard profile, named local app routes use:

```text
http://10.88.0.1:4174/relay/ROUTE_NAME/
```

The bare `/relay/` path deliberately returns `404`; the Home Agent UI and its
administration API are local-only. They cannot be added as relay routes.

For example, add the main Tater app as a named route for its local URL:

```bash
python3.11 -m tater_tunnel.home_agent \
  --host 127.0.0.1 \
  --port 4173 \
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
  @public_relay path /relay /relay/*
  handle @public_relay {
    respond 404
  }

  handle {
    reverse_proxy 127.0.0.1:4174
  }
}
```

The VPS Agent also verifies the socket source of every relay request against
its active WireGuard peers. Do not add a public proxy exception for `/relay`.

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
- During a blank VPS install, can expose WebAdmin at a dedicated HTTPS
  hostname through Caddy. ZNC's web-only backend remains on `127.0.0.1:6698`
  and is not opened in UFW.

The same DNS-only hostname can serve both purposes: IRC clients connect to
`znc.example.com:6697`, while browsers open `https://znc.example.com`. Caddy
handles browser HTTPS on port `443`; the raw IRC connection goes directly to
ZNC on its configured listener port. Choose SSL when ZNC's config wizard asks
about the public IRC listener. The installer also protects ZNC web sessions,
hides the exact ZNC version, and trusts forwarded client addresses only from
the localhost Caddy proxy. The ZNC username and password created by the wizard
are used for both IRC clients and WebAdmin; no extra password is generated or
stored by Tater Tunnel.

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

## Optional SFTPGo Install

Choose `Optional SFTPGo install/update` to add a managed file-transfer server
to the VPS. This add-on is independent of the Tater Tunnel service and runs as
SFTPGo's own restricted system user.

The installer:

- Downloads the current open-source SFTPGo Debian package from its official
  GitHub release.
- Verifies the package against the release's published SHA-256 digest.
- Preserves existing SFTPGo configuration, users, and files when rerun for an
  update.
- Enables the `sftpgo` systemd service at boot.
- Can open `2022/tcp` in UFW for SFTP clients.
- Keeps `8080/tcp` private by default so the first WebAdmin account is not
  exposed before it has been configured.
- Binds WebAdmin to `127.0.0.1`, enables the built-in Defender against repeated
  failed logins, and hides the exact SFTPGo version.
- Enforces minimum password strength for new admin and SFTP user passwords.
- Can cap all default local SFTPGo user data at a selected total size while
  leaving at least `2 GiB` outside that cap when it is created.
- Preserves existing users, password hashes, public keys, 2FA settings, and
  provider data on updates.

Direct command:

```bash
sudo ./scripts/install-sftpgo.sh \
  --open-sftp-firewall \
  --max-storage-gb 20
```

The total storage cap creates a sparse, fixed-size ext4 filesystem image at
`/var/lib/sftpgo-storage/tater-data.img` and mounts it persistently at
`/srv/sftpgo/data` with `nosuid`, `nodev`, and `noexec`. The image consumes
host storage only as files are written, but it can never grow beyond the
selected size. The installer checks current free space and requires at least
`2 GiB` to remain outside the new cap.

The cap applies to the default local storage under `/srv/sftpgo/data`. An
administrator can still configure external storage or virtual folders at other
paths, which are outside this cap. Per-user quotas should also be set in
WebAdmin when individual users need separate limits. SFTPGo's software quota
counters are useful account controls, while the fixed filesystem is the total
local-storage backstop.

The installer can enlarge an existing managed image, but it will not shrink
one automatically. It also refuses to enable the cap over a nonempty existing
`/srv/sftpgo/data` directory, avoiding any hidden or implicit data migration.
Back up and migrate an existing installation manually before adding a cap.

From your PC, open an SSH port forward for the initial WebAdmin setup:

```bash
ssh -L 8080:127.0.0.1:8080 tater@YOUR_VPS
```

Keep that SSH session open and visit:

```text
http://127.0.0.1:8080/web/admin
```

Create the SFTPGo admin and SFTP users there. SFTP clients connect to the VPS
on port `2022`. SFTPGo stores its configuration under `/etc/sftpgo`, its state
under `/var/lib/sftpgo`, and local user files under `/srv/sftpgo/data`. Tater's
update-safe environment overrides are stored in
`/etc/sftpgo/env.d/tater-tunnel.env`.

Use a unique password for the first administrator and enable TOTP from the
admin profile after logging in. Prefer SSH public keys for SFTP users when the
client supports them. The installer deliberately does not create a default
administrator or save a password in a file, environment variable, or command
line argument.

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
WireGuard tools. Optional ZNC and SFTPGo installations are also left in place
so their user data is not removed as a side effect of uninstalling Tater
Tunnel.

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
curl -fsS https://tunnel.example.com/
```

For WireGuard live status:

```bash
sudo wg show tater0
```
