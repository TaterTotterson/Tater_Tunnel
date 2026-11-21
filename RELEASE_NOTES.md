# Tater Tunnel v0.5.2

Adds complete app lifecycle controls so disabled apps can be enabled or removed
without getting stuck in the Control Center.

## App Management

- Add a direct **Enable** action for stopped or disabled apps. Uses saved
  configuration without running the installer again.
- Add **Uninstall** for SFTPGo, ZNC, Uptime Kuma, ntfy, Forgejo, and Matrix.
- Keep app data and settings by default when uninstalling. The catalog shows
  **Data kept** and offers **Reinstall** afterward.
- Offer permanent data deletion separately. It requires typing the exact app
  name and confirming; the backend enforces those confirmations too.
- Remove the selected app's runtime, startup entry, and managed access when
  uninstalling. Shared Docker images, system dependencies, external storage,
  and ZNC Linux accounts are kept.
- Refuse unsafe data paths and unmanaged mounted storage. Multiple ZNC
  services require manual package removal over SSH.

## Interface Fixes

- Distinguish disabled apps from stopped apps and apps with retained data.
- Restore controls and clear the progress indicator if a job cannot start.
- Prevent conflicting app actions while a job is running.
- Make lifecycle buttons and uninstall confirmation usable on mobile.

## Updating

- Update the VPS Agent first, then the Home Agent to get the new controls.
  Updating does not delete app data or require re-pairing.
- If an old stuck installation blocks Control Center updates, run the VPS
  setup script over SSH and choose **Update Tater Tunnel** first.
- The macOS app, Docker image, and signed VPS archive share the v0.5.2 tag.

## Verification

- All 97 local regression tests pass.
- Checked desktop and mobile UI behavior with an isolated preview, including
  Enable, rejected-job recovery, deletion confirmation, and Reinstall states.
- No live VPS data was deleted during testing.
