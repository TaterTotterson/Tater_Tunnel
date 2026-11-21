# Tater Tunnel v0.5.1

Fixes managed VPS app installations getting stuck during firewall setup.

## Fixed

- Stop firewall cleanup when UFW reports that a rule no longer exists, even
  when UFW returns a successful exit status. Previously, installation could
  loop indefinitely after creating the container.
- Limit duplicate-rule cleanup and report genuine firewall failures, including
  IPv6 failures, instead of silently ignoring them.
- Applies to Uptime Kuma, ntfy, Forgejo, and Matrix installation and management.
  Existing private-access restrictions remain in place.

## Updating

- Update the VPS Agent, then retry the affected app's installation or saved
  configuration. Existing pairing, devices, app data, and settings are kept.
- If an installation is already stuck and blocks Control Center updates, run
  the VPS setup script over SSH and choose **Update Tater Tunnel** first.
- The fix is VPS-side; an existing v0.5.0 Home Agent can continue to be used.
  Matching macOS and Docker packages are also built for v0.5.1.

## Verification

- All 85 local regression tests pass.
- Verified absent-rule cleanup, existing-rule removal, and repeated cleanup
  against real UFW in an isolated Ubuntu 26.04 container.
