# Tater Tunnel v0.2.2

This patch keeps the Home Agent connected when optional live WireGuard
diagnostics are slow or unavailable.

## Connection reliability

- A successful authenticated VPS health check now remains authoritative even
  when live peer diagnostics time out.
- VPS diagnostic commands and the complete diagnostics request have bounded
  deadlines, preventing a stalled OS probe from making the UI report that the
  private tunnel is down.
- Existing VPS pairing, WireGuard keys, devices, and private service routes are
  preserved during the update.
