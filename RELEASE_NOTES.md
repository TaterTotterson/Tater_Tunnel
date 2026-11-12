# Tater Tunnel v0.3.1

This hotfix corrects the VPS CPU reading in the new Control Center.

## Fixed

- CPU usage now comes from actual Linux processor-time deltas in `/proc/stat`.
- The one-minute system load remains available as separate diagnostic data and
  is no longer presented as CPU utilization.
- Readings are averaged between dashboard polls, avoiding the misleading 100%
  display commonly seen on otherwise idle single-core VPS installations.

This update preserves the existing pairing, devices, routes, and optional-app
configuration.
