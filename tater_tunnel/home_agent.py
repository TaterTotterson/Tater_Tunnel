from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import re
import secrets
import socket
import ssl
import threading
import time
import uuid
import urllib.error
import urllib.request
from copy import deepcopy
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

from .config_store import ConfigStore, default_state
from .wireguard import KeyPair, WireGuardKeyProvider
from .wireguard_runtime import WireGuardRuntimeError, build_wireguard_client_runtime
from .websocket_relay import (
    OPCODE_CLOSE,
    OPCODE_PING,
    OPCODE_PONG,
    create_websocket_key,
    frame_to_payload,
    payload_to_frame,
    read_frame,
    websocket_accept_key,
    write_frame,
)


PROJECT_ROOT = Path(__file__).resolve().parent.parent
STATE_PATH = PROJECT_ROOT / ".tater_tunnel" / "home-agent.json"
WIREGUARD_CONFIG_PATH = PROJECT_ROOT / ".tater_tunnel" / "wireguard" / "home-agent.conf"
VPS_AGENT_PORT = 4174
VALID_MODES = {"minimal", "safe", "lockdown"}
VALID_DEVICE_TYPES = {"Phone", "Laptop", "Tablet", "Desktop"}
RELAY_POLL_INTERVAL_SECONDS = 1.0
RELAY_PROXY_TIMEOUT_SECONDS = 15
DEFAULT_RELAY_WORKERS = 6
HOP_BY_HOP_HEADERS = {
    "connection",
    "content-length",
    "host",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        return None


class AgentError(Exception):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class HomeAgentService:
    def __init__(
        self,
        store: ConfigStore,
        key_provider: WireGuardKeyProvider | None = None,
        vps_client: "VpsAgentClient | None" = None,
        wireguard_runtime: Any | None = None,
        relay_target: str = "http://127.0.0.1:4173",
        relay_routes: dict[str, str] | None = None,
    ):
        self.store = store
        self.key_provider = key_provider or WireGuardKeyProvider()
        self.vps_client = vps_client or VpsAgentClient()
        self.relay_target = relay_target.rstrip("/") or "http://127.0.0.1:4173"
        self.relay_routes = normalize_relay_routes(self.relay_target, relay_routes or {})
        self.wireguard_runtime = wireguard_runtime or build_wireguard_client_runtime(
            "config",
            WIREGUARD_CONFIG_PATH,
            "tater-home",
        )

    def state(self) -> dict[str, Any]:
        return self._public_state(self.store.load())

    def pair_vps(self, payload: dict[str, Any]) -> dict[str, Any]:
        vps = str(payload.get("vpsAddress") or payload.get("vps") or "").strip()
        pairing_code = str(payload.get("pairingCode") or "").strip()
        mode = str(payload.get("securityMode") or payload.get("mode") or "safe").strip().lower()

        if not vps:
            raise AgentError(HTTPStatus.BAD_REQUEST, "VPS address is required")
        if not pairing_code:
            raise AgentError(HTTPStatus.BAD_REQUEST, "Pairing code is required")
        if mode not in VALID_MODES:
            raise AgentError(HTTPStatus.BAD_REQUEST, "Security mode must be minimal, safe, or lockdown")

        state = self.store.load()
        management_url = management_url_for(vps)
        vps_claim = self.vps_client.claim(
            management_url,
            {
                "pairingCode": pairing_code,
                "securityMode": mode,
                "homeAgent": {
                    "id": "local-home-agent",
                    "transport": "relay",
                },
            },
        )
        now = utc_now()

        state.update(
            {
                "paired": True,
                "vps": vps,
                "mode": mode,
                "lastCheck": now,
            }
        )
        state["pairing"] = {
            "claimedAt": state["lastCheck"],
            "pairingMode": "disabled",
        }
        state["homeAgent"]["relay"] = {
            "status": "connected",
            "transport": "tls-reverse-tunnel",
            "managementUrl": management_url,
            "target": self.relay_target,
            "routes": self._current_relay_routes(state),
            "pairedAt": now,
        }
        relay_token = str((vps_claim.get("relay") or {}).get("token") or "")
        if relay_token:
            state["homeAgent"]["relay"]["token"] = relay_token
        state["homeAgent"]["wireguard"] = None
        state["homeAgent"]["runtime"] = self._home_relay_runtime("paired", "Home Agent paired as relay client")
        state["vpsAgent"] = {
            "managementUrl": management_url,
            "wireguard": vps_claim["vpsWireGuard"],
            "claimed": True,
        }
        state["wireguardPort"] = vps_claim["vpsWireGuard"]["listenPort"]

        return self._with_state(self.store.save(state))

    def check_health(self) -> dict[str, Any]:
        state = self.store.load()
        if not state["paired"]:
            raise AgentError(HTTPStatus.CONFLICT, "No VPS is paired")

        management_url = (state.get("vpsAgent") or {}).get("managementUrl")
        if not management_url:
            raise AgentError(HTTPStatus.CONFLICT, "VPS management URL is not available")

        now = utc_now()
        vps_health = self.vps_client.health(management_url)
        wireguard = self.vps_client.wireguard(management_url, self._relay_token(state))

        state["lastCheck"] = now
        vps_agent = state.setdefault("vpsAgent", {})
        vps_agent["managementUrl"] = management_url
        vps_agent["health"] = self._vps_health_summary(vps_health, now)
        vps_agent["wireguardRuntime"] = wireguard.get("wireguard") or {}
        state["devices"] = self._devices_with_live_wireguard(state.get("devices", []), vps_agent["wireguardRuntime"])
        return self._with_state(self.store.save(state))

    def wireguard_diagnostics(self) -> dict[str, Any]:
        state = self.store.load()
        return {
            "wireguard": {
                "role": "remote-device-vpn",
                "endpoint": self._endpoint(state),
                "homeAgentRunsWireGuard": False,
            },
            "relay": self._public_state(state).get("homeAgent", {}).get("relay"),
            "runtime": self._public_state(state).get("homeAgent", {}).get("runtime"),
        }

    def relay_once(self) -> bool:
        state = self.store.load()
        relay = (state.get("homeAgent") or {}).get("relay") or {}
        management_url = relay.get("managementUrl") or (state.get("vpsAgent") or {}).get("managementUrl")
        relay_token = str(relay.get("token") or "")

        if not state.get("paired") or not management_url or not relay_token:
            return False

        relay_request = self.vps_client.poll_relay(management_url, relay_token)
        if relay_request is None:
            self._record_relay_ok("polling", "Home Relay connected and waiting for requests", only_after_error=True)
            return False

        response = self._proxy_relay_request(relay_request)
        self.vps_client.complete_relay(
            management_url,
            relay_token,
            str(relay_request["id"]),
            response,
        )
        self._record_relay_ok("relayed", "Home Relay request completed")
        return True

    def relay_loop(self, stop_event: threading.Event) -> None:
        while not stop_event.is_set():
            try:
                handled = self.relay_once()
                if not handled:
                    stop_event.wait(RELAY_POLL_INTERVAL_SECONDS)
            except Exception as error:
                self._record_relay_error(str(error))
                stop_event.wait(RELAY_POLL_INTERVAL_SECONDS)

    def add_device(self, payload: dict[str, Any]) -> dict[str, Any]:
        state = self.store.load()
        if not state["paired"]:
            raise AgentError(HTTPStatus.CONFLICT, "Pair a VPS before adding devices")

        person = str(payload.get("person") or "Tater Person").strip() or "Tater Person"
        device_type = str(payload.get("type") or "Phone").strip()
        if device_type not in VALID_DEVICE_TYPES:
            raise AgentError(HTTPStatus.BAD_REQUEST, "Device type is not supported")

        name = str(payload.get("name") or f"{person}'s {device_type}").strip()
        if not name:
            name = f"{person}'s {device_type}"

        keypair = self.key_provider.generate_keypair()
        device_id = str(uuid.uuid4())
        allowed_ip = self._next_device_ip(state)
        token = self._create_pairing_token(name)
        now = utc_now()

        device = {
            "id": device_id,
            "person": person,
            "name": name,
            "type": device_type,
            "status": "Approved",
            "lastSeen": "Just now",
            "createdAt": now,
            "token": token,
            "wireguard": {
                "publicKey": keypair.public_key,
                "allowedIp": allowed_ip,
                "keySource": keypair.source,
            },
        }

        self._sync_add_peer(state, device)

        state["devices"].insert(0, device)
        state["lastCheck"] = now
        saved = self.store.save(state)

        return {
            "state": self._public_state(saved),
            "enrollment": self._enrollment_payload(device, keypair, saved),
        }

    def revoke_device(self, device_id: str) -> dict[str, Any]:
        state = self.store.load()
        original_count = len(state["devices"])
        state["devices"] = [device for device in state["devices"] if device["id"] != device_id]

        if len(state["devices"]) == original_count:
            raise AgentError(HTTPStatus.NOT_FOUND, "Device not found")

        try:
            self._sync_remove_peer(state, device_id)
        except AgentError as error:
            if error.status != HTTPStatus.NOT_FOUND:
                raise

        state["lastCheck"] = utc_now()
        return self._with_state(self.store.save(state))

    def add_relay_route(self, payload: dict[str, Any]) -> dict[str, Any]:
        state = self.store.load()
        if not state.get("paired"):
            raise AgentError(HTTPStatus.CONFLICT, "Pair a VPS before adding relay routes")

        name, target = route_from_payload(payload)
        routes = self._current_relay_routes(state)
        routes[name] = target
        relay = state.setdefault("homeAgent", {}).setdefault("relay", {})
        relay["routes"] = routes
        settings = self._current_relay_route_settings(state)
        settings[name] = route_settings_from_payload(payload)
        relay["routeSettings"] = settings
        state["lastCheck"] = utc_now()
        return self._with_state(self.store.save(state))

    def test_relay_route(self, payload: dict[str, Any]) -> dict[str, Any]:
        state = self.store.load()
        if not state.get("paired"):
            raise AgentError(HTTPStatus.CONFLICT, "Pair a VPS before testing relay routes")

        route_name = normalize_route_name(str(payload.get("name") or ""))
        routes = self._current_relay_routes(state)
        target = routes.get(route_name)
        if not target:
            raise AgentError(HTTPStatus.NOT_FOUND, "Relay route not found")

        return {
            "route": route_name,
            "target": target,
            "result": test_route_target(target, self._current_relay_route_settings(state).get(route_name, {})),
        }

    def remove_relay_route(self, name: str) -> dict[str, Any]:
        state = self.store.load()
        route_name = normalize_route_name(name)

        if route_name == "tunnel":
            raise AgentError(HTTPStatus.BAD_REQUEST, "The tunnel route cannot be removed")

        routes = self._current_relay_routes(state)
        if route_name not in routes:
            raise AgentError(HTTPStatus.NOT_FOUND, "Relay route not found")

        routes.pop(route_name, None)
        self.relay_routes.pop(route_name, None)
        relay = state.setdefault("homeAgent", {}).setdefault("relay", {})
        relay["routes"] = routes
        settings = self._current_relay_route_settings(state)
        settings.pop(route_name, None)
        relay["routeSettings"] = settings
        state["lastCheck"] = utc_now()
        return self._with_state(self.store.save(state))

    def reset(self) -> dict[str, Any]:
        state = self.store.reset()
        state["homeAgent"]["runtime"] = self._home_relay_runtime("reset", "Home Agent relay state reset")
        self.wireguard_runtime.reset()
        return self._with_state(self.store.save(state))

    def _next_device_ip(self, state: dict[str, Any]) -> str:
        used = {
            device.get("wireguard", {}).get("allowedIp")
            for device in state.get("devices", [])
        }
        for host in range(10, 250):
            candidate = f"10.88.0.{host}/32"
            if candidate not in used:
                return candidate
        raise AgentError(HTTPStatus.CONFLICT, "No device addresses are available")

    def _create_pairing_token(self, name: str) -> str:
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:28] or "device"
        return f"tt://{slug}-{secrets.token_urlsafe(8)}"

    def _enrollment_payload(self, device: dict[str, Any], keypair: KeyPair, state: dict[str, Any]) -> dict[str, Any]:
        endpoint = self._endpoint(state)
        peer_public_key = self._enrollment_peer_public_key(state)
        wireguard_config = "\n".join(
            [
                "[Interface]",
                f"PrivateKey = {keypair.private_key}",
                f"Address = {device['wireguard']['allowedIp']}",
                "",
                "[Peer]",
                f"PublicKey = {peer_public_key}",
                f"Endpoint = {endpoint}",
                "AllowedIPs = 10.88.0.0/24",
                "PersistentKeepalive = 25",
            ]
        )

        return {
            "uri": device["token"],
            "deviceId": device["id"],
            "wireguardConfig": wireguard_config,
        }

    def _endpoint(self, state: dict[str, Any]) -> str:
        vps_agent = state.get("vpsAgent") or {}
        if vps_agent.get("managementUrl"):
            host = endpoint_host(vps_agent["managementUrl"])
            return f"{host}:{state['wireguardPort']}"
        if not state.get("vps"):
            return f":{state['wireguardPort']}"
        return f"{state['vps']}:{state['wireguardPort']}"

    def _enrollment_peer_public_key(self, state: dict[str, Any]) -> str:
        vps_wireguard = (state.get("vpsAgent") or {}).get("wireguard") or {}
        if vps_wireguard.get("publicKey"):
            return vps_wireguard["publicKey"]
        raise AgentError(HTTPStatus.CONFLICT, "VPS WireGuard public key is not available")

    def _sync_add_peer(self, state: dict[str, Any], device: dict[str, Any]) -> None:
        management_url = (state.get("vpsAgent") or {}).get("managementUrl")
        if not management_url:
            return

        self.vps_client.add_peer(
            management_url,
            {
                "id": device["id"],
                "name": device["name"],
                "publicKey": device["wireguard"]["publicKey"],
                "allowedIp": device["wireguard"]["allowedIp"],
            },
            self._relay_token(state),
        )

    def _sync_remove_peer(self, state: dict[str, Any], device_id: str) -> None:
        management_url = (state.get("vpsAgent") or {}).get("managementUrl")
        if not management_url:
            return

        self.vps_client.remove_peer(management_url, device_id, self._relay_token(state))

    def _relay_token(self, state: dict[str, Any]) -> str:
        return str(((state.get("homeAgent") or {}).get("relay") or {}).get("token") or "")

    def _vps_health_summary(self, payload: dict[str, Any] | None, checked_at: str) -> dict[str, Any]:
        payload = payload or {}
        summary = {
            "status": str(payload.get("status") or "unknown"),
            "checkedAt": checked_at,
        }

        for key in ("claimed", "pairingEnabled", "peerCount"):
            if key in payload:
                summary[key] = payload[key]

        return summary

    def _devices_with_live_wireguard(
        self,
        devices: list[dict[str, Any]],
        wireguard_runtime: dict[str, Any],
    ) -> list[dict[str, Any]]:
        live_peers = wireguard_runtime.get("livePeers")
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
            public_key = str(wireguard.get("publicKey") or "")
            live_peer = live_by_key.get(public_key)

            if live_peer:
                wireguard["live"] = deepcopy(live_peer)
                updated["status"] = "Connected" if live_peer.get("connected") else "Waiting"
                updated["lastSeen"] = self._describe_live_peer(live_peer)
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

    def _describe_live_peer(self, live_peer: dict[str, Any]) -> str:
        age = live_peer.get("latestHandshakeAgeSeconds")
        if age is None or not live_peer.get("latestHandshakeAt"):
            return "No handshake yet"

        try:
            age_seconds = int(age)
        except (TypeError, ValueError):
            return str(live_peer.get("latestHandshakeAt") or "Seen")

        if age_seconds < 5:
            return "Just now"
        if age_seconds < 60:
            return f"{age_seconds}s ago"
        if age_seconds < 3600:
            return f"{age_seconds // 60}m ago"
        if age_seconds < 86400:
            return f"{age_seconds // 3600}h ago"
        return f"{age_seconds // 86400}d ago"

    def _proxy_relay_request(self, relay_request: dict[str, Any]) -> dict[str, Any]:
        method = str(relay_request.get("method") or "GET").upper()
        if method == "WEBSOCKET":
            return self._proxy_websocket_relay_request(relay_request)

        path = str(relay_request.get("path") or "/")
        target_base, target_path, route_name = self._resolve_relay_target(path)
        target_url = f"{target_base}/{target_path.lstrip('/')}"
        request_body = base64.b64decode(str(relay_request.get("bodyBase64") or "").encode("ascii"))
        relay_headers = relay_request.get("headers") or {}
        request_headers = sanitize_headers(relay_headers)
        request_headers["Accept-Encoding"] = "identity"

        data = None if method in {"GET", "HEAD"} else request_body
        rewrite_base_path = "/relay/" if route_name == "tunnel" else f"/relay/{route_name}/"
        request_headers.update(proxy_forwarding_headers(relay_headers, rewrite_base_path, path))
        route_settings = self._current_relay_route_settings().get(route_name, {})
        if route_settings.get("hostHeader"):
            request_headers["Host"] = str(route_settings["hostHeader"])
        request = urllib.request.Request(target_url, data=data, method=method, headers=request_headers)

        try:
            with urllib.request.build_opener(NoRedirectHandler).open(request, timeout=RELAY_PROXY_TIMEOUT_SECONDS) as response:
                body = response.read()
                return {
                    "status": response.status,
                    "headers": sanitize_headers(dict(response.headers.items())),
                    "bodyBase64": base64.b64encode(body).decode("ascii"),
                    "rewriteBasePath": rewrite_base_path,
                    "rewriteOrigin": target_base,
                }
        except urllib.error.HTTPError as error:
            body = error.read()
            return {
                "status": error.code,
                "headers": sanitize_headers(dict(error.headers.items())),
                "bodyBase64": base64.b64encode(body).decode("ascii"),
                "rewriteBasePath": rewrite_base_path,
                "rewriteOrigin": target_base,
            }
        except OSError as error:
            body = f"Tater local service is not reachable: {error}".encode("utf-8")
            return {
                "status": HTTPStatus.BAD_GATEWAY,
                "headers": {"Content-Type": "text/plain; charset=utf-8"},
                "bodyBase64": base64.b64encode(body).decode("ascii"),
                "rewriteBasePath": rewrite_base_path,
                "rewriteOrigin": target_base,
            }

    def _proxy_websocket_relay_request(self, relay_request: dict[str, Any]) -> dict[str, Any]:
        state = self.store.load()
        relay = (state.get("homeAgent") or {}).get("relay") or {}
        management_url = relay.get("managementUrl") or (state.get("vpsAgent") or {}).get("managementUrl")
        relay_token = str(relay.get("token") or "")
        session_id = str(relay_request.get("sessionId") or relay_request.get("id") or "")
        path = str(relay_request.get("path") or "/")
        target_base, target_path, route_name = self._resolve_relay_target(path)
        route_settings = self._current_relay_route_settings(state).get(route_name, {})
        rewrite_base_path = "/relay/" if route_name == "tunnel" else f"/relay/{route_name}/"

        if route_settings.get("websocket") is False:
            return relay_error_response("WebSockets are disabled for this route", rewrite_base_path, target_base)
        if not management_url or not relay_token or not session_id:
            return relay_error_response("Home Relay WebSocket session is not ready", rewrite_base_path, target_base)

        target_url = websocket_url_for(f"{target_base}/{target_path.lstrip('/')}")
        relay_headers = relay_request.get("headers") or {}
        try:
            local_socket, response_headers = open_local_websocket(
                target_url,
                relay_headers,
                proxy_forwarding_headers(relay_headers, rewrite_base_path, path),
                str(route_settings.get("hostHeader") or ""),
            )
        except Exception as error:
            return relay_error_response(f"Local WebSocket is not reachable: {error}", rewrite_base_path, target_base)

        stop_event = threading.Event()
        local_to_vps = threading.Thread(
            target=self._pump_local_websocket_to_vps,
            args=(local_socket, management_url, relay_token, session_id, stop_event),
            name=f"tater-home-ws-local-{session_id}",
            daemon=True,
        )
        vps_to_local = threading.Thread(
            target=self._pump_vps_websocket_to_local,
            args=(local_socket, management_url, relay_token, session_id, stop_event),
            name=f"tater-home-ws-vps-{session_id}",
            daemon=True,
        )
        local_to_vps.start()
        vps_to_local.start()

        return {
            "status": HTTPStatus.SWITCHING_PROTOCOLS,
            "headers": websocket_response_headers(response_headers),
            "bodyBase64": "",
            "rewriteBasePath": rewrite_base_path,
            "rewriteOrigin": target_base,
        }

    def _pump_local_websocket_to_vps(
        self,
        local_socket: socket.socket,
        management_url: str,
        relay_token: str,
        session_id: str,
        stop_event: threading.Event,
    ) -> None:
        try:
            while not stop_event.is_set():
                frame = read_frame(local_socket, masked=False)
                opcode = int(frame["opcode"])
                if opcode == OPCODE_PING:
                    write_frame(local_socket, OPCODE_PONG, frame["payload"], masked=True)
                    continue
                if opcode == OPCODE_PONG:
                    continue

                self.vps_client.send_websocket_frames(
                    management_url,
                    relay_token,
                    session_id,
                    [frame_to_payload(frame)],
                    closed=opcode == OPCODE_CLOSE,
                )
                if opcode == OPCODE_CLOSE:
                    break
        except Exception:
            pass
        finally:
            stop_event.set()
            close_socket(local_socket)
            try:
                self.vps_client.send_websocket_frames(management_url, relay_token, session_id, [], closed=True)
            except Exception:
                pass

    def _pump_vps_websocket_to_local(
        self,
        local_socket: socket.socket,
        management_url: str,
        relay_token: str,
        session_id: str,
        stop_event: threading.Event,
    ) -> None:
        try:
            while not stop_event.is_set():
                payload = self.vps_client.poll_websocket_frames(management_url, relay_token, session_id)
                for frame_payload in payload.get("frames") or []:
                    frame = payload_to_frame(frame_payload)
                    opcode = int(frame["opcode"])
                    write_frame(local_socket, opcode, frame["payload"], bool(frame["fin"]), masked=True)
                    if opcode == OPCODE_CLOSE:
                        stop_event.set()
                        break

                if payload.get("closed"):
                    stop_event.set()
        except Exception:
            pass
        finally:
            stop_event.set()
            close_socket(local_socket)

    def _record_relay_error(self, message: str) -> None:
        state = self.store.load()
        if not state.get("homeAgent"):
            return
        state["homeAgent"]["runtime"] = self._home_relay_runtime("relay-error", f"Home Relay failed: {message}")
        self.store.save(state)

    def _record_relay_ok(self, action: str, message: str, only_after_error: bool = False) -> None:
        state = self.store.load()
        if not state.get("homeAgent"):
            return
        runtime = state["homeAgent"].get("runtime") or {}
        if only_after_error and runtime.get("lastAction") != "relay-error":
            return
        state["homeAgent"]["runtime"] = self._home_relay_runtime(action, message)
        self.store.save(state)

    def _apply_wireguard(self, state: dict[str, Any]) -> None:
        try:
            state["homeAgent"]["runtime"] = self.wireguard_runtime.apply(state, self._endpoint(state))
        except WireGuardRuntimeError as error:
            raise AgentError(HTTPStatus.BAD_GATEWAY, f"WireGuard runtime failed: {error}") from error

    def _home_relay_runtime(self, action: str, message: str) -> dict[str, str]:
        return {
            "backend": "relay",
            "transport": "tls-reverse-tunnel",
            "lastAction": action,
            "lastAppliedAt": utc_now(),
            "message": message,
        }

    def _public_state(self, state: dict[str, Any]) -> dict[str, Any]:
        public = deepcopy(state)
        home_agent = public.setdefault("homeAgent", {})
        if public.get("paired"):
            if not home_agent.get("relay"):
                home_agent["relay"] = {
                    "status": "connected",
                    "transport": "tls-reverse-tunnel",
                    "managementUrl": (public.get("vpsAgent") or {}).get("managementUrl") or management_url_for(public.get("vps", "")),
                    "target": self.relay_target,
                    "routes": self._current_relay_routes(public),
                    "pairedAt": public.get("lastCheck", ""),
                }
            home_agent["relay"]["routes"] = self._current_relay_routes(public)
            home_agent["relay"]["routeSettings"] = self._current_relay_route_settings(public)
            home_agent["relay"].pop("token", None)
            if not home_agent.get("runtime") or home_agent.get("runtime", {}).get("backend") != "relay":
                home_agent["runtime"] = self._home_relay_runtime("paired", "Home Agent paired as relay client")
            home_agent["wireguard"] = None
        else:
            wireguard = home_agent.get("wireguard")
            if wireguard:
                wireguard.pop("privateKey", None)
        public["endpoint"] = self._endpoint(public)
        return public

    def _with_state(self, state: dict[str, Any]) -> dict[str, Any]:
        return {"state": self._public_state(state)}

    def _resolve_relay_target(self, path: str) -> tuple[str, str, str]:
        raw_path = f"/{str(path or '/').lstrip('/')}"
        parsed = urlparse(raw_path)
        path_parts = parsed.path.lstrip("/").split("/", 1)
        route_name = path_parts[0] if path_parts and path_parts[0] else ""
        routes = self._current_relay_routes()

        if route_name in routes:
            routed_path = f"/{path_parts[1]}" if len(path_parts) > 1 else "/"
            if parsed.query:
                routed_path = f"{routed_path}?{parsed.query}"
            return routes[route_name], routed_path, route_name

        return self.relay_target, raw_path, "tunnel"

    def _current_relay_routes(self, state: dict[str, Any] | None = None) -> dict[str, str]:
        if state is None:
            state = self.store.load()
        persisted = ((state.get("homeAgent") or {}).get("relay") or {}).get("routes") or {}
        return normalize_relay_routes(self.relay_target, {**self.relay_routes, **persisted})

    def _current_relay_route_settings(self, state: dict[str, Any] | None = None) -> dict[str, dict[str, Any]]:
        if state is None:
            state = self.store.load()
        persisted = ((state.get("homeAgent") or {}).get("relay") or {}).get("routeSettings") or {}
        if not isinstance(persisted, dict):
            return {}
        return {
            normalize_route_name(name): normalize_route_settings(settings)
            for name, settings in persisted.items()
            if str(name).strip() and isinstance(settings, dict)
        }

    def _serialize_keypair(self, keypair: KeyPair) -> dict[str, str]:
        return {
            "privateKey": keypair.private_key,
            "publicKey": keypair.public_key,
            "keySource": keypair.source,
        }


class VpsAgentClient:
    def health(self, base_url: str) -> dict[str, Any]:
        return self._request("GET", base_url, "/api/health", None)

    def wireguard(self, base_url: str, token: str = "") -> dict[str, Any]:
        return self._request("GET", base_url, "/api/wireguard", None, headers=management_headers(token))

    def claim(self, base_url: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self._request("POST", base_url, "/api/claim", payload)

    def add_peer(self, base_url: str, payload: dict[str, Any], token: str = "") -> dict[str, Any]:
        return self._request("POST", base_url, "/api/peers", payload, headers=management_headers(token))

    def remove_peer(self, base_url: str, peer_id: str, token: str = "") -> dict[str, Any]:
        return self._request("DELETE", base_url, f"/api/peers/{peer_id}", None, headers=management_headers(token))

    def poll_relay(self, base_url: str, token: str) -> dict[str, Any] | None:
        return self._request(
            "GET",
            base_url,
            "/api/relay/next",
            None,
            headers={"X-Tater-Relay-Token": token},
            timeout=25,
            allow_empty=True,
        )

    def complete_relay(self, base_url: str, token: str, request_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self._request(
            "POST",
            base_url,
            f"/api/relay/responses/{request_id}",
            payload,
            headers={"X-Tater-Relay-Token": token},
        )

    def poll_websocket_frames(self, base_url: str, token: str, session_id: str) -> dict[str, Any]:
        return self._request(
            "GET",
            base_url,
            f"/api/relay/ws/{session_id}/client-frames",
            None,
            headers={"X-Tater-Relay-Token": token},
            timeout=25,
        )

    def send_websocket_frames(
        self,
        base_url: str,
        token: str,
        session_id: str,
        frames: list[dict[str, Any]],
        closed: bool = False,
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            base_url,
            f"/api/relay/ws/{session_id}/server-frames",
            {
                "frames": frames,
                "closed": closed,
            },
            headers={"X-Tater-Relay-Token": token},
        )

    def _request(
        self,
        method: str,
        base_url: str,
        path: str,
        payload: dict[str, Any] | None,
        headers: dict[str, str] | None = None,
        timeout: float = 3,
        allow_empty: bool = False,
    ) -> dict[str, Any] | None:
        url = f"{base_url.rstrip('/')}{path}"
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        request_headers = {"Content-Type": "application/json"}
        request_headers.update(headers or {})
        request = urllib.request.Request(
            url,
            data=body,
            method=method,
            headers=request_headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw_body = response.read()
                if allow_empty and not raw_body:
                    return None
                return json.loads(raw_body.decode("utf-8"))
        except urllib.error.HTTPError as error:
            message = error.read().decode("utf-8")
            if allow_empty and error.code == HTTPStatus.NO_CONTENT:
                return None
            try:
                message = json.loads(message).get("error", message)
            except json.JSONDecodeError:
                pass
            raise AgentError(HTTPStatus(error.code), f"VPS Agent: {message}") from error
        except OSError as error:
            raise AgentError(HTTPStatus.BAD_GATEWAY, f"VPS Agent is not reachable: {error}") from error


class HomeAgentServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        static_root: Path,
        service: HomeAgentService,
        start_relay_worker: bool = True,
        relay_workers: int = DEFAULT_RELAY_WORKERS,
    ):
        self._relay_stop = threading.Event()
        self._relay_threads: list[threading.Thread] = []
        super().__init__(server_address, HomeAgentHandler)
        self.static_root = static_root
        self.service = service
        if start_relay_worker:
            for worker_index in range(max(1, relay_workers)):
                relay_thread = threading.Thread(
                    target=self.service.relay_loop,
                    args=(self._relay_stop,),
                    name=f"tater-home-relay-{worker_index + 1}",
                    daemon=True,
                )
                relay_thread.start()
                self._relay_threads.append(relay_thread)

    def server_close(self) -> None:
        relay_stop = getattr(self, "_relay_stop", None)
        if relay_stop:
            relay_stop.set()
        relay_threads = getattr(self, "_relay_threads", [])
        for relay_thread in relay_threads:
            relay_thread.join(timeout=2)
        super().server_close()


class HomeAgentHandler(BaseHTTPRequestHandler):
    server: HomeAgentServer

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/state":
            self._send_json(self.server.service.state())
            return
        if path == "/api/wireguard":
            self._send_json(self.server.service.wireguard_diagnostics())
            return

        self._serve_static(path)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            payload = self._read_json()
            if path == "/api/pair":
                self._send_json(self.server.service.pair_vps(payload))
            elif path == "/api/health":
                self._send_json(self.server.service.check_health())
            elif path == "/api/devices":
                self._send_json(self.server.service.add_device(payload), HTTPStatus.CREATED)
            elif path == "/api/relay-routes":
                self._send_json(self.server.service.add_relay_route(payload), HTTPStatus.CREATED)
            elif path == "/api/relay-routes/test":
                self._send_json(self.server.service.test_relay_route(payload))
            elif path == "/api/reset":
                self._send_json(self.server.service.reset())
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
        except AgentError as error:
            self._send_error(error.status, error.message)
        except json.JSONDecodeError:
            self._send_error(HTTPStatus.BAD_REQUEST, "Request body must be valid JSON")

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        route_prefix = "/api/relay-routes/"
        if path.startswith(route_prefix):
            route_name = unquote(path[len(route_prefix) :])
            try:
                self._send_json(self.server.service.remove_relay_route(route_name))
            except AgentError as error:
                self._send_error(error.status, error.message)
            return

        prefix = "/api/devices/"
        if not path.startswith(prefix):
            self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
            return

        device_id = unquote(path[len(prefix) :])
        try:
            self._send_json(self.server.service.revoke_device(device_id))
        except AgentError as error:
            self._send_error(error.status, error.message)

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.address_string()} - {format % args}")

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        body = self.rfile.read(length)
        return json.loads(body.decode("utf-8"))

    def _serve_static(self, path: str) -> None:
        relative = "index.html" if path in {"", "/"} else path.lstrip("/")
        target = (self.server.static_root / unquote(relative)).resolve()

        try:
            target.relative_to(self.server.static_root.resolve())
        except ValueError:
            self._send_error(HTTPStatus.FORBIDDEN, "Static path is outside the app")
            return

        if not target.exists() or not target.is_file():
            self._send_error(HTTPStatus.NOT_FOUND, "File not found")
            return

        mime_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        body = target.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", mime_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status: HTTPStatus, message: str) -> None:
        self._send_json({"error": message}, status)


def management_headers(token: str) -> dict[str, str]:
    return {"X-Tater-Relay-Token": token} if token else {}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def normalize_route_name(name: str) -> str:
    route_name = str(name or "").strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", route_name):
        raise AgentError(HTTPStatus.BAD_REQUEST, "Route name must use lowercase letters, numbers, or dashes")
    if route_name in {"api", "relay"}:
        raise AgentError(HTTPStatus.BAD_REQUEST, f"{route_name} is reserved")
    return route_name


def normalize_route_target(target: str) -> str:
    route_target = str(target or "").strip().rstrip("/")
    parsed = urlparse(route_target)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Route target must start with http:// or https://")
    return route_target


def header_value(headers: dict[str, Any], name: str) -> str:
    expected = name.lower()
    for header_name, value in headers.items():
        if str(header_name).lower() == expected:
            return str(value)
    return ""


def proxy_forwarding_headers(headers: dict[str, Any], base_path: str, relay_path: str) -> dict[str, str]:
    prefix = base_path.rstrip("/") or "/relay"
    original_host = header_value(headers, "X-Forwarded-Host") or header_value(headers, "Host")
    original_proto = header_value(headers, "X-Forwarded-Proto") or "http"
    original_for = header_value(headers, "X-Forwarded-For")
    public_uri = f"/relay/{str(relay_path or '/').lstrip('/')}"

    forwarded = {
        "X-Forwarded-Prefix": prefix,
        "X-Script-Name": prefix,
        "X-Original-URI": public_uri,
        "X-Forwarded-Proto": original_proto,
    }
    if original_host:
        forwarded["X-Forwarded-Host"] = original_host
    if original_for:
        forwarded["X-Forwarded-For"] = original_for
    return forwarded


def websocket_url_for(target_url: str) -> str:
    parsed = urlparse(target_url)
    if parsed.scheme == "http":
        return f"ws://{parsed.netloc}{parsed.path or '/'}{f'?{parsed.query}' if parsed.query else ''}"
    if parsed.scheme == "https":
        return f"wss://{parsed.netloc}{parsed.path or '/'}{f'?{parsed.query}' if parsed.query else ''}"
    if parsed.scheme in {"ws", "wss"}:
        return target_url
    raise AgentError(HTTPStatus.BAD_GATEWAY, "Route target cannot be used for WebSockets")


def open_local_websocket(
    target_url: str,
    relay_headers: dict[str, Any],
    forwarded_headers: dict[str, str],
    host_header: str = "",
) -> tuple[socket.socket, dict[str, str]]:
    parsed = urlparse(target_url)
    if parsed.scheme not in {"ws", "wss"} or not parsed.hostname:
        raise OSError("invalid WebSocket target")

    port = parsed.port or (443 if parsed.scheme == "wss" else 80)
    raw_socket = socket.create_connection((parsed.hostname, port), timeout=RELAY_PROXY_TIMEOUT_SECONDS)
    local_socket: socket.socket
    if parsed.scheme == "wss":
        local_socket = ssl.create_default_context().wrap_socket(raw_socket, server_hostname=parsed.hostname)
    else:
        local_socket = raw_socket

    key = create_websocket_key()
    request_path = parsed.path or "/"
    if parsed.query:
        request_path = f"{request_path}?{parsed.query}"

    host = host_header or parsed.netloc
    headers = {
        "Host": host,
        "Upgrade": "websocket",
        "Connection": "Upgrade",
        "Sec-WebSocket-Key": key,
        "Sec-WebSocket-Version": "13",
        "User-Agent": "Tater-Tunnel-WebSocket/1.0",
    }
    protocol = header_value(relay_headers, "Sec-WebSocket-Protocol")
    if protocol:
        headers["Sec-WebSocket-Protocol"] = protocol
    origin = header_value(relay_headers, "Origin")
    if origin:
        headers["Origin"] = origin
    cookie = header_value(relay_headers, "Cookie")
    if cookie:
        headers["Cookie"] = cookie
    headers.update(forwarded_headers)

    request = "\r\n".join(
        [f"GET {request_path} HTTP/1.1", *[f"{name}: {value}" for name, value in headers.items()], "", ""]
    ).encode("utf-8")
    local_socket.sendall(request)

    status, response_headers = read_websocket_handshake_response(local_socket)
    if status != HTTPStatus.SWITCHING_PROTOCOLS:
        close_socket(local_socket)
        raise OSError(f"local WebSocket returned HTTP {status}")

    expected_accept = websocket_accept_key(key)
    actual_accept = header_value(response_headers, "Sec-WebSocket-Accept")
    if actual_accept and actual_accept != expected_accept:
        close_socket(local_socket)
        raise OSError("local WebSocket accept key did not match")

    return local_socket, response_headers


def read_websocket_handshake_response(local_socket: socket.socket) -> tuple[int, dict[str, str]]:
    buffer = b""
    while b"\r\n\r\n" not in buffer:
        chunk = local_socket.recv(4096)
        if not chunk:
            raise OSError("local WebSocket closed during handshake")
        buffer += chunk
        if len(buffer) > 65536:
            raise OSError("local WebSocket handshake is too large")

    head = buffer.split(b"\r\n\r\n", 1)[0].decode("iso-8859-1", errors="replace")
    lines = head.split("\r\n")
    status_parts = lines[0].split(" ", 2)
    if len(status_parts) < 2 or not status_parts[1].isdigit():
        raise OSError("local WebSocket returned an invalid response")

    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        headers[name.strip()] = value.strip()
    return int(status_parts[1]), headers


def websocket_response_headers(headers: dict[str, str]) -> dict[str, str]:
    protocol = header_value(headers, "Sec-WebSocket-Protocol")
    return {"Sec-WebSocket-Protocol": protocol} if protocol else {}


def relay_error_response(message: str, rewrite_base_path: str, rewrite_origin: str) -> dict[str, Any]:
    body = message.encode("utf-8")
    return {
        "status": HTTPStatus.BAD_GATEWAY,
        "headers": {"Content-Type": "text/plain; charset=utf-8"},
        "bodyBase64": base64.b64encode(body).decode("ascii"),
        "rewriteBasePath": rewrite_base_path,
        "rewriteOrigin": rewrite_origin,
    }


def close_socket(local_socket: socket.socket) -> None:
    try:
        local_socket.close()
    except OSError:
        pass


def normalize_route_path(path: str) -> str:
    route_path = str(path or "").strip()
    if not route_path:
        return ""
    if not route_path.startswith("/"):
        route_path = f"/{route_path}"
    parsed = urlparse(route_path)
    if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Route path must be a local path like /web")
    normalized = "/" + parsed.path.strip("/")
    return "" if normalized == "/" else normalized


def route_from_payload(payload: dict[str, Any]) -> tuple[str, str]:
    name = normalize_route_name(str(payload.get("name") or ""))
    if payload.get("target"):
        return name, normalize_route_target(str(payload["target"]))

    host = str(payload.get("host") or payload.get("localHost") or "127.0.0.1").strip()
    port_value = str(payload.get("port") or "").strip()
    if not port_value:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Route port is required")

    try:
        port = int(port_value)
    except ValueError as error:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Route port must be a number") from error

    if port < 1 or port > 65535:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Route port must be between 1 and 65535")

    parsed_host = urlparse(host if "://" in host else f"//{host}")
    clean_host = parsed_host.hostname or host
    if not clean_host or "/" in clean_host:
        raise AgentError(HTTPStatus.BAD_REQUEST, "Route host is invalid")

    route_path = normalize_route_path(str(payload.get("path") or payload.get("basePath") or ""))
    return name, normalize_route_target(f"http://{clean_host}:{port}{route_path}")


def route_settings_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return normalize_route_settings(
        {
            "websocket": payload.get("websocket", payload.get("webSockets", True)),
            "hostHeader": payload.get("hostHeader") or payload.get("forceHostHeader") or "",
        }
    )


def normalize_route_settings(settings: dict[str, Any]) -> dict[str, Any]:
    normalized: dict[str, Any] = {}
    if settings.get("websocket") is not None:
        normalized["websocket"] = bool_setting(settings.get("websocket"))

    host_header = str(settings.get("hostHeader") or settings.get("forceHostHeader") or "").strip()
    if host_header:
        if "/" in host_header or "\r" in host_header or "\n" in host_header:
            raise AgentError(HTTPStatus.BAD_REQUEST, "Route host header is invalid")
        normalized["hostHeader"] = host_header

    return normalized


def bool_setting(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() not in {"0", "false", "no", "off"}
    return bool(value)


def test_route_target(target: str, settings: dict[str, Any] | None = None) -> dict[str, Any]:
    target_url = normalize_route_target(target)
    route_settings = normalize_route_settings(settings or {})
    checked_at = utc_now()
    try:
        status, message = request_route_target(target_url, "HEAD", route_settings)
    except urllib.error.HTTPError as error:
        if error.code in {HTTPStatus.METHOD_NOT_ALLOWED, HTTPStatus.NOT_IMPLEMENTED}:
            status, message = request_route_target(target_url, "GET", route_settings)
        else:
            status = error.code
            message = error.reason or HTTPStatus(error.code).phrase
    except OSError as error:
        return {
            "ok": False,
            "status": None,
            "message": str(error),
            "checkedAt": checked_at,
        }

    return {
        "ok": 200 <= int(status) < 500,
        "status": int(status),
        "message": message,
        "checkedAt": checked_at,
    }


def request_route_target(target_url: str, method: str, settings: dict[str, Any] | None = None) -> tuple[int, str]:
    headers = {
        "Accept": "*/*",
        "Accept-Encoding": "identity",
        "User-Agent": "Tater-Tunnel-Route-Test/1.0",
    }
    route_settings = normalize_route_settings(settings or {})
    if route_settings.get("hostHeader"):
        headers["Host"] = str(route_settings["hostHeader"])

    request = urllib.request.Request(
        target_url,
        method=method,
        headers=headers,
    )
    with urllib.request.build_opener(NoRedirectHandler).open(request, timeout=5) as response:
        return int(response.status), response.reason or HTTPStatus(response.status).phrase


def parse_relay_route(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("Relay routes must look like name=http://127.0.0.1:PORT")

    name, target = value.split("=", 1)
    try:
        return normalize_route_name(name), normalize_route_target(target)
    except AgentError as error:
        raise argparse.ArgumentTypeError(error.message) from error


def normalize_relay_routes(relay_target: str, relay_routes: dict[str, str]) -> dict[str, str]:
    normalized = {
        str(name).strip().lower(): str(target).strip().rstrip("/")
        for name, target in relay_routes.items()
        if str(name).strip() and str(target).strip()
    }
    normalized.setdefault("tunnel", relay_target.rstrip("/"))
    return normalized


def management_url_for(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme in {"http", "https"}:
        if parsed.port:
            return value.rstrip("/")

        host = parsed.hostname or parsed.netloc or parsed.path
        if parsed.scheme == "https":
            return f"https://{host}"
        return f"{parsed.scheme}://{host}:{VPS_AGENT_PORT}"

    host = value.strip().rstrip("/")
    parsed_host = urlparse(f"//{host}")
    if parsed_host.port:
        return f"http://{host}"
    return f"http://{host}:{VPS_AGENT_PORT}"


def endpoint_host(value: str) -> str:
    parsed = urlparse(value)
    if parsed.hostname:
        return parsed.hostname
    return value


def sanitize_headers(headers: dict[str, Any]) -> dict[str, str]:
    sanitized: dict[str, str] = {}
    for name, value in headers.items():
        header_name = str(name).strip()
        if not header_name or header_name.lower() in HOP_BY_HOP_HEADERS:
            continue
        sanitized[header_name] = str(value)
    return sanitized


def build_server(
    host: str,
    port: int,
    state_file: Path,
    static_root: Path,
    wireguard_backend: str = "config",
    wireguard_config: Path = WIREGUARD_CONFIG_PATH,
    wireguard_interface: str = "tater-home",
    relay_target: str = "http://127.0.0.1:4173",
    relay_routes: dict[str, str] | None = None,
    relay_workers: int = DEFAULT_RELAY_WORKERS,
) -> HomeAgentServer:
    store = ConfigStore(state_file)
    runtime = build_wireguard_client_runtime(wireguard_backend, wireguard_config, wireguard_interface)
    service = HomeAgentService(store, wireguard_runtime=runtime, relay_target=relay_target, relay_routes=relay_routes)
    return HomeAgentServer((host, port), static_root.resolve(), service, relay_workers=relay_workers)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the Tater Tunnel Home Agent prototype")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=4173, type=int)
    parser.add_argument("--state-file", default=STATE_PATH, type=Path)
    parser.add_argument("--static-root", default=PROJECT_ROOT, type=Path)
    parser.add_argument("--wireguard-backend", choices=["config", "wg", "system"], default="config")
    parser.add_argument("--wireguard-config", default=WIREGUARD_CONFIG_PATH, type=Path)
    parser.add_argument("--wireguard-interface", default="tater-home")
    parser.add_argument("--relay-target", default="http://127.0.0.1:4173")
    parser.add_argument("--relay-workers", default=DEFAULT_RELAY_WORKERS, type=int)
    parser.add_argument(
        "--relay-route",
        action="append",
        default=[],
        type=parse_relay_route,
        help="Named route in the form name=http://127.0.0.1:PORT. Example: --relay-route tater=http://127.0.0.1:8000",
    )
    args = parser.parse_args(argv)
    relay_routes = dict(args.relay_route)

    server = build_server(
        args.host,
        args.port,
        args.state_file,
        args.static_root,
        args.wireguard_backend,
        args.wireguard_config,
        args.wireguard_interface,
        args.relay_target,
        relay_routes,
        args.relay_workers,
    )
    print(f"Tater Tunnel Home Agent listening on http://{args.host}:{args.port}")
    print(f"State file: {args.state_file}")
    print(f"WireGuard backend: {args.wireguard_backend}")
    print(f"WireGuard config: {args.wireguard_config}")
    print(f"Home Relay target: {args.relay_target}")
    print(f"Home Relay workers: {max(1, args.relay_workers)}")
    if relay_routes:
        for name, target in sorted(relay_routes.items()):
            print(f"Home Relay route /{name}/ -> {target}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Home Agent")
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
