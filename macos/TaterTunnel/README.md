# Tater Tunnel macOS App

This is the menu bar wrapper for the Tater Tunnel Home Agent.

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

The app stores local state and logs under:

```text
~/.tatertunnel/
```
