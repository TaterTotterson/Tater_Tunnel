# Tater Tunnel Trust Boundaries

## Core Rule

Tater Tunnel exposes explicit services, not the home network. Every data path
after the one-time claim is carried by authenticated WireGuard peers.

## Transport Paths

### Public Bootstrap

Caddy exposes only:

- `GET /` for the static landing page.
- `GET /assets/tater-vps-mascot.png` for that page.
- `POST /api/claim` for one-time Home Agent pairing.

The claim requires the current pairing code and a valid Home Agent WireGuard
public key. Repeated bad codes are rate limited in the VPS Agent. A successful
claim disables pairing and returns the VPS public key, private management
address, and a random management token.

The hostname should be DNS-only when Cloudflare DNS is used. Tunnel traffic
must connect directly to the VPS rather than passing through a public CDN.

### Home Agent WireGuard

The Home Agent owns `10.88.0.2/32`. Its generated configuration routes only
`10.88.0.0/24`; ordinary internet traffic does not use the VPS.

VPS management is available at `10.88.0.1:4174` only when both controls pass:

- The socket source is exactly `10.88.0.2` or VPS loopback.
- `X-Tater-Management-Token` matches the random token created during claim.

The token and Home Agent private key are stored in state files with mode
`0600`. They are removed from API responses shown to the browser.

### Remote Device WireGuard

Each approved remote device receives a unique key and exact `/32` tunnel
address. Device profiles route only `10.88.0.0/24`, so this is not a full
internet VPN.

The VPS routes the allowed private service range back through the Home Agent
peer. Devices cannot use the VPS management API because source checks allow
only `10.88.0.2`.

## Private Services

The Home Agent creates one raw TCP or UDP listener per approved service on
`10.88.0.2:30000-30999`. Each listener has exactly one configured local target.
No HTTP proxy, path rewriting, public hostname, or application credential is
created by Tater Tunnel.

Raw forwarding is intentionally protocol-neutral. Authentication inside Tater,
Matrix, Emby, or another app remains that app's responsibility.

The Home Agent UI and API are never private service targets. Requests whose
source is in `10.88.0.0/24` are rejected by the local control server, and route
validation rejects its local admin port.

## Firewall Boundary

The recommended UFW configuration:

- Opens `51888/udp` publicly for WireGuard.
- Opens `80/tcp` and `443/tcp` for Caddy and ACME.
- Denies public access to TCP `4174`.
- Allows TCP `4174` on `tater0` only from `10.88.0.2`.
- Allows routed TCP and UDP `30000-30999` on `tater0` only toward
  `10.88.0.2`.
- Defaults incoming and routed traffic to deny.

The VPS Agent repeats the management source and token checks, so a reverse
proxy or firewall mistake does not by itself expose management endpoints.

## Revocation

Revoking a device removes its public key and exact Allowed IP from the VPS
WireGuard configuration. The copied profile stops working after removal.
Application sessions may remain valid inside the target service and should be
revoked there when needed.

## Compromise Notes

### Compromised VPS

The VPS holds WireGuard peer metadata and routes encrypted device traffic to
the Home Agent. A fully compromised VPS can add peers, inspect tunnel metadata,
or connect to configured private service listeners while the Home Agent is
online. Tater Tunnel limits the reachable home surface, but cannot make an
untrusted VPS safe.

Use a dedicated, patched VPS; SSH keys; disabled root/password login; UFW; and
the included security audit.

### Compromised Home Agent

The Home Agent stores its private key, VPS management token, device inventory,
and local service targets. A compromised Home Agent has the same access to
those services as the local operating-system account.

### Stolen Device Profile

A copied WireGuard profile has the same network authority as the original until
revoked. Tater Tunnel does not replace application-level login, MFA, or session
revocation.

## Clean Migration

Schema-v1 HTTPS relay state is not upgraded in place. Both agents replace it
with clean schema-v2 state and require a fresh pairing. This deliberately
prevents retired relay credentials, routes, and assumptions from surviving the
WireGuard-only boundary.
