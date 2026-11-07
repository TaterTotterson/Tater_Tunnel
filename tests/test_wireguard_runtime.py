from __future__ import annotations

import base64
import subprocess
import tempfile
import unittest
from pathlib import Path

from tater_tunnel.wireguard_runtime import WireGuardSystemRuntime


PRIVATE_KEY = base64.b64encode(b"k" * 32).decode("ascii")
HOME_PUBLIC_KEY = base64.b64encode(b"h" * 32).decode("ascii")
VPS_PUBLIC_KEY = base64.b64encode(b"v" * 32).decode("ascii")


class RecordingRunner:
    def __init__(self):
        self.calls: list[tuple[list[str], str | None]] = []

    def which(self, command: str) -> str | None:
        return f"/usr/bin/{command}" if command in {"wg", "ip"} else None

    def system(self) -> str:
        return "Linux"

    def run(
        self,
        command: list[str],
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self.calls.append((command, input_text))
        return subprocess.CompletedProcess(command, 0, "", "")


class WireGuardRuntimeTests(unittest.TestCase):
    def test_system_runtime_passes_setconf_over_stdin(self):
        state = {
            "claimed": True,
            "wireguardPort": 51888,
            "interface": {
                "address": "10.88.0.1/24",
                "network": "10.88.0.0/24",
                "wireguard": {
                    "privateKey": PRIVATE_KEY,
                    "publicKey": VPS_PUBLIC_KEY,
                },
            },
            "homeAgent": {
                "id": "home-agent",
                "publicKey": HOME_PUBLIC_KEY,
                "allowedIp": "10.88.0.2/32",
            },
            "peers": [],
        }

        with tempfile.TemporaryDirectory() as directory:
            runner = RecordingRunner()
            config_path = Path(directory) / "tater0.conf"
            runtime = WireGuardSystemRuntime(config_path, runner=runner)
            runtime.apply(state)

            setconf_calls = [
                call for call in runner.calls if call[0][:2] == ["wg", "setconf"]
            ]
            self.assertEqual(len(setconf_calls), 1)
            command, input_text = setconf_calls[0]
            self.assertEqual(command, ["wg", "setconf", "tater0", "/dev/stdin"])
            self.assertIn(f"PrivateKey = {PRIVATE_KEY}", input_text or "")
            self.assertNotIn("Address =", input_text or "")
            self.assertEqual(list(config_path.parent.glob("*.setconf.*")), [])


if __name__ == "__main__":
    unittest.main()
