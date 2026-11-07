# Tater Tunnel v0.2.1

This patch fixes the macOS Home Agent VPN switching off immediately after it
was enabled.

## macOS Home Agent

- WireGuard configuration comments are now parsed correctly by the bundled
  packet-tunnel extension.
- Existing VPS pairing, keys, devices, and private service routes are preserved.
- The system extension remains signed with the Tater Tunnel Developer ID and
  retains the same split-tunnel network permissions introduced in v0.2.0.
