# Tater Tunnel v0.2.8

This update simplifies optional-service exposure while keeping each service's
intended audience in mind.

## Optional service access

- SFTPGo is publicly available on TCP `2022` using SFTP so separate users can
  connect with their own SFTPGo accounts. Legacy FTP is not enabled.
- SFTPGo WebAdmin remains private on `127.0.0.1:8080` for SSH-forwarded setup.
- ZNC is available at `10.88.0.1` on the listener port selected during setup.
- The installer no longer asks for ZNC or SFTP subdomains or offers to open
  optional ports through additional prompts.
- UFW keeps ZNC WireGuard-only and automatically permits the public SFTPGo
  listener while leaving WebAdmin private.
- The update path removes the retired public ZNC Caddy route and replaces old
  optional-service firewall rules with the intended access policy.
- The VPS security audit now checks these optional-service boundaries.
