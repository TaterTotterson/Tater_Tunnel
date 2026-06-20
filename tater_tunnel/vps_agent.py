from __future__ import annotations

import argparse
import base64
import json
import os
import re
import secrets
import tempfile
import threading
import time
import traceback
from copy import deepcopy
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urljoin, urlparse

from .wireguard import KeyPair, WireGuardKeyProvider
from .wireguard_runtime import WireGuardRuntimeError, build_wireguard_runtime
from .websocket_relay import (
    OPCODE_CLOSE,
    OPCODE_PING,
    OPCODE_PONG,
    frame_to_payload,
    payload_to_frame,
    read_frame,
    websocket_accept_key,
    write_frame,
)


PROJECT_ROOT = Path(__file__).resolve().parent.parent
STATE_PATH = PROJECT_ROOT / ".tater_tunnel" / "vps-agent.json"
WIREGUARD_CONFIG_PATH = PROJECT_ROOT / ".tater_tunnel" / "wireguard" / "tater0.conf"
VALID_MODES = {"minimal", "safe", "lockdown"}
RELAY_POLL_TIMEOUT_SECONDS = 20
RELAY_REQUEST_TIMEOUT_SECONDS = 75
RELAY_MAX_BODY_BYTES = 2 * 1024 * 1024
LANDING_MASCOT_PATH = PROJECT_ROOT / "assets" / "tater-vps-mascot.png"
LANDING_PAGE_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tater Tunnel</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #12100d;
      --panel: #1f1b16;
      --text: #fff4e4;
      --muted: #cdbda9;
      --accent: #ff981a;
      --line: #3a3127;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background:
        radial-gradient(circle at 50% 20%, rgba(255, 152, 26, 0.18), transparent 34rem),
        linear-gradient(180deg, #18130f, var(--bg));
      color: var(--text);
      font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main {
      width: min(38rem, calc(100vw - 2rem));
      padding: clamp(1.25rem, 4vw, 2rem);
      text-align: center;
    }
    img {
      display: block;
      width: min(18rem, 72vw);
      height: auto;
      margin: 0 auto 1rem;
      filter: drop-shadow(0 28px 60px rgba(0, 0, 0, 0.38));
    }
    section {
      padding: 1.35rem;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: color-mix(in srgb, var(--panel) 90%, transparent);
      box-shadow: 0 24px 70px rgba(0, 0, 0, 0.32);
    }
    h1 {
      margin: 0 0 0.45rem;
      font-size: clamp(1.75rem, 4vw, 2.35rem);
      line-height: 1.1;
      letter-spacing: 0;
    }
    p {
      max-width: 30rem;
      margin: 0 auto;
      color: var(--muted);
    }
    a {
      display: inline-flex;
      margin-top: 1.1rem;
      color: #1a1007;
      background: var(--accent);
      text-decoration: none;
      font-weight: 700;
      padding: 0.65rem 0.85rem;
      border-radius: 7px;
    }
  </style>
</head>
<body>
  <main>
    <img src="/assets/tater-vps-mascot.png" alt="Tater mascot connecting two ethernet cables">
    <section>
      <h1>Tater Tunnel is running.</h1>
      <p>Nothing to see here, just a private relay keeping the cables connected.</p>
      <a href="/api/health">Check health</a>
    </section>
  </main>
</body>
</html>
"""
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


class VpsAgentError(Exception):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class WebSocketRelaySession:
    def __init__(self, session_id: str):
        self.id = session_id
        self._condition = threading.Condition()
        self._client_frames: list[dict[str, Any]] = []
        self._server_frames: list[dict[str, Any]] = []
        self.closed = False

    def close(self) -> None:
        with self._condition:
            self.closed = True
            self._condition.notify_all()

    def push_client_frame(self, frame: dict[str, Any]) -> None:
        self._push(self._client_frames, frame)

    def push_server_frame(self, frame: dict[str, Any]) -> None:
        self._push(self._server_frames, frame)

    def poll_client_frames(self, timeout: float = RELAY_POLL_TIMEOUT_SECONDS) -> dict[str, Any]:
        return self._poll(self._client_frames, timeout)

    def poll_server_frames(self, timeout: float = 1.0) -> dict[str, Any]:
        return self._poll(self._server_frames, timeout)

    def _push(self, queue: list[dict[str, Any]], frame: dict[str, Any]) -> None:
        with self._condition:
            if not self.closed:
                queue.append(frame)
            self._condition.notify_all()

    def _poll(self, queue: list[dict[str, Any]], timeout: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        with self._condition:
            while not queue and not self.closed:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self._condition.wait(remaining)

            frames = list(queue)
            queue.clear()
            return {
                "frames": frames,
                "closed": self.closed and not queue,
            }


class RelayBroker:
    def __init__(self):
        self._condition = threading.Condition()
        self._pending: list[str] = []
        self._requests: dict[str, dict[str, Any]] = {}
        self._websocket_sessions: dict[str, WebSocketRelaySession] = {}

    def enqueue(self, relay_request: dict[str, Any], timeout: float = RELAY_REQUEST_TIMEOUT_SECONDS) -> dict[str, Any]:
        request_id = relay_request["id"]
        deadline = time.monotonic() + timeout

        with self._condition:
            self._requests[request_id] = {
                "request": relay_request,
                "response": None,
            }
            self._pending.append(request_id)
            self._condition.notify_all()

            while True:
                entry = self._requests.get(request_id)
                if entry and entry["response"] is not None:
                    response = entry["response"]
                    self._requests.pop(request_id, None)
                    return response

                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._requests.pop(request_id, None)
                    self._pending = [pending_id for pending_id in self._pending if pending_id != request_id]
                    raise VpsAgentError(HTTPStatus.GATEWAY_TIMEOUT, "Home Relay did not answer in time")

                self._condition.wait(remaining)

    def poll(self, timeout: float = RELAY_POLL_TIMEOUT_SECONDS) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout

        with self._condition:
            while not self._pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self._condition.wait(remaining)

            request_id = self._pending.pop(0)
            entry = self._requests.get(request_id)
            if not entry:
                return None
            return deepcopy(entry["request"])

    def complete(self, request_id: str, response: dict[str, Any]) -> dict[str, Any]:
        with self._condition:
            entry = self._requests.get(request_id)
            if not entry:
                raise VpsAgentError(HTTPStatus.NOT_FOUND, "Relay request is no longer waiting")

            entry["response"] = response
            self._condition.notify_all()
            return {"accepted": True, "id": request_id}

    def create_websocket_session(self) -> WebSocketRelaySession:
        session = WebSocketRelaySession(secrets.token_urlsafe(18))
        with self._condition:
            self._websocket_sessions[session.id] = session
        return session

    def websocket_session(self, session_id: str) -> WebSocketRelaySession:
        with self._condition:
            session = self._websocket_sessions.get(session_id)
        if not session:
            raise VpsAgentError(HTTPStatus.NOT_FOUND, "WebSocket relay session not found")
        return session

    def close_websocket_session(self, session_id: str) -> None:
        with self._condition:
            session = self._websocket_sessions.pop(session_id, None)
        if session:
            session.close()


def default_vps_state(pairing_code: str | None = None) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "claimed": False,
        "securityMode": "safe",
        "wireguardPort": 51888,
        "lastCheck": "",
        "pairing": {
            "enabled": True,
            "code": pairing_code or create_pairing_code(),
            "claimedAt": "",
        },
        "interface": {
            "name": "tater0",
            "address": "10.88.0.1/24",
            "network": "10.88.0.0/24",
            "wireguard": None,
        },
        "homeAgent": None,
        "runtime": None,
        "peers": [],
    }


class VpsConfigStore:
    def __init__(self, path: Path | str, pairing_code: str | None = None):
        self.path = Path(path)
        self.pairing_code = pairing_code
        self._lock = threading.RLock()

    def load(self) -> dict[str, Any]:
        with self._lock:
            if not self.path.exists():
                return self.save(default_vps_state(self.pairing_code))

            with self.path.open("r", encoding="utf-8") as handle:
                loaded = json.load(handle)

            return self._merge_defaults(loaded)

    def save(self, state: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            merged = self._merge_defaults(state)
            existing_stat = None
            if self.path.exists():
                existing_stat = self.path.stat()
            fd, temp_name = tempfile.mkstemp(
                prefix=f".{self.path.name}.",
                suffix=".tmp",
                dir=self.path.parent,
                text=True,
            )

            try:
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    json.dump(merged, handle, indent=2, sort_keys=True)
                    handle.write("\n")
                if existing_stat:
                    os.chmod(temp_name, existing_stat.st_mode & 0o777)
                    if hasattr(os, "chown"):
                        os.chown(temp_name, existing_stat.st_uid, existing_stat.st_gid)
                os.replace(temp_name, self.path)
            finally:
                if os.path.exists(temp_name):
                    os.unlink(temp_name)

            return deepcopy(merged)

    def reset(self) -> dict[str, Any]:
        return self.save(default_vps_state(self.pairing_code))

    def reopen_pairing(self, pairing_code: str | None = None) -> dict[str, Any]:
        state = self.load()
        state["pairing"]["enabled"] = True
        state["pairing"]["claimedAt"] = ""
        state["pairing"]["code"] = pairing_code or state["pairing"].get("code") or create_pairing_code()
        return self.save(state)

    def _merge_defaults(self, state: dict[str, Any]) -> dict[str, Any]:
        defaults = default_vps_state(self.pairing_code)
        merged = deepcopy(defaults)
        merged.update(
            {
                key: value
                for key, value in state.items()
                if key not in {"pairing", "interface"}
            }
        )
        merged["pairing"].update(state.get("pairing", {}))
        merged["interface"].update(state.get("interface", {}))
        return merged


class VpsAgentService:
    def __init__(
        self,
        store: VpsConfigStore,
        key_provider: WireGuardKeyProvider | None = None,
        wireguard_runtime: Any | None = None,
        relay_broker: RelayBroker | None = None,
    ):
        self.store = store
        self.key_provider = key_provider or WireGuardKeyProvider()
        self.wireguard_runtime = wireguard_runtime or build_wireguard_runtime(
            "config",
            WIREGUARD_CONFIG_PATH,
            "tater0",
        )
        self.relay_broker = relay_broker or RelayBroker()

    def state(self) -> dict[str, Any]:
        return self._public_state(self.store.load())

    def health(self) -> dict[str, Any]:
        state = self.store.load()
        state["lastCheck"] = utc_now()
        saved = self.store.save(state)
        return {
            "status": "ok",
            "claimed": saved["claimed"],
            "pairingEnabled": saved["pairing"]["enabled"],
            "peerCount": len(saved["peers"]),
        }

    def wireguard_diagnostics(self) -> dict[str, Any]:
        state = self.store.load()
        return {
            "wireguard": self.wireguard_runtime.diagnostics(state),
            "runtime": self._public_state(state).get("runtime"),
        }

    def claim(self, payload: dict[str, Any], remote_address: str = "") -> dict[str, Any]:
        state = self.store.load()
        pairing_code = str(payload.get("pairingCode") or "").strip()
        mode = str(payload.get("securityMode") or payload.get("mode") or "safe").strip().lower()
        home_agent = payload.get("homeAgent") or {}
        home_public_key = str(home_agent.get("publicKey") or "").strip()
        home_transport = str(home_agent.get("transport") or "wireguard").strip().lower()

        if not state["pairing"]["enabled"]:
            raise VpsAgentError(HTTPStatus.CONFLICT, "Pairing mode is disabled")
        if pairing_code != state["pairing"]["code"]:
            raise VpsAgentError(HTTPStatus.FORBIDDEN, "Pairing code is not valid")
        if mode not in VALID_MODES:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Security mode must be minimal, safe, or lockdown")
        if home_transport not in {"relay", "wireguard"}:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Home Agent transport must be relay or wireguard")
        if home_transport == "wireguard" and not home_public_key:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Home Agent WireGuard public key is required")

        if not state["interface"].get("wireguard"):
            state["interface"]["wireguard"] = self._serialize_keypair(self.key_provider.generate_keypair())

        now = utc_now()
        state["claimed"] = True
        state["securityMode"] = mode
        state["lastCheck"] = now
        state["pairing"]["enabled"] = False
        state["pairing"]["claimedAt"] = now
        state["homeAgent"] = {
            "id": str(home_agent.get("id") or "home-agent"),
            "transport": home_transport,
            "claimedFrom": remote_address,
        }
        if home_transport == "relay":
            state["homeAgent"]["relayToken"] = secrets.token_urlsafe(32)
        if home_public_key:
            state["homeAgent"]["publicKey"] = home_public_key
            state["homeAgent"]["allowedIp"] = "10.88.0.2/32"

        self._apply_wireguard(state)
        saved = self.store.save(state)
        vps_wireguard = {
            "publicKey": saved["interface"]["wireguard"]["publicKey"],
            "address": saved["interface"]["address"],
            "network": saved["interface"]["network"],
            "listenPort": saved["wireguardPort"],
        }
        if saved["homeAgent"].get("allowedIp"):
            vps_wireguard["homeAllowedIp"] = saved["homeAgent"]["allowedIp"]

        response = {
            "state": self._public_state(saved),
            "vpsWireGuard": vps_wireguard,
        }
        if saved["homeAgent"].get("relayToken"):
            response["relay"] = {
                "token": saved["homeAgent"]["relayToken"],
                "pollPath": "/api/relay/next",
                "responsePath": "/api/relay/responses/{id}",
                "publicPath": "/relay/",
            }

        return response

    def add_peer(self, payload: dict[str, Any]) -> dict[str, Any]:
        state = self.store.load()
        self._require_claimed(state)

        peer_id = str(payload.get("id") or "").strip()
        public_key = str(payload.get("publicKey") or "").strip()
        allowed_ip = str(payload.get("allowedIp") or "").strip()
        name = str(payload.get("name") or peer_id or "device").strip()

        if not peer_id:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer id is required")
        if not public_key:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer public key is required")
        if not allowed_ip:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Allowed IP is required")

        state["peers"] = [
            peer
            for peer in state["peers"]
            if peer.get("id") != peer_id
            and peer.get("publicKey") != public_key
            and peer.get("allowedIp") != allowed_ip
        ]
        state["peers"].insert(
            0,
            {
                "id": peer_id,
                "name": name,
                "publicKey": public_key,
                "allowedIp": allowed_ip,
                "createdAt": utc_now(),
                "status": "active",
            },
        )
        state["lastCheck"] = utc_now()
        self._apply_wireguard(state)
        return {"state": self._public_state(self.store.save(state))}

    def remove_peer(self, peer_id: str) -> dict[str, Any]:
        state = self.store.load()
        self._require_claimed(state)
        original_count = len(state["peers"])
        state["peers"] = [peer for peer in state["peers"] if peer["id"] != peer_id]

        if len(state["peers"]) == original_count:
            raise VpsAgentError(HTTPStatus.NOT_FOUND, "Peer not found")

        state["lastCheck"] = utc_now()
        self._apply_wireguard(state)
        return {"state": self._public_state(self.store.save(state))}

    def reset(self) -> dict[str, Any]:
        state = self.store.reset()
        self._apply_wireguard(state)
        return {"state": self._public_state(self.store.save(state))}

    def reopen_pairing(self, pairing_code: str | None = None) -> dict[str, Any]:
        state = self.store.reopen_pairing(pairing_code)
        return {"state": self._public_state(state)}

    def relay_request(
        self,
        method: str,
        path: str,
        headers: dict[str, str],
        body: bytes,
        timeout: float = RELAY_REQUEST_TIMEOUT_SECONDS,
    ) -> dict[str, Any]:
        state = self.store.load()
        self._require_claimed(state)
        if (state.get("homeAgent") or {}).get("transport") != "relay":
            raise VpsAgentError(HTTPStatus.CONFLICT, "Home Agent is not using relay transport")

        relay_request = {
            "id": secrets.token_urlsafe(18),
            "method": method.upper(),
            "path": path or "/",
            "headers": sanitize_headers(headers),
            "bodyBase64": base64.b64encode(body).decode("ascii"),
            "receivedAt": utc_now(),
        }
        return self.relay_broker.enqueue(relay_request, timeout)

    def open_websocket_relay(
        self,
        path: str,
        headers: dict[str, str],
        timeout: float = 10,
    ) -> tuple[WebSocketRelaySession, dict[str, Any]]:
        state = self.store.load()
        self._require_claimed(state)
        if (state.get("homeAgent") or {}).get("transport") != "relay":
            raise VpsAgentError(HTTPStatus.CONFLICT, "Home Agent is not using relay transport")

        session = self.relay_broker.create_websocket_session()
        relay_request = {
            "id": session.id,
            "sessionId": session.id,
            "method": "WEBSOCKET",
            "path": path or "/",
            "headers": sanitize_headers(headers),
            "bodyBase64": "",
            "receivedAt": utc_now(),
        }

        try:
            response = self.relay_broker.enqueue(relay_request, timeout)
        except Exception:
            self.relay_broker.close_websocket_session(session.id)
            raise

        return session, response

    def next_relay_request(self, token: str, timeout: float = RELAY_POLL_TIMEOUT_SECONDS) -> dict[str, Any] | None:
        self._require_relay_token(token)
        return self.relay_broker.poll(timeout)

    def complete_relay_request(self, token: str, request_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        self._require_relay_token(token)
        status = int(payload.get("status") or HTTPStatus.BAD_GATEWAY)
        headers = sanitize_headers(payload.get("headers") or {})
        body_base64 = str(payload.get("bodyBase64") or "")
        rewrite_base_path = normalize_rewrite_base_path(payload.get("rewriteBasePath"))

        if status < 100 or status > 599:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Relay response status is invalid")

        try:
            base64.b64decode(body_base64.encode("ascii"), validate=True)
        except (ValueError, TypeError) as error:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Relay response body is not valid base64") from error

        response = {
            "status": status,
            "headers": headers,
            "bodyBase64": body_base64,
        }
        if rewrite_base_path:
            response["rewriteBasePath"] = rewrite_base_path
        if payload.get("rewriteOrigin"):
            response["rewriteOrigin"] = str(payload.get("rewriteOrigin") or "")

        return self.relay_broker.complete(request_id, response)

    def poll_websocket_client_frames(self, token: str, session_id: str) -> dict[str, Any]:
        self._require_relay_token(token)
        session = self.relay_broker.websocket_session(session_id)
        return session.poll_client_frames()

    def send_websocket_server_frames(self, token: str, session_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        self._require_relay_token(token)
        session = self.relay_broker.websocket_session(session_id)
        frames = payload.get("frames") or []
        if not isinstance(frames, list):
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "WebSocket frames must be a list")

        for frame in frames:
            if not isinstance(frame, dict):
                raise VpsAgentError(HTTPStatus.BAD_REQUEST, "WebSocket frame must be an object")
            session.push_server_frame(frame)
            if int(frame.get("opcode") or 0) == OPCODE_CLOSE:
                session.close()

        if payload.get("closed"):
            session.close()

        return {"accepted": True, "closed": session.closed}

    def close_websocket_relay(self, session_id: str) -> None:
        self.relay_broker.close_websocket_session(session_id)

    def require_management_token(self, token: str) -> None:
        self._require_relay_token(token)

    def _require_claimed(self, state: dict[str, Any]) -> None:
        if not state["claimed"]:
            raise VpsAgentError(HTTPStatus.CONFLICT, "VPS Agent is not claimed")

    def _require_relay_token(self, token: str) -> None:
        state = self.store.load()
        self._require_claimed(state)
        relay_token = str((state.get("homeAgent") or {}).get("relayToken") or "")
        if not relay_token or not secrets.compare_digest(relay_token, str(token or "")):
            raise VpsAgentError(HTTPStatus.FORBIDDEN, "Home Relay token is not valid")

    def _apply_wireguard(self, state: dict[str, Any]) -> None:
        try:
            state["runtime"] = self.wireguard_runtime.apply(state)
        except WireGuardRuntimeError as error:
            raise VpsAgentError(HTTPStatus.BAD_GATEWAY, f"WireGuard runtime failed: {error}") from error

    def _public_state(self, state: dict[str, Any]) -> dict[str, Any]:
        public = deepcopy(state)
        wireguard = public.get("interface", {}).get("wireguard")
        if wireguard:
            wireguard.pop("privateKey", None)
        if public.get("pairing", {}).get("enabled") is False:
            public["pairing"].pop("code", None)
        if public.get("homeAgent"):
            public["homeAgent"].pop("relayToken", None)
        return public

    def _serialize_keypair(self, keypair: KeyPair) -> dict[str, str]:
        return {
            "privateKey": keypair.private_key,
            "publicKey": keypair.public_key,
            "keySource": keypair.source,
        }


class VpsAgentServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], service: VpsAgentService):
        super().__init__(server_address, VpsAgentHandler)
        self.service = service


class VpsAgentHandler(BaseHTTPRequestHandler):
    server: VpsAgentServer

    def do_GET(self) -> None:
        try:
            parsed = urlparse(self.path)
            path = parsed.path
            if path in {"", "/"}:
                self._send_landing_page()
            elif path == "/assets/tater-vps-mascot.png":
                self._send_static_png(LANDING_MASCOT_PATH)
            elif path == "/api/health":
                self._send_json(self.server.service.health())
            elif path == "/api/state":
                self.server.service.require_management_token(self._management_token())
                self._send_json(self.server.service.state())
            elif path == "/api/wireguard":
                self.server.service.require_management_token(self._management_token())
                self._send_json(self.server.service.wireguard_diagnostics())
            elif path == "/api/relay/next":
                self._handle_relay_poll()
            elif path.startswith("/api/relay/ws/"):
                self._handle_websocket_frame_poll(path)
            elif path.startswith("/relay"):
                self._handle_public_relay("GET", parsed)
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
        except VpsAgentError as error:
            self._send_error(error.status, error.message)
        except Exception as error:
            self._send_unexpected_error(error)

    def do_HEAD(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"", "/"}:
            self._send_landing_page()
            return
        if parsed.path == "/assets/tater-vps-mascot.png":
            self._send_static_png(LANDING_MASCOT_PATH)
            return
        if parsed.path.startswith("/relay"):
            self._handle_public_relay("HEAD", parsed)
            return

        self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path.startswith("/relay"):
            self._handle_public_relay("POST", urlparse(self.path))
            return

        try:
            payload = self._read_json()
            if path == "/api/claim":
                self._send_json(self.server.service.claim(payload, self.client_address[0]))
            elif path == "/api/peers":
                self.server.service.require_management_token(self._management_token())
                self._send_json(self.server.service.add_peer(payload), HTTPStatus.CREATED)
            elif path == "/api/reset":
                self.server.service.require_management_token(self._management_token())
                self._send_json(self.server.service.reset())
            elif path.startswith("/api/relay/responses/"):
                request_id = unquote(path.removeprefix("/api/relay/responses/"))
                token = self.headers.get("X-Tater-Relay-Token", "")
                self._send_json(self.server.service.complete_relay_request(token, request_id, payload))
            elif path.startswith("/api/relay/ws/"):
                self._handle_websocket_frame_post(path, payload)
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
        except VpsAgentError as error:
            self._send_error(error.status, error.message)
        except json.JSONDecodeError:
            self._send_error(HTTPStatus.BAD_REQUEST, "Request body must be valid JSON")
        except Exception as error:
            self._send_unexpected_error(error)

    def do_PUT(self) -> None:
        self._handle_public_relay("PUT", urlparse(self.path))

    def do_PATCH(self) -> None:
        self._handle_public_relay("PATCH", urlparse(self.path))

    def do_OPTIONS(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.startswith("/relay"):
            self._handle_public_relay("OPTIONS", parsed)
            return

        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Allow", "GET,HEAD,POST,PUT,PATCH,DELETE,OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        if path.startswith("/relay"):
            self._handle_public_relay("DELETE", urlparse(self.path))
            return

        prefix = "/api/peers/"
        if not path.startswith(prefix):
            self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
            return

        peer_id = unquote(path[len(prefix) :])
        try:
            self.server.service.require_management_token(self._management_token())
            self._send_json(self.server.service.remove_peer(peer_id))
        except VpsAgentError as error:
            self._send_error(error.status, error.message)
        except Exception as error:
            self._send_unexpected_error(error)

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.address_string()} - {format % args}")

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length == 0:
            return {}
        body = self.rfile.read(length)
        return json.loads(body.decode("utf-8"))

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        if length > RELAY_MAX_BODY_BYTES:
            raise VpsAgentError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Relay request body is too large")
        if length == 0:
            return b""
        return self.rfile.read(length)

    def _management_token(self) -> str:
        return self.headers.get("X-Tater-Management-Token") or self.headers.get("X-Tater-Relay-Token", "")

    def _handle_relay_poll(self) -> None:
        try:
            token = self.headers.get("X-Tater-Relay-Token", "")
            relay_request = self.server.service.next_relay_request(token)
            if relay_request is None:
                self.send_response(HTTPStatus.NO_CONTENT)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            self._send_json(relay_request)
        except VpsAgentError as error:
            self._send_error(error.status, error.message)
        except Exception as error:
            self._send_unexpected_error(error)

    def _handle_public_relay(self, method: str, parsed: Any) -> None:
        try:
            if is_websocket_upgrade(dict(self.headers.items())):
                self._handle_public_websocket_relay(parsed)
                return

            path = parsed.path.removeprefix("/relay") or "/"
            if parsed.query:
                path = f"{path}?{parsed.query}"
            response = self.server.service.relay_request(
                method,
                path,
                dict(self.headers.items()),
                self._read_body(),
            )
            self._send_relay_response(response)
        except VpsAgentError as error:
            self._send_error(error.status, error.message)
        except Exception as error:
            self._send_unexpected_error(error)

    def _handle_websocket_frame_poll(self, path: str) -> None:
        session_id, endpoint = parse_websocket_relay_api_path(path)
        if endpoint != "client-frames":
            self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
            return

        token = self.headers.get("X-Tater-Relay-Token", "")
        try:
            self._send_json(self.server.service.poll_websocket_client_frames(token, session_id))
        except VpsAgentError as error:
            self._send_error(error.status, error.message)

    def _handle_websocket_frame_post(self, path: str, payload: dict[str, Any]) -> None:
        session_id, endpoint = parse_websocket_relay_api_path(path)
        if endpoint != "server-frames":
            self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
            return

        token = self.headers.get("X-Tater-Relay-Token", "")
        try:
            self._send_json(self.server.service.send_websocket_server_frames(token, session_id, payload))
        except VpsAgentError as error:
            self._send_error(error.status, error.message)

    def _handle_public_websocket_relay(self, parsed: Any) -> None:
        headers = dict(self.headers.items())
        client_key = header_value(headers, "Sec-WebSocket-Key")
        if not client_key:
            self._send_error(HTTPStatus.BAD_REQUEST, "WebSocket key is required")
            return

        path = parsed.path.removeprefix("/relay") or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"

        session, response = self.server.service.open_websocket_relay(path, headers)
        status = int(response.get("status") or HTTPStatus.BAD_GATEWAY)
        if status != HTTPStatus.SWITCHING_PROTOCOLS:
            self.server.service.close_websocket_relay(session.id)
            self._send_relay_response(response)
            return

        response_headers = sanitize_headers(response.get("headers") or {})
        protocol = header_value(response_headers, "Sec-WebSocket-Protocol")
        self.send_response(HTTPStatus.SWITCHING_PROTOCOLS)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", websocket_accept_key(client_key))
        if protocol:
            self.send_header("Sec-WebSocket-Protocol", protocol)
        self.end_headers()
        self.close_connection = True
        self._bridge_public_websocket(session)

    def _bridge_public_websocket(self, session: WebSocketRelaySession) -> None:
        stop_event = threading.Event()
        write_lock = threading.Lock()

        def read_client_frames() -> None:
            try:
                while not stop_event.is_set():
                    frame = read_frame(self.connection, masked=True)
                    opcode = int(frame["opcode"])
                    if opcode == OPCODE_PING:
                        with write_lock:
                            write_frame(self.connection, OPCODE_PONG, frame["payload"], masked=False)
                        continue
                    if opcode == OPCODE_PONG:
                        continue

                    session.push_client_frame(frame_to_payload(frame))
                    if opcode == OPCODE_CLOSE:
                        stop_event.set()
                        session.close()
                        break
            except Exception:
                stop_event.set()
                session.close()

        reader = threading.Thread(target=read_client_frames, name=f"tater-vps-ws-reader-{session.id}", daemon=True)
        reader.start()

        try:
            while not stop_event.is_set():
                payload = session.poll_server_frames(timeout=1)
                for frame_payload in payload.get("frames") or []:
                    frame = payload_to_frame(frame_payload)
                    with write_lock:
                        write_frame(self.connection, int(frame["opcode"]), frame["payload"], bool(frame["fin"]), masked=False)
                    if int(frame["opcode"]) == OPCODE_CLOSE:
                        stop_event.set()
                        break

                if payload.get("closed"):
                    stop_event.set()
        finally:
            self.server.service.close_websocket_relay(session.id)
            stop_event.set()
            reader.join(timeout=1)

    def _send_relay_response(self, response: dict[str, Any]) -> None:
        body = base64.b64decode(str(response.get("bodyBase64") or "").encode("ascii"))
        status = HTTPStatus(int(response.get("status") or HTTPStatus.BAD_GATEWAY))
        headers = sanitize_headers(response.get("headers") or {})
        rewrite_base_path = normalize_rewrite_base_path(response.get("rewriteBasePath"))
        rewrite_origin = normalize_rewrite_origin(response.get("rewriteOrigin"))
        if rewrite_base_path:
            headers = rewrite_relay_headers(headers, rewrite_base_path, rewrite_origin)
            body = rewrite_relay_body(body, header_value(headers, "Content-Type"), rewrite_base_path, rewrite_origin)

        self.send_response(status)
        for name, value in headers.items():
            if name.lower() not in HOP_BY_HOP_HEADERS:
                self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
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

    def _send_landing_page(self) -> None:
        body = LANDING_PAGE_HTML.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_static_png(self, path: Path) -> None:
        try:
            body = path.read_bytes()
        except OSError:
            self._send_error(HTTPStatus.NOT_FOUND, "Asset not found")
            return

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_unexpected_error(self, error: Exception) -> None:
        print("VPS Agent unexpected error:")
        traceback.print_exception(type(error), error, error.__traceback__)
        self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, f"VPS Agent internal error: {error}")


def create_pairing_code() -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    left = "".join(secrets.choice(alphabet) for _ in range(4))
    right = "".join(secrets.choice(alphabet) for _ in range(4))
    return f"{left}-{right}"


def sanitize_headers(headers: dict[str, Any]) -> dict[str, str]:
    sanitized: dict[str, str] = {}
    for name, value in headers.items():
        header_name = str(name).strip()
        if not header_name or header_name.lower() in HOP_BY_HOP_HEADERS:
            continue
        sanitized[header_name] = str(value)
    return sanitized


def header_value(headers: dict[str, str], name: str) -> str:
    expected = name.lower()
    for header_name, value in headers.items():
        if header_name.lower() == expected:
            return value
    return ""


def is_websocket_upgrade(headers: dict[str, Any]) -> bool:
    upgrade = str(header_value(headers, "Upgrade")).lower()
    connection = str(header_value(headers, "Connection")).lower()
    return upgrade == "websocket" and "upgrade" in connection


def parse_websocket_relay_api_path(path: str) -> tuple[str, str]:
    prefix = "/api/relay/ws/"
    if not path.startswith(prefix):
        raise VpsAgentError(HTTPStatus.NOT_FOUND, "Endpoint not found")

    remainder = path[len(prefix) :]
    session_id, _, endpoint = remainder.partition("/")
    session_id = unquote(session_id)
    if not session_id or not endpoint:
        raise VpsAgentError(HTTPStatus.NOT_FOUND, "Endpoint not found")
    return session_id, endpoint


def normalize_rewrite_base_path(value: Any) -> str:
    base_path = str(value or "").strip()
    if not base_path.startswith("/relay"):
        return ""
    return f"{base_path.rstrip('/')}/"


def normalize_rewrite_origin(value: Any) -> str:
    origin = str(value or "").strip().rstrip("/")
    parsed = urlparse(origin)
    if parsed.scheme not in {"http", "https", "ws", "wss"} or not parsed.netloc:
        return ""
    return origin


def rewrite_relay_headers(headers: dict[str, str], base_path: str, target_origin: str = "") -> dict[str, str]:
    rewritten = dict(headers)
    for name, value in list(rewritten.items()):
        header_name = name.lower()
        if header_name == "location":
            rewritten[name] = rewrite_header_location(value, base_path, target_origin)
        elif header_name == "set-cookie":
            rewritten[name] = rewrite_cookie_path(value, base_path)
    return rewritten


def rewrite_header_location(value: str, base_path: str, target_origin: str = "") -> str:
    if target_origin and value.startswith(f"{target_origin}/"):
        return f"{base_path.rstrip('/')}/{value[len(target_origin):].lstrip('/')}"
    if value.startswith("//") or urlparse(value).scheme:
        return value

    normalized_base = base_path.rstrip("/")
    if value.startswith("/"):
        if not value.startswith(f"{normalized_base}/"):
            return f"{normalized_base}{value}"
        return value

    return urljoin(base_path, value)


def rewrite_cookie_path(value: str, base_path: str) -> str:
    normalized_base = base_path.rstrip("/")

    def replace_path(match: re.Match[str]) -> str:
        prefix = match.group("prefix")
        cookie_path = match.group("path").strip()
        if not cookie_path.startswith("/"):
            return match.group(0)
        if cookie_path == normalized_base or cookie_path.startswith(f"{normalized_base}/"):
            return match.group(0)
        if cookie_path == "/":
            return f"{prefix}{normalized_base}"
        return f"{prefix}{normalized_base}{cookie_path}"

    rewritten = re.sub(
        r"(?P<prefix>(?:^|;)\s*Path=)(?P<path>[^;]*)",
        replace_path,
        value,
        flags=re.IGNORECASE,
    )
    return re.sub(r";\s*Domain=[^;]*", "", rewritten, flags=re.IGNORECASE)


def rewrite_relay_body(body: bytes, content_type: str, base_path: str, target_origin: str = "") -> bytes:
    lowered = content_type.lower()
    if not any(kind in lowered for kind in ("text/html", "text/css", "javascript")):
        return body

    text = body.decode("utf-8", errors="replace")
    base = base_path.rstrip("/")
    target_origin = normalize_rewrite_origin(target_origin)

    def prefixed_url(url: str) -> str:
        if url == base or url.startswith(f"{base}/"):
            return url
        return f"{base}{url}"

    def replace_root_url(match: re.Match[str]) -> str:
        return f"{match.group('prefix')}{prefixed_url(match.group('url'))}"

    if target_origin:
        ws_origin = websocket_origin_for(target_origin)
        text = text.replace(f"{target_origin}/", f"{base}/")
        text = text.replace(target_origin, base)
        if ws_origin:
            text = text.replace(f"{ws_origin}/", f"{base}/")
            text = text.replace(ws_origin, base)

    text = re.sub(
        r"(?P<prefix>\b(?:href|src|action|poster|data)=['\"])(?P<url>/(?!/)[^'\"]*)",
        replace_root_url,
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"(?P<prefix>url\(\s*['\"]?)(?P<url>/(?!/)[^'\"\)\s]*)",
        replace_root_url,
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"(?P<prefix>\b(?:fetch|sendBeacon)\(\s*['\"])(?P<url>/(?!/)[^'\"]*)",
        replace_root_url,
        text,
    )
    text = re.sub(
        r"(?P<prefix>\bopen\(\s*['\"][A-Z]+['\"]\s*,\s*['\"])(?P<url>/(?!/)[^'\"]*)",
        replace_root_url,
        text,
    )

    return text.encode("utf-8")


def websocket_origin_for(origin: str) -> str:
    parsed = urlparse(origin)
    if parsed.scheme == "http":
        return f"ws://{parsed.netloc}"
    if parsed.scheme == "https":
        return f"wss://{parsed.netloc}"
    return ""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def build_server(
    host: str,
    port: int,
    state_file: Path,
    pairing_code: str | None = None,
    wireguard_backend: str = "config",
    wireguard_config: Path = WIREGUARD_CONFIG_PATH,
    wireguard_interface: str = "tater0",
) -> VpsAgentServer:
    store = VpsConfigStore(state_file, pairing_code)
    runtime = build_wireguard_runtime(wireguard_backend, wireguard_config, wireguard_interface)
    service = VpsAgentService(store, wireguard_runtime=runtime)
    return VpsAgentServer((host, port), service)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the Tater Tunnel VPS Agent prototype")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=4174, type=int)
    parser.add_argument("--state-file", default=STATE_PATH, type=Path)
    parser.add_argument("--pairing-code", default=None)
    parser.add_argument("--pairing-code-file", default=None, type=Path)
    parser.add_argument(
        "--reopen-pairing",
        action="store_true",
        help="Enable pairing on an existing claimed VPS without resetting peers.",
    )
    parser.add_argument("--wireguard-backend", choices=["config", "wg", "system"], default="config")
    parser.add_argument("--wireguard-config", default=WIREGUARD_CONFIG_PATH, type=Path)
    parser.add_argument("--wireguard-interface", default="tater0")
    args = parser.parse_args(argv)

    if args.pairing_code and args.pairing_code_file:
        parser.error("--pairing-code and --pairing-code-file cannot be used together")

    pairing_code = args.pairing_code
    if args.pairing_code_file:
        pairing_code = args.pairing_code_file.read_text(encoding="utf-8").strip()
        if not pairing_code:
            parser.error("--pairing-code-file is empty")

    if args.reopen_pairing:
        store = VpsConfigStore(args.state_file, pairing_code)
        state = store.reopen_pairing(pairing_code)
        print(f"State file: {args.state_file}")
        print(f"Pairing code: {state['pairing']['code']}")
        print("Pairing mode: enabled")
        print("VPS Agent pairing was reopened. Restart is not required if the service is already running.")
        return 0

    server = build_server(
        args.host,
        args.port,
        args.state_file,
        pairing_code,
        args.wireguard_backend,
        args.wireguard_config,
        args.wireguard_interface,
    )
    state = server.service.state()
    print(f"Tater Tunnel VPS Agent listening on http://{args.host}:{args.port}")
    print(f"State file: {args.state_file}")
    print(f"WireGuard backend: {args.wireguard_backend}")
    print(f"WireGuard config: {args.wireguard_config}")
    if state["pairing"]["enabled"]:
        print(f"Pairing code: {state['pairing']['code']}")
    else:
        print("Pairing mode: disabled")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping VPS Agent")
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
