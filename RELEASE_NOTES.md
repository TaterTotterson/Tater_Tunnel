# Tater Tunnel v0.2.4

This patch fixes device enrollment and private management requests on network
paths that cannot carry the previous WireGuard packet size.

## Reliable private tunnel

- The VPS, Home Agent, and generated device profiles now use a conservative
  1280-byte MTU to avoid silent packet loss on constrained VPS and mobile paths.
- Device approval and revocation return compact acknowledgements instead of
  sending the complete VPS state through the private tunnel.
- Live WireGuard diagnostics omit internal details that the Home Agent does not
  need, keeping routine management responses small.
- Generated phone QR profiles inherit the safe MTU automatically.
