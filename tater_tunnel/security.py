from __future__ import annotations

import json
import os
import re
import secrets
import tempfile
import threading
import time
from collections import Counter
from datetime import datetime, timezone
from http.cookies import CookieError, SimpleCookie
from pathlib import Path
from urllib.parse import urlsplit
from typing import Any


class BoundedRequests:
    max_connections = 64
    max_connections_per_client = 16
    daemon_threads = True

    def __init__(self, *args, **kwargs):
        self._connection_lock = threading.Lock()
        self._connection_counts = Counter()
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        client = client_address[0] if isinstance(client_address, tuple) else "local"
        with self._connection_lock:
            if (
                sum(self._connection_counts.values()) >= self.max_connections
                or self._connection_counts[client] >= self.max_connections_per_client
            ):
                self.shutdown_request(request)
                return
            self._connection_counts[client] += 1
        try:
            super().process_request(request, client_address)
        except Exception:
            self._release_connection(client)
            raise

    def process_request_thread(self, request, client_address):
        client = client_address[0] if isinstance(client_address, tuple) else "local"
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._release_connection(client)

    def _release_connection(self, client):
        with self._connection_lock:
            self._connection_counts[client] -= 1
            if self._connection_counts[client] <= 0:
                self._connection_counts.pop(client, None)


class BrowserSessions:
    cookie_name = "tater_session"
    lifetime = 8 * 60 * 60

    def __init__(self):
        self._lock = threading.Lock()
        self._sessions = {}

    def create(self):
        token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with self._lock:
            self._prune()
            if len(self._sessions) >= 64:
                self._sessions.pop(next(iter(self._sessions)))
            self._sessions[token] = (csrf, time.monotonic() + self.lifetime)
        return token, csrf

    def validate(self, cookie_header, csrf_header=None):
        cookie = SimpleCookie()
        try:
            cookie.load(cookie_header or "")
            token = cookie[self.cookie_name].value
        except (CookieError, KeyError, ValueError):
            return None
        with self._lock:
            self._prune()
            entry = self._sessions.get(token)
        if not entry:
            return None
        if csrf_header is not None and not secrets.compare_digest(entry[0], str(csrf_header)):
            return None
        return entry[0]

    def _prune(self):
        now = time.monotonic()
        self._sessions = {key: value for key, value in self._sessions.items() if value[1] > now}


def trusted_browser_request(headers, host_header, *, mutation=False):
    if headers.get("Sec-Fetch-Site", "") not in {"", "none", "same-origin"}:
        return False
    origin = headers.get("Origin")
    if origin:
        try:
            parsed = urlsplit(origin)
        except ValueError:
            return False
        if parsed.scheme != "http" or parsed.netloc.lower() != host_header.lower() or parsed.path:
            return False
    elif mutation:
        return False
    return True


def read_request_body(stream, connection, length, timeout=15):
    deadline = time.monotonic() + timeout
    body = bytearray()
    try:
        while len(body) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Request body deadline exceeded")
            connection.settimeout(remaining)
            chunk = stream.read1(min(8192, length - len(body)))
            if not chunk:
                break
            body.extend(chunk)
    finally:
        connection.settimeout(30)
    return bytes(body)


class SecurityHistory:
    """A bounded event history that accepts identifiers, never submitted payloads."""

    limit = 500
    max_bytes = 256 * 1024

    def __init__(self, path: Path):
        self.path = Path(path)
        self._lock = threading.RLock()

    def entries(self):
        with self._lock:
            try:
                if self.path.stat().st_size > self.max_bytes:
                    return []
                entries = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return []
        return entries[-self.limit:] if isinstance(entries, list) else []

    def record(self, event, target="", outcome="success"):
        allowed = {
            "pairing.opened", "pairing.expired", "pairing.failed", "pairing.completed",
            "device.added", "device.revoked", "device.permissions", "service.saved",
            "service.removed", "tunnel.reset", "configure-app", "service-action",
            "security-audit", "update-vps", "dashboard.blocked",
        }
        if event not in allowed:
            raise ValueError("Security event is not supported")
        entry = {
            "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "event": event,
            "target": "".join(c for c in str(target) if c.isalnum() or c in "-_.")[:128],
            "outcome": "success" if outcome == "success" else "failed",
        }
        with self._lock:
            entries = (self.entries() + [entry])[-self.limit:]
            self.path.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(prefix=".security-events.", dir=self.path.parent)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                    json.dump(entries, handle, separators=(",", ":"))
                os.chmod(temporary, 0o600)
                os.replace(temporary, self.path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)


def device_access(value, *, legacy=False):
    if value is None:
        return {"mode": "all" if legacy else "selected", "services": []}
    if not isinstance(value, dict) or value.get("mode") not in {"all", "selected"}:
        raise ValueError("Device access must be all services or selected services")
    services = value.get("services", [])
    if not isinstance(services, list) or len(services) > 1000:
        raise ValueError("Selected services must be a list")
    if any(not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", name) for name in services):
        raise ValueError("Selected service name is invalid")
    return {"mode": value["mode"], "services": sorted(set(services))}


def redact_submitted_secrets(value: Any, payload: dict[str, Any]) -> Any:
    secrets_to_remove = []

    def collect(item):
        if isinstance(item, dict):
            for key, nested in item.items():
                if any(word in str(key).lower() for word in ("password", "token", "secret", "privatekey")):
                    if isinstance(nested, str) and nested:
                        secrets_to_remove.append(nested)
                else:
                    collect(nested)
        elif isinstance(item, list):
            for nested in item:
                collect(nested)

    def sanitize(item):
        if isinstance(item, str):
            for secret in sorted(secrets_to_remove, key=len, reverse=True):
                item = item.replace(secret, "[redacted]")
            return item
        if isinstance(item, dict):
            return {key: sanitize(nested) for key, nested in item.items()}
        if isinstance(item, list):
            return [sanitize(nested) for nested in item]
        return item

    collect(payload)
    return sanitize(value)
