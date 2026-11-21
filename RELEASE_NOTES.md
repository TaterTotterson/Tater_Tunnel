# Tater Tunnel v0.5.4

Fixes Kuma database ownership and prevents VPS updates from resetting
container data permissions.

## Database Permissions

- Stop systemd from recursively assigning the control helper's owner/group to
  persistent app storage. Container data keeps its app-specific ownership
  through VPS updates and control-helper restarts.
- Prepare Kuma data for its embedded database user, `1000:1000`, during
  installation. Enable and restart also repair existing data ownership.
- Keep the data directory private, skip symlinks, reject storage on another
  filesystem, and tolerate temporary files disappearing during repair.
- Do not reset databases or switch database types automatically.
- Document backup-first recovery for embedded MariaDB setups that were
  interrupted before their internal system tables were created.

## Updating And Testing

- Update the VPS Agent from Control Center's **Updates** view first. No Home
  Agent update or re-pairing is required for these server-side fixes.
- An existing incomplete MariaDB setup still needs the documented recovery
  procedure or a clean reinstall. Ownership repair alone cannot create its
  missing system tables.
- For a disposable clean-install test, uninstall Kuma and explicitly choose
  **Delete data**, then reinstall. Keeping data also keeps the incomplete
  database. Do not choose deletion for data you need to retain.
- The macOS app, Docker image, and signed VPS archive share the v0.5.4 tag.

## Verification

- All 106 local regression tests pass.
- Isolated container tests verified fresh SQLite and embedded MariaDB setup,
  recovery after an ownership reset, and repeated repair/restart behavior.
- Reproduced missing MariaDB system tables, verified backup-first
  initialization restored the setup page, and checked the retained data and
  backup contents.
- No live VPS data was removed during verification.
