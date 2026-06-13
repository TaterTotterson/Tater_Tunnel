from __future__ import annotations

import base64
import shutil
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class KeyPair:
    private_key: str
    public_key: str
    source: str


class WireGuardKeyProvider:
    """Generate WireGuard key material behind a small replaceable boundary."""

    def generate_keypair(self) -> KeyPair:
        if shutil.which("wg"):
            return self._generate_with_wg()

        return self._generate_with_cryptography()

    def _generate_with_wg(self) -> KeyPair:
        private_result = subprocess.run(
            ["wg", "genkey"],
            check=True,
            capture_output=True,
            text=True,
        )
        private_key = private_result.stdout.strip()
        public_result = subprocess.run(
            ["wg", "pubkey"],
            check=True,
            capture_output=True,
            input=f"{private_key}\n",
            text=True,
        )
        return KeyPair(
            private_key=private_key,
            public_key=public_result.stdout.strip(),
            source="wg",
        )

    def _generate_with_cryptography(self) -> KeyPair:
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric import x25519
        except ImportError as error:
            raise RuntimeError("WireGuard key generation requires wg or the cryptography Python package") from error

        private = x25519.X25519PrivateKey.generate()
        private_key = base64.b64encode(
            private.private_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PrivateFormat.Raw,
                encryption_algorithm=serialization.NoEncryption(),
            )
        ).decode("ascii")
        public_key = base64.b64encode(
            private.public_key().public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
        ).decode("ascii")
        return KeyPair(private_key=private_key, public_key=public_key, source="cryptography")
