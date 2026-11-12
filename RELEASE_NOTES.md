# Tater Tunnel v0.4.0

This release adds guarded VPS updates directly to the Control Center and makes
CPU activity easier to diagnose.

## VPS Updates

- The Updates view can install the newest official stable VPS release without
  an SSH session.
- The updater accepts no repository, branch, tag, package, or shell input from
  the browser.
- Only stable semantic-version tags from the official Tater Tunnel repository
  are considered, and the packaged version must match the selected tag.
- Pairing, WireGuard peers, service routes, and optional-app settings are
  preserved while managed proxy and firewall hardening is reapplied.
- Update progress survives the VPS Agent and control-helper restart and is
  reported back in the Home Agent UI.

## System Diagnostics

- The System view now lists the five busiest VPS processes with CPU and memory
  usage so a high CPU reading can be traced without opening a general shell.
- The dashboard shows one-minute system load beside the actual CPU utilization,
  keeping the two measurements clear.

## First Update

Install this release on the VPS once through the existing terminal setup menu.
After `v0.4.0` is installed, later stable VPS updates can be applied from the
Updates view.
