# Tater Tunnel v0.2.0

This is the new clean security baseline for Tater Tunnel. It intentionally
removes the previous HTTPS application relay and does not provide a fallback.

## Security

- The Home Agent now has a dedicated WireGuard peer at `10.88.0.2`.
- Public HTTPS is limited to the landing page, mascot asset, and one-time claim.
- All later management stays inside WireGuard and requires a random management
  token in addition to the expected tunnel source address.
- Remote devices receive unique WireGuard keys and exact `/32` addresses.
- The Home Agent UI rejects tunnel traffic and remains local-only.
- UFW permits private services through `tater0` while denying public access to
  the VPS management port.
- Caddy, systemd, state-file permissions, and the VPS audit have been hardened
  around the new WireGuard-only boundary.

## Home Agent

- The signed macOS app bundles the official WireGuardKit packet tunnel system
  extension; users do not install a separate WireGuard app for the Home Agent.
- Docker bundles `wireguard-tools` and `wireguard-go` and supports Linux host
  networking with `/dev/net/tun` and `NET_ADMIN`.
- The interface now follows three steps: connect the VPS, approve devices, and
  share private services.
- Private services use raw TCP or UDP listeners on
  `10.88.0.2:30000-30999`, avoiding HTTP path and WebSocket rewriting.
- HTTP, WebSockets, Matrix, media streams, and other application protocols pass
  through unchanged to the selected local target.

## Required Clean Start

Existing pairing, devices, and relay routes are deliberately reset. To migrate:

1. Update the VPS and reopen pairing.
2. Install or update the Home Agent.
3. Claim the VPS again and approve the macOS VPN/system extension prompts.
4. Re-enroll remote devices and recreate private services.

After installation, verify the VPS with:

```bash
sudo /opt/tater-tunnel/scripts/audit-vps-security.sh --domain tunnel.example.com
```
