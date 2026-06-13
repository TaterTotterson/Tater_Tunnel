import base64
import json
import tempfile
import threading
import urllib.error
import urllib.request
import unittest
from pathlib import Path

from tater_tunnel.vps_agent import (
    VpsAgentError,
    VpsAgentServer,
    VpsAgentService,
    VpsConfigStore,
    is_websocket_upgrade,
    parse_websocket_relay_api_path,
    rewrite_relay_body,
    rewrite_relay_headers,
)
from tater_tunnel.websocket_relay import OPCODE_TEXT, read_frame, websocket_accept_key, write_frame
from tater_tunnel.wireguard import KeyPair
from tater_tunnel.wireguard_runtime import WireGuardConfigRuntime


class MemorySocket:
    def __init__(self, data=b""):
        self.data = bytearray(data)
        self.sent = bytearray()

    def recv(self, length):
        if not self.data:
            return b""
        chunk = self.data[:length]
        del self.data[:length]
        return bytes(chunk)

    def sendall(self, data):
        self.sent.extend(data)


class FixedKeyProvider:
    def __init__(self):
        self.count = 0

    def generate_keypair(self):
        self.count += 1
        return KeyPair(
            private_key=f"vps-private-{self.count}",
            public_key=f"vps-public-{self.count}",
            source="test",
        )


class VpsAgentServiceTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state_file = Path(self.temp_dir.name) / "vps-agent.json"
        self.config_file = Path(self.temp_dir.name) / "tater0.conf"
        self.service = VpsAgentService(
            VpsConfigStore(self.state_file, pairing_code="ABCD-1234"),
            FixedKeyProvider(),
            WireGuardConfigRuntime(self.config_file),
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    def start_http_server(self):
        server = VpsAgentServer(("127.0.0.1", 0), self.service)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    def http_json(self, base_url, method, path, payload=None, token=""):
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if token:
            headers["X-Tater-Relay-Token"] = token
        request = urllib.request.Request(f"{base_url}{path}", data=body, method=method, headers=headers)
        with urllib.request.urlopen(request, timeout=3) as response:
            return json.loads(response.read().decode("utf-8"))

    def test_initial_state_has_pairing_code(self):
        state = self.service.state()

        self.assertFalse(state["claimed"])
        self.assertTrue(state["pairing"]["enabled"])
        self.assertEqual(state["pairing"]["code"], "ABCD-1234")

    def test_claim_disables_pairing_and_hides_private_key(self):
        result = self.service.claim(
            {
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
                "homeAgent": {
                    "id": "home-1",
                    "transport": "relay",
                },
            },
            remote_address="127.0.0.1",
        )

        state = result["state"]
        self.assertTrue(state["claimed"])
        self.assertFalse(state["pairing"]["enabled"])
        self.assertNotIn("code", state["pairing"])
        self.assertEqual(state["homeAgent"]["transport"], "relay")
        self.assertNotIn("publicKey", state["homeAgent"])
        self.assertNotIn("allowedIp", state["homeAgent"])
        self.assertIn("token", result["relay"])
        self.assertNotIn("relayToken", state["homeAgent"])
        self.assertEqual(result["vpsWireGuard"]["publicKey"], "vps-public-1")
        self.assertNotIn("homeAllowedIp", result["vpsWireGuard"])
        self.assertNotIn("privateKey", state["interface"]["wireguard"])
        self.assertEqual(state["runtime"]["backend"], "config")
        self.assertEqual(state["runtime"]["configPath"], str(self.config_file))

    def test_http_management_endpoints_require_relay_token_after_claim(self):
        claim = self.service.claim(
            {
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
                "homeAgent": {
                    "id": "home-1",
                    "transport": "relay",
                },
            },
            remote_address="127.0.0.1",
        )
        base_url = self.start_http_server()
        token = claim["relay"]["token"]

        health = self.http_json(base_url, "GET", "/api/health")
        self.assertEqual(health["status"], "ok")
        self.assertTrue(health["claimed"])
        self.assertNotIn("state", health)

        for method, path, payload in (
            ("GET", "/api/state", None),
            ("GET", "/api/wireguard", None),
            ("POST", "/api/peers", {"id": "device-1"}),
            ("POST", "/api/reset", {}),
            ("DELETE", "/api/peers/device-1", None),
        ):
            with self.subTest(method=method, path=path):
                with self.assertRaises(urllib.error.HTTPError) as context:
                    self.http_json(base_url, method, path, payload)
                self.assertEqual(context.exception.code, 403)

        state = self.http_json(base_url, "GET", "/api/state", token=token)
        self.assertTrue(state["claimed"])

    def test_close_websocket_session_removes_it_from_broker(self):
        result = self.service.claim(
            {
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
                "homeAgent": {
                    "id": "home-1",
                    "transport": "relay",
                },
            },
            remote_address="127.0.0.1",
        )
        session = self.service.relay_broker.create_websocket_session()

        self.service.close_websocket_relay(session.id)

        with self.assertRaises(VpsAgentError) as context:
            self.service.poll_websocket_client_frames(result["relay"]["token"], session.id)
        self.assertEqual(context.exception.status.value, 404)

        config = self.config_file.read_text(encoding="utf-8")
        self.assertIn("PrivateKey = vps-private-1", config)
        self.assertIn("Address = 10.88.0.1/24", config)
        self.assertIn("ListenPort = 51888", config)
        self.assertNotIn("# peer: Tater Home Agent", config)

        with self.assertRaises(VpsAgentError) as context:
            self.service.claim(
                {
                    "pairingCode": "ABCD-1234",
                    "homeAgent": {"publicKey": "another-home"},
                }
            )

        self.assertEqual(context.exception.status.value, 409)

    def test_peer_lifecycle_requires_claim(self):
        with self.assertRaises(VpsAgentError):
            self.service.add_peer(
                {
                    "id": "device-1",
                    "name": "Alex's iPhone",
                    "publicKey": "device-public",
                    "allowedIp": "10.88.0.10/32",
                }
            )

        self.service.claim(
            {
                "pairingCode": "ABCD-1234",
                "homeAgent": {"transport": "relay"},
            }
        )
        added = self.service.add_peer(
            {
                "id": "device-1",
                "name": "Alex's iPhone",
                "publicKey": "device-public",
                "allowedIp": "10.88.0.10/32",
            }
        )

        self.assertEqual(len(added["state"]["peers"]), 1)
        self.assertEqual(added["state"]["peers"][0]["id"], "device-1")
        config = self.config_file.read_text(encoding="utf-8")
        self.assertNotIn("# peer: Tater Home Agent", config)
        self.assertIn("# peer: Alex's iPhone (device-1)", config)
        self.assertIn("PublicKey = device-public", config)
        self.assertIn("AllowedIPs = 10.88.0.10/32", config)

        removed = self.service.remove_peer("device-1")

        self.assertEqual(removed["state"]["peers"], [])
        config = self.config_file.read_text(encoding="utf-8")
        self.assertNotIn("# peer: Tater Home Agent", config)
        self.assertNotIn("device-public", config)

    def test_wireguard_home_transport_requires_public_key(self):
        with self.assertRaises(VpsAgentError) as context:
            self.service.claim(
                {
                    "pairingCode": "ABCD-1234",
                    "homeAgent": {"transport": "wireguard"},
                }
            )

        self.assertEqual(context.exception.status.value, 400)

    def test_home_relay_round_trip(self):
        claim = self.service.claim(
            {
                "pairingCode": "ABCD-1234",
                "homeAgent": {"transport": "relay"},
            }
        )
        relay_token = claim["relay"]["token"]
        responses = []

        def remote_request():
            responses.append(
                self.service.relay_request(
                    "GET",
                    "/status?x=1",
                    {"Accept": "text/plain", "Host": "example.com"},
                    b"",
                    timeout=2,
                )
            )

        thread = threading.Thread(target=remote_request)
        thread.start()
        relay_request = self.service.next_relay_request(relay_token, timeout=2)

        self.assertIsNotNone(relay_request)
        self.assertEqual(relay_request["method"], "GET")
        self.assertEqual(relay_request["path"], "/status?x=1")
        self.assertEqual(relay_request["headers"], {"Accept": "text/plain"})

        self.service.complete_relay_request(
            relay_token,
            relay_request["id"],
            {
                "status": 200,
                "headers": {"Content-Type": "text/plain"},
                "bodyBase64": base64.b64encode(b"ok").decode("ascii"),
            },
        )
        thread.join(timeout=2)

        self.assertEqual(responses[0]["status"], 200)
        self.assertEqual(base64.b64decode(responses[0]["bodyBase64"]), b"ok")

        with self.assertRaises(VpsAgentError) as context:
            self.service.next_relay_request("wrong-token", timeout=0)

        self.assertEqual(context.exception.status.value, 403)

    def test_relay_response_preserves_rewrite_base_path(self):
        claim = self.service.claim(
            {
                "pairingCode": "ABCD-1234",
                "homeAgent": {"transport": "relay"},
            }
        )
        relay_token = claim["relay"]["token"]
        responses = []

        def remote_request():
            responses.append(
                self.service.relay_request(
                    "GET",
                    "/tater/",
                    {"Accept": "text/html"},
                    b"",
                    timeout=2,
                )
            )

        thread = threading.Thread(target=remote_request)
        thread.start()
        relay_request = self.service.next_relay_request(relay_token, timeout=2)

        self.service.complete_relay_request(
            relay_token,
            relay_request["id"],
            {
                "status": 200,
                "headers": {"Content-Type": "text/html"},
                "bodyBase64": base64.b64encode(b"<html></html>").decode("ascii"),
                "rewriteBasePath": "/relay/tater/",
            },
        )
        thread.join(timeout=2)

        self.assertEqual(responses[0]["rewriteBasePath"], "/relay/tater/")

    def test_relay_rewrites_root_relative_assets_and_redirects(self):
        body = rewrite_relay_body(
            (
                b'<html><head></head><body><script src="/static/app.js"></script>'
                b'<a href="/web/">Web</a><a href="http://127.0.0.1:8501/api/status">API</a></body></html>'
            ),
            "text/html; charset=utf-8",
            "/relay/emby/",
            "http://127.0.0.1:8501",
        ).decode("utf-8")
        headers = rewrite_relay_headers({"Location": "/web/index.html"}, "/relay/emby/", "http://127.0.0.1:8501")
        origin_headers = rewrite_relay_headers(
            {"Location": "http://127.0.0.1:8501/login"},
            "/relay/emby/",
            "http://127.0.0.1:8501",
        )
        relative_headers = rewrite_relay_headers({"Location": "web/index.html"}, "/relay/emby/")
        cookie_headers = rewrite_relay_headers(
            {"Set-Cookie": "tater_session=abc; Domain=127.0.0.1; Path=/api; HttpOnly; SameSite=Lax"},
            "/relay/tater/",
        )
        root_cookie_headers = rewrite_relay_headers(
            {"Set-Cookie": "tater_session=abc; Path=/; HttpOnly; SameSite=Lax"},
            "/relay/tater/",
        )

        self.assertNotIn("<base ", body)
        self.assertIn('src="/relay/emby/static/app.js"', body)
        self.assertIn('href="/relay/emby/web/"', body)
        self.assertIn('href="/relay/emby/api/status"', body)
        self.assertEqual(headers["Location"], "/relay/emby/web/index.html")
        self.assertEqual(origin_headers["Location"], "/relay/emby/login")
        self.assertEqual(relative_headers["Location"], "/relay/emby/web/index.html")
        self.assertIn("Path=/relay/tater/api", cookie_headers["Set-Cookie"])
        self.assertNotIn("Domain=", cookie_headers["Set-Cookie"])
        self.assertIn("Path=/relay/tater", root_cookie_headers["Set-Cookie"])

    def test_detects_websocket_upgrade_requests(self):
        self.assertTrue(
            is_websocket_upgrade(
                {
                    "Connection": "keep-alive, Upgrade",
                    "Upgrade": "websocket",
                }
            )
        )
        self.assertFalse(is_websocket_upgrade({"Connection": "keep-alive"}))
        self.assertFalse(is_websocket_upgrade({"Upgrade": "websocket"}))

    def test_parses_websocket_relay_api_path(self):
        self.assertEqual(
            parse_websocket_relay_api_path("/api/relay/ws/session-1/client-frames"),
            ("session-1", "client-frames"),
        )


class WebSocketRelayHelpersTest(unittest.TestCase):
    def test_websocket_accept_key_matches_rfc_example(self):
        self.assertEqual(
            websocket_accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        )

    def test_reads_masked_text_frame(self):
        writer = MemorySocket()
        write_frame(writer, OPCODE_TEXT, b"hello", masked=True)

        frame = read_frame(MemorySocket(bytes(writer.sent)), masked=True)

        self.assertTrue(frame["fin"])
        self.assertEqual(frame["opcode"], OPCODE_TEXT)
        self.assertEqual(frame["payload"], b"hello")


if __name__ == "__main__":
    unittest.main()
