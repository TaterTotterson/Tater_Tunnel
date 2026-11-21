#!/usr/bin/env python3
"""Verify a VPS release against the installed signing key before extracting it."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tarfile
from pathlib import Path, PurePosixPath


def verify_release(manifest, signature, archive, allowed_signers, tag, destination):
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Release tag is invalid")
    if manifest.stat().st_size > 16 * 1024 or signature.stat().st_size > 16 * 1024:
        raise ValueError("Release metadata is too large")
    metadata_bytes = manifest.read_bytes()
    verification = subprocess.run(
        ["ssh-keygen", "-Y", "verify", "-f", str(allowed_signers), "-I", "tater-tunnel-release",
         "-n", "release@tatertunnel.com", "-s", str(signature)],
        input=metadata_bytes, capture_output=True, timeout=15,
    )
    if verification.returncode:
        raise ValueError("VPS release signature is not trusted")
    metadata = json.loads(metadata_bytes)
    if metadata.get("tag") != tag or metadata.get("repository") != "TaterTotterson/Tater_Tunnel":
        raise ValueError("Signed release identity does not match")
    if not re.fullmatch(r"[0-9a-f]{64}", str(metadata.get("sha256") or "")):
        raise ValueError("Signed archive checksum is invalid")
    if archive.stat().st_size > 100 * 1024 * 1024:
        raise ValueError("VPS archive is too large")
    with archive.open("rb") as handle:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
        digest = hasher.hexdigest()
    if digest != metadata["sha256"]:
        raise ValueError("VPS archive checksum does not match the signed release")
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        if len(members) > 10000 or sum(member.size for member in members) > 250 * 1024 * 1024:
            raise ValueError("VPS archive exceeds extraction limits")
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "tater-tunnel":
                raise ValueError("VPS archive has an unsafe path")
            if not member.isfile() and not member.isdir():
                raise ValueError("VPS archive contains a link or special file")
        destination.mkdir(mode=0o700, parents=True, exist_ok=False)
        for member in members:
            path = destination.joinpath(*PurePosixPath(member.name).parts[1:])
            if member.isdir():
                path.mkdir(mode=0o755, parents=True, exist_ok=True)
            else:
                path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                with source.extractfile(member) as incoming, path.open("xb") as output:
                    shutil.copyfileobj(incoming, output)
                path.chmod(0o644)
    packaged = destination / "tater_tunnel" / "__init__.py"
    if not re.search(r'^__version__ = "' + re.escape(tag[1:]) + '"$', packaged.read_text(), re.MULTILINE):
        raise ValueError("Signed archive version does not match the release tag")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("manifest", "signature", "archive", "allowed-signers", "destination"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    try:
        verify_release(args.manifest, args.signature, args.archive, args.allowed_signers, args.tag, args.destination)
    except (ValueError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Release verification failed: {error}\n")


if __name__ == "__main__":
    main()
