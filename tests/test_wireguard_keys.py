import base64
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import x25519

from tater_tunnel.wireguard import WireGuardKeyProvider


class WireGuardKeyProviderTest(unittest.TestCase):
    def test_cryptography_fallback_generates_matching_public_key(self):
        with patch("shutil.which", return_value=None):
            keypair = WireGuardKeyProvider().generate_keypair()

        private = x25519.X25519PrivateKey.from_private_bytes(base64.b64decode(keypair.private_key))
        public_key = base64.b64encode(
            private.public_key().public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
        ).decode("ascii")

        self.assertEqual(keypair.source, "cryptography")
        self.assertEqual(keypair.public_key, public_key)


if __name__ == "__main__":
    unittest.main()
