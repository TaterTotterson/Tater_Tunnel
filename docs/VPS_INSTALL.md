# Tater Tunnel VPS Install

## Guided Setup

From a normal sudo account on Debian or Ubuntu:

```bash
curl -fsSL https://raw.githubusercontent.com/TaterTotterson/Tater_Tunnel/main/scripts/tater-vps-setup.sh \
  -o "$HOME/tater-vps-setup.sh" && sudo bash "$HOME/tater-vps-setup.sh"
```

Use the arrow keys to choose:

- `Update existing install`
- `Blank VPS full install`
- `Advanced existing VPS install`
- `Optional ZNC install`
- `Optional SFTPGo install/update`
- `Audit VPS security`
- `Uninstall VPS install`
- `View setup notes`

The downloaded file form is preferred for the interactive menu. If the repo is
already on the VPS, run `sudo ./scripts/tater-vps-setup.sh`.

## First Login As Root

On a new VPS where the only account is root, run the setup command without
`sudo`. The blank install path offers to create a normal sudo user, copy any
existing authorized keys, and print PC-side SSH key commands.

For example:

```bash
ssh-keygen -t ed25519 -C "tater-tunnel-vps"
ssh-copy-id -i ~/.ssh/id_ed25519.pub tater@YOUR_VPS
ssh tater@YOUR_VPS
```

Keep the original root session open until the new key login succeeds. Then
reconnect as the sudo user and rerun the guided setup with `sudo`.

After key login works, disable password and root SSH login:

```bash
sudo install -d -m 0755 /etc/ssh/sshd_config.d
printf '%s\n' \
  'PubkeyAuthentication yes' \
  'PasswordAuthentication no' \
  'PermitRootLogin no' \
  | sudo tee /etc/ssh/sshd_config.d/99-tater-hardening.conf
sudo sshd -t
sudo systemctl reload ssh || sudo systemctl reload sshd
```

## Blank VPS Full Install

Choose this on a fresh VPS where Tater Tunnel may manage Caddy and UFW. You
need:

- A dedicated DNS hostname such as `tunnel.example.com` pointing directly to
  the VPS.
- Public `80/tcp`, `443/tcp`, and `51888/udp` available.
- A normal sudo account.

The installer:

- Installs the `tater-tunnel-vps` systemd service.
- Creates the `tater0` WireGuard interface at `10.88.0.1/24`.
- Installs Caddy and obtains the hostname certificate automatically.
- Exposes only `/`, the landing mascot, and `POST /api/claim` through Caddy.
- Opens HTTP, HTTPS, WireGuard, and the selected SSH port in UFW.
- Denies public TCP `4174`.
- Allows management on TCP `4174` only from Home Agent address `10.88.0.2`.
- Allows routed TCP/UDP `30000-30999` only from `tater0` to `10.88.0.2`.
- Enables IPv4 forwarding with routed traffic denied by default.

Run the noninteractive installer directly when needed:

```bash
sudo ./scripts/install-vps-full.sh --domain tunnel.example.com
```

An optional ACME email may be added with `--email admin@example.com`.

### Cloudflare DNS

The guided setup can create DNS-only `A` records with a zone-scoped Cloudflare
API token. Grant only:

- `Zone > Zone > Read`
- `Zone > DNS > Edit`

The token is read from a hidden prompt and is not saved. Keep the tunnel record
DNS-only, not proxied, so WireGuard and bootstrap traffic connect directly to
the VPS. Registrar nameserver changes remain manual.

The helper is also available directly:

```bash
sudo ./scripts/configure-cloudflare-dns.sh \
  --zone example.com \
  --record tunnel.example.com
```

## Pair The Home Agent

The installer prints:

```text
VPS URL: https://tunnel.example.com
Pairing code: ABCDE-23456
```

Enter those values in the local Home Agent. The public claim sends the Home
Agent WireGuard public key. On success, the VPS:

1. Disables pairing.
2. Adds the Home Agent at `10.88.0.2/32`.
3. Returns the private management URL and random management token.
4. Keeps all later management inside WireGuard.

The public hostname then continues to show only the static landing page.
`/api/health`, `/api/state`, `/api/wireguard`, and peer APIs return `404`
through Caddy.

## Clean-Start Migration

The WireGuard-only release does not preserve schema-v1 HTTPS relay identities,
device peers, or routes. Updating keeps the files so the service can detect the
old schema, then replaces their contents with fresh schema-v2 state.

After updating:

1. Choose `Update existing install` and reopen pairing.
2. Restart or update the Home Agent.
3. Pair again with the newly shown code.
4. Re-enroll remote devices.
5. Recreate private services.

There is no HTTPS relay fallback.

## Updating

Run the same one-command setup and choose `Update existing install`. It updates
the installed source, preserves current schema-v2 state, rewrites Caddy to the
bootstrap-only policy, repairs UFW rules, and restarts the service. Choose to
reopen pairing only when connecting a fresh Home Agent.

To test another branch or fork:

```bash
sudo ./scripts/tater-vps-setup.sh \
  --repo https://github.com/TaterTotterson/Tater_Tunnel.git \
  --branch main
```

## Advanced Existing VPS Install

Use this path when an existing web stack or firewall should remain under your
control:

```bash
sudo ./scripts/install-vps-agent.sh --wireguard-management-access
```

You must provide all of the following:

- A trusted HTTPS proxy that forwards only `/`, the mascot asset, and
  `/api/claim` to `127.0.0.1:4174`.
- A `404` response for every other public path.
- Public UDP `51888` for WireGuard.
- No public access to TCP `4174`.
- Private TCP `4174` access only from `10.88.0.2` on `tater0`.
- Forwarding rules for TCP/UDP `30000-30999` on `tater0` toward `10.88.0.2`.

Example Caddy policy:

```caddyfile
tunnel.example.com {
  @bootstrap path / /assets/tater-vps-mascot.png /api/claim
  handle @bootstrap {
    reverse_proxy 127.0.0.1:4174
  }
  handle {
    respond 404
  }
}
```

## Security Audit

Run after every install or update:

```bash
sudo /opt/tater-tunnel/scripts/audit-vps-security.sh \
  --domain tunnel.example.com
```

The audit exits nonzero when a required boundary is missing. It checks service
sandboxing, private file modes, exact peer addresses, live WireGuard state,
closed pairing, token-protected management, absent legacy relay endpoints,
Caddy exposure, and UFW routing.

## Optional ZNC

The menu can install ZNC for the selected sudo user. Its config remains under
that user's home directory, the service starts at boot, and WebAdmin can use a
dedicated Caddy HTTPS hostname while the backend stays on localhost.

```bash
sudo ./scripts/install-znc.sh --user tater --makeconf
```

The ZNC username and password created by its wizard remain the security gate.
Use TLS for public IRC connections and a unique password.

## Optional SFTPGo

The menu can install or update SFTPGo, enable Defender, hide the exact version,
enforce minimum password strength, and keep WebAdmin private for initial setup.

```bash
sudo ./scripts/install-sftpgo.sh \
  --open-sftp-firewall \
  --max-storage-gb 20
```

The optional cap creates a sparse ext4 image at
`/var/lib/sftpgo-storage/tater-data.img`, mounted at `/srv/sftpgo/data` with
`nosuid`, `nodev`, and `noexec`. It can grow to the selected limit but is never
shrunk automatically.

Open the initial WebAdmin through SSH:

```bash
ssh -L 8080:127.0.0.1:8080 tater@YOUR_VPS
```

Then visit `http://127.0.0.1:8080/web/admin`. Prefer SSH public keys for SFTP
users and enable TOTP for administrators.

## Service Commands

```bash
sudo systemctl status tater-tunnel-vps
sudo journalctl -u tater-tunnel-vps -f
sudo systemctl restart tater-tunnel-vps
sudo wg show tater0
```

Reopen pairing with a new code from the guided update path, or directly:

```bash
cd /opt/tater-tunnel
sudo -u tater-tunnel python3 -B -m tater_tunnel.vps_agent \
  --state-file /var/lib/tater-tunnel/vps-agent.json \
  --pairing-code-file /var/lib/tater-tunnel/pairing-code \
  --reopen-pairing
```

## Uninstall

Choose `Uninstall VPS install` in the guided menu or run:

```bash
sudo ./scripts/uninstall-vps.sh
```

It removes the VPS service and app files, then asks before deleting state,
WireGuard configuration, UFW rules, source checkout, or Caddy configuration.
It does not remove shared packages, ZNC, or SFTPGo data.
