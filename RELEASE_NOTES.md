# Tater Tunnel v0.2.9

This update simplifies optional-service exposure while keeping each service's
intended audience in mind.

## Optional service access

- SFTPGo setup now asks whether TCP `2022` should be WireGuard-only or public
  for separate users. WireGuard-only is the secure default.
- Public mode uses SFTP with individual SFTPGo accounts. Legacy FTP is not
  enabled.
- SFTPGo WebAdmin remains private on `127.0.0.1:8080` for SSH-forwarded setup.
- ZNC is available at `10.88.0.1` on the listener port selected during setup.
- The installer no longer asks for ZNC or SFTP subdomains or offers to open
  optional ports through additional prompts.
- UFW keeps ZNC WireGuard-only and applies the selected SFTPGo access mode while
  leaving WebAdmin private.
- The update path removes the retired public ZNC Caddy route and replaces old
  optional-service firewall rules while preserving an existing public/private
  SFTPGo choice.
- The VPS security audit now checks these optional-service boundaries.
