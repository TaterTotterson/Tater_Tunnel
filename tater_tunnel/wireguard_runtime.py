from __future__ import annotations

import os
import platform
import shutil
import subprocess
import tempfile
import time
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class WireGuardRuntimeError(Exception):
    pass


class CommandRunner:
    def which(self, command: str) -> str | None:
        return shutil.which(command)

    def system(self) -> str:
        return platform.system()

    def run(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(command, check=False, capture_output=True, text=True)


class WireGuardSystemProbe:
    def __init__(self, runner: CommandRunner | None = None):
        self.runner = runner or CommandRunner()

    def inspect(self, interface_name: str) -> dict[str, Any]:
        system_name = self.runner.system()
        commands = {
            "wg": self.runner.which("wg"),
            "ip": self.runner.which("ip"),
            "ifconfig": self.runner.which("ifconfig"),
        }
        interface_exists = self._interface_exists(system_name, interface_name)
        warnings: list[str] = []

        if system_name != "Linux":
            warnings.append("system backend is currently Linux-only")
        if not commands["wg"]:
            warnings.append("wg command is not installed")
        if system_name == "Linux" and not commands["ip"]:
            warnings.append("ip command is not installed")

        can_create = system_name == "Linux" and bool(commands["ip"])
        can_apply = system_name == "Linux" and bool(commands["wg"]) and (interface_exists or can_create)

        return {
            "platform": system_name,
            "interfaceName": interface_name,
            "interfaceExists": interface_exists,
            "canCreateInterface": can_create,
            "canApply": can_apply,
            "commands": commands,
            "warnings": warnings,
        }

    def _interface_exists(self, system_name: str, interface_name: str) -> bool:
        if system_name == "Linux" and self.runner.which("ip"):
            result = self.runner.run(["ip", "link", "show", "dev", interface_name])
            return result.returncode == 0

        if self.runner.which("ifconfig"):
            result = self.runner.run(["ifconfig", interface_name])
            return result.returncode == 0

        return False


class WireGuardConfigRuntime:
    backend = "config"

    def __init__(
        self,
        config_path: Path | str,
        interface_name: str = "tater0",
        runner: CommandRunner | None = None,
    ):
        self.config_path = Path(config_path)
        self.interface_name = interface_name
        self.runner = runner or CommandRunner()
        self.probe = WireGuardSystemProbe(self.runner)

    def apply(self, state: dict[str, Any]) -> dict[str, Any]:
        if not state.get("claimed") or not state.get("interface", {}).get("wireguard"):
            return self.reset()

        config = render_server_config(state)
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(
            prefix=f".{self.config_path.name}.",
            suffix=".tmp",
            dir=self.config_path.parent,
            text=True,
        )

        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(config)
            os.replace(temp_name, self.config_path)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)

        return self._result("rendered", "WireGuard config rendered")

    def reset(self) -> dict[str, Any]:
        if self.config_path.exists():
            self.config_path.unlink()

        return self._result("reset", "WireGuard config removed")

    def _result(self, action: str, message: str) -> dict[str, Any]:
        return {
            "backend": self.backend,
            "interfaceName": self.interface_name,
            "configPath": str(self.config_path),
            "lastAction": action,
            "lastAppliedAt": utc_now(),
            "message": message,
        }

    def _write_setconf_config(self) -> Path:
        config = render_wg_setconf_config(self.config_path.read_text(encoding="utf-8"))
        fd, temp_name = tempfile.mkstemp(
            prefix=f".{self.config_path.name}.setconf.",
            suffix=".tmp",
            dir=self.config_path.parent,
            text=True,
        )

        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(config)

        return Path(temp_name)

    def diagnostics(self, state: dict[str, Any] | None = None) -> dict[str, Any]:
        system = self.probe.inspect(self.interface_name)
        return {
            "backend": self.backend,
            "interfaceName": self.interface_name,
            "configPath": str(self.config_path),
            "configExists": self.config_path.exists(),
            "system": system,
            **self._live_peer_diagnostics(system),
        }

    def _live_peer_diagnostics(self, system: dict[str, Any]) -> dict[str, Any]:
        diagnostics: dict[str, Any] = {
            "livePeerSource": "wg show dump",
            "livePeerSnapshotAt": utc_now(),
            "livePeers": [],
            "livePeerWarnings": [],
        }
        warnings = diagnostics["livePeerWarnings"]

        if not system.get("commands", {}).get("wg"):
            warnings.append("wg command is not installed")
            return diagnostics
        if not system.get("interfaceExists"):
            warnings.append(f"interface {self.interface_name} does not exist")
            return diagnostics

        completed = self.runner.run(["wg", "show", self.interface_name, "dump"])
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "wg show dump failed"
            warnings.append(detail)
            return diagnostics

        diagnostics["livePeers"] = parse_wg_show_dump(completed.stdout)
        return diagnostics


class WireGuardCommandRuntime(WireGuardConfigRuntime):
    backend = "wg"

    def apply(self, state: dict[str, Any]) -> dict[str, Any]:
        result = super().apply(state)
        if result["lastAction"] == "reset":
            return result

        diagnostics = self.probe.inspect(self.interface_name)
        if not diagnostics["commands"]["wg"]:
            raise WireGuardRuntimeError("wg command is not installed")
        if not diagnostics["interfaceExists"]:
            raise WireGuardRuntimeError(
                f"interface {self.interface_name} does not exist; use the system backend to create it"
            )

        setconf_path = self._write_setconf_config()
        try:
            command = ["wg", "setconf", self.interface_name, str(setconf_path)]
            completed = self.runner.run(command)
            if completed.returncode != 0:
                detail = completed.stderr.strip() or completed.stdout.strip() or "wg setconf failed"
                raise WireGuardRuntimeError(detail)
        finally:
            setconf_path.unlink(missing_ok=True)

        result["lastAction"] = "applied"
        result["message"] = "WireGuard config applied with wg setconf"
        result["command"] = " ".join(command)
        return result


class WireGuardSystemRuntime(WireGuardConfigRuntime):
    backend = "system"

    def apply(self, state: dict[str, Any]) -> dict[str, Any]:
        result = super().apply(state)
        if result["lastAction"] == "reset":
            result["system"] = self.probe.inspect(self.interface_name)
            return result

        diagnostics = self.probe.inspect(self.interface_name)
        self._require_system_ready(diagnostics)
        commands_run: list[str] = []

        if not diagnostics["interfaceExists"]:
            commands_run.append(self._run_system_command(["ip", "link", "add", "dev", self.interface_name, "type", "wireguard"]))

        setconf_path = self._write_setconf_config()
        try:
            commands_run.append(self._run_system_command(["wg", "setconf", self.interface_name, str(setconf_path)]))
        finally:
            setconf_path.unlink(missing_ok=True)
        commands_run.append(self._run_system_command(["ip", "address", "replace", state["interface"]["address"], "dev", self.interface_name]))
        commands_run.append(self._run_system_command(["ip", "link", "set", "up", "dev", self.interface_name]))

        result["lastAction"] = "applied"
        result["message"] = "WireGuard interface configured with system commands"
        result["commands"] = commands_run
        result["system"] = self.probe.inspect(self.interface_name)
        return result

    def reset(self) -> dict[str, Any]:
        result = super().reset()
        result["message"] = "WireGuard config removed; live interface unchanged"
        result["system"] = self.probe.inspect(self.interface_name)
        return result

    def _require_system_ready(self, diagnostics: dict[str, Any]) -> None:
        if diagnostics["platform"] != "Linux":
            raise WireGuardRuntimeError("system backend is currently Linux-only")
        if not diagnostics["commands"]["wg"]:
            raise WireGuardRuntimeError("wg command is not installed")
        if not diagnostics["commands"]["ip"]:
            raise WireGuardRuntimeError("ip command is not installed")

    def _run_system_command(self, command: list[str]) -> str:
        completed = self.runner.run(command)
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "command failed"
            raise WireGuardRuntimeError(f"{' '.join(command)}: {detail}")
        return " ".join(command)


class WireGuardClientConfigRuntime(WireGuardConfigRuntime):
    def apply(self, state: dict[str, Any], endpoint: str) -> dict[str, Any]:
        home_wireguard = state.get("homeAgent", {}).get("wireguard")
        vps_wireguard = (state.get("vpsAgent") or {}).get("wireguard")
        if not state.get("paired") or not home_wireguard or not vps_wireguard:
            return self.reset()

        config = render_home_agent_config(state, endpoint)
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(
            prefix=f".{self.config_path.name}.",
            suffix=".tmp",
            dir=self.config_path.parent,
            text=True,
        )

        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(config)
            os.replace(temp_name, self.config_path)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)

        return self._result("rendered", "Home Agent WireGuard config rendered")


class WireGuardClientCommandRuntime(WireGuardClientConfigRuntime):
    backend = "wg"

    def apply(self, state: dict[str, Any], endpoint: str) -> dict[str, Any]:
        result = super().apply(state, endpoint)
        if result["lastAction"] == "reset":
            return result

        diagnostics = self.probe.inspect(self.interface_name)
        if not diagnostics["commands"]["wg"]:
            raise WireGuardRuntimeError("wg command is not installed")
        if not diagnostics["interfaceExists"]:
            raise WireGuardRuntimeError(
                f"interface {self.interface_name} does not exist; use the system backend to create it"
            )

        setconf_path = self._write_setconf_config()
        try:
            command = ["wg", "setconf", self.interface_name, str(setconf_path)]
            completed = self.runner.run(command)
            if completed.returncode != 0:
                detail = completed.stderr.strip() or completed.stdout.strip() or "wg setconf failed"
                raise WireGuardRuntimeError(detail)
        finally:
            setconf_path.unlink(missing_ok=True)

        result["lastAction"] = "applied"
        result["message"] = "Home Agent WireGuard config applied with wg setconf"
        result["command"] = " ".join(command)
        return result


class WireGuardClientSystemRuntime(WireGuardClientConfigRuntime):
    backend = "system"

    def apply(self, state: dict[str, Any], endpoint: str) -> dict[str, Any]:
        result = super().apply(state, endpoint)
        if result["lastAction"] == "reset":
            result["system"] = self.probe.inspect(self.interface_name)
            return result

        diagnostics = self.probe.inspect(self.interface_name)
        self._require_system_ready(diagnostics)
        address = state["vpsAgent"]["wireguard"].get("homeAllowedIp") or "10.88.0.2/32"
        commands_run: list[str] = []

        if not diagnostics["interfaceExists"]:
            commands_run.append(self._run_system_command(["ip", "link", "add", "dev", self.interface_name, "type", "wireguard"]))

        setconf_path = self._write_setconf_config()
        try:
            commands_run.append(self._run_system_command(["wg", "setconf", self.interface_name, str(setconf_path)]))
        finally:
            setconf_path.unlink(missing_ok=True)
        commands_run.append(self._run_system_command(["ip", "address", "replace", address, "dev", self.interface_name]))
        commands_run.append(self._run_system_command(["ip", "link", "set", "up", "dev", self.interface_name]))

        result["lastAction"] = "applied"
        result["message"] = "Home Agent WireGuard interface configured with system commands"
        result["commands"] = commands_run
        result["system"] = self.probe.inspect(self.interface_name)
        return result

    def reset(self) -> dict[str, Any]:
        result = super().reset()
        result["message"] = "WireGuard config removed; live interface unchanged"
        result["system"] = self.probe.inspect(self.interface_name)
        return result

    def _require_system_ready(self, diagnostics: dict[str, Any]) -> None:
        if diagnostics["platform"] != "Linux":
            raise WireGuardRuntimeError("system backend is currently Linux-only")
        if not diagnostics["commands"]["wg"]:
            raise WireGuardRuntimeError("wg command is not installed")
        if not diagnostics["commands"]["ip"]:
            raise WireGuardRuntimeError("ip command is not installed")

    def _run_system_command(self, command: list[str]) -> str:
        completed = self.runner.run(command)
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "command failed"
            raise WireGuardRuntimeError(f"{' '.join(command)}: {detail}")
        return " ".join(command)


def build_wireguard_runtime(
    backend: str,
    config_path: Path | str,
    interface_name: str = "tater0",
    runner: CommandRunner | None = None,
) -> WireGuardConfigRuntime:
    if backend == "config":
        return WireGuardConfigRuntime(config_path, interface_name, runner)
    if backend == "wg":
        return WireGuardCommandRuntime(config_path, interface_name, runner)
    if backend == "system":
        return WireGuardSystemRuntime(config_path, interface_name, runner)

    raise ValueError("WireGuard backend must be config, wg, or system")


def build_wireguard_client_runtime(
    backend: str,
    config_path: Path | str,
    interface_name: str = "tater-home",
    runner: CommandRunner | None = None,
) -> WireGuardClientConfigRuntime:
    if backend == "config":
        return WireGuardClientConfigRuntime(config_path, interface_name, runner)
    if backend == "wg":
        return WireGuardClientCommandRuntime(config_path, interface_name, runner)
    if backend == "system":
        return WireGuardClientSystemRuntime(config_path, interface_name, runner)

    raise ValueError("WireGuard backend must be config, wg, or system")


def render_server_config(state: dict[str, Any]) -> str:
    interface = state["interface"]
    wireguard = interface["wireguard"]
    peers = normalized_peers(state)
    lines = [
        "# Generated by Tater Tunnel VPS Agent",
        "# Do not edit by hand while the agent is managing peers.",
        "",
        "[Interface]",
        f"PrivateKey = {wireguard['privateKey']}",
        f"Address = {interface['address']}",
        f"ListenPort = {state['wireguardPort']}",
    ]

    for peer in peers:
        lines.extend(
            [
                "",
                f"# peer: {sanitize_comment(peer['name'])} ({sanitize_comment(peer['id'])})",
                "[Peer]",
                f"PublicKey = {peer['publicKey']}",
                f"AllowedIPs = {peer['allowedIp']}",
            ]
        )

    return "\n".join(lines) + "\n"


def render_home_agent_config(state: dict[str, Any], endpoint: str) -> str:
    home_wireguard = state["homeAgent"]["wireguard"]
    vps_wireguard = state["vpsAgent"]["wireguard"]
    lines = [
        "# Generated by Tater Tunnel Home Agent",
        "# Do not edit by hand while the agent is managing the tunnel.",
        "",
        "[Interface]",
        f"PrivateKey = {home_wireguard['privateKey']}",
        f"Address = {vps_wireguard.get('homeAllowedIp') or '10.88.0.2/32'}",
        "",
        "# peer: Tater VPS Agent",
        "[Peer]",
        f"PublicKey = {vps_wireguard['publicKey']}",
        f"Endpoint = {endpoint}",
        f"AllowedIPs = {vps_wireguard.get('network') or '10.88.0.0/24'}",
        "PersistentKeepalive = 25",
    ]

    return "\n".join(lines) + "\n"


def render_wg_setconf_config(config: str) -> str:
    unsupported_interface_keys = {
        "address",
        "dns",
        "mtu",
        "table",
        "preup",
        "postup",
        "predown",
        "postdown",
        "saveconfig",
    }
    section = ""
    lines: list[str] = []

    for line in config.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped.lower()
            lines.append(line)
            continue

        if section == "[interface]" and "=" in stripped:
            key = stripped.split("=", 1)[0].strip().lower()
            if key in unsupported_interface_keys:
                continue

        lines.append(line)

    return "\n".join(lines).rstrip() + "\n"


def normalized_peers(state: dict[str, Any]) -> list[dict[str, str]]:
    peers: list[dict[str, str]] = []
    home_agent = state.get("homeAgent")
    if home_agent and home_agent.get("publicKey"):
        peers.append(
            {
                "id": str(home_agent.get("id") or "home-agent"),
                "name": "Tater Home Agent",
                "publicKey": home_agent["publicKey"],
                "allowedIp": home_agent.get("allowedIp") or "10.88.0.2/32",
            }
        )

    for peer in state.get("peers", []):
        peers.append(deepcopy(peer))

    return peers


def parse_wg_show_dump(output: str, now: int | None = None) -> list[dict[str, Any]]:
    peers: list[dict[str, Any]] = []
    now = int(time.time()) if now is None else now

    for line_number, line in enumerate(output.splitlines()):
        if not line.strip() or line_number == 0:
            continue

        parts = line.split("\t")
        if len(parts) < 8:
            parts = line.split()
        if len(parts) < 8:
            continue

        latest_handshake = parse_int(parts[4])
        handshake_at = ""
        handshake_age: int | None = None
        if latest_handshake:
            handshake_age = max(0, now - latest_handshake)
            handshake_at = datetime.fromtimestamp(latest_handshake, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

        peers.append(
            {
                "publicKey": parts[0],
                "endpoint": "" if parts[2] == "(none)" else parts[2],
                "allowedIps": [] if parts[3] == "(none)" else parts[3].split(","),
                "latestHandshakeAt": handshake_at,
                "latestHandshakeAgeSeconds": handshake_age,
                "transferRxBytes": parse_int(parts[5]),
                "transferTxBytes": parse_int(parts[6]),
                "persistentKeepalive": None if parts[7] == "off" else parse_int(parts[7]),
                "connected": handshake_age is not None and handshake_age <= 180,
            }
        )

    return peers


def parse_int(value: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def sanitize_comment(value: str) -> str:
    return value.replace("\n", " ").replace("\r", " ").strip()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
