from __future__ import annotations

import base64
import secrets
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

        try:
            return self._generate_with_cryptography()
        except RuntimeError:
            return self._generate_with_python()

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

    def _generate_with_python(self) -> KeyPair:
        private_key_bytes = secrets.token_bytes(32)
        public_key_bytes = self._public_key_bytes(private_key_bytes)
        return KeyPair(
            private_key=base64.b64encode(private_key_bytes).decode("ascii"),
            public_key=base64.b64encode(public_key_bytes).decode("ascii"),
            source="python",
        )

    @classmethod
    def _public_key_bytes(cls, private_key: bytes) -> bytes:
        return cls._x25519(private_key, 9)

    @staticmethod
    def _x25519(scalar_bytes: bytes, u_coordinate: int) -> bytes:
        if len(scalar_bytes) != 32:
            raise ValueError("WireGuard private keys must be 32 bytes")

        prime = 2**255 - 19
        scalar = bytearray(scalar_bytes)
        scalar[0] &= 248
        scalar[31] &= 127
        scalar[31] |= 64
        scalar_int = int.from_bytes(scalar, "little")

        x1 = u_coordinate
        x2 = 1
        z2 = 0
        x3 = u_coordinate
        z3 = 1
        swap = 0

        for bit_index in range(254, -1, -1):
            bit = (scalar_int >> bit_index) & 1
            swap ^= bit
            if swap:
                x2, x3 = x3, x2
                z2, z3 = z3, z2
            swap = bit

            a = (x2 + z2) % prime
            aa = (a * a) % prime
            b = (x2 - z2) % prime
            bb = (b * b) % prime
            e = (aa - bb) % prime
            c = (x3 + z3) % prime
            d = (x3 - z3) % prime
            da = (d * a) % prime
            cb = (c * b) % prime
            x3 = pow(da + cb, 2, prime)
            z3 = (x1 * pow(da - cb, 2, prime)) % prime
            x2 = (aa * bb) % prime
            z2 = (e * (aa + 121665 * e)) % prime

        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2

        return ((x2 * pow(z2, prime - 2, prime)) % prime).to_bytes(32, "little")
