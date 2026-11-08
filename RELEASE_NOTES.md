# Tater Tunnel v0.2.12

This release makes the VPS setup console easier to operate and turns ZNC and
SFTPGo into guided, securely bounded optional services.

## Guided optional services

- SFTPGo setup now offers SFTP, FTP, WebDAV, or any combination and applies the
  selected listeners automatically.
- SFTP and FTP can remain WireGuard-only or be deliberately opened for public
  clients. External WebDAV uses a dedicated Caddy hostname with automatic HTTPS.
- Cloudflare DNS-only records can be created from a one-time masked API-token
  prompt; the token is not saved.
- Existing managed SFTPGo storage caps are detected and preserved during
  updates, and setup verifies every requested listener before reporting success.
- First-time ZNC setup now asks only for an administrator login and creates the
  private IRC listener, private WebAdmin listener, hashed password, systemd
  service, and firewall rules automatically.
- Existing ZNC users and networks are preserved while managed listeners are
  reconciled, and credential entry now moves cleanly into the review screen.

## Setup and security

- The full-screen VPS console uses a black and amber Tater theme, keeps progress
  output visible, and returns completed or failed actions to the main menu.
- SFTPGo and ZNC firewall rules are reconciled on every setup run, including
  removal of stale access for protocols that have been disabled.
- The guided security audit can repair managed firewall boundaries before
  checking them and recognizes UFW's normalized deny-rule output.
- Optional-service administration remains private to Tater Tunnel WireGuard,
  while explicitly selected public file-transfer listeners keep their own exact
  firewall boundaries.
- SSH setup documentation now uses the standard `ssh-copy-id USER@SERVER` flow
  and provides the commands for disabling password and root login after key
  access has been verified.
