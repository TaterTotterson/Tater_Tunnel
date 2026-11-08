# Tater Tunnel v0.2.7

This security update moves the optional ZNC and SFTPGo services fully behind
Tater Tunnel WireGuard.

## Private optional services

- SFTPGo remains available to connected devices at `10.88.0.1:2022` using
  SFTP. Legacy FTP is not enabled.
- ZNC is available at `10.88.0.1` on the listener port selected during setup.
- The installer no longer asks for ZNC or SFTP subdomains or offers to open
  their client ports publicly.
- UFW allows each installed service only from `10.88.0.0/24` on `tater0` and
  adds an explicit deny on public interfaces.
- The update path removes the retired public ZNC Caddy route and replaces old
  broad firewall rules for detected optional services.
- The VPS security audit now checks these optional-service boundaries.
