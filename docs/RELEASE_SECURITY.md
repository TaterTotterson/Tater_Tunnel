# VPS Release Signing

Tagged releases run `.github/workflows/vps-release.yml`. The workflow builds a
source archive, records its SHA-256 digest and release tag, signs the manifest,
verifies the result, and attaches all three files to the GitHub release:

- `tater-tunnel-vps.tar.gz`
- `vps-release.json`
- `vps-release.json.sig`

The Ed25519 private key is supplied by the repository Actions secret
`TATER_TUNNEL_VPS_SIGNING_KEY`. Only its public key is committed in
`scripts/release-allowed-signers`. Signing uses the dedicated
`release@tatertunnel.com` namespace and `tater-tunnel-release` identity.

The VPS updater uses its already-installed verifier and allowed-signers file.
It never takes a replacement key from a downloaded manifest. Verification
covers the signature, repository identity, tag, archive digest, archive paths,
entry types, extraction size, and packaged version before executing the
installer. Updates to older versions are rejected.

Protect the signing secret, repository write access, release tags, and runners.
Keep an offline backup of the private key. Key rotation requires a release
signed by the existing key that installs the new trusted public key before
future releases depend on it. If the current key is lost, recover by installing
a trusted new version manually.

The first installation and manual recovery script are trust-on-first-use. The
download source and initial public key must be trusted by the administrator.

The macOS updater separately verifies the app's Developer ID team identity.
