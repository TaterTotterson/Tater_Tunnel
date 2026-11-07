# Tater Tunnel MVP Spec

## Product Promise

Private remote access to selected home apps through a user-owned VPS, without
opening inbound ports at home or publishing those apps on the web.

## User Journey

1. Install the VPS Agent with the guided script.
2. Enter the VPS HTTPS URL and one-time code in the Home Agent.
3. Approve the WireGuard system extension when the native app requests it.
4. The Home Agent connects to the VPS as `10.88.0.2`.
5. Add a phone, tablet, laptop, or desktop.
6. Scan its QR code with WireGuard or import the generated configuration.
7. Add an explicit TCP or UDP service target in the Home Agent.
8. Open the displayed `10.88.0.2:PORT` address from the connected device.
9. Revoke the device when it should no longer have access.

## VPS Agent

Responsibilities:

- Configure the `tater0` WireGuard interface.
- Accept one public HTTPS claim through Caddy.
- Assign the Home Agent the reserved `10.88.0.2/32` identity.
- Authenticate private management by source address and random token.
- Add and remove exact `/32` device peers.
- Expose only the landing page and claim endpoint publicly.
- Report private health and WireGuard diagnostics.

Non-responsibilities:

- No public dashboard.
- No public app proxy.
- No local app credentials.
- No access decisions inside a target app.

## Home Agent

Responsibilities:

- Create and maintain its WireGuard identity.
- Keep the UI and control API local.
- Create and revoke remote device peers.
- Create explicit raw TCP or UDP service forwards.
- Show tunnel, device, and listener status.
- Render one-time WireGuard QR enrollment data.

## Product Screens

### Step 1: Connect Your VPS

- VPS HTTPS URL.
- One-time pairing code.
- WireGuard connection status.
- Check, reconnect, and local reset actions.

### Step 2: Approved Devices

- Person, device name, and type.
- Live handshake and transfer status when available.
- One-time enrollment QR.
- Revoke action.

### Step 3: Private Services

- Preset or custom service.
- Local hostname/IP and port.
- TCP or UDP protocol.
- Allocated tunnel port in `30000-30999`.
- Displayed device address and connection test.

## Platforms

- macOS app: bundled WireGuardKit Network Extension.
- Docker/Linux: bundled or installed WireGuard tools with `NET_ADMIN` and TUN.
- Remote phones/computers: standard WireGuard clients.
- Windows native Home Agent: future work; Docker remains available where host
  networking and TUN support meet the required routing model.

## Explicit Non-Goals

- Full internet VPN routing.
- Whole-LAN routing.
- Public app hostnames.
- Multiple VPS or multiple Home Agent sites.
- Temporary guest roles.
- Application login or MFA replacement.
- Compatibility fallback to the retired HTTPS relay.

## Release Criteria

- Public HTTPS exposes only bootstrap resources.
- Pairing closes after one successful claim.
- Home management requires `10.88.0.2` and the management token.
- Devices receive unique key pairs and exact tunnel addresses.
- Revocation removes the live peer.
- Private service listeners bind only to `10.88.0.2`.
- Local control rejects tunnel-originated requests.
- Installer applies deny-by-default firewall routing.
- Security tests, Python compile checks, shell checks, Docker build, and macOS
  universal build all pass.
