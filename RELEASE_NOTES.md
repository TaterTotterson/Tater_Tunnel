# Tater Tunnel v0.5.3

Fixes private connections to managed Docker apps that appeared to be running
but could not load through WireGuard.

## Private App Connectivity

- Correct the container firewall so it permits reply packets returning through
  Docker's bridge while still blocking incoming connections outside WireGuard.
- Apply the shared fix to Uptime Kuma, ntfy, Forgejo, and Matrix. SFTPGo and ZNC
  run natively and are not affected by this Docker firewall issue.
- Refresh existing container firewall rules atomically during VPS updates,
  without restarting Docker to apply the rule change. The corrected guard is
  restored at boot and on Docker restart.
- Update the security audit to reject the old rule that blocked legitimate
  replies.

## Updating

- Install the VPS Agent update from Control Center's **Updates** view, or run
  the VPS setup script and choose **Update Tater Tunnel**.
- No managed app reinstall, data deletion, re-pairing, or Home Agent update is
  required for this fix. The update also replaces any temporary reply-allow
  rule used to restore access while troubleshooting.
- The macOS app, Docker image, and signed VPS archive share the v0.5.3 tag.

## Verification

- All 100 local regression tests pass, including firewall, audit, and updater
  checks.
- Isolated packet-flow tests reproduced the old timeout, verified HTTP 200
  through the corrected guard, and confirmed off-tunnel access remains blocked.
- Tested the actual guard script twice to verify rules can be reapplied.
- Confirmed Kuma access was restored on the live VPS with the temporary rule.
