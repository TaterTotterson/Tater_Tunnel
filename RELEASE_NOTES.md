# Next release

- SFTPGo setup now offers SFTP, FTP, WebDAV, or any combination, with managed
  firewall boundaries for every listener.
- External WebDAV uses a dedicated Caddy subdomain with automatic HTTPS while
  its backend port remains blocked publicly.
- FTP passive ports are configured and managed together with its control port.
- Rerunning setup removes stale allow rules for protocols that are disabled.
- The VPS setup console now uses a black, orange, and gray Tater theme.

# Tater Tunnel v0.2.11

This update makes VPS setup easier to follow and gives optional services
reliable browser interfaces without exposing their administration pages.

## Full-screen VPS setup

- The guided installer now uses the proven `dialog` ncurses interface for its
  main menu, prompts, confirmation screens, live logs, setup notes, and final
  pairing screen.
- Arrow-key navigation and contextual help replace the hand-drawn menu.
- A numbered text fallback remains available for noninteractive terminals and
  recovery use.
- Review screens summarize the selected network and service boundaries before
  setup changes anything.

## Private optional-service administration

- SFTPGo WebAdmin is now available at
  `http://10.88.0.1:8080/web/admin` while connected through Tater Tunnel
  WireGuard.
- ZNC now uses a dedicated WebAdmin listener at
  `http://10.88.0.1:6698/`, fixing blank browser responses from its IRC
  listener.
- UFW explicitly allows both WebAdmin listeners only on `tater0` and blocks
  their ports on public interfaces.
- ZNC IRC remains on the selected listener port, separate from WebAdmin.
- The normal update path migrates existing SFTPGo and ZNC installs to these
  private listeners and preserves SFTPGo's public or WireGuard-only SFTP mode.
- The VPS security audit verifies the new WireGuard-only firewall boundaries.
