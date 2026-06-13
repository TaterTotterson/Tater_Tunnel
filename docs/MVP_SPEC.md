# Tater Tunnel MVP Spec

## Product Promise

Secure remote access to Tater without port forwarding, public dashboards, cloud tunnel accounts, or advanced networking setup.

## MVP User Journey

1. User rents or already has a VPS.
2. User installs Tater VPS Agent.
3. VPS Agent shows a pairing code.
4. User opens Tater Home Agent.
5. User enters VPS address and pairing code.
6. Home Agent claims the VPS and disables pairing mode.
7. Home Agent keeps an outbound relay connection to the VPS.
8. User adds a phone, laptop, or tablet.
9. Home Agent creates a WireGuard device enrollment for VPN mode.
10. User scans a QR code in the WireGuard app.
11. Device can reach approved Tater services remotely.
12. User can revoke the device from Home Agent.

## Components

### Tater VPS Agent

Runs on the VPS.

MVP responsibilities:

- Install and configure WireGuard.
- Expose one UDP WireGuard port.
- Accept one pairing claim from Home Agent.
- Store the Home Agent relay authority record.
- Add and remove WireGuard peers when instructed by Home Agent.
- Bridge approved device traffic to the Home Agent relay path.
- Report basic health.

Non-responsibilities:

- No browser dashboard.
- No service-level approval decisions.
- No user or permission management.
- No public access to Tater services.

### Tater Home Agent

Runs on the user's home machine, Docker host, Unraid server, or future Home Assistant add-on.

MVP responsibilities:

- Claim a VPS Agent.
- Maintain an outbound relay path to the VPS.
- Generate remote-device WireGuard enrollment payloads.
- Register Tater device identities.
- Add and revoke devices.
- Show tunnel health.
- Gate Tater service access by approved device identity.

## MVP Screens

### Tunnel Status

Shows:

- Tunnel state.
- VPS address.
- WireGuard endpoint.
- Home relay state.
- Last health check.
- Number of enrolled devices.

Primary actions:

- Pair VPS.
- Add Device.
- Run Check.

### VPS Pairing

Inputs:

- VPS IP or domain.
- Pairing code.
- Security mode: Minimal, Safe, Lockdown.

States:

- Waiting for VPS.
- Pairing.
- Connected.
- Needs attention.

### Devices

Fields:

- Person.
- Device name.
- Device type.
- Approval state.
- Last seen.

Actions:

- Add device.
- Revoke device.

Enrollment modes:

- VPN Mode: scan a WireGuard QR with the official WireGuard app.
- Future Tater App Mode: scan a Tater invite that installs/starts VPN internally.

## Explicit Non-Goals For MVP

- Multi-home support.
- Multiple VPS support.
- Temporary guests.
- Site-to-site networking.
- Direct NAS or camera access.
- Home Assistant remote access.
- Home Agent as a WireGuard peer.
- Public web UI on the VPS.
- Advanced roles beyond approved or revoked.

## Milestones

### Milestone 1: Prototype

- Static Home Agent UI.
- MVP docs.
- Trust boundary docs.
- Simulated pairing and device enrollment.

### Milestone 2: Local Agent Skeleton

- Home Agent service.
- Local API.
- Persistent config store.
- WireGuard key generation abstraction.
- Device inventory model.

### Milestone 3: VPS Agent Skeleton

- VPS Agent service.
- Pairing mode.
- Claim endpoint.
- Peer management interface.
- Health endpoint.

### Milestone 4: Real Pairing

- Home Agent claims VPS Agent.
- Pairing mode disables after claim.
- Home Agent records relay status.
- Home Agent can add and remove WireGuard peers.
- Tunnel health is reported from both sides.

### Milestone 5: Tater Service Gate

- Approved device identity required for Tater services.
- Revoked devices lose both WireGuard peer access and Tater access.
- Audit log records pairing, enrollment, and revocation.
