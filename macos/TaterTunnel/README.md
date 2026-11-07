# Tater Tunnel macOS App

This is the signed menu bar Home Agent for Tater Tunnel. It includes an
official WireGuardKit packet tunnel system extension, so users do not install
or import the Home Agent connection into a separate WireGuard app.

[Download Tater Tunnel for macOS](https://github.com/TaterTotterson/Tater_Tunnel/releases/latest)

It starts the local Home Agent on:

```text
http://127.0.0.1:4173/
```

After the VPS is claimed, the app detects the generated configuration and asks
macOS to approve the Tater Tunnel system extension and VPN configuration. The
tunnel uses split routing for `10.88.0.0/24`; normal internet traffic is
unchanged.

## Build

```bash
macos/TaterTunnel/scripts/build_app.sh
```

The build installs no dependency globally except the required `xcodegen`
command. It clones the pinned official WireGuard Apple source into the ignored
`Generated/` directory, generates the Xcode project, and builds a universal
app. An unsigned local build is ad-hoc signed for structural verification.

Developer ID releases require app and system-extension provisioning profiles
with the Network Extension capabilities. Store the complete base64-encoded
profile files as GitHub Actions secrets:

```text
TATER_TUNNEL_APP_PROFILE_BASE64
TATER_TUNNEL_EXTENSION_PROFILE_BASE64
```

The release workflow validates and installs both profiles, then discovers their
names automatically. For an already-provisioned self-hosted runner, repository
variables `TATER_TUNNEL_APP_PROFILE` and `TATER_TUNNEL_EXTENSION_PROFILE` remain
available as a fallback.

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

Schema-v1 HTTPS relay state is deliberately reset. Users update the VPS,
reopen pairing, and connect again to create the new WireGuard-only identity.
