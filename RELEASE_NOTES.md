# Tater Tunnel v0.2.5

This patch fixes device QR enrollment being left on "Generating code" even
though the VPS had already created the device.

## Reliable device enrollment

- WireGuard peer changes now use `syncconf`, preserving the Home Agent peer's
  live endpoint and handshake while a phone or laptop is added or revoked.
- The enrollment response carrying the private device configuration can return
  through the same tunnel without the VPS interrupting it.
- The macOS app now detects a changed tunnel profile, stops the old Network
  Extension connection, and starts it again with the updated settings.
- Existing pairing, routes, and approved devices are preserved during updates.
