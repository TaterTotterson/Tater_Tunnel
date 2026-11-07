# What's New in Tater Tunnel v0.1.12

- Closed public access to `/relay` in the generated Caddy configuration.
- Added VPS-side enforcement requiring every relay connection to originate from an active WireGuard peer address.
- Removed the built-in relay route to the Home Agent UI and administration API; only explicit named app routes can be relayed.
- Added pairing attempt throttling, longer fresh pairing codes, bounded request and WebSocket resources, safer error responses, and query-free request logs.
- Removed persisted device enrollment tokens from Home Agent state and strengthened the VPS systemd sandbox.
- Added Developer ID and Team ID verification before the macOS updater installs future releases.
- Added automated regression tests for the relay boundary and corrected the documented trust model.

Existing named app routes, device peers, pairing state, WireGuard configuration, SFTPGo accounts, and ZNC configuration are preserved. The legacy `tunnel` route is removed automatically.

**Full changelog:** https://github.com/TaterTotterson/Tater_Tunnel/compare/v0.1.11...v0.1.12
