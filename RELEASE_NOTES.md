# What's New in Tater Tunnel v0.1.13

- Restricted every relay request to the exact `/32` address of an active WireGuard peer and rejected malformed, broad, reserved, or invalid-key peer records.
- Removed the development loopback relay bypass entirely and made device revocation close active relayed WebSocket sessions.
- Added startup reconciliation of the sanitized WireGuard peer list and managed-interface removal on reset so stale peers cannot survive a reboot or reset.
- Made health checks read-only, serialized peer mutations, and made reset close active relayed WebSockets so concurrent status traffic cannot undo revocation.
- Updated the normal VPS update path to repair older generated Caddy configurations that exposed `/relay` publicly.
- Replaced broad agent-port firewall rules with an interface-specific `tater0` allow and an explicit public deny, while adding SSH rate limiting and routed-traffic denial to fresh installs.
- Strengthened the VPS systemd sandbox with namespace, executable-memory, hostname, clock, and socket-bind restrictions.
- Added a read-only VPS security audit covering service hardening, state permissions, peer scope, pairing state, Caddy, UFW, and agent-level relay rejection.

Existing named app routes, valid device peers, pairing state, WireGuard configuration, SFTPGo accounts, and ZNC configuration are preserved.

After installing this release, run:

```bash
sudo /opt/tater-tunnel/scripts/audit-vps-security.sh --domain tunnel.example.com
```

**Full changelog:** https://github.com/TaterTotterson/Tater_Tunnel/compare/v0.1.12...v0.1.13
