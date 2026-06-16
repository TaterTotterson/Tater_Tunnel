# Tater Tunnel macOS App

This is the signed menu bar wrapper for the Tater Tunnel Home Agent.

[Download Tater Tunnel for macOS](https://github.com/TaterTotterson/Tater_Tunnel/releases/latest)

It starts the local Home Agent on:

```text
http://127.0.0.1:4173/
```

## Build

```bash
macos/TaterTunnel/scripts/build_app.sh
```

## Package Update Zip

```bash
macos/TaterTunnel/scripts/package_update.sh
```

## Build DMG

```bash
macos/TaterTunnel/scripts/build_dmg.sh
```

## Updates

The menu bar app includes a `Check for Updates` item. It reads
`TaterTunnelUpdateManifestURL` from `Resources/Info.plist`, compares the
published manifest against the running app version, verifies the downloaded
update zip with SHA-256, then replaces and relaunches the app after user
confirmation.

The app stores local state and logs under:

```text
~/.tatertunnel/
```
