from __future__ import annotations

import select
import socket
import socketserver
import threading
import time
from copy import deepcopy
from typing import Any


ACCESS_BIND_ADDRESS = "10.88.0.2"
ACCESS_PORT_MIN = 30000
ACCESS_PORT_MAX = 30999


class _ThreadingTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class _ThreadingUDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class _TCPForwardHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        target = self.server.target  # type: ignore[attr-defined]
        try:
            upstream = socket.create_connection(target, timeout=10)
        except OSError:
            return

        with upstream:
            self.request.setblocking(False)
            upstream.setblocking(False)
            sockets = [self.request, upstream]
            while True:
                try:
                    readable, _, exceptional = select.select(sockets, [], sockets, 30)
                except OSError:
                    return
                if exceptional:
                    return
                if not readable:
                    continue
                for source in readable:
                    destination = upstream if source is self.request else self.request
                    try:
                        chunk = source.recv(65536)
                    except OSError:
                        return
                    if not chunk:
                        return
                    try:
                        destination.sendall(chunk)
                    except OSError:
                        return


class _UDPForwardHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        body, listener = self.request
        target = self.server.target  # type: ignore[attr-defined]
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as upstream:
            upstream.settimeout(3)
            try:
                upstream.sendto(body, target)
                response, _ = upstream.recvfrom(65535)
                listener.sendto(response, self.client_address)
            except OSError:
                return


class AccessForwardManager:
    """Own raw TCP/UDP listeners on the Home Agent WireGuard address."""

    def __init__(self, bind_address: str = ACCESS_BIND_ADDRESS):
        self.bind_address = bind_address
        self._lock = threading.RLock()
        self._servers: dict[str, tuple[dict[str, Any], socketserver.BaseServer, threading.Thread]] = {}
        self._errors: dict[str, str] = {}

    def sync(self, routes: dict[str, dict[str, Any]]) -> dict[str, Any]:
        normalized = {
            str(name): deepcopy(route)
            for name, route in routes.items()
            if isinstance(route, dict)
        }
        with self._lock:
            for name in list(self._servers):
                current = self._servers[name][0]
                if name not in normalized or self._signature(current) != self._signature(normalized[name]):
                    self._stop_locked(name)

            for name, route in normalized.items():
                if name in self._servers:
                    self._errors.pop(name, None)
                    continue
                try:
                    self._start_locked(name, route)
                    self._errors.pop(name, None)
                except OSError as error:
                    self._errors[name] = str(error)

            return self.diagnostics()

    def close(self) -> None:
        with self._lock:
            for name in list(self._servers):
                self._stop_locked(name)

    def diagnostics(self) -> dict[str, Any]:
        with self._lock:
            listeners = []
            for name, (route, _, thread) in self._servers.items():
                listeners.append(
                    {
                        "name": name,
                        "protocol": route["protocol"],
                        "accessAddress": self.bind_address,
                        "accessPort": route["accessPort"],
                        "targetHost": route["targetHost"],
                        "targetPort": route["targetPort"],
                        "running": thread.is_alive(),
                    }
                )
            return {
                "bindAddress": self.bind_address,
                "listeners": listeners,
                "errors": deepcopy(self._errors),
                "checkedAt": _utc_now(),
            }

    def _start_locked(self, name: str, route: dict[str, Any]) -> None:
        protocol = str(route.get("protocol") or "tcp").lower()
        access_port = int(route["accessPort"])
        target = (str(route["targetHost"]), int(route["targetPort"]))
        server_type: type[socketserver.BaseServer]
        handler_type: type[socketserver.BaseRequestHandler]
        if protocol == "udp":
            server_type = _ThreadingUDPServer
            handler_type = _UDPForwardHandler
        else:
            server_type = _ThreadingTCPServer
            handler_type = _TCPForwardHandler

        server = server_type((self.bind_address, access_port), handler_type)
        server.target = target  # type: ignore[attr-defined]
        thread = threading.Thread(
            target=server.serve_forever,
            kwargs={"poll_interval": 0.5},
            name=f"tater-access-{protocol}-{access_port}",
            daemon=True,
        )
        thread.start()
        self._servers[name] = (deepcopy(route), server, thread)

    def _stop_locked(self, name: str) -> None:
        _, server, thread = self._servers.pop(name)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    @staticmethod
    def _signature(route: dict[str, Any]) -> tuple[Any, ...]:
        return (
            str(route.get("protocol") or "tcp").lower(),
            int(route.get("accessPort") or 0),
            str(route.get("targetHost") or ""),
            int(route.get("targetPort") or 0),
        )


class AccessForwardLoop:
    """Retries listener binding while a native tunnel interface is coming up."""

    def __init__(self, manager: AccessForwardManager, route_provider):
        self.manager = manager
        self.route_provider = route_provider

    def run(self, stop_event: threading.Event) -> None:
        while not stop_event.is_set():
            try:
                self.manager.sync(self.route_provider())
            except Exception:
                pass
            stop_event.wait(2)


def _utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
