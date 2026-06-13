import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import ANY

from tater_tunnel.wireguard_runtime import (
    WireGuardRuntimeError,
    WireGuardSystemRuntime,
    parse_wg_show_dump,
    render_home_agent_config,
    render_wg_setconf_config,
)


class FakeRunner:
    def __init__(self, system="Linux", commands=None, interface_exists=False):
        self.system_name = system
        self.commands = commands or {"wg": "/usr/bin/wg", "ip": "/usr/sbin/ip"}
        self.interface_exists = interface_exists
        self.commands_run = []
        self.setconf_configs = []

    def which(self, command):
        return self.commands.get(command)

    def system(self):
        return self.system_name

    def run(self, command):
        self.commands_run.append(command)
        if command[:4] == ["ip", "link", "show", "dev"]:
            return SimpleNamespace(returncode=0 if self.interface_exists else 1, stdout="", stderr="")
        if command[:4] == ["ip", "link", "add", "dev"]:
            self.interface_exists = True
        if command[:3] == ["wg", "setconf", "tater0"]:
            self.setconf_configs.append(Path(command[3]).read_text(encoding="utf-8"))
        return SimpleNamespace(returncode=0, stdout="", stderr="")


def server_state():
    return {
        "claimed": True,
        "wireguardPort": 51888,
        "interface": {
            "address": "10.88.0.1/24",
            "wireguard": {
                "privateKey": "vps-private",
                "publicKey": "vps-public",
            },
        },
        "homeAgent": {
            "id": "home-agent",
            "publicKey": "home-public",
            "allowedIp": "10.88.0.2/32",
        },
        "peers": [
            {
                "id": "device-1",
                "name": "Alexs iPhone",
                "publicKey": "device-public",
                "allowedIp": "10.88.0.10/32",
            }
        ],
    }


class WireGuardRuntimeTest(unittest.TestCase):
    def test_parse_wg_show_dump_marks_recent_peer_connected(self):
        output = "\n".join(
            [
                "server-public\tserver-private\t51888\toff",
                "device-public\t(none)\t172.56.23.219:1031\t10.88.0.10/32\t1800000000\t392\t184\t25",
                "stale-public\t(none)\t(none)\t10.88.0.11/32\t0\t0\t0\toff",
            ]
        )

        peers = parse_wg_show_dump(output, now=1800000007)

        self.assertEqual(len(peers), 2)
        self.assertTrue(peers[0]["connected"])
        self.assertEqual(peers[0]["latestHandshakeAgeSeconds"], 7)
        self.assertEqual(peers[0]["latestHandshakeAt"], "2027-01-15T08:00:00Z")
        self.assertEqual(peers[0]["endpoint"], "172.56.23.219:1031")
        self.assertEqual(peers[0]["transferRxBytes"], 392)
        self.assertFalse(peers[1]["connected"])
        self.assertEqual(peers[1]["latestHandshakeAt"], "")

    def test_system_backend_creates_interface_and_applies_config(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "tater0.conf"
            runner = FakeRunner(interface_exists=False)
            runtime = WireGuardSystemRuntime(config_path, "tater0", runner)

            result = runtime.apply(server_state())

            self.assertEqual(result["lastAction"], "applied")
            self.assertEqual(
                runner.commands_run,
                [
                    ["ip", "link", "show", "dev", "tater0"],
                    ["ip", "link", "add", "dev", "tater0", "type", "wireguard"],
                    ["wg", "setconf", "tater0", ANY],
                    ["ip", "address", "replace", "10.88.0.1/24", "dev", "tater0"],
                    ["ip", "link", "set", "up", "dev", "tater0"],
                    ["ip", "link", "show", "dev", "tater0"],
                ],
            )
            config = config_path.read_text(encoding="utf-8")
            self.assertIn("PrivateKey = vps-private", config)
            self.assertIn("Address = 10.88.0.1/24", config)
            self.assertIn("PublicKey = home-public", config)
            self.assertIn("AllowedIPs = 10.88.0.10/32", config)
            self.assertNotIn("Address = 10.88.0.1/24", runner.setconf_configs[0])
            self.assertIn("ListenPort = 51888", runner.setconf_configs[0])

    def test_system_backend_rejects_non_linux(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "tater0.conf"
            runner = FakeRunner(system="Darwin", commands={"wg": "/usr/bin/wg"})
            runtime = WireGuardSystemRuntime(config_path, "tater0", runner)

            with self.assertRaises(WireGuardRuntimeError) as context:
                runtime.apply(server_state())

            self.assertIn("Linux-only", str(context.exception))

    def test_home_agent_config_renderer(self):
        state = {
            "homeAgent": {
                "wireguard": {
                    "privateKey": "home-private",
                }
            },
            "vpsAgent": {
                "wireguard": {
                    "publicKey": "vps-public",
                    "homeAllowedIp": "10.88.0.2/32",
                    "network": "10.88.0.0/24",
                }
            },
        }

        config = render_home_agent_config(state, "tunnel.example.com:51888")

        self.assertIn("PrivateKey = home-private", config)
        self.assertIn("Address = 10.88.0.2/32", config)
        self.assertIn("PublicKey = vps-public", config)
        self.assertIn("Endpoint = tunnel.example.com:51888", config)

    def test_setconf_renderer_removes_wg_quick_only_interface_keys(self):
        config = "\n".join(
            [
                "[Interface]",
                "PrivateKey = private",
                "Address = 10.88.0.1/24",
                "MTU = 1420",
                "ListenPort = 51888",
                "",
                "[Peer]",
                "PublicKey = peer",
                "AllowedIPs = 10.88.0.2/32",
            ]
        )

        setconf = render_wg_setconf_config(config)

        self.assertIn("PrivateKey = private", setconf)
        self.assertIn("ListenPort = 51888", setconf)
        self.assertNotIn("Address = 10.88.0.1/24", setconf)
        self.assertNotIn("MTU = 1420", setconf)
        self.assertIn("AllowedIPs = 10.88.0.2/32", setconf)


if __name__ == "__main__":
    unittest.main()
