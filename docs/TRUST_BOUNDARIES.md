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

Unused codes expire after 15 minutes. The deadline is stored and survives
restarts; restarting the service does not renew it. Legacy open pairing windows
without an expiry are closed. Reopening pairing creates a new window.

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

### VPS Control Helper

The browser never contacts a privileged VPS process. It talks to the local
Home Agent, which forwards authenticated requests through WireGuard to the
unprivileged VPS Agent. The VPS Agent validates the source address and
management token before accepting a control request.

The Home Agent accepts the dashboard and all APIs only from loopback, even when
bound to a LAN address. Accepted hosts are explicit loopback addresses and
`localhost`; resolving an arbitrary domain to loopback does not grant access.
Browser API calls require an eight-hour HttpOnly, SameSite=Strict session.
Mutations also require the matching Origin and session CSRF header. Health and
menu-bar traffic endpoints expose only status and counters. Static files are
limited to approved UI assets; state, code, dotfiles, and symlinks are excluded.

Privileged app and audit work is delegated over a mode-`0660` Unix socket to
`tater-tunnel-control`. The helper accepts only typed operations for SFTPGo,
ZNC, Uptime Kuma, ntfy, Forgejo, Matrix Synapse, service state, the security
audit, and the official VPS updater. It builds argument arrays for root-owned
scripts and never accepts shell text, arbitrary command names, container images,
or Compose definitions. Only one mutation job may run at a time.

The VPS updater has a fixed GitHub repository and accepts no repository URL,
branch, tag, package, or command from the browser. It selects only stable
semantic-version tags, verifies an Ed25519 signature using the installed trusted
release key, verifies the archive digest and version, rejects downgrades,
runs in a detached systemd unit, preserves tunnel state, and reapplies managed
firewall and proxy hardening before reporting success.

Privileged app configuration and updater state live under root-owned
`/etc/tater-tunnel-control` and `/var/lib/tater-tunnel-control`, outside the
unprivileged VPS Agent's writable directories. The release private key is held
in the GitHub Actions signing secret, never in the repository or VPS package.

ZNC passwords use a short-lived root-only file under `/run`. Cloudflare tokens
exist only in the child process environment for the DNS request. Neither is
stored in VPS Agent job history.

Container app settings use a short-lived mode-`0600` JSON file under `/run`.
Only fixed, version-pinned images and generated Compose definitions are used.
Raw web ports bind to loopback and `10.88.0.1`; public mode adds only a Caddy
HTTPS hostname. Application databases are not published to the host network.
The security audit verifies file modes, Caddy routes, UFW rules, and Docker port
bindings for each installed app.
An nftables forwarding guard also rejects traffic addressed to private Docker
bindings when it arrives outside `tater0`, before Docker forwarding rules run.
The guard is restored at boot and on Docker restart.

### Remote Device WireGuard

Each approved remote device receives a unique key and exact `/32` tunnel
address. Device profiles route only `10.88.0.0/24`, so this is not a full
internet VPN.

The VPS routes the allowed private service range back through the Home Agent
peer. Devices cannot use the VPS management API because source checks allow
only `10.88.0.2`.

Each home forwarding listener accepts only approved device source addresses
whose selected service list includes that listener. The optional all-services
mode also includes future home services. Existing devices without a policy
retain all-services mode. New devices default to an empty selection. Revocation
and permission changes close active TCP connections as well as updating future
access. These policies do not replace login within VPS-hosted applications.

Home forwarding shares a budget of 256 workers and 32 per source across all
services. API servers allow at most 64 connections and 16 per source. Idle TCP
forwards expire after five minutes. Request sizes and socket waits are bounded.

Security history stores up to 500 structured events in private mode-0600 files.
It records action names and resource identifiers, excludes submitted payloads,
and redacts submitted credentials from control-job errors and output. Root can
alter VPS history; it is not a remote tamper-proof audit ledger.

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

The VPS terminates both WireGuard connections and holds peer metadata. A fully
compromised VPS can add peers, inspect application traffic that is not protected
by application-level TLS, or connect to configured private service listeners
while the Home Agent is online. Tater Tunnel limits the reachable home surface,
but cannot make an untrusted VPS safe.

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
