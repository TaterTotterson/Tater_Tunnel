# Tater Tunnel v0.5.0

This release hardens the tunnel and expands the Control Center with four
allow-listed VPS apps.

## Tunnel Security

- Serve only approved UI assets; private state, source, dotfiles, and symlinks
  cannot be downloaded through the Home Agent web server.
- Require loopback access, a browser session, matching Origin, and CSRF tokens
  for dashboard changes. macOS traffic counters and Docker health checks use
  separate minimal status endpoints.
- Expire unused pairing codes after 15 minutes without extending their deadline
  on restart. Validate pairing responses before creating tunnel configuration.
- Choose home services per device. Permission changes and revocation close
  existing forwarded connections. Existing devices retain their prior access.
- Bound API connections and forwarding workers across home services and close
  idle TCP forwards after five minutes.
- Verify signed VPS release archives against an installed Ed25519 key and
  reject unsigned, modified, and older releases before running their code.
- Keep privileged settings outside the unprivileged agent's writable state;
  add a persistent container forwarding guard and IPv6 firewall checks.
- Add credential-redacted security history and an independent network checker
  for public access, ordinary peers, revocation, and reboot comparisons.

## Managed Apps

- Install and manage Uptime Kuma, ntfy, Forgejo, and Matrix Synapse from the
  Home Agent.
- Choose WireGuard-only access or a dedicated public Caddy HTTPS hostname per
  app. Raw container web ports remain private in both modes.
- Use guarded defaults for administrators, registration, attachments, storage,
  PostgreSQL, Git SSH, and Matrix federation.
- Run version-pinned generated Compose definitions without accepting arbitrary
  images, Compose files, or commands from the browser.
- Audit managed app file modes, firewall rules, Caddy routes, and Docker port
  bindings from the System view.
- Start managed apps after WireGuard and the container firewall at boot;
  preserve generated database credentials when an installation is interrupted.

## Updating

- Update the VPS Agent first, then the Home Agent. Existing pairing, devices,
  and home service routes are preserved.
- Open the dashboard on the Home Agent computer at `http://127.0.0.1:4173`.
  Direct LAN dashboard access is now blocked. For a headless Home Agent, use
  `ssh -L 4173:127.0.0.1:4173 YOUR_USER@HOME_AGENT_HOST`.
- Existing devices retain their previous home service access. Use **Access**
  beside a device to select individual services. These permissions do not
  replace authentication for VPS-hosted apps.
- The macOS app, Linux Docker image, and signed VPS update archive are built
  from the same `v0.5.0` tag.
