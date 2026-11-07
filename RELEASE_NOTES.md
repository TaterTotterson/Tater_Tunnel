# What's New in Tater Tunnel v0.1.11

- Added optional SFTPGo installation with private first-admin setup, strong-password defaults, Defender protection, and automatic startup.
- Added a guided total-storage cap for SFTPGo local user data so uploads cannot consume the entire VPS disk.
- Added optional Cloudflare DNS-only record setup using a scoped token that is never stored.
- Added ZNC WebAdmin behind automatic Caddy HTTPS with a localhost-only backend and safer proxy/session defaults.
- Improved the blank VPS setup flow, service summaries, documentation, and update-safe configuration.

The existing Tater Tunnel pairing state, WireGuard configuration, SFTPGo accounts, and ZNC configuration are preserved during updates.

**Full changelog:** https://github.com/TaterTotterson/Tater_Tunnel/compare/v0.1.10...v0.1.11
