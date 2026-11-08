# Next release

- SFTPGo setup now offers SFTP, FTP, WebDAV, or any combination, with managed
  firewall boundaries for every listener.
- External WebDAV uses a dedicated Caddy subdomain with automatic HTTPS while
  its backend port remains blocked publicly.
- The standalone SFTPGo wizard can create the WebDAV DNS-only Cloudflare record;
  blank-VPS setup creates tunnel and WebDAV records with one token prompt.
- FTP passive ports are configured and managed together with its control port.
- Rerunning setup removes stale allow rules for protocols that are disabled.
- The VPS setup console now uses a black, orange, and gray Tater theme.
- Progress windows no longer interrupt the underlying installer and now report
  the real command status with useful failure details.
- Dialog accents use portable terminal yellow/amber instead of red.
- Completed and failed actions return to the main setup menu; only Exit closes
  the setup console during normal use.
- New sudo accounts no longer inherit root's potentially unrelated SSH keys;
  setup documentation now uses the standard `ssh-copy-id USER@SERVER` flow.
- Cloudflare setup now collects API tokens in a masked dialog with normal
  OK/Cancel controls instead of waiting for input inside the progress window.
- The guided security audit can repair stale managed firewall and optional
  service boundaries before verifying them.
- The UFW audit recognizes both verbose rules and UFW's normalized
  `deny PORT/tcp` output, avoiding false missing-deny failures.
- SFTPGo protocol setup now applies the SFTP, FTP, and WebDAV checklist choices
  directly, including output from `dialog` versions that quote selected tags.
- SFTPGo setup now verifies every requested listener and waits for external
  WebDAV HTTPS to become usable before reporting a successful installation.
- The optional SFTPGo menu now verifies its selected protocol modes against the
  saved SFTPGo environment after installation and shows the applied result.
- The full-screen SFTPGo menu now proceeds directly from the optional storage
  cap into installation; canceling the cap safely continues without one.
- SFTPGo updates now detect and preserve an existing managed storage image
  instead of suggesting a smaller cap that the installer must safely reject.
- Interactive ZNC configuration now leaves the read-only progress viewer and
  receives the terminal directly before returning to the setup console.

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
