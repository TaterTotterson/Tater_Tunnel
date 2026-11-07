# Tater Tunnel Trust Boundaries

## Core Rule

The VPS relays traffic. The Home Agent owns trust.

The Home Agent decides which devices and named app routes are approved. The VPS
stores the WireGuard peer list needed to enforce that only enrolled VPN source
addresses can enter the relay.

## Two Transport Paths

### Path 1: Home Relay

The Home Agent connects out to the VPS over a Tater-controlled secure relay path. This keeps setup simple for Docker, macOS, Windows, and Linux users because the home side does not need to install or operate WireGuard.

The relay path provides:

- Encrypted home-to-VPS transport.
- Home Agent authentication.
- No inbound ports at home.
- A narrow route to approved Tater services and local app targets.

### Path 2: Remote Device WireGuard

Remote phones and laptops can use WireGuard VPN mode against the VPS. This keeps the familiar "scan QR, enable VPN" mobile flow while avoiding WireGuard setup on the home machine.

WireGuard device mode provides:

- Encrypted transport.
- Peer authentication.
- A private path between remote devices and the VPS.

For general app routes, possession of an enrolled WireGuard peer key is the
device credential. A copied profile has the same authority until that peer is
revoked.

## Tater Service Identity

Tater services may add application-level identity on top of the tunnel:

- Tater Device ID.
- Pairing token or signing key.
- Approval record.
- Revocation state.

When a Tater service supports it, it should require both:

- The request arrives through an approved transport path.
- The requester proves an approved Tater device identity.

## Important Boundary: Tater Access vs LAN Access

Tater access and raw local network access must be treated as different products.

### Tater Access

Tater services can enforce Tater Device Trust directly. This is the safest MVP path.
For non-Tater local apps, the enrolled WireGuard peer and explicit Home Agent
route are the enforcement points because those apps cannot validate Tater
identity themselves.

Approved device:

- Has a WireGuard peer.
- Is approved by Home Agent.
- Can access approved Tater services or local app routes through the VPS-to-Home relay.

Revoked device:

- WireGuard peer is removed.
- New relay connections from that peer address are rejected.
- Existing relayed WebSocket sessions from that peer are closed immediately.

### Local Network Access

NAS devices, cameras, Home Assistant, printers, and other LAN services usually cannot validate Tater Device Trust by themselves.

If local network access is added, enforcement must happen through routing, firewall rules, a proxy controlled by Home Agent, or per-device route policy.

Until that exists, local network access should remain off by default and outside the MVP.

## Threat Notes

### VPS Compromise

The VPS terminates the device WireGuard connection and participates in the Home
Relay, so a compromised VPS can observe relayed traffic and access the named
routes while the Home Agent is connected. Tater Tunnel limits the reachable
surface to explicit routes, but it does not claim to protect those routes from
a fully compromised VPS.

Required controls:

- No local application credentials are stored on the VPS.
- The Home Agent UI and administration API are never relay routes.
- Public HTTPS requests to `/relay` are rejected.
- TCP `4174` is allowed only on the WireGuard interface and explicitly denied
  on public interfaces.
- Relay socket sources must exactly match an active WireGuard peer `/32` address.
- Broad, out-of-network, invalid-key, and reserved-address peer records are
  rejected or discarded when state is loaded.
- Service startup reapplies the sanitized peer list to WireGuard; reset removes
  both the generated configuration and the managed live interface.
- Home Agent can rotate keys and reclaim to a new VPS.

### Stolen WireGuard Config

If a remote device's WireGuard config is copied, the copy has the same route
access as that device until the peer is revoked.

Required controls:

- Home Agent removes the WireGuard peer.
- VPS Agent rejects relay traffic from addresses without an active peer.
- Tater services should separately revoke application sessions when supported.

### Lost Device

Revocation must remove both layers:

- Delete WireGuard peer.
- Revoke application identity and sessions when the routed app supports them.

## MVP Policy

For the first build:

- Enable Tater service and explicit app-route access.
- Keep the Home Agent UI and API local-only.
- Require an active WireGuard peer source for every relay request.
- Keep raw LAN routes disabled.
- Show raw LAN access as an advanced future control.
- Document that LAN access needs separate enforcement before release.
