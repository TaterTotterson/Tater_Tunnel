# Tater Tunnel v0.2.3

This patch makes device enrollment reliable on VPS hosts that take longer to
apply WireGuard peer changes.

## Device enrollment

- Pairing, device approval, and device revocation now use a dedicated bounded
  timeout sized for WireGuard configuration changes.
- Retrying an enrollment safely replaces an incomplete peer that used the same
  tunnel address instead of accumulating duplicates.
- VPS health responses now report the running Tater Tunnel version, making
  future deployment checks straightforward.
- The guided VPS installer now continues after creating an admin user and uses
  that account automatically for user-owned services.
