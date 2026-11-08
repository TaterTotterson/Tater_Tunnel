from __future__ import annotations

import base64
import json
import os
import subprocess
import tempfile
import unittest
from http import HTTPStatus
from pathlib import Path
from unittest.mock import patch

from tater_tunnel.config_store import ConfigStore
from tater_tunnel.home_agent import AgentError, HomeAgentService
from tater_tunnel.vps_agent import VpsAgentService, VpsConfigStore
from tater_tunnel.wireguard import KeyPair
from tater_tunnel.wireguard_runtime import (
    WIREGUARD_MTU,
    CommandRunner,
    WireGuardSystemRuntime,
    render_home_agent_config,
)


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
    @patch("tater_tunnel.wireguard_runtime.subprocess.run")
    def test_system_commands_return_a_bounded_timeout(self, run):
        run.side_effect = subprocess.TimeoutExpired(["wg", "show"], 2)

        completed = CommandRunner().run(["wg", "show"])

        self.assertEqual(completed.returncode, 124)
        self.assertIn("timed out", completed.stderr)

    def test_health_survives_a_live_diagnostics_timeout(self):
        class KeyProvider:
            def generate_keypair(self):
                return KeyPair(PRIVATE_KEY, HOME_PUBLIC_KEY, "test")

        class VpsClient:
            def claim(self, base_url, payload):
                return {
                    "vpsWireGuard": {
                        "publicKey": VPS_PUBLIC_KEY,
                        "address": "10.88.0.1/24",
                        "network": "10.88.0.0/24",
                        "homeAllowedIp": "10.88.0.2/32",
                        "listenPort": 51888,
                    },
                    "management": {
                        "url": "http://10.88.0.1:4174",
                        "token": "management-secret",
                    },
                }

            def health(self, base_url, token):
                return {"status": "ok", "claimed": True, "peerCount": 0}

            def wireguard(self, base_url, token):
                raise AgentError(HTTPStatus.BAD_GATEWAY, "VPS diagnostics timed out")

            def add_peer(self, base_url, payload, token):
                return {"status": "ok"}

        class HomeRuntime:
            backend = "test"

            def apply(self, state, endpoint):
                return {"backend": self.backend, "lastAction": "applied"}

            def reset(self):
                return {"backend": self.backend, "lastAction": "reset"}

        class AccessManager:
            def sync(self, routes):
                return {"listeners": [], "errors": {}}

        with tempfile.TemporaryDirectory() as directory:
            service = HomeAgentService(
                ConfigStore(Path(directory) / "home.json"),
                key_provider=KeyProvider(),
                vps_client=VpsClient(),
                wireguard_runtime=HomeRuntime(),
                access_manager=AccessManager(),
            )
            service.pair_vps(
                {"vpsAddress": "tunnel.example.com", "pairingCode": "RIGHT-CODE"}
            )
            enrollment = service.add_device(
                {"person": "Tater Person", "name": "Phone", "type": "Phone"}
            )["enrollment"]

            state = service.check_health()["state"]

        self.assertEqual(state["vpsAgent"]["health"]["status"], "ok")
        self.assertIn("timed out", state["vpsAgent"]["diagnosticsWarning"])
        self.assertIn(f"MTU = {WIREGUARD_MTU}", enrollment["wireguardConfig"])

    def test_home_agent_config_uses_safe_tunnel_mtu(self):
        config = render_home_agent_config(
            {
                "homeAgent": {"wireguard": {"privateKey": PRIVATE_KEY}},
                "vpsAgent": {
                    "wireguard": {
                        "publicKey": VPS_PUBLIC_KEY,
                        "homeAllowedIp": "10.88.0.2/32",
                        "network": "10.88.0.0/24",
                    }
                },
            },
            "tunnel.example.com:51888",
        )

        self.assertIn(f"MTU = {WIREGUARD_MTU}", config)

    def test_vps_peer_mutation_response_stays_below_tunnel_mtu(self):
        class KeyProvider:
            def generate_keypair(self):
                return KeyPair(PRIVATE_KEY, VPS_PUBLIC_KEY, "test")

        class Runtime:
            backend = "test"

            def apply(self, state):
                return {"backend": self.backend, "lastAction": "applied"}

        with tempfile.TemporaryDirectory() as directory:
            service = VpsAgentService(
                VpsConfigStore(Path(directory) / "vps.json", "RIGHT-CODE"),
                key_provider=KeyProvider(),
                wireguard_runtime=Runtime(),
            )
            service.claim(
                {
                    "pairingCode": "RIGHT-CODE",
                    "homeAgent": {"transport": "wireguard", "publicKey": HOME_PUBLIC_KEY},
                },
                "203.0.113.10",
            )
            response = service.add_peer(
                {
                    "id": "phone",
                    "name": "Phone",
                    "publicKey": base64.b64encode(b"d" * 32).decode("ascii"),
                    "allowedIp": "10.88.0.10/32",
                }
            )

        self.assertEqual(
            response,
            {"status": "ok", "peer": {"id": "phone", "allowedIp": "10.88.0.10/32"}},
        )
        self.assertLess(len(json.dumps(response)), WIREGUARD_MTU)

    def test_bootstrap_keeps_its_managed_source_updateable(self):
        root = Path(__file__).parents[1]
        setup = (root / "scripts" / "tater-vps-setup.sh").read_text(encoding="utf-8")

        self.assertIn("status --porcelain --untracked-files=all", setup)
        self.assertIn("Existing modified source preserved", setup)
        self.assertTrue(os.access(root / "scripts" / "audit-vps-security.sh", os.X_OK))

    def test_optional_service_access_boundaries(self):
        root = Path(__file__).parents[1]
        setup = (root / "scripts" / "tater-vps-setup.sh").read_text(encoding="utf-8")
        sftpgo = (root / "scripts" / "install-sftpgo.sh").read_text(encoding="utf-8")
        znc = (root / "scripts" / "install-znc.sh").read_text(encoding="utf-8")

        self.assertNotIn("--open-sftp-firewall", setup + sftpgo)
        self.assertNotIn("--open-firewall", setup + znc)
        self.assertNotIn("ZNC DNS-only hostname", setup)
        self.assertNotIn("SFTP DNS-only hostname", setup)
        self.assertIn("allow in on tater0 from 10.88.0.0/24", znc)
        self.assertIn("deny in to any port", znc)
        self.assertIn("--public-sftp", setup + sftpgo)
        self.assertIn("Allow SFTPGo users to connect from the public internet", setup)
        self.assertIn('ufw allow "$SFTP_PORT/tcp"', sftpgo)
        self.assertIn("Block public SFTPGo", sftpgo)
        self.assertIn("SFTPGO_HTTPD__BINDINGS__0__ADDRESS=0.0.0.0", sftpgo)
        self.assertIn("SFTPGo WebAdmin private WireGuard", sftpgo)
        self.assertIn("Block public SFTPGo WebAdmin", sftpgo)
        self.assertIn('WEB_LISTEN_PORT="6698"', znc)
        self.assertIn("ZNC WebAdmin private WireGuard", znc)
        self.assertIn("Block public ZNC WebAdmin", znc)
        self.assertIn("migrate_installed_znc_webadmin", setup)
        self.assertIn("/etc/caddy/tater-sites/znc-web.caddy", setup)

    def test_vps_setup_uses_focused_terminal_completion(self):
        setup = (
            Path(__file__).parents[1] / "scripts" / "tater-vps-setup.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("TATER TUNNEL // VPS SETUP CONSOLE", setup)
        self.assertIn('apt-get install -y ca-certificates dialog git', setup)
        self.assertIn("--item-help", setup)
        self.assertIn("--programbox", setup)
        self.assertIn("ONE-TIME PAIRING CODE", setup)
        self.assertIn('show_pairing_completion "$domain" "$final_pairing_code"', setup)
        self.assertNotIn("VPS Agent service:", setup)
        self.assertNotIn("WireGuard port:", setup)

    def test_vps_service_allows_only_agent_tcp_and_wireguard_udp(self):
        installer = (
            Path(__file__).parents[1] / "scripts" / "install-vps-agent.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("SocketBindDeny=any", installer)
        self.assertIn("SocketBindAllow=tcp:$LISTEN_PORT", installer)
        self.assertIn("SocketBindAllow=udp:51888", installer)

    def test_system_runtime_passes_syncconf_over_stdin(self):
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

            syncconf_calls = [
                call for call in runner.calls if call[0][:2] == ["wg", "syncconf"]
            ]
            self.assertEqual(len(syncconf_calls), 1)
            command, input_text = syncconf_calls[0]
            self.assertEqual(command, ["wg", "syncconf", "tater0", "/dev/stdin"])
            self.assertIn(f"PrivateKey = {PRIVATE_KEY}", input_text or "")
            self.assertNotIn("Address =", input_text or "")
            self.assertNotIn("MTU =", input_text or "")
            self.assertIn(f"MTU = {WIREGUARD_MTU}", config_path.read_text(encoding="utf-8"))
            self.assertIn(
                (["ip", "link", "set", "mtu", str(WIREGUARD_MTU), "dev", "tater0"], None),
                runner.calls,
            )
            self.assertEqual(list(config_path.parent.glob("*.setconf.*")), [])


if __name__ == "__main__":
    unittest.main()
