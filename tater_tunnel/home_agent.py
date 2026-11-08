from __future__ import annotations

import argparse
import ipaddress
import json
import mimetypes
import re
import socket
import threading
import traceback
import urllib.error
import urllib.request
import uuid
from copy import deepcopy
from datetime import datetime, timezone
from functools import lru_cache
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

from .access_forward import (
    ACCESS_BIND_ADDRESS,
    ACCESS_PORT_MAX,
    ACCESS_PORT_MIN,
    AccessForwardLoop,
    AccessForwardManager,
)
from .config_store import ConfigStore
from .wireguard import KeyPair, WireGuardKeyProvider
from .wireguard_runtime import WireGuardRuntimeError, build_wireguard_client_runtime


PROJECT_ROOT = Path(__file__).resolve().parent.parent
STATE_PATH = PROJECT_ROOT / ".tater_tunnel" / "home-agent.json"
WIREGUARD_CONFIG_PATH = PROJECT_ROOT / ".tater_tunnel" / "wireguard" / "home-agent.conf"
VALID_DEVICE_TYPES = {"Phone", "Laptop", "Tablet", "Desktop"}
API_MAX_BODY_BYTES = 64 * 1024
REQUEST_SOCKET_TIMEOUT_SECONDS = 30
VPS_MUTATION_TIMEOUT_SECONDS = 30
TUNNEL_NETWORK = ipaddress.ip_network("10.88.0.0/24")
CF_1010_MESSAGE = (
    "Cloudflare blocked the VPS bootstrap request with error 1010. "
    "Use a DNS-only hostname that points directly to the VPS, then connect with "
    "an HTTPS URL such as https://tunnel.example.com."
)


class AgentError(Exception):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def is_cloudflare_1010_response(message: str) -> bool:
    normalized = re.sub(r"\s+", " ", message).lower()
    return "cloudflare" in normalized and (
        "error code: 1010" in normalized
        or "error 1010" in normalized
        or "access denied" in normalized
    )


class HomeAgentService:
    def __init__(
        self,
        store: ConfigStore,
        key_provider: WireGuardKeyProvider | None = None,
        vps_client: "VpsAgentClient | None" = None,
        wireguard_runtime: Any | None = None,
        access_manager: AccessForwardManager | None = None,
        admin_port: int = 4173,
    ):
        self.store = store
        self.key_provider = key_provider or WireGuardKeyProvider()
        self.vps_client = vps_client or VpsAgentClient()
        self.admin_port = admin_port
        self.access_manager = access_manager or AccessForwardManager()
        self.wireguard_runtime = wireguard_runtime or build_wireguard_client_runtime(
            "config", WIREGUARD_CONFIG_PATH, "tater-home"
        )
        self._restore_wireguard_state()

    def state(self) -> dict[str, Any]:
        state = self.store.load()
        state.setdefault("homeAgent", {})["accessForwarding"] = self.access_manager.sync(
            self.access_routes(state)
        )
        return self._public_state(state)

    def pair_vps(self, payload: dict[str, Any]) -> dict[str, Any]:
        vps = str(payload.get("vpsAddress") or payload.get("vps") or "").strip()
        pairing_code = str(payload.get("pairingCode") or "").strip()
        if not vps:
            raise AgentError(HTTPStatus.BAD_REQUEST, "VPS address is required")
        if not pairing_code:
            raise AgentError(HTTPStatus.BAD_REQUEST, "Pairing code is required")

        bootstrap_url = bootstrap_url_for(vps)
        keypair = self.key_provider.generate_keypair()
        claim = self.vps_client.claim(
            bootstrap_url,
            {
                "pairingCode": pairing_code,
                "homeAgent": {
                    "id": "local-home-agent",
                    "transport": "wireguard",
                    "publicKey": keypair.public_key,
                },
            },
        )
        management = claim.get("management") or {}
        management_url = str(management.get("url") or "").strip()
        management_token = str(management.get("token") or "").strip()
        vps_wireguard = claim.get("vpsWireGuard") or {}
        if not management_url.startswith("http://10.88.0.1:"):
            raise AgentError(HTTPStatus.BAD_GATEWAY, "VPS did not return its private management address")
        if not management_token:
            raise AgentError(HTTPStatus.BAD_GATEWAY, "VPS did not return a management credential")
        if not vps_wireguard.get("publicKey"):
            raise AgentError(HTTPStatus.BAD_GATEWAY, "VPS did not return its WireGuard public key")

        state = self.store.load()
        now = utc_now()
        state.update(
            {
                "paired": True,
                "migrationRequired": False,
                "vps": vps,
                "wireguardPort": int(vps_wireguard.get("listenPort") or 51888),
                "lastCheck": now,
            }
        )
        state["pairing"] = {"claimedAt": now, "pairingMode": "disabled"}
        state["management"] = {
            "url": management_url,
            "token": management_token,
            "bootstrapUrl": bootstrap_url,
        }
        state.setdefault("homeAgent", {})["wireguard"] = self._serialize_keypair(keypair)
        state["vpsAgent"] = {
            "managementUrl": management_url,
            "bootstrapUrl": bootstrap_url,
            "wireguard": vps_wireguard,
            "claimed": True,
        }
        self.store.save(state)

        try:
            self._apply_wireguard(state)
        except AgentError as error:
            state["homeAgent"]["runtime"] = {
                "backend": getattr(self.wireguard_runtime, "backend", "unknown"),
                "transport": "wireguard",
                "lastAction": "setup-error",
                "lastAppliedAt": utc_now(),
                "message": error.message,
            }
        state["homeAgent"]["accessForwarding"] = self.access_manager.sync(self.access_routes(state))
        return self._with_state(self.store.save(state))

    def check_health(self) -> dict[str, Any]:
        state = self.store.load()
        if not state.get("paired"):
            raise AgentError(HTTPStatus.CONFLICT, "No VPS is connected")

        management_url = str((state.get("management") or {}).get("url") or "")
        management_token = self._management_token(state)
        if not management_url:
            raise AgentError(HTTPStatus.CONFLICT, "Reconnect this Home Agent to finish the WireGuard upgrade")

        checked_at = utc_now()
        health = self.vps_client.health(management_url, management_token)
        diagnostics: dict[str, Any] = {}
        diagnostics_warning = ""
        try:
            diagnostics = self.vps_client.wireguard(management_url, management_token)
        except AgentError as error:
            diagnostics_warning = error.message
        live_devices = self._devices_with_live_wireguard(
            state.get("devices", []), diagnostics.get("wireguard") or {}
        )
        if diagnostics and self._devices_need_peer_sync(live_devices):
            self._sync_device_peers(state)
            diagnostics = self.vps_client.wireguard(management_url, management_token)
            live_devices = self._devices_with_live_wireguard(
                state.get("devices", []), diagnostics.get("wireguard") or {}
            )

        state["lastCheck"] = checked_at
        vps_agent = state.setdefault("vpsAgent", {})
        vps_agent["managementUrl"] = management_url
        vps_agent["health"] = self._vps_health_summary(health, checked_at)
        if diagnostics:
            vps_agent["wireguardRuntime"] = diagnostics.get("wireguard") or {}
            vps_agent.pop("diagnosticsWarning", None)
        elif diagnostics_warning:
            vps_agent["diagnosticsWarning"] = diagnostics_warning
        state["devices"] = live_devices
        state.setdefault("homeAgent", {})["accessForwarding"] = self.access_manager.sync(
            self.access_routes(state)
        )
        return self._with_state(self.store.save(state))

    def wireguard_diagnostics(self) -> dict[str, Any]:
        state = self.store.load()
        return {
            "wireguard": {
                "role": "home-gateway",
                "endpoint": self._endpoint(state),
                "privateAddress": ACCESS_BIND_ADDRESS,
                "runtime": self.wireguard_runtime.diagnostics(state),
            },
            "runtime": self._public_state(state).get("homeAgent", {}).get("runtime"),
            "accessForwarding": self.access_manager.diagnostics(),
        }

    def add_device(self, payload: dict[str, Any]) -> dict[str, Any]:
        state = self.store.load()
        if not state.get("paired"):
            raise AgentError(HTTPStatus.CONFLICT, "Connect a VPS before adding devices")

        person = str(payload.get("person") or "Tater Person").strip() or "Tater Person"
        device_type = str(payload.get("type") or "Phone").strip()
        if device_type not in VALID_DEVICE_TYPES:
            raise AgentError(HTTPStatus.BAD_REQUEST, "Device type is not supported")
        name = str(payload.get("name") or f"{person}'s {device_type}").strip()
        if not name:
            name = f"{person}'s {device_type}"

        keypair = self.key_provider.generate_keypair()
        now = utc_now()
        device = {
            "id": str(uuid.uuid4()),
            "person": person,
            "name": name,
            "type": device_type,
            "status": "Approved",
            "lastSeen": "Just now",
            "createdAt": now,
            "wireguard": {
                "publicKey": keypair.public_key,
                "allowedIp": self._next_device_ip(state),
                "keySource": keypair.source,
            },
        }
        self._sync_add_peer(state, device)
        state.setdefault("devices", []).insert(0, device)
        state["lastCheck"] = now
        saved = self.store.save(state)
        return {
            "state": self._public_state(saved),
            "enrollment": self._enrollment_payload(device, keypair, saved),
        }

    def revoke_device(self, device_id: str) -> dict[str, Any]:
        state = self.store.load()
        original_count = len(state.get("devices", []))
        state["devices"] = [device for device in state.get("devices", []) if device.get("id") != device_id]
        if len(state["devices"]) == original_count:
            raise AgentError(HTTPStatus.NOT_FOUND, "Device not found")
        self._sync_remove_peer(state, device_id)
        state["lastCheck"] = utc_now()
        return self._with_state(self.store.save(state))

    def add_access_route(self, payload: dict[str, Any]) -> dict[str, Any]:
        state = self.store.load()
        if not state.get("paired"):
            raise AgentError(HTTPStatus.CONFLICT, "Connect the Home Agent before adding services")

        name = normalize_route_name(payload.get("name"))
        target_host = normalize_access_host(payload.get("host") or payload.get("targetHost"))
        target_port = normalize_access_port(payload.get("port") or payload.get("targetPort"), "Local port")
        protocol = str(payload.get("protocol") or "tcp").strip().lower()
        if protocol not in {"tcp", "udp"}:
            raise AgentError(HTTPStatus.BAD_REQUEST, "Protocol must be TCP or UDP")
        if is_local_admin_target(target_host, target_port, self.admin_port):
            raise AgentError(HTTPStatus.BAD_REQUEST, "The Home Agent control panel cannot be shared")

        routes = self.access_routes(state)
        current = routes.get(name) or {}
        requested_port = payload.get("accessPort") or current.get("accessPort")
        access_port = (
            normalize_access_port(requested_port, "Tunnel port", access=True)
            if requested_port
            else self._next_access_port(routes)
        )
        for other_name, route in routes.items():
            if (
                other_name != name
                and int(route.get("accessPort") or 0) == access_port
                and str(route.get("protocol") or "tcp") == protocol
            ):
                raise AgentError(HTTPStatus.CONFLICT, "That tunnel port is already in use")

        routes[name] = {
            "name": name,
            "targetHost": target_host,
            "targetPort": target_port,
            "accessAddress": ACCESS_BIND_ADDRESS,
            "accessPort": access_port,
            "protocol": protocol,
            "createdAt": current.get("createdAt") or utc_now(),
        }
        state["accessRoutes"] = routes
        state["lastCheck"] = utc_now()
        state.setdefault("homeAgent", {})["accessForwarding"] = self.access_manager.sync(routes)
        return self._with_state(self.store.save(state))

    def test_access_route(self, payload: dict[str, Any]) -> dict[str, Any]:
        route_name = normalize_route_name(payload.get("name"))
        route = self.access_routes().get(route_name)
        if not route:
            raise AgentError(HTTPStatus.NOT_FOUND, "Service not found")
        return {
            "route": route_name,
            "target": f"{route['targetHost']}:{route['targetPort']}",
            "result": test_access_target(route),
        }

    def remove_access_route(self, name: str) -> dict[str, Any]:
        state = self.store.load()
        route_name = normalize_route_name(name)
        routes = self.access_routes(state)
        if route_name not in routes:
            raise AgentError(HTTPStatus.NOT_FOUND, "Service not found")
        routes.pop(route_name)
        state["accessRoutes"] = routes
        state["lastCheck"] = utc_now()
        state.setdefault("homeAgent", {})["accessForwarding"] = self.access_manager.sync(routes)
        return self._with_state(self.store.save(state))

    def access_routes(self, state: dict[str, Any] | None = None) -> dict[str, dict[str, Any]]:
        routes = (state or self.store.load()).get("accessRoutes") or {}
        return {
            str(name): deepcopy(route)
            for name, route in routes.items()
            if isinstance(route, dict)
        }

    def reset(self) -> dict[str, Any]:
        self.access_manager.sync({})
        runtime = self.wireguard_runtime.reset()
        state = self.store.reset()
        state.setdefault("homeAgent", {})["runtime"] = {
            **runtime,
            "transport": "wireguard",
            "message": "Home Agent tunnel state reset",
        }
        return self._with_state(self.store.save(state))

    def _next_access_port(self, routes: dict[str, dict[str, Any]]) -> int:
        used = {int(route.get("accessPort") or 0) for route in routes.values()}
        for port in range(ACCESS_PORT_MIN, ACCESS_PORT_MAX + 1):
            if port not in used:
                return port
        raise AgentError(HTTPStatus.CONFLICT, "No private service ports are available")

    def _next_device_ip(self, state: dict[str, Any]) -> str:
        used = {device.get("wireguard", {}).get("allowedIp") for device in state.get("devices", [])}
        for host in range(10, 250):
            candidate = f"10.88.0.{host}/32"
            if candidate not in used:
                return candidate
        raise AgentError(HTTPStatus.CONFLICT, "No device addresses are available")

    def _enrollment_payload(
        self, device: dict[str, Any], keypair: KeyPair, state: dict[str, Any]
    ) -> dict[str, Any]:
        config = "\n".join(
            [
                "[Interface]",
                f"PrivateKey = {keypair.private_key}",
                f"Address = {device['wireguard']['allowedIp']}",
                "",
                "[Peer]",
                f"PublicKey = {self._enrollment_peer_public_key(state)}",
                f"Endpoint = {self._endpoint(state)}",
                "AllowedIPs = 10.88.0.0/24",
                "PersistentKeepalive = 25",
            ]
        )
        return {"deviceId": device["id"], "wireguardConfig": config}

    def _endpoint(self, state: dict[str, Any]) -> str:
        bootstrap = str((state.get("vpsAgent") or {}).get("bootstrapUrl") or "")
        host = endpoint_host(bootstrap) if bootstrap else endpoint_host(str(state.get("vps") or ""))
        return f"{host}:{int(state.get('wireguardPort') or 51888)}"

    def _enrollment_peer_public_key(self, state: dict[str, Any]) -> str:
        public_key = str(((state.get("vpsAgent") or {}).get("wireguard") or {}).get("publicKey") or "")
        if not public_key:
            raise AgentError(HTTPStatus.CONFLICT, "VPS WireGuard public key is not available")
        return public_key

    def _sync_add_peer(self, state: dict[str, Any], device: dict[str, Any]) -> None:
        self.vps_client.add_peer(
            self._management_url(state),
            {
                "id": device["id"],
                "name": device["name"],
                "publicKey": device["wireguard"]["publicKey"],
                "allowedIp": device["wireguard"]["allowedIp"],
            },
            self._management_token(state),
        )

    def _sync_device_peers(self, state: dict[str, Any]) -> None:
        for device in state.get("devices", []):
            wireguard = device.get("wireguard") or {}
            if wireguard.get("publicKey") and wireguard.get("allowedIp"):
                self._sync_add_peer(state, device)

    def _sync_remove_peer(self, state: dict[str, Any], device_id: str) -> None:
        self.vps_client.remove_peer(
            self._management_url(state), device_id, self._management_token(state)
        )

    def _management_url(self, state: dict[str, Any]) -> str:
        value = str((state.get("management") or {}).get("url") or "")
        if not value:
            raise AgentError(HTTPStatus.CONFLICT, "Private VPS management address is not available")
        return value

    def _management_token(self, state: dict[str, Any]) -> str:
        token = str((state.get("management") or {}).get("token") or "")
        if not token:
            raise AgentError(HTTPStatus.CONFLICT, "Private VPS management credential is not available")
        return token

    def _devices_need_peer_sync(self, devices: list[dict[str, Any]]) -> bool:
        for device in devices:
            wireguard = device.get("wireguard") or {}
            live = wireguard.get("live") or {}
            if wireguard.get("publicKey") and live.get("publicKey") != wireguard.get("publicKey"):
                return True
            if wireguard.get("allowedIp") and wireguard.get("allowedIp") not in (live.get("allowedIps") or []):
                return True
        return False

    def _devices_with_live_wireguard(
        self, devices: list[dict[str, Any]], diagnostics: dict[str, Any]
    ) -> list[dict[str, Any]]:
        live_peers = diagnostics.get("livePeers")
        if not isinstance(live_peers, list):
            return devices
        live_by_key = {
            str(peer.get("publicKey") or ""): peer
            for peer in live_peers
            if isinstance(peer, dict) and peer.get("publicKey")
        }
        updated_devices: list[dict[str, Any]] = []
        for device in devices:
            updated = deepcopy(device)
            wireguard = updated.setdefault("wireguard", {})
            live = deepcopy(live_by_key.get(str(wireguard.get("publicKey") or "")) or {})
            if live:
                wireguard["live"] = live
                updated["status"] = "Connected" if live.get("connected") else "Waiting"
                updated["lastSeen"] = describe_live_peer(live)
            else:
                wireguard["live"] = {
                    "connected": False,
                    "latestHandshakeAt": "",
                    "latestHandshakeAgeSeconds": None,
                    "transferRxBytes": 0,
                    "transferTxBytes": 0,
                }
                updated["status"] = "Waiting"
                updated["lastSeen"] = "No handshake yet"
            updated_devices.append(updated)
        return updated_devices

    def _vps_health_summary(self, payload: dict[str, Any], checked_at: str) -> dict[str, Any]:
        summary = {"status": str(payload.get("status") or "unknown"), "checkedAt": checked_at}
        for key in ("version", "claimed", "pairingEnabled", "peerCount"):
            if key in payload:
                summary[key] = payload[key]
        return summary

    def _apply_wireguard(self, state: dict[str, Any]) -> None:
        try:
            state.setdefault("homeAgent", {})["runtime"] = self.wireguard_runtime.apply(
                state, self._endpoint(state)
            )
        except WireGuardRuntimeError as error:
            raise AgentError(HTTPStatus.BAD_GATEWAY, f"WireGuard runtime failed: {error}") from error

    def _restore_wireguard_state(self) -> None:
        state = self.store.load()
        try:
            if state.get("paired"):
                runtime = self.wireguard_runtime.apply(state, self._endpoint(state))
                action = "restored"
            else:
                runtime = self.wireguard_runtime.reset()
                action = "clean"
            state.setdefault("homeAgent", {})["runtime"] = {
                **runtime,
                "transport": "wireguard",
                "startupAction": action,
            }
        except WireGuardRuntimeError as error:
            state.setdefault("homeAgent", {})["runtime"] = {
                "backend": getattr(self.wireguard_runtime, "backend", "unknown"),
                "transport": "wireguard",
                "lastAction": "startup-error",
                "message": str(error),
            }
        self.store.save(state)

    def _public_state(self, state: dict[str, Any]) -> dict[str, Any]:
        public = deepcopy(state)
        wireguard = public.setdefault("homeAgent", {}).get("wireguard")
        if isinstance(wireguard, dict):
            wireguard.pop("privateKey", None)
        management = public.get("management")
        if isinstance(management, dict):
            management.pop("token", None)
        public["endpoint"] = self._endpoint(public)
        public["accessAddress"] = ACCESS_BIND_ADDRESS
        public["accessPortRange"] = [ACCESS_PORT_MIN, ACCESS_PORT_MAX]
        for device in public.get("devices", []):
            if isinstance(device, dict):
                device.pop("token", None)
        return public

    def _with_state(self, state: dict[str, Any]) -> dict[str, Any]:
        return {"state": self._public_state(state)}

    @staticmethod
    def _serialize_keypair(keypair: KeyPair) -> dict[str, str]:
        return {
            "privateKey": keypair.private_key,
            "publicKey": keypair.public_key,
            "keySource": keypair.source,
        }


class VpsAgentClient:
    def health(self, base_url: str, token: str) -> dict[str, Any]:
        return self._request("GET", base_url, "/api/health", headers=management_headers(token))

    def wireguard(self, base_url: str, token: str) -> dict[str, Any]:
        return self._request(
            "GET",
            base_url,
            "/api/wireguard",
            headers=management_headers(token),
            timeout=2,
        )

    def claim(self, base_url: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self._request(
            "POST",
            base_url,
            "/api/claim",
            payload,
            timeout=VPS_MUTATION_TIMEOUT_SECONDS,
        )

    def add_peer(self, base_url: str, payload: dict[str, Any], token: str) -> dict[str, Any]:
        return self._request(
            "POST",
            base_url,
            "/api/peers",
            payload,
            management_headers(token),
            timeout=VPS_MUTATION_TIMEOUT_SECONDS,
        )

    def remove_peer(self, base_url: str, peer_id: str, token: str) -> dict[str, Any]:
        return self._request(
            "DELETE",
            base_url,
            f"/api/peers/{peer_id}",
            headers=management_headers(token),
            timeout=VPS_MUTATION_TIMEOUT_SECONDS,
        )

    def _request(
        self,
        method: str,
        base_url: str,
        path: str,
        payload: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        timeout: float = 5,
    ) -> dict[str, Any]:
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        request_headers = {"Accept": "application/json"}
        if body is not None:
            request_headers["Content-Type"] = "application/json"
        request_headers.update(headers or {})
        request = urllib.request.Request(
            f"{base_url.rstrip('/')}{path}", data=body, method=method, headers=request_headers
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                decoded = json.loads(response.read().decode("utf-8"))
                if not isinstance(decoded, dict):
                    raise AgentError(HTTPStatus.BAD_GATEWAY, "VPS Agent returned an invalid response")
                return decoded
        except urllib.error.HTTPError as error:
            message = error.read().decode("utf-8", errors="replace")
            if is_cloudflare_1010_response(message):
                raise AgentError(HTTPStatus.BAD_GATEWAY, CF_1010_MESSAGE) from error
            try:
                message = str(json.loads(message).get("error") or message)
            except (json.JSONDecodeError, AttributeError):
                pass
            try:
                status = HTTPStatus(error.code)
            except ValueError:
                status = HTTPStatus.BAD_GATEWAY
            raise AgentError(status, f"VPS Agent: {message}") from error
        except AgentError:
            raise
        except (OSError, json.JSONDecodeError) as error:
            raise AgentError(HTTPStatus.BAD_GATEWAY, f"VPS Agent is not reachable: {error}") from error


class HomeAgentServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], static_root: Path, service: HomeAgentService):
        self._forward_stop = threading.Event()
        super().__init__(server_address, HomeAgentHandler)
        self.static_root = static_root
        self.service = service
        loop = AccessForwardLoop(self.service.access_manager, self.service.access_routes)
        self._forward_thread = threading.Thread(
            target=loop.run,
            args=(self._forward_stop,),
            name="tater-access-forwarding",
            daemon=True,
        )
        self._forward_thread.start()

    def server_close(self) -> None:
        self._forward_stop.set()
        self._forward_thread.join(timeout=3)
        self.service.access_manager.close()
        super().server_close()


class HomeAgentHandler(BaseHTTPRequestHandler):
    server: HomeAgentServer
    protocol_version = "HTTP/1.1"
    server_version = "TaterTunnel"
    sys_version = ""

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(REQUEST_SOCKET_TIMEOUT_SECONDS)

    def do_GET(self) -> None:
        if not self._require_local_request():
            return
        path = urlparse(self.path).path
        if path == "/api/state":
            self._send_json(self.server.service.state())
        elif path == "/api/wireguard":
            self._send_json(self.server.service.wireguard_diagnostics())
        else:
            self._serve_static(path)

    def do_POST(self) -> None:
        if not self._require_local_request():
            return
        path = urlparse(self.path).path
        try:
            payload = self._read_json()
            if path == "/api/pair":
                self._send_json(self.server.service.pair_vps(payload))
            elif path == "/api/health":
                self._send_json(self.server.service.check_health())
            elif path == "/api/devices":
                self._send_json(self.server.service.add_device(payload), HTTPStatus.CREATED)
            elif path == "/api/access-routes":
                self._send_json(self.server.service.add_access_route(payload), HTTPStatus.CREATED)
            elif path == "/api/access-routes/test":
                self._send_json(self.server.service.test_access_route(payload))
            elif path == "/api/reset":
                self._send_json(self.server.service.reset())
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
        except AgentError as error:
            self._send_error(error.status, error.message)
        except json.JSONDecodeError:
            self._send_error(HTTPStatus.BAD_REQUEST, "Request body must be valid JSON")
        except Exception as error:
            self._send_unexpected_error(error)

    def do_DELETE(self) -> None:
        if not self._require_local_request():
            return
        path = urlparse(self.path).path
        try:
            if path.startswith("/api/access-routes/"):
                name = unquote(path.removeprefix("/api/access-routes/"))
                self._send_json(self.server.service.remove_access_route(name))
            elif path.startswith("/api/devices/"):
                device_id = unquote(path.removeprefix("/api/devices/"))
                self._send_json(self.server.service.revoke_device(device_id))
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
        except AgentError as error:
            self._send_error(error.status, error.message)
        except Exception as error:
            self._send_unexpected_error(error)

    def log_message(self, format: str, *args: Any) -> None:
        status = args[1] if len(args) > 1 else "-"
        size = args[2] if len(args) > 2 else "-"
        safe_path = urlparse(self.path).path or "/"
        print(f'{self.client_address[0]} - "{self.command} {safe_path} {self.request_version}" {status} {size}')

    def _read_json(self) -> dict[str, Any]:
        if self.headers.get("Transfer-Encoding"):
            raise AgentError(HTTPStatus.BAD_REQUEST, "Transfer-Encoding is not supported")
        if self.headers.get_content_type() != "application/json":
            raise AgentError(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "API requests must use application/json")
        length = parse_content_length(self.headers.get("Content-Length", "0"))
        if length > API_MAX_BODY_BYTES:
            raise AgentError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Request body is too large")
        payload = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
        if not isinstance(payload, dict):
            raise AgentError(HTTPStatus.BAD_REQUEST, "Request body must be a JSON object")
        return payload

    def _require_local_request(self) -> bool:
        client = str(self.client_address[0] or "")
        try:
            client_address = ipaddress.ip_address(client)
        except ValueError:
            client_address = None
        if client_address and client_address in TUNNEL_NETWORK:
            self._send_error(HTTPStatus.FORBIDDEN, "Home Agent controls are not available through the tunnel")
            return False
        if not is_allowed_home_agent_host(self.headers.get("Host", "")):
            self._send_error(HTTPStatus.MISDIRECTED_REQUEST, "Home Agent is only available on the local network")
            return False
        return True

    def _serve_static(self, path: str) -> None:
        relative = "index.html" if path in {"", "/"} else path.lstrip("/")
        target = (self.server.static_root / unquote(relative)).resolve()
        try:
            target.relative_to(self.server.static_root.resolve())
        except ValueError:
            self._send_error(HTTPStatus.FORBIDDEN, "Static path is outside the app")
            return
        if not target.is_file():
            self._send_error(HTTPStatus.NOT_FOUND, "File not found")
            return
        body = target.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", mimetypes.guess_type(target.name)[0] or "application/octet-stream")
        self._send_browser_security_headers()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status: HTTPStatus, message: str) -> None:
        self._send_json({"error": message}, status)

    def _send_unexpected_error(self, error: Exception) -> None:
        print("Home Agent unexpected error:")
        traceback.print_exception(type(error), error, error.__traceback__)
        self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, "Home Agent internal error")

    def _send_browser_security_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; img-src 'self' data:; style-src 'self'; "
            "script-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        )


def management_headers(token: str) -> dict[str, str]:
    return {"X-Tater-Management-Token": token}


def parse_content_length(value: Any) -> int:
    try:
        length = int(str(value or "0"))
    except (TypeError, ValueError) as error:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Content-Length must be a number") from error
    if length < 0:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Content-Length cannot be negative")
    return length


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def describe_live_peer(peer: dict[str, Any]) -> str:
    age = peer.get("latestHandshakeAgeSeconds")
    if age is None or not peer.get("latestHandshakeAt"):
        return "No handshake yet"
    try:
        seconds = int(age)
    except (TypeError, ValueError):
        return str(peer.get("latestHandshakeAt") or "Seen")
    if seconds < 5:
        return "Just now"
    if seconds < 60:
        return f"{seconds}s ago"
    if seconds < 3600:
        return f"{seconds // 60}m ago"
    if seconds < 86400:
        return f"{seconds // 3600}h ago"
    return f"{seconds // 86400}d ago"


def normalize_route_name(value: Any) -> str:
    name = str(value or "").strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", name):
        raise AgentError(HTTPStatus.BAD_REQUEST, "Service name must use lowercase letters, numbers, or dashes")
    if name in {"api", "tunnel", "home-agent"}:
        raise AgentError(HTTPStatus.BAD_REQUEST, f"{name} is reserved")
    return name


def normalize_access_host(value: Any) -> str:
    host = str(value or "").strip()
    if not host or len(host) > 253 or any(character.isspace() for character in host):
        raise AgentError(HTTPStatus.BAD_REQUEST, "Local IP or hostname is invalid")
    if "://" in host or "/" in host:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Enter only a local IP or hostname")
    return host


def normalize_access_port(value: Any, label: str, access: bool = False) -> int:
    try:
        port = int(str(value or ""))
    except ValueError as error:
        raise AgentError(HTTPStatus.BAD_REQUEST, f"{label} must be a number") from error
    minimum, maximum = (ACCESS_PORT_MIN, ACCESS_PORT_MAX) if access else (1, 65535)
    if not minimum <= port <= maximum:
        raise AgentError(HTTPStatus.BAD_REQUEST, f"{label} must be between {minimum} and {maximum}")
    return port


def is_local_admin_target(host: str, port: int, admin_port: int) -> bool:
    if port != admin_port:
        return False
    normalized = host.lower()
    if normalized in {"localhost", "0.0.0.0", "::", "::1"}:
        return True
    try:
        addresses = {str(ipaddress.ip_address(normalized))}
    except ValueError:
        addresses = set(resolve_host_addresses(normalized))
    return bool(addresses & set(local_interface_addresses()))


def test_access_target(route: dict[str, Any]) -> dict[str, Any]:
    checked_at = utc_now()
    if str(route.get("protocol") or "tcp").lower() == "udp":
        return {
            "ok": True,
            "status": 0,
            "message": "UDP forwarding is ready; the target is checked when traffic arrives",
            "checkedAt": checked_at,
        }
    try:
        with socket.create_connection((str(route["targetHost"]), int(route["targetPort"])), timeout=3):
            pass
    except OSError as error:
        return {"ok": False, "status": 0, "message": str(error), "checkedAt": checked_at}
    return {
        "ok": True,
        "status": 200,
        "message": "Local service accepted a TCP connection",
        "checkedAt": checked_at,
    }


def is_allowed_home_agent_host(value: str) -> bool:
    try:
        hostname = (urlparse(f"//{value}").hostname or "").lower()
    except ValueError:
        return False
    if not hostname or hostname == ACCESS_BIND_ADDRESS:
        return False
    if hostname in {"localhost", "0.0.0.0", "::"}:
        return True
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        local_names = {socket.gethostname().lower(), socket.getfqdn().lower()}
        return hostname in local_names or bool(resolve_host_addresses(hostname) & local_interface_addresses())
    return bool(address.is_loopback or address.is_link_local or address.is_private)


@lru_cache(maxsize=64)
def resolve_host_addresses(host: str) -> frozenset[str]:
    addresses: set[str] = set()
    try:
        for info in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM):
            addresses.add(str(ipaddress.ip_address(info[4][0])))
    except (OSError, ValueError):
        pass
    return frozenset(addresses)


@lru_cache(maxsize=1)
def local_interface_addresses() -> frozenset[str]:
    addresses = {"127.0.0.1", "::1", "0.0.0.0", "::"}
    for host in {socket.gethostname(), socket.getfqdn(), "localhost"}:
        addresses.update(resolve_host_addresses(host))
    for family, probe in (
        (socket.AF_INET, ("192.0.2.1", 9)),
        (socket.AF_INET6, ("2001:db8::1", 9, 0, 0)),
    ):
        try:
            with socket.socket(family, socket.SOCK_DGRAM) as probe_socket:
                probe_socket.connect(probe)
                addresses.add(str(ipaddress.ip_address(probe_socket.getsockname()[0])))
        except (OSError, ValueError):
            pass
    return frozenset(addresses)


def bootstrap_url_for(value: str) -> str:
    raw = str(value or "").strip().rstrip("/")
    parsed = urlparse(raw if "://" in raw else f"https://{raw}")
    if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise AgentError(HTTPStatus.BAD_REQUEST, "VPS address is invalid")
    if parsed.path not in {"", "/"}:
        raise AgentError(HTTPStatus.BAD_REQUEST, "VPS address must not include a path")
    if parsed.scheme == "https":
        return parsed.geturl().rstrip("/")
    if parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}:
        return parsed.geturl().rstrip("/")
    raise AgentError(HTTPStatus.BAD_REQUEST, "Tater Tunnel requires an HTTPS VPS address")


def endpoint_host(value: str) -> str:
    parsed = urlparse(value if "://" in value else f"//{value}")
    return parsed.hostname or value


def build_server(
    host: str,
    port: int,
    state_file: Path,
    static_root: Path,
    wireguard_backend: str = "config",
    wireguard_config: Path = WIREGUARD_CONFIG_PATH,
    wireguard_interface: str = "tater-home",
) -> HomeAgentServer:
    store = ConfigStore(state_file)
    runtime = build_wireguard_client_runtime(wireguard_backend, wireguard_config, wireguard_interface)
    service = HomeAgentService(store, wireguard_runtime=runtime, admin_port=port)
    return HomeAgentServer((host, port), static_root.resolve(), service)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the Tater Tunnel WireGuard Home Agent")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=4173, type=int)
    parser.add_argument("--state-file", default=STATE_PATH, type=Path)
    parser.add_argument("--static-root", default=PROJECT_ROOT, type=Path)
    parser.add_argument("--wireguard-backend", choices=["config", "wg", "system"], default="config")
    parser.add_argument("--wireguard-config", default=WIREGUARD_CONFIG_PATH, type=Path)
    parser.add_argument("--wireguard-interface", default="tater-home")
    args = parser.parse_args(argv)

    server = build_server(
        args.host,
        args.port,
        args.state_file,
        args.static_root,
        args.wireguard_backend,
        args.wireguard_config,
        args.wireguard_interface,
    )
    print(f"Tater Tunnel Home Agent listening on http://{args.host}:{args.port}")
    print(f"State file: {args.state_file}")
    print(f"WireGuard backend: {args.wireguard_backend}")
    print(f"WireGuard config: {args.wireguard_config}")
    print(f"Private services: {ACCESS_BIND_ADDRESS}:{ACCESS_PORT_MIN}-{ACCESS_PORT_MAX}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Home Agent")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
