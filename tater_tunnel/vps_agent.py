from __future__ import annotations

import argparse
import base64
import binascii
import functools
import ipaddress
import json
import os
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
from urllib.parse import unquote, urlparse

from . import __version__
from .control_helper import ControlHelperClient, ControlHelperClientError, DEFAULT_SOCKET_PATH
from .wireguard import KeyPair, WireGuardKeyProvider
from .wireguard_runtime import WIREGUARD_MTU, WireGuardRuntimeError, build_wireguard_runtime


PROJECT_ROOT = Path(__file__).resolve().parent.parent
STATE_PATH = PROJECT_ROOT / ".tater_tunnel" / "vps-agent.json"
WIREGUARD_CONFIG_PATH = PROJECT_ROOT / ".tater_tunnel" / "wireguard" / "tater0.conf"
API_MAX_BODY_BYTES = 64 * 1024
PAIRING_FAILURE_LIMIT = 8
PAIRING_FAILURE_WINDOW_SECONDS = 5 * 60
MAX_TRACKED_PAIRING_ADDRESSES = 1024
REQUEST_SOCKET_TIMEOUT_SECONDS = 30
WIREGUARD_DIAGNOSTICS_WAIT_SECONDS = 1.5
CONTROL_JOB_HISTORY_LIMIT = 50
CONTROL_ACTIVE_JOB_LIMIT = 1
CONTROL_JOB_TIMEOUT_SECONDS = 30 * 60
HOME_AGENT_ADDRESS = ipaddress.ip_address("10.88.0.2")
LANDING_MASCOT_PATH = PROJECT_ROOT / "assets" / "tater-vps-mascot.png"
LANDING_PAGE_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Private Host</title>
  <style>
    :root { color-scheme: dark; --bg:#11100f; --panel:#1d1915; --text:#fff5e7; --muted:#cdbca7; --orange:#ff9418; --line:#3b3127; }
    * { box-sizing:border-box; }
    body { margin:0; min-height:100vh; display:grid; place-items:center; color:var(--text); background:linear-gradient(180deg,#19140f,var(--bg)); font:16px/1.5 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    main { width:min(52rem,calc(100vw - 2rem)); display:grid; grid-template-columns:minmax(13rem,22rem) minmax(0,1fr); align-items:center; gap:clamp(1rem,5vw,3rem); padding:2rem; }
    img { width:100%; max-height:68vh; object-fit:contain; filter:drop-shadow(0 26px 54px rgba(0,0,0,.42)); }
    section { padding:1.5rem; border:1px solid var(--line); border-radius:8px; background:var(--panel); box-shadow:0 24px 70px rgba(0,0,0,.34); }
    b { display:block; margin-bottom:.45rem; color:var(--orange); font-size:.75rem; text-transform:uppercase; }
    h1 { margin:0 0 .55rem; font-size:clamp(1.8rem,5vw,2.7rem); line-height:1.05; letter-spacing:0; }
    p { margin:0; color:var(--muted); }
    @media (max-width:680px) { main { grid-template-columns:1fr; text-align:center; } img { width:min(19rem,80vw); margin:auto; } }
  </style>
</head>
<body>
  <main>
    <img src="/assets/tater-vps-mascot.png" alt="A friendly mascot holding two network cables">
    <section>
      <b>Private host</b>
      <h1>Nothing to see here.</h1>
      <p>This address does not provide a public service.</p>
    </section>
  </main>
</body>
</html>
"""


class VpsAgentError(Exception):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def synchronized_state(method: Any) -> Any:
    @functools.wraps(method)
    def wrapped(self: "VpsAgentService", *args: Any, **kwargs: Any) -> Any:
        with self._state_lock:
            return method(self, *args, **kwargs)

    return wrapped


def default_vps_state(pairing_code: str | None = None) -> dict[str, Any]:
    return {
        "schemaVersion": 2,
        "claimed": False,
        "migrationRequired": False,
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
                return self._merge_defaults(json.load(handle))

    def save(self, state: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            merged = self._merge_defaults(state)
            existing = self.path.stat() if self.path.exists() else None
            fd, temp_name = tempfile.mkstemp(
                prefix=f".{self.path.name}.", suffix=".tmp", dir=self.path.parent, text=True
            )
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    json.dump(merged, handle, indent=2, sort_keys=True)
                    handle.write("\n")
                os.chmod(temp_name, 0o600)
                if existing and hasattr(os, "chown"):
                    os.chown(temp_name, existing.st_uid, existing.st_gid)
                os.replace(temp_name, self.path)
            finally:
                if os.path.exists(temp_name):
                    os.unlink(temp_name)
            return deepcopy(merged)

    def reset(self) -> dict[str, Any]:
        return self.save(default_vps_state(self.pairing_code))

    def reopen_pairing(self, pairing_code: str | None = None) -> dict[str, Any]:
        state = self.load()
        state["pairing"] = {
            "enabled": True,
            "claimedAt": "",
            "code": pairing_code or create_pairing_code(),
        }
        return self.save(state)

    def _merge_defaults(self, state: dict[str, Any]) -> dict[str, Any]:
        home_agent_state = state.get("homeAgent")
        retired_state = int(state.get("schemaVersion") or 0) != 2
        if state.get("claimed") and not isinstance(home_agent_state, dict):
            retired_state = True
        if state.get("peers") and not isinstance(home_agent_state, dict):
            retired_state = True
        if isinstance(home_agent_state, dict):
            retired_state = retired_state or (
                home_agent_state.get("transport") != "wireguard"
                or not home_agent_state.get("publicKey")
                or not home_agent_state.get("managementToken")
            )
        if retired_state:
            clean = default_vps_state(self.pairing_code)
            clean["migrationRequired"] = True
            return clean

        merged = default_vps_state(self.pairing_code)
        merged.update({key: value for key, value in state.items() if key not in {"pairing", "interface"}})
        merged["pairing"].update(state.get("pairing", {}))
        merged["interface"].update(state.get("interface", {}))

        home_agent = merged.get("homeAgent")
        if isinstance(home_agent, dict):
            public_key = str(home_agent.get("publicKey") or "")
            if public_key:
                try:
                    validate_wireguard_public_key(public_key)
                except VpsAgentError:
                    public_key = ""
            if public_key:
                home_agent["transport"] = "wireguard"
                home_agent["allowedIp"] = "10.88.0.2/32"
            else:
                clean = default_vps_state(self.pairing_code)
                clean["migrationRequired"] = True
                return clean

        peers: list[dict[str, Any]] = []
        for peer in merged.get("peers", []):
            if not isinstance(peer, dict):
                continue
            try:
                validate_wireguard_public_key(str(peer.get("publicKey") or ""))
                allowed_ip = normalize_peer_allowed_ip(merged, str(peer.get("allowedIp") or ""))
            except VpsAgentError:
                continue
            normalized = deepcopy(peer)
            normalized["allowedIp"] = allowed_ip
            peers.append(normalized)
        merged["peers"] = peers
        return merged


class VpsControlJobs:
    ALLOWED_OPERATIONS = {"configure-app", "service-action", "security-audit", "update-vps"}

    def __init__(self, client: ControlHelperClient):
        self.client = client
        self._jobs: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    def snapshot(self) -> dict[str, Any]:
        try:
            return self.client.request("snapshot", timeout=10)
        except ControlHelperClientError as error:
            raise VpsAgentError(HTTPStatus.SERVICE_UNAVAILABLE, str(error)) from error

    def start(self, payload: dict[str, Any]) -> dict[str, Any]:
        operation = str(payload.get("operation") or "").strip()
        operation_payload = payload.get("payload") or {}
        if operation not in self.ALLOWED_OPERATIONS:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Control operation is not allowed")
        if not isinstance(operation_payload, dict):
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Control job payload must be an object")

        job_id = secrets.token_urlsafe(18)
        job = {
            "id": job_id,
            "operation": operation,
            "status": "queued",
            "createdAt": utc_now(),
            "startedAt": "",
            "finishedAt": "",
            "result": None,
            "error": "",
        }
        with self._lock:
            active = sum(
                value.get("status") in {"queued", "running"}
                for value in self._jobs.values()
            )
            if active >= CONTROL_ACTIVE_JOB_LIMIT:
                raise VpsAgentError(
                    HTTPStatus.CONFLICT,
                    "Another VPS control job is already running",
                )
            self._jobs[job_id] = job
            self._trim_history()
        threading.Thread(
            target=self._run,
            args=(job_id, operation, deepcopy(operation_payload)),
            name=f"tater-control-{operation}",
            daemon=True,
        ).start()
        return self.get(job_id)

    def get(self, job_id: str) -> dict[str, Any]:
        with self._lock:
            job = deepcopy(self._jobs.get(job_id))
        if not job:
            raise VpsAgentError(HTTPStatus.NOT_FOUND, "Control job was not found")
        return job

    def _run(self, job_id: str, operation: str, payload: dict[str, Any]) -> None:
        self._update(job_id, status="running", startedAt=utc_now())
        try:
            result = self.client.request(
                operation, payload, timeout=CONTROL_JOB_TIMEOUT_SECONDS
            )
        except ControlHelperClientError as error:
            self._update(job_id, status="failed", error=str(error), finishedAt=utc_now())
        except Exception:
            self._update(
                job_id,
                status="failed",
                error="VPS control operation failed unexpectedly",
                finishedAt=utc_now(),
            )
        else:
            self._update(job_id, status="complete", result=result, finishedAt=utc_now())
        finally:
            payload.clear()

    def _update(self, job_id: str, **changes: Any) -> None:
        with self._lock:
            if job_id in self._jobs:
                self._jobs[job_id].update(changes)

    def _trim_history(self) -> None:
        while len(self._jobs) > CONTROL_JOB_HISTORY_LIMIT:
            removable = next(
                (
                    key
                    for key, value in self._jobs.items()
                    if value.get("status") in {"complete", "failed"}
                ),
                None,
            )
            if not removable:
                break
            self._jobs.pop(removable, None)


class VpsAgentService:
    def __init__(
        self,
        store: VpsConfigStore,
        key_provider: WireGuardKeyProvider | None = None,
        wireguard_runtime: Any | None = None,
        management_port: int = 4174,
        control_jobs: VpsControlJobs | None = None,
    ):
        self.store = store
        self.key_provider = key_provider or WireGuardKeyProvider()
        self.wireguard_runtime = wireguard_runtime or build_wireguard_runtime(
            "config", WIREGUARD_CONFIG_PATH, "tater0"
        )
        self.management_port = management_port
        self.control_jobs = control_jobs or VpsControlJobs(ControlHelperClient())
        self._pairing_failures: dict[str, list[float]] = {}
        self._pairing_failure_lock = threading.Lock()
        self._state_lock = threading.RLock()
        self._diagnostics_lock = threading.Lock()
        self._diagnostics_event = threading.Event()
        self._diagnostics_running = False
        self._diagnostics_result: dict[str, Any] = {}
        self._diagnostics_error = ""
        self._restore_wireguard_state()

    def state(self) -> dict[str, Any]:
        return self._public_state(self.store.load())

    def health(self) -> dict[str, Any]:
        state = self.store.load()
        return {
            "status": "ok",
            "version": __version__,
            "claimed": state["claimed"],
            "pairingEnabled": state["pairing"]["enabled"],
            "peerCount": len(state["peers"]),
        }

    def control_overview(self) -> dict[str, Any]:
        return self.control_jobs.snapshot()

    def start_control_job(self, payload: dict[str, Any]) -> dict[str, Any]:
        return {"job": self.control_jobs.start(payload)}

    def control_job(self, job_id: str) -> dict[str, Any]:
        return {"job": self.control_jobs.get(job_id)}

    def wireguard_diagnostics(self) -> dict[str, Any]:
        state = self.store.load()
        diagnostics, warning = self._bounded_wireguard_diagnostics(state)
        if warning:
            diagnostics.setdefault("livePeers", [])
            warnings = diagnostics.setdefault("livePeerWarnings", [])
            if warning not in warnings:
                warnings.append(warning)
        compact_diagnostics = {
            key: deepcopy(diagnostics[key])
            for key in (
                "backend",
                "interfaceName",
                "livePeerSource",
                "livePeerSnapshotAt",
                "livePeers",
                "livePeerWarnings",
            )
            if key in diagnostics
        }
        compact_diagnostics["mtu"] = WIREGUARD_MTU
        runtime = state.get("runtime") or {}
        return {
            "wireguard": compact_diagnostics,
            "runtime": {
                key: runtime[key]
                for key in ("backend", "interfaceName", "lastAction", "lastAppliedAt", "message")
                if key in runtime
            },
        }

    def _bounded_wireguard_diagnostics(
        self, state: dict[str, Any]
    ) -> tuple[dict[str, Any], str]:
        with self._diagnostics_lock:
            if not self._diagnostics_running:
                self._diagnostics_running = True
                self._diagnostics_event = threading.Event()
                worker = threading.Thread(
                    target=self._refresh_wireguard_diagnostics,
                    args=(deepcopy(state), self._diagnostics_event),
                    name="tater-wireguard-diagnostics",
                    daemon=True,
                )
                worker.start()
            event = self._diagnostics_event

        completed = event.wait(WIREGUARD_DIAGNOSTICS_WAIT_SECONDS)
        with self._diagnostics_lock:
            diagnostics = deepcopy(self._diagnostics_result)
            error = self._diagnostics_error

        if completed and diagnostics:
            return diagnostics, error
        if not diagnostics:
            diagnostics = {
                "backend": getattr(self.wireguard_runtime, "backend", "unknown"),
                "interfaceName": getattr(self.wireguard_runtime, "interface_name", "tater0"),
                "livePeers": [],
                "livePeerWarnings": [],
            }
        return diagnostics, error or "Live WireGuard diagnostics are still being collected"

    def _refresh_wireguard_diagnostics(
        self, state: dict[str, Any], event: threading.Event
    ) -> None:
        diagnostics: dict[str, Any] = {}
        error = ""
        try:
            diagnostics = self.wireguard_runtime.diagnostics(state)
        except Exception as caught:
            error = f"Live WireGuard diagnostics failed: {caught}"
        finally:
            with self._diagnostics_lock:
                if diagnostics:
                    self._diagnostics_result = diagnostics
                self._diagnostics_error = error
                self._diagnostics_running = False
                event.set()

    @synchronized_state
    def claim(self, payload: dict[str, Any], remote_address: str = "") -> dict[str, Any]:
        state = self.store.load()
        code = str(payload.get("pairingCode") or "").strip()
        home_agent = payload.get("homeAgent") or {}
        transport = str(home_agent.get("transport") or "").strip().lower()
        public_key = str(home_agent.get("publicKey") or "").strip()

        if not state["pairing"]["enabled"]:
            raise VpsAgentError(HTTPStatus.CONFLICT, "Pairing mode is disabled")
        self._check_pairing_rate_limit(remote_address)
        if not secrets.compare_digest(code, str(state["pairing"]["code"])):
            self._record_pairing_failure(remote_address)
            raise VpsAgentError(HTTPStatus.FORBIDDEN, "Pairing code is not valid")
        if transport != "wireguard":
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Home Agent transport must be WireGuard")
        validate_wireguard_public_key(public_key)

        if not state["interface"].get("wireguard"):
            state["interface"]["wireguard"] = self._serialize_keypair(
                self.key_provider.generate_keypair()
            )
        now = utc_now()
        state["claimed"] = True
        state["migrationRequired"] = False
        state["lastCheck"] = now
        state["pairing"]["enabled"] = False
        state["pairing"]["claimedAt"] = now
        state["homeAgent"] = {
            "id": str(home_agent.get("id") or "home-agent")[:128],
            "transport": "wireguard",
            "claimedFrom": str(remote_address or ""),
            "managementToken": secrets.token_urlsafe(48),
            "publicKey": public_key,
            "allowedIp": "10.88.0.2/32",
        }
        self._clear_pairing_failures(remote_address)
        self._apply_wireguard(state)
        saved = self.store.save(state)
        vps_wireguard = {
            "publicKey": saved["interface"]["wireguard"]["publicKey"],
            "address": saved["interface"]["address"],
            "network": saved["interface"]["network"],
            "listenPort": saved["wireguardPort"],
            "homeAllowedIp": saved["homeAgent"]["allowedIp"],
        }
        return {
            "state": self._public_state(saved),
            "vpsWireGuard": vps_wireguard,
            "management": {
                "url": f"http://10.88.0.1:{self.management_port}",
                "token": saved["homeAgent"]["managementToken"],
            },
        }

    @synchronized_state
    def add_peer(self, payload: dict[str, Any]) -> dict[str, Any]:
        state = self.store.load()
        self._require_claimed(state)
        peer_id = str(payload.get("id") or "").strip()
        name = str(payload.get("name") or peer_id or "device").strip()
        public_key = str(payload.get("publicKey") or "").strip()
        allowed_ip = str(payload.get("allowedIp") or "").strip()
        if not peer_id or not public_key or not allowed_ip:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer id, public key, and Allowed IP are required")
        if len(peer_id) > 128 or len(name) > 128:
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer id and name must be 128 characters or fewer")
        validate_wireguard_public_key(public_key)
        allowed_ip = normalize_peer_allowed_ip(state, allowed_ip)
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
        self.store.save(state)
        return {
            "status": "ok",
            "peer": {"id": peer_id, "allowedIp": allowed_ip},
        }

    @synchronized_state
    def remove_peer(self, peer_id: str) -> dict[str, Any]:
        state = self.store.load()
        self._require_claimed(state)
        remaining = [peer for peer in state["peers"] if peer.get("id") != peer_id]
        if len(remaining) == len(state["peers"]):
            raise VpsAgentError(HTTPStatus.NOT_FOUND, "Peer not found")
        state["peers"] = remaining
        state["lastCheck"] = utc_now()
        self._apply_wireguard(state)
        self.store.save(state)
        return {"status": "ok", "removedPeerId": peer_id}

    @synchronized_state
    def reset(self) -> dict[str, Any]:
        state = self.store.reset()
        self._apply_wireguard(state)
        return {"state": self._public_state(self.store.save(state))}

    def require_management_client(self, token: str, remote_address: str) -> None:
        try:
            address = ipaddress.ip_address(str(remote_address or ""))
        except ValueError as error:
            raise VpsAgentError(HTTPStatus.FORBIDDEN, "Management requires the Home Agent tunnel") from error
        if address != HOME_AGENT_ADDRESS and not address.is_loopback:
            raise VpsAgentError(HTTPStatus.FORBIDDEN, "Management requires the Home Agent tunnel")
        state = self.store.load()
        self._require_claimed(state)
        expected = str((state.get("homeAgent") or {}).get("managementToken") or "")
        if not expected or not secrets.compare_digest(expected, str(token or "")):
            raise VpsAgentError(HTTPStatus.FORBIDDEN, "Home Agent management token is not valid")

    def _require_claimed(self, state: dict[str, Any]) -> None:
        if not state.get("claimed"):
            raise VpsAgentError(HTTPStatus.CONFLICT, "VPS Agent is not claimed")

    def _check_pairing_rate_limit(self, remote_address: str) -> None:
        address = str(remote_address or "unknown")
        now = time.monotonic()
        with self._pairing_failure_lock:
            for tracked, attempts in list(self._pairing_failures.items()):
                recent = [attempt for attempt in attempts if now - attempt < PAIRING_FAILURE_WINDOW_SECONDS]
                if recent:
                    self._pairing_failures[tracked] = recent
                else:
                    self._pairing_failures.pop(tracked, None)
            while address not in self._pairing_failures and len(self._pairing_failures) >= MAX_TRACKED_PAIRING_ADDRESSES:
                self._pairing_failures.pop(next(iter(self._pairing_failures)))
            recent = self._pairing_failures.get(address, [])
            self._pairing_failures[address] = recent
            if len(recent) >= PAIRING_FAILURE_LIMIT:
                raise VpsAgentError(HTTPStatus.TOO_MANY_REQUESTS, "Too many pairing attempts; try again later")

    def _record_pairing_failure(self, remote_address: str) -> None:
        with self._pairing_failure_lock:
            self._pairing_failures.setdefault(str(remote_address or "unknown"), []).append(time.monotonic())

    def _clear_pairing_failures(self, remote_address: str) -> None:
        with self._pairing_failure_lock:
            self._pairing_failures.pop(str(remote_address or "unknown"), None)

    def _apply_wireguard(self, state: dict[str, Any]) -> None:
        try:
            state["runtime"] = self.wireguard_runtime.apply(state)
        except WireGuardRuntimeError as error:
            raise VpsAgentError(HTTPStatus.BAD_GATEWAY, f"WireGuard runtime failed: {error}") from error

    def _restore_wireguard_state(self) -> None:
        state = self.store.load()
        self._apply_wireguard(state)
        self.store.save(state)

    def _public_state(self, state: dict[str, Any]) -> dict[str, Any]:
        public = deepcopy(state)
        wireguard = public.get("interface", {}).get("wireguard")
        if isinstance(wireguard, dict):
            wireguard.pop("privateKey", None)
        if not public.get("pairing", {}).get("enabled"):
            public["pairing"].pop("code", None)
        if isinstance(public.get("homeAgent"), dict):
            public["homeAgent"].pop("managementToken", None)
        return public

    @staticmethod
    def _serialize_keypair(keypair: KeyPair) -> dict[str, str]:
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
    protocol_version = "HTTP/1.1"
    server_version = "TaterTunnel"
    sys_version = ""

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(REQUEST_SOCKET_TIMEOUT_SECONDS)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        try:
            if path in {"", "/"}:
                self._send_landing_page()
            elif path == "/assets/tater-vps-mascot.png":
                self._send_static_png(LANDING_MASCOT_PATH)
            elif path in {"/api/health", "/api/state", "/api/wireguard", "/api/control/overview"}:
                self._require_management()
                if path == "/api/health":
                    self._send_json(self.server.service.health())
                elif path == "/api/state":
                    self._send_json(self.server.service.state())
                elif path == "/api/wireguard":
                    self._send_json(self.server.service.wireguard_diagnostics())
                else:
                    self._send_json(self.server.service.control_overview())
            elif path.startswith("/api/control/jobs/"):
                self._require_management()
                job_id = unquote(path.removeprefix("/api/control/jobs/"))
                self._send_json(self.server.service.control_job(job_id))
            else:
                self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
        except VpsAgentError as error:
            self._send_error(error.status, error.message)
        except Exception as error:
            self._send_unexpected_error(error)

    def do_HEAD(self) -> None:
        path = urlparse(self.path).path
        if path in {"", "/"}:
            self._send_landing_page()
        elif path == "/assets/tater-vps-mascot.png":
            self._send_static_png(LANDING_MASCOT_PATH)
        else:
            self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            if path not in {"/api/claim", "/api/peers", "/api/reset", "/api/control/jobs"}:
                self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
                return
            if path != "/api/claim":
                self._require_management()
            payload = self._read_json()
            if path == "/api/claim":
                self._send_json(self.server.service.claim(payload, self.client_address[0]))
            elif path == "/api/peers":
                self._send_json(self.server.service.add_peer(payload), HTTPStatus.CREATED)
            elif path == "/api/reset":
                self._send_json(self.server.service.reset())
            else:
                self._send_json(
                    self.server.service.start_control_job(payload), HTTPStatus.ACCEPTED
                )
        except VpsAgentError as error:
            self._send_error(error.status, error.message)
        except json.JSONDecodeError:
            self._send_error(HTTPStatus.BAD_REQUEST, "Request body must be valid JSON")
        except Exception as error:
            self._send_unexpected_error(error)

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        try:
            if not path.startswith("/api/peers/"):
                self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")
                return
            self._require_management()
            peer_id = unquote(path.removeprefix("/api/peers/"))
            self._send_json(self.server.service.remove_peer(peer_id))
        except VpsAgentError as error:
            self._send_error(error.status, error.message)
        except Exception as error:
            self._send_unexpected_error(error)

    def do_PUT(self) -> None:
        self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")

    def do_PATCH(self) -> None:
        self._send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")

    def do_OPTIONS(self) -> None:
        self._send_error(HTTPStatus.METHOD_NOT_ALLOWED, "Method not allowed")

    def log_message(self, format: str, *args: Any) -> None:
        status = args[1] if len(args) > 1 else "-"
        size = args[2] if len(args) > 2 else "-"
        safe_path = urlparse(self.path).path or "/"
        print(f'{self.client_address[0]} - "{self.command} {safe_path} {self.request_version}" {status} {size}')

    def _read_json(self) -> dict[str, Any]:
        if self.headers.get("Transfer-Encoding"):
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Transfer-Encoding is not supported")
        if self.headers.get_content_type() != "application/json":
            raise VpsAgentError(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "API requests must use application/json")
        length = parse_content_length(self.headers.get("Content-Length", "0"))
        if length > API_MAX_BODY_BYTES:
            raise VpsAgentError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Request body is too large")
        payload = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
        if not isinstance(payload, dict):
            raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Request body must be a JSON object")
        return payload

    def _require_management(self) -> None:
        self.server.service.require_management_client(
            self.headers.get("X-Tater-Management-Token", ""), self.client_address[0]
        )

    def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_error(self, status: HTTPStatus, message: str) -> None:
        self._send_json({"error": message}, status)

    def _send_landing_page(self) -> None:
        body = LANDING_PAGE_HTML.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
        )
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
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_unexpected_error(self, error: Exception) -> None:
        print("VPS Agent unexpected error:")
        traceback.print_exception(type(error), error, error.__traceback__)
        self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, "VPS Agent internal error")


def create_pairing_code() -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(5)) + "-" + "".join(
        secrets.choice(alphabet) for _ in range(5)
    )


def validate_wireguard_public_key(value: str) -> None:
    try:
        decoded = base64.b64decode(str(value or "").encode("ascii"), validate=True)
    except (binascii.Error, UnicodeEncodeError, ValueError) as error:
        raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer public key is not valid base64") from error
    if len(decoded) != 32 or not any(decoded):
        raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer public key must be a nonzero 32-byte WireGuard key")


def normalize_peer_allowed_ip(state: dict[str, Any], value: str) -> str:
    try:
        allowed = ipaddress.ip_network(str(value or ""), strict=True)
        tunnel = ipaddress.ip_network(str(state["interface"]["network"]), strict=True)
        server_address = ipaddress.ip_interface(str(state["interface"]["address"])).ip
    except (KeyError, ValueError) as error:
        raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer Allowed IP is invalid") from error
    if allowed.version != tunnel.version or allowed.prefixlen != allowed.max_prefixlen:
        raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer Allowed IP must identify exactly one tunnel address")
    address = allowed.network_address
    if address not in tunnel or address in {
        server_address,
        HOME_AGENT_ADDRESS,
        tunnel.network_address,
        tunnel.broadcast_address,
    }:
        raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Peer Allowed IP is reserved or outside the tunnel network")
    return f"{address}/{allowed.max_prefixlen}"


def parse_content_length(value: Any) -> int:
    try:
        length = int(str(value or "0"))
    except (TypeError, ValueError) as error:
        raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Content-Length must be a number") from error
    if length < 0:
        raise VpsAgentError(HTTPStatus.BAD_REQUEST, "Content-Length cannot be negative")
    return length


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
    control_socket: Path = DEFAULT_SOCKET_PATH,
) -> VpsAgentServer:
    store = VpsConfigStore(state_file, pairing_code)
    runtime = build_wireguard_runtime(wireguard_backend, wireguard_config, wireguard_interface)
    control_jobs = VpsControlJobs(ControlHelperClient(control_socket))
    service = VpsAgentService(
        store,
        wireguard_runtime=runtime,
        management_port=port,
        control_jobs=control_jobs,
    )
    return VpsAgentServer((host, port), service)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the Tater Tunnel VPS Agent")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=4174, type=int)
    parser.add_argument("--state-file", default=STATE_PATH, type=Path)
    parser.add_argument("--pairing-code", default=None)
    parser.add_argument("--pairing-code-file", default=None, type=Path)
    parser.add_argument(
        "--reopen-pairing",
        action="store_true",
        help="Enable one-time pairing with a new code without resetting device peers.",
    )
    parser.add_argument("--wireguard-backend", choices=["config", "wg", "system"], default="config")
    parser.add_argument("--wireguard-config", default=WIREGUARD_CONFIG_PATH, type=Path)
    parser.add_argument("--wireguard-interface", default="tater0")
    parser.add_argument("--control-socket", default=DEFAULT_SOCKET_PATH, type=Path)
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
        if args.pairing_code_file:
            args.pairing_code_file.write_text(f"{state['pairing']['code']}\n", encoding="utf-8")
            os.chmod(args.pairing_code_file, 0o600)
        print(f"State file: {args.state_file}")
        print(f"Pairing code: {state['pairing']['code']}")
        print("Pairing mode: enabled")
        return 0

    server = build_server(
        args.host,
        args.port,
        args.state_file,
        pairing_code,
        args.wireguard_backend,
        args.wireguard_config,
        args.wireguard_interface,
        args.control_socket,
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
