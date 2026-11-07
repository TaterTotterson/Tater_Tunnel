from __future__ import annotations

import json
import re
import tempfile
import unittest
from http import HTTPStatus
from pathlib import Path
from unittest.mock import patch

from tater_tunnel.config_store import ConfigStore, default_state
from tater_tunnel.home_agent import (
    AgentError,
    HomeAgentService,
    is_allowed_home_agent_host,
    is_local_admin_service,
    normalize_relay_routes,
)
from tater_tunnel.vps_agent import (
    PAIRING_FAILURE_LIMIT,
    VpsAgentError,
    VpsAgentService,
    VpsConfigStore,
    create_pairing_code,
)
from tater_tunnel.websocket_relay import MAX_WEBSOCKET_FRAME_BYTES, WebSocketProtocolError, payload_to_frame


class NoopWireGuardRuntime:
    def apply(self, state):
        return {"backend": "test", "lastAction": "applied"}

    def diagnostics(self, state):
        return {"backend": "test", "livePeers": []}


class SecurityTests(unittest.TestCase):
    def test_pairing_codes_are_longer_and_reopen_rotates_them(self):
        with tempfile.TemporaryDirectory() as directory:
            store = VpsConfigStore(Path(directory) / "vps.json", "OLD-CODE")
            original = store.load()["pairing"]["code"]
            reopened = store.reopen_pairing()

        self.assertRegex(create_pairing_code(), r"^[A-Z2-9]{5}-[A-Z2-9]{5}$")
        self.assertNotEqual(original, reopened["pairing"]["code"])
        self.assertTrue(reopened["pairing"]["enabled"])

    def test_relay_requires_an_enrolled_wireguard_source(self):
        with tempfile.TemporaryDirectory() as directory:
            store = VpsConfigStore(Path(directory) / "vps.json", "PAIR-CODE")
            state = store.load()
            state["claimed"] = True
            state["homeAgent"] = {"transport": "relay", "relayToken": "secret"}
            state["peers"] = [
                {
                    "id": "phone",
                    "status": "active",
                    "allowedIp": "10.88.0.10/32",
                    "publicKey": "public-key",
                }
            ]
            store.save(state)
            service = VpsAgentService(store, wireguard_runtime=NoopWireGuardRuntime())

            service._require_relay_client(state, "10.88.0.10")
            with self.assertRaises(VpsAgentError) as public_error:
                service._require_relay_client(state, "127.0.0.1")
            with self.assertRaises(VpsAgentError) as unknown_peer_error:
                service._require_relay_client(state, "10.88.0.99")

        self.assertEqual(public_error.exception.status, HTTPStatus.FORBIDDEN)
        self.assertEqual(unknown_peer_error.exception.status, HTTPStatus.FORBIDDEN)

    def test_pairing_attempts_are_rate_limited(self):
        with tempfile.TemporaryDirectory() as directory:
            store = VpsConfigStore(Path(directory) / "vps.json", "RIGHT-CODE")
            service = VpsAgentService(store, wireguard_runtime=NoopWireGuardRuntime())
            for _ in range(PAIRING_FAILURE_LIMIT):
                with self.assertRaises(VpsAgentError) as invalid:
                    service.claim({"pairingCode": "WRONG-CODE"}, "203.0.113.10")
                self.assertEqual(invalid.exception.status, HTTPStatus.FORBIDDEN)

            with self.assertRaises(VpsAgentError) as limited:
                service.claim({"pairingCode": "RIGHT-CODE"}, "203.0.113.10")

        self.assertEqual(limited.exception.status, HTTPStatus.TOO_MANY_REQUESTS)

    def test_home_agent_has_no_default_or_admin_ui_relay_route(self):
        routes = normalize_relay_routes(
            4173,
            {
                "tunnel": "http://127.0.0.1:4173",
                "admin": "http://localhost:4173",
                "tater": "http://127.0.0.1:8501",
            },
        )
        self.assertEqual(routes, {"tater": "http://127.0.0.1:8501"})

        with tempfile.TemporaryDirectory() as directory:
            store = ConfigStore(Path(directory) / "home.json")
            state = default_state()
            state["paired"] = True
            state["homeAgent"]["relay"] = {"routes": routes}
            store.save(state)
            service = HomeAgentService(store, admin_port=4173)

            with self.assertRaises(AgentError) as missing_route:
                service._resolve_relay_target("/api/state")
            with self.assertRaises(AgentError) as admin_route:
                service.add_relay_route({"name": "admin", "target": "http://localhost:4173"})

        self.assertEqual(missing_route.exception.status, HTTPStatus.NOT_FOUND)
        self.assertEqual(admin_route.exception.status, HTTPStatus.BAD_REQUEST)

    def test_home_agent_blocks_its_lan_address_as_a_route(self):
        with patch(
            "tater_tunnel.home_agent.local_interface_addresses",
            return_value=frozenset({"127.0.0.1", "192.168.50.12"}),
        ):
            self.assertTrue(is_local_admin_service("http://192.168.50.12:4173", 4173))
            self.assertFalse(is_local_admin_service("http://192.168.50.20:4173", 4173))

    def test_home_agent_rejects_public_or_rebound_hostnames(self):
        self.assertTrue(is_allowed_home_agent_host("127.0.0.1:4173"))
        self.assertTrue(is_allowed_home_agent_host("192.168.50.12:4173"))
        with patch("tater_tunnel.home_agent.resolve_host_addresses", return_value=frozenset()):
            self.assertFalse(is_allowed_home_agent_host("attacker.example:4173"))

    def test_legacy_tunnel_route_and_device_tokens_are_redacted(self):
        with tempfile.TemporaryDirectory() as directory:
            state_path = Path(directory) / "home.json"
            state_path.write_text(
                json.dumps(
                    {
                        "paired": True,
                        "homeAgent": {
                            "relay": {
                                "target": "http://127.0.0.1:4173",
                                "routes": {
                                    "tunnel": "http://127.0.0.1:4173",
                                    "tater": "http://127.0.0.1:8501",
                                },
                            }
                        },
                        "devices": [{"id": "phone", "token": "tt://secret"}],
                    }
                ),
                encoding="utf-8",
            )
            store = ConfigStore(state_path)
            service = HomeAgentService(store)
            public = service.state()
            migrated = store.load()

        self.assertNotIn("target", public["homeAgent"]["relay"])
        self.assertNotIn("tunnel", public["homeAgent"]["relay"]["routes"])
        self.assertNotIn("token", public["devices"][0])
        self.assertNotIn("token", migrated["devices"][0])

    def test_websocket_frames_have_a_hard_size_limit(self):
        oversized = "A" * (((MAX_WEBSOCKET_FRAME_BYTES + 1) * 4 // 3) + 8)
        with self.assertRaises(WebSocketProtocolError):
            payload_to_frame({"opcode": 2, "bodyBase64": oversized})

    def test_new_caddy_template_blocks_public_relay(self):
        script = (Path(__file__).parent / "scripts" / "install-vps-full.sh").read_text(encoding="utf-8")
        self.assertGreaterEqual(len(re.findall(r"@public_relay path /relay /relay/\*", script)), 2)
        self.assertGreaterEqual(len(re.findall(r"handle @public_relay", script)), 2)


if __name__ == "__main__":
    unittest.main()
