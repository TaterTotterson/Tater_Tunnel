# Tater Tunnel Trust Boundaries

## Core Rule

The VPS relays traffic. The Home Agent owns trust.

The VPS should not decide who may use Tater services. It should only hold the minimum relay and WireGuard peer state needed to connect approved devices to the Home Agent.

## Two Transport Paths

### Path 1: Home Relay

The Home Agent connects out to the VPS over a Tater-controlled secure relay path. This keeps setup simple for Docker, macOS, Windows, and Linux users because the home side does not need to install or operate WireGuard.

The relay path provides:

- Encrypted home-to-VPS transport.
- Home Agent authentication.
- No inbound ports at home.
- A narrow route to approved Tater services.

### Path 2: Remote Device WireGuard

Remote phones and laptops can use WireGuard VPN mode against the VPS. This keeps the familiar "scan QR, enable VPN" mobile flow while avoiding WireGuard setup on the home machine.

WireGuard device mode provides:

- Encrypted transport.
- Peer authentication.
- A private path between remote devices and the VPS.

WireGuard does not prove that a device is approved by Tater. It proves possession of a peer private key.

## Tater Device Trust

Tater Device Trust provides:

- Tater Device ID.
- Pairing token or signing key.
- Approval record.
- Revocation state.

Tater services should require both:

- The request arrives through an approved transport path.
- The requester proves an approved Tater device identity.

## Important Boundary: Tater Access vs LAN Access

Tater access and raw local network access must be treated as different products.

### Tater Access

Tater services can enforce Tater Device Trust directly. This is the safest MVP path.

Approved device:

- Has a WireGuard peer.
- Has a Tater identity.
- Is approved by Home Agent.
- Can access approved Tater services through the VPS-to-Home relay.

Revoked device:

- WireGuard peer is removed.
- Tater identity is revoked.
- Active sessions are invalidated.

### Local Network Access

NAS devices, cameras, Home Assistant, printers, and other LAN services usually cannot validate Tater Device Trust by themselves.

If local network access is added, enforcement must happen through routing, firewall rules, a proxy controlled by Home Agent, or per-device route policy.

Until that exists, local network access should remain off by default and outside the MVP.

## Threat Notes

### VPS Compromise

If the VPS is compromised, an attacker may see relay metadata and WireGuard peer configuration. They should still be unable to access Tater services without approved Tater device identity.

Required controls:

- No service tokens stored on the VPS.
- No Tater admin authority on the VPS.
- Home Agent can rotate keys and reclaim to a new VPS.

### Stolen WireGuard Config

If a remote device's WireGuard config is copied, WireGuard access alone should not grant Tater service access.

Required controls:

- Tater service requests require device identity proof.
- Device revocation invalidates the Tater identity.
- Home Agent removes the WireGuard peer.

### Lost Device

Revocation must remove both layers:

- Delete WireGuard peer.
- Revoke Tater identity.
- Invalidate sessions and pairing tokens.

## MVP Policy

For the first build:

- Enable Tater service access.
- Keep raw LAN routes disabled.
- Show raw LAN access as an advanced future control.
- Document that LAN access needs separate enforcement before release.
