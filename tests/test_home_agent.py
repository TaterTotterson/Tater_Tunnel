import base64
import tempfile
import threading
import unittest
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from tater_tunnel.config_store import ConfigStore
from tater_tunnel.home_agent import AgentError, HomeAgentService, management_url_for
from tater_tunnel.wireguard import KeyPair
from tater_tunnel.wireguard_runtime import WireGuardClientConfigRuntime


class FixedKeyProvider:
    def __init__(self):
        self.count = 0

    def generate_keypair(self):
        self.count += 1
        return KeyPair(
            private_key=f"private-{self.count}",
            public_key=f"public-{self.count}",
            source="test",
        )


class FakeVpsClient:
    def __init__(self):
        self.claims = []
        self.added_peers = []
        self.removed_peers = []
        self.missing_peer_ids = set()
        self.relay_requests = []
        self.relay_responses = []
        self.health_payload = {
            "status": "ok",
            "claimed": True,
            "pairingEnabled": False,
            "peerCount": 0,
        }
        self.wireguard_payload = {
            "wireguard": {
                "livePeers": [],
            },
        }

    def health(self, base_url):
        return self.health_payload

    def wireguard(self, base_url):
        return self.wireguard_payload

    def claim(self, base_url, payload):
        self.claims.append((base_url, payload))
        return {
            "vpsWireGuard": {
                "publicKey": "vps-public",
                "address": "10.88.0.1/24",
                "homeAllowedIp": "10.88.0.2/32",
                "network": "10.88.0.0/24",
                "listenPort": 51888,
            },
            "relay": {
                "token": "relay-token",
            },
        }

    def add_peer(self, base_url, payload):
        self.added_peers.append((base_url, payload))
        return {"state": {"peers": [payload]}}

    def remove_peer(self, base_url, peer_id):
        self.removed_peers.append((base_url, peer_id))
        if peer_id in self.missing_peer_ids:
            raise AgentError(HTTPStatus.NOT_FOUND, "VPS Agent: Peer not found")
        return {"state": {"peers": []}}

    def poll_relay(self, base_url, token):
        if not self.relay_requests:
            return None
        return self.relay_requests.pop(0)

    def complete_relay(self, base_url, token, request_id, payload):
        self.relay_responses.append((base_url, token, request_id, payload))
        return {"accepted": True}


class LocalServiceHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        body = f"served {self.path}".encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class TaterServiceHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"tater {self.path}".encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class RedirectServiceHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.send_response(HTTPStatus.FOUND)
            self.send_header("Location", "web/index.html")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        body = f"redirect target {self.path}".encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class HeaderEchoServiceHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = "\n".join(
            [
                f"path={self.path}",
                f"prefix={self.headers.get('X-Forwarded-Prefix', '')}",
                f"script={self.headers.get('X-Script-Name', '')}",
                f"host={self.headers.get('X-Forwarded-Host', '')}",
                f"proto={self.headers.get('X-Forwarded-Proto', '')}",
                f"uri={self.headers.get('X-Original-URI', '')}",
            ]
        ).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class HomeAgentServiceTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state_file = Path(self.temp_dir.name) / "home-agent.json"
        self.config_file = Path(self.temp_dir.name) / "home-agent.conf"
        self.service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            FakeVpsClient(),
            wireguard_runtime=WireGuardClientConfigRuntime(self.config_file),
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_pair_vps_persists_claim(self):
        result = self.service.pair_vps(
            {
                "vpsAddress": "tunnel.example.com",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )

        state = result["state"]
        self.assertTrue(state["paired"])
        self.assertEqual(state["vps"], "tunnel.example.com")
        self.assertEqual(state["mode"], "safe")
        self.assertEqual(state["pairing"]["pairingMode"], "disabled")
        self.assertIsNone(state["homeAgent"]["wireguard"])
        self.assertEqual(state["homeAgent"]["relay"]["transport"], "tls-reverse-tunnel")
        self.assertNotIn("token", state["homeAgent"]["relay"])
        self.assertEqual(state["vpsAgent"]["managementUrl"], "http://tunnel.example.com:4174")
        self.assertEqual(state["homeAgent"]["runtime"]["lastAction"], "paired")
        self.assertFalse(self.config_file.exists())
        self.assertEqual(self.service.key_provider.count, 0)

        reloaded = self.service.state()
        self.assertTrue(reloaded["paired"])
        self.assertEqual(reloaded["vps"], "tunnel.example.com")
        self.assertNotIn("token", reloaded["homeAgent"]["relay"])
        self.assertEqual(self.service.store.load()["homeAgent"]["relay"]["token"], "relay-token")

    def test_bare_ip_pairing_claims_default_vps_agent_port(self):
        vps_client = FakeVpsClient()
        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
        )

        result = service.pair_vps(
            {
                "vpsAddress": "157.250.201.200",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )

        self.assertEqual(vps_client.claims[0][0], "http://157.250.201.200:4174")
        self.assertEqual(result["state"]["vps"], "157.250.201.200")
        self.assertEqual(result["state"]["vpsAgent"]["managementUrl"], "http://157.250.201.200:4174")
        self.assertEqual(result["state"]["endpoint"], "157.250.201.200:51888")

    def test_https_pairing_keeps_default_tls_port(self):
        self.assertEqual(management_url_for("https://tunnel.example.com"), "https://tunnel.example.com")
        self.assertEqual(management_url_for("https://tunnel.example.com:8443"), "https://tunnel.example.com:8443")
        self.assertEqual(management_url_for("http://157.250.201.200"), "http://157.250.201.200:4174")

    def test_cannot_add_device_before_pairing(self):
        with self.assertRaises(AgentError) as context:
            self.service.add_device({"person": "Alex", "name": "Alex's iPhone", "type": "Phone"})

        self.assertEqual(context.exception.status.value, 409)

    def test_add_device_returns_enrollment_and_stores_public_peer(self):
        self.service.pair_vps(
            {
                "vpsAddress": "tunnel.example.com",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )

        result = self.service.add_device({"person": "Alex", "name": "Alex's iPhone", "type": "Phone"})
        state = result["state"]
        enrollment = result["enrollment"]

        self.assertEqual(len(state["devices"]), 1)
        device = state["devices"][0]
        self.assertEqual(device["name"], "Alex's iPhone")
        self.assertEqual(device["wireguard"]["publicKey"], "public-1")
        self.assertEqual(device["wireguard"]["allowedIp"], "10.88.0.10/32")
        self.assertNotIn("privateKey", device["wireguard"])
        self.assertEqual(enrollment["deviceId"], device["id"])
        self.assertIn("PrivateKey = private-1", enrollment["wireguardConfig"])
        self.assertIn("Endpoint = tunnel.example.com:51888", enrollment["wireguardConfig"])
        self.assertTrue(enrollment["uri"].startswith("tt://alex-s-iphone-"))

    def test_revoke_device_removes_peer(self):
        self.service.pair_vps(
            {
                "vpsAddress": "tunnel.example.com",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        added = self.service.add_device({"person": "Alex", "name": "Alex's iPhone", "type": "Phone"})
        device_id = added["state"]["devices"][0]["id"]

        result = self.service.revoke_device(device_id)

        self.assertEqual(result["state"]["devices"], [])

    def test_revoke_device_removes_local_device_when_vps_peer_is_already_missing(self):
        vps_client = FakeVpsClient()
        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
        )
        service.pair_vps(
            {
                "vpsAddress": "tunnel.example.com",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        added = service.add_device({"person": "Alex", "name": "Old iPhone", "type": "Phone"})
        device_id = added["state"]["devices"][0]["id"]
        vps_client.missing_peer_ids.add(device_id)

        result = service.revoke_device(device_id)

        self.assertEqual(result["state"]["devices"], [])
        self.assertEqual(vps_client.removed_peers[0], ("http://tunnel.example.com:4174", device_id))

    def test_health_check_marks_live_wireguard_devices(self):
        vps_client = FakeVpsClient()
        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
        )
        service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        added = service.add_device({"person": "Alex", "name": "Alex's iPhone", "type": "Phone"})
        device = added["state"]["devices"][0]
        vps_client.health_payload["peerCount"] = 1
        vps_client.wireguard_payload = {
            "wireguard": {
                "livePeers": [
                    {
                        "publicKey": device["wireguard"]["publicKey"],
                        "endpoint": "172.56.23.219:1031",
                        "allowedIps": ["10.88.0.10/32"],
                        "latestHandshakeAt": "2026-06-12T12:00:00Z",
                        "latestHandshakeAgeSeconds": 7,
                        "transferRxBytes": 392,
                        "transferTxBytes": 184,
                        "connected": True,
                    }
                ]
            },
        }

        result = service.check_health()

        checked_device = result["state"]["devices"][0]
        self.assertEqual(checked_device["status"], "Connected")
        self.assertEqual(checked_device["lastSeen"], "7s ago")
        self.assertEqual(checked_device["wireguard"]["live"]["endpoint"], "172.56.23.219:1031")
        self.assertEqual(checked_device["wireguard"]["live"]["transferRxBytes"], 392)
        self.assertEqual(result["state"]["vpsAgent"]["health"]["peerCount"], 1)
        self.assertEqual(result["state"]["vpsAgent"]["wireguardRuntime"]["livePeers"][0]["publicKey"], "public-1")

    def test_http_vps_pairing_claims_vps_and_syncs_peers(self):
        vps_client = FakeVpsClient()
        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
        )

        paired = service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )

        self.assertEqual(vps_client.claims[0][0], "http://127.0.0.1:4174")
        self.assertEqual(vps_client.claims[0][1]["homeAgent"]["transport"], "relay")
        self.assertNotIn("publicKey", vps_client.claims[0][1]["homeAgent"])
        self.assertEqual(paired["state"]["endpoint"], "127.0.0.1:51888")
        self.assertEqual(paired["state"]["vpsAgent"]["wireguard"]["publicKey"], "vps-public")
        self.assertEqual(paired["state"]["homeAgent"]["runtime"]["lastAction"], "paired")
        self.assertFalse(self.config_file.exists())

        added = service.add_device({"person": "Alex", "name": "Alex's iPhone", "type": "Phone"})
        device = added["state"]["devices"][0]

        self.assertEqual(vps_client.added_peers[0][0], "http://127.0.0.1:4174")
        self.assertEqual(vps_client.added_peers[0][1]["id"], device["id"])
        self.assertIn("PublicKey = vps-public", added["enrollment"]["wireguardConfig"])
        self.assertIn("Endpoint = 127.0.0.1:51888", added["enrollment"]["wireguardConfig"])

        service.revoke_device(device["id"])

        self.assertEqual(vps_client.removed_peers[0], ("http://127.0.0.1:4174", device["id"]))

    def test_home_relay_proxies_one_queued_request(self):
        vps_client = FakeVpsClient()
        local_server = ThreadingHTTPServer(("127.0.0.1", 0), LocalServiceHandler)
        local_thread = threading.Thread(target=local_server.serve_forever, daemon=True)
        local_thread.start()
        self.addCleanup(local_server.server_close)
        self.addCleanup(local_server.shutdown)

        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
            relay_target=f"http://127.0.0.1:{local_server.server_port}",
        )
        service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        vps_client.relay_requests.append(
            {
                "id": "request-1",
                "method": "GET",
                "path": "/hello?x=1",
                "headers": {},
                "bodyBase64": "",
            }
        )

        self.assertTrue(service.relay_once())

        _, token, request_id, response = vps_client.relay_responses[0]
        self.assertEqual(token, "relay-token")
        self.assertEqual(request_id, "request-1")
        self.assertEqual(response["status"], 200)
        self.assertEqual(base64.b64decode(response["bodyBase64"]).decode("utf-8"), "served /hello?x=1")
        self.assertEqual(service.store.load()["homeAgent"]["runtime"]["lastAction"], "relayed")

    def test_home_relay_named_route_proxies_to_selected_local_service(self):
        vps_client = FakeVpsClient()
        tunnel_server = ThreadingHTTPServer(("127.0.0.1", 0), LocalServiceHandler)
        tater_server = ThreadingHTTPServer(("127.0.0.1", 0), TaterServiceHandler)
        tunnel_thread = threading.Thread(target=tunnel_server.serve_forever, daemon=True)
        tater_thread = threading.Thread(target=tater_server.serve_forever, daemon=True)
        tunnel_thread.start()
        tater_thread.start()
        self.addCleanup(tunnel_server.server_close)
        self.addCleanup(tunnel_server.shutdown)
        self.addCleanup(tater_server.server_close)
        self.addCleanup(tater_server.shutdown)

        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
            relay_target=f"http://127.0.0.1:{tunnel_server.server_port}",
            relay_routes={"tater": f"http://127.0.0.1:{tater_server.server_port}"},
        )
        service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        vps_client.relay_requests.append(
            {
                "id": "request-2",
                "method": "GET",
                "path": "/tater/app/status?x=1",
                "headers": {},
                "bodyBase64": "",
            }
        )

        self.assertTrue(service.relay_once())

        response = vps_client.relay_responses[0][3]
        self.assertEqual(response["status"], 200)
        self.assertEqual(base64.b64decode(response["bodyBase64"]).decode("utf-8"), "tater /app/status?x=1")
        self.assertEqual(response["rewriteBasePath"], "/relay/tater/")
        self.assertEqual(service.state()["homeAgent"]["relay"]["routes"]["tater"], f"http://127.0.0.1:{tater_server.server_port}")

    def test_add_relay_route_updates_live_proxy_table(self):
        vps_client = FakeVpsClient()
        tater_server = ThreadingHTTPServer(("127.0.0.1", 0), TaterServiceHandler)
        tater_thread = threading.Thread(target=tater_server.serve_forever, daemon=True)
        tater_thread.start()
        self.addCleanup(tater_server.server_close)
        self.addCleanup(tater_server.shutdown)

        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
        )
        service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        state = service.add_relay_route(
            {
                "name": "tater",
                "host": "127.0.0.1",
                "port": tater_server.server_port,
                "websocket": False,
                "hostHeader": "tater.local",
            }
        )["state"]

        self.assertEqual(state["homeAgent"]["relay"]["routes"]["tater"], f"http://127.0.0.1:{tater_server.server_port}")
        self.assertEqual(
            state["homeAgent"]["relay"]["routeSettings"]["tater"],
            {"websocket": False, "hostHeader": "tater.local"},
        )

        vps_client.relay_requests.append(
            {
                "id": "request-3",
                "method": "GET",
                "path": "/tater/hello",
                "headers": {},
                "bodyBase64": "",
            }
        )
        self.assertTrue(service.relay_once())
        response = vps_client.relay_responses[0][3]
        self.assertEqual(base64.b64decode(response["bodyBase64"]).decode("utf-8"), "tater /hello")
        self.assertEqual(response["rewriteBasePath"], "/relay/tater/")

        removed = service.remove_relay_route("tater")["state"]
        self.assertNotIn("tater", removed["homeAgent"]["relay"]["routes"])
        self.assertNotIn("tater", removed["homeAgent"]["relay"]["routeSettings"])

    def test_relay_route_health_checks_saved_target(self):
        local_server = ThreadingHTTPServer(("127.0.0.1", 0), LocalServiceHandler)
        local_thread = threading.Thread(target=local_server.serve_forever, daemon=True)
        local_thread.start()
        self.addCleanup(local_server.server_close)
        self.addCleanup(local_server.shutdown)

        self.service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        self.service.add_relay_route(
            {
                "name": "local",
                "host": "127.0.0.1",
                "port": local_server.server_port,
            }
        )

        result = self.service.test_relay_route({"name": "local"})

        self.assertEqual(result["route"], "local")
        self.assertEqual(result["result"]["status"], 200)
        self.assertTrue(result["result"]["ok"])

    def test_add_relay_route_accepts_optional_local_path(self):
        self.service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )

        state = self.service.add_relay_route(
            {
                "name": "admin",
                "host": "10.4.20.50",
                "port": "8080",
                "path": "/console/",
            }
        )["state"]

        self.assertEqual(state["homeAgent"]["relay"]["routes"]["admin"], "http://10.4.20.50:8080/console")

    def test_home_relay_adds_forwarded_prefix_headers(self):
        vps_client = FakeVpsClient()
        local_server = ThreadingHTTPServer(("127.0.0.1", 0), HeaderEchoServiceHandler)
        local_thread = threading.Thread(target=local_server.serve_forever, daemon=True)
        local_thread.start()
        self.addCleanup(local_server.server_close)
        self.addCleanup(local_server.shutdown)

        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
            relay_routes={"app": f"http://127.0.0.1:{local_server.server_port}"},
        )
        service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        vps_client.relay_requests.append(
            {
                "id": "request-forwarded",
                "method": "GET",
                "path": "/app/dashboard?x=1",
                "headers": {
                    "Host": "10.88.0.1:4174",
                    "X-Forwarded-Proto": "https",
                },
                "bodyBase64": "",
            }
        )

        self.assertTrue(service.relay_once())

        response = vps_client.relay_responses[0][3]
        body = base64.b64decode(response["bodyBase64"]).decode("utf-8")
        self.assertIn("path=/dashboard?x=1", body)
        self.assertIn("prefix=/relay/app", body)
        self.assertIn("script=/relay/app", body)
        self.assertIn("host=10.88.0.1:4174", body)
        self.assertIn("proto=https", body)
        self.assertIn("uri=/relay/app/dashboard?x=1", body)

    def test_home_relay_preserves_local_redirects(self):
        vps_client = FakeVpsClient()
        emby_server = ThreadingHTTPServer(("127.0.0.1", 0), RedirectServiceHandler)
        emby_thread = threading.Thread(target=emby_server.serve_forever, daemon=True)
        emby_thread.start()
        self.addCleanup(emby_server.server_close)
        self.addCleanup(emby_server.shutdown)

        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
            relay_routes={"emby": f"http://127.0.0.1:{emby_server.server_port}"},
        )
        service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        vps_client.relay_requests.append(
            {
                "id": "request-redirect",
                "method": "GET",
                "path": "/emby/",
                "headers": {},
                "bodyBase64": "",
            }
        )

        self.assertTrue(service.relay_once())

        response = vps_client.relay_responses[0][3]
        self.assertEqual(response["status"], HTTPStatus.FOUND)
        self.assertEqual(response["headers"]["Location"], "web/index.html")
        self.assertEqual(response["rewriteBasePath"], "/relay/emby/")

    def test_successful_relay_poll_clears_previous_error(self):
        vps_client = FakeVpsClient()
        service = HomeAgentService(
            ConfigStore(self.state_file),
            FixedKeyProvider(),
            vps_client,
            WireGuardClientConfigRuntime(self.config_file),
        )
        service.pair_vps(
            {
                "vpsAddress": "http://127.0.0.1:4174",
                "pairingCode": "ABCD-1234",
                "securityMode": "safe",
            }
        )
        service._record_relay_error("old failure")

        self.assertFalse(service.relay_once())

        runtime = service.store.load()["homeAgent"]["runtime"]
        self.assertEqual(runtime["lastAction"], "polling")
        self.assertIn("waiting for requests", runtime["message"])


if __name__ == "__main__":
    unittest.main()
