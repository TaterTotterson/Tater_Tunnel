from __future__ import annotations

import argparse
import json
import os
import platform
import pwd
import re
import shutil
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

from . import __version__


DEFAULT_SOCKET_PATH = Path("/run/tater-tunnel-control/control.sock")
DEFAULT_INSTALL_DIR = Path("/opt/tater-tunnel")
MAX_REQUEST_BYTES = 128 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_COMMAND_OUTPUT_CHARS = 64 * 1024
APP_OPERATION_TIMEOUT_SECONDS = 30 * 60
SFTPGO_ENV_PATH = Path("/etc/sftpgo/env.d/tater-tunnel.env")
SFTPGO_STORAGE_IMAGE = Path("/var/lib/sftpgo-storage/tater-data.img")
SFTPGO_STORAGE_ROOT = Path("/srv/sftpgo/data")
ZNC_UNIT_DIR = Path("/etc/systemd/system")
UPDATE_STATUS_PATH = Path("/var/lib/tater-tunnel/update-status.json")
WIREGUARD_HOST = "10.88.0.1"
VALID_ACCESS = {
    "sftp": {"disabled", "private", "public"},
    "ftp": {"disabled", "private", "public"},
    "webdav": {"disabled", "private", "https"},
}
VALID_SERVICE_ACTIONS = {"start", "restart", "disable"}


class ControlHelperError(Exception):
    pass


class ControlHelperClientError(Exception):
    pass


class CpuSampler:
    def __init__(self):
        self._lock = threading.Lock()
        self._previous = read_cpu_times()

    def percent(self) -> float:
        current = read_cpu_times()
        with self._lock:
            previous = self._previous
            self._previous = current
        if previous is None or current is None:
            return 0.0
        total_delta = current[0] - previous[0]
        idle_delta = current[1] - previous[1]
        if total_delta <= 0:
            return 0.0
        busy_delta = max(0, total_delta - max(0, idle_delta))
        return round(min(100.0, busy_delta / total_delta * 100), 1)


class ControlHelperClient:
    def __init__(self, socket_path: Path | str = DEFAULT_SOCKET_PATH):
        self.socket_path = Path(socket_path)

    def request(self, operation: str, payload: dict[str, Any] | None = None, timeout: float = 5) -> dict[str, Any]:
        request = json.dumps(
            {"operation": str(operation), "payload": payload or {}}, separators=(",", ":")
        ).encode("utf-8") + b"\n"
        if len(request) > MAX_REQUEST_BYTES:
            raise ControlHelperClientError("Control request is too large")

        response = bytearray()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(timeout)
                client.connect(str(self.socket_path))
                client.sendall(request)
                client.shutdown(socket.SHUT_WR)
                while True:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    response.extend(chunk)
                    if len(response) > MAX_RESPONSE_BYTES:
                        raise ControlHelperClientError("Control response is too large")
        except (OSError, TimeoutError) as error:
            raise ControlHelperClientError(f"VPS control helper is unavailable: {error}") from error

        try:
            decoded = json.loads(response.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ControlHelperClientError("VPS control helper returned an invalid response") from error
        if not isinstance(decoded, dict):
            raise ControlHelperClientError("VPS control helper returned an invalid response")
        if not decoded.get("ok"):
            raise ControlHelperClientError(str(decoded.get("error") or "VPS control operation failed"))
        result = decoded.get("result")
        if not isinstance(result, dict):
            raise ControlHelperClientError("VPS control helper returned an invalid result")
        return result


class ControlHelperService:
    def __init__(self, install_dir: Path | str = DEFAULT_INSTALL_DIR):
        self.install_dir = Path(install_dir).resolve()
        self._mutation_lock = threading.Lock()
        self._cpu_sampler = CpuSampler()

    def execute(self, operation: str, payload: dict[str, Any]) -> dict[str, Any]:
        if operation == "snapshot":
            return self.snapshot()
        if operation == "configure-app":
            with self._mutation_lock:
                return self.configure_app(payload)
        if operation == "service-action":
            with self._mutation_lock:
                return self.service_action(payload)
        if operation == "security-audit":
            with self._mutation_lock:
                return self.security_audit(payload)
        if operation == "update-vps":
            with self._mutation_lock:
                return self.schedule_vps_update()
        raise ControlHelperError("Control operation is not allowed")

    def snapshot(self) -> dict[str, Any]:
        return {
            "system": system_snapshot(self._cpu_sampler),
            "apps": {
                "sftpgo": sftpgo_snapshot(),
                "znc": znc_snapshot(),
            },
            "updates": {"vps": vps_update_snapshot()},
            "capabilities": {
                "appManagement": True,
                "securityAudit": True,
                "vpsUpdate": True,
            },
        }

    def schedule_vps_update(self) -> dict[str, Any]:
        status = vps_update_snapshot()
        if status["status"] in {"scheduled", "running"}:
            raise ControlHelperError("A VPS update is already running")

        script = self._script("update-vps-from-ui.sh")
        unit = f"tater-tunnel-update-{int(time.time())}"
        write_vps_update_status("scheduled", "", "The VPS update is scheduled.")
        completed = run_command(
            [
                "systemd-run",
                "--quiet",
                "--collect",
                "--no-block",
                f"--unit={unit}",
                "--property=Type=oneshot",
                "--property=TimeoutStartSec=1800",
                str(script),
            ],
            timeout=15,
        )
        if completed.returncode != 0:
            output = combined_output(completed)
            write_vps_update_status("failed", "", "The VPS update could not be scheduled.")
            raise ControlHelperError(output or "The VPS update could not be scheduled")
        return {
            "status": "scheduled",
            "message": "The official VPS updater was scheduled.",
        }

    def configure_app(self, payload: dict[str, Any]) -> dict[str, Any]:
        app = normalize_app(payload.get("app"))
        settings = payload.get("settings") or {}
        if not isinstance(settings, dict):
            raise ControlHelperError("App settings must be an object")
        if app == "sftpgo":
            return self._configure_sftpgo(settings)
        return self._configure_znc(settings)

    def service_action(self, payload: dict[str, Any]) -> dict[str, Any]:
        app = normalize_app(payload.get("app"))
        action = str(payload.get("action") or "").strip().lower()
        if action not in VALID_SERVICE_ACTIONS:
            raise ControlHelperError("Service action is not allowed")
        unit = "sftpgo.service" if app == "sftpgo" else znc_unit_name()
        if not unit:
            raise ControlHelperError(f"{display_app_name(app)} is not installed")
        if action == "start":
            command = ["systemctl", "enable", "--now", unit]
        elif action == "restart":
            command = ["systemctl", "restart", unit]
        else:
            command = ["systemctl", "disable", "--now", unit]
        result = run_mutation(command)
        return {
            "status": "ok",
            "app": app,
            "action": action,
            "output": result,
            "snapshot": self.snapshot()["apps"][app],
        }

    def security_audit(self, payload: dict[str, Any]) -> dict[str, Any]:
        domain = normalize_optional_domain(payload.get("domain"))
        command = [str(self._script("audit-vps-security.sh"))]
        if domain:
            command.extend(["--domain", domain])
        completed = run_command(command, timeout=5 * 60)
        output = combined_output(completed)
        return {
            "status": "passed" if completed.returncode == 0 else "failed",
            "passed": completed.returncode == 0,
            "output": output,
        }

    def _configure_sftpgo(self, settings: dict[str, Any]) -> dict[str, Any]:
        sftp_access = normalize_access("sftp", settings.get("sftpAccess"), "private")
        ftp_access = normalize_access("ftp", settings.get("ftpAccess"), "disabled")
        webdav_access = normalize_access("webdav", settings.get("webdavAccess"), "disabled")
        if {sftp_access, ftp_access, webdav_access} == {"disabled"}:
            raise ControlHelperError("Enable at least one SFTPGo protocol")

        command = [
            str(self._script("install-sftpgo.sh")),
            "--sftp-access",
            sftp_access,
            "--ftp-access",
            ftp_access,
            "--webdav-access",
            webdav_access,
        ]
        webdav_domain = ""
        if webdav_access == "https":
            webdav_domain = normalize_required_domain(settings.get("webdavDomain"), "WebDAV hostname")
            command.extend(["--webdav-domain", webdav_domain])
        if ftp_access == "public":
            if settings.get("allowInsecurePublicFtp") is not True:
                raise ControlHelperError("Public FTP requires explicit acknowledgement that it is unencrypted")
            command.append("--allow-insecure-public-protocols")

        storage_cap = normalize_optional_int(settings.get("maxStorageGb"), "Storage cap", 1, 1048576)
        if storage_cap is not None:
            command.extend(["--max-storage-gb", str(storage_cap)])

        cloudflare = settings.get("cloudflare") or {}
        if cloudflare:
            if not isinstance(cloudflare, dict) or cloudflare.get("enabled") is not True:
                raise ControlHelperError("Cloudflare settings are invalid")
            if webdav_access != "https":
                raise ControlHelperError("Cloudflare DNS setup requires HTTPS WebDAV")
            self._configure_cloudflare(cloudflare, webdav_domain)

        output = run_mutation(command)
        return {
            "status": "ok",
            "app": "sftpgo",
            "output": output,
            "snapshot": sftpgo_snapshot(),
        }

    def _configure_cloudflare(self, settings: dict[str, Any], record: str) -> None:
        zone = normalize_required_domain(settings.get("zone"), "Cloudflare zone")
        token = str(settings.get("apiToken") or "")
        if not 20 <= len(token) <= 4096 or any(character.isspace() for character in token):
            raise ControlHelperError("Cloudflare API token is invalid")
        command = [
            str(self._script("configure-cloudflare-dns.sh")),
            "--zone",
            zone,
            "--record",
            record,
        ]
        public_ip = str(settings.get("publicIpv4") or "").strip()
        if public_ip:
            try:
                import ipaddress

                address = ipaddress.ip_address(public_ip)
            except ValueError as error:
                raise ControlHelperError("VPS public IPv4 is invalid") from error
            if address.version != 4 or not address.is_global:
                raise ControlHelperError("VPS public IPv4 must be a public IPv4 address")
            command.extend(["--ipv4", public_ip])
        environment = safe_environment()
        environment["CLOUDFLARE_API_TOKEN"] = token
        run_mutation(command, environment=environment)

    def _configure_znc(self, settings: dict[str, Any]) -> dict[str, Any]:
        username = normalize_linux_username(settings.get("user"))
        try:
            account = pwd.getpwnam(username)
        except KeyError as error:
            raise ControlHelperError(f"Linux user {username} does not exist") from error
        if account.pw_uid == 0:
            raise ControlHelperError("ZNC cannot run as root")

        irc_port = normalize_int(settings.get("ircPort"), "IRC port", 1, 65535, 6697)
        web_port = normalize_int(settings.get("webPort"), "WebAdmin port", 1, 65535, 6698)
        if irc_port == web_port:
            raise ControlHelperError("ZNC IRC and WebAdmin ports must be different")

        command = [
            str(self._script("install-znc.sh")),
            "--user",
            username,
            "--port",
            str(irc_port),
            "--web-listen-port",
            str(web_port),
        ]
        config_path = Path(account.pw_dir) / ".znc" / "configs" / "znc.conf"
        admin_user = str(settings.get("adminUser") or "").strip()
        admin_password = str(settings.get("adminPassword") or "")
        password_file: Path | None = None
        try:
            if not config_path.exists():
                if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,31}", admin_user):
                    raise ControlHelperError("Initial ZNC administrator name is invalid")
                if len(admin_password) < 12 or len(admin_password) > 1024:
                    raise ControlHelperError("Initial ZNC administrator password must be 12 to 1024 characters")
                password_file = Path("/run/tater-tunnel-control/znc-admin-password")
                password_file.write_text(f"{admin_password}\n", encoding="utf-8")
                os.chmod(password_file, 0o600)
                command.extend(
                    ["--admin-user", admin_user, "--admin-password-file", str(password_file)]
                )
            output = run_mutation(command)
        finally:
            admin_password = ""
            if password_file:
                password_file.unlink(missing_ok=True)
        return {
            "status": "ok",
            "app": "znc",
            "output": output,
            "snapshot": znc_snapshot(),
        }

    def _script(self, name: str) -> Path:
        path = (self.install_dir / "scripts" / name).resolve()
        try:
            path.relative_to(self.install_dir)
        except ValueError as error:
            raise ControlHelperError("Managed script path is invalid") from error
        if not path.is_file() or path.is_symlink():
            raise ControlHelperError(f"Managed script is missing: {name}")
        owner = path.stat()
        if owner.st_uid != 0 or owner.st_mode & 0o022:
            raise ControlHelperError(f"Managed script permissions are unsafe: {name}")
        return path


def system_snapshot(cpu_sampler: CpuSampler | None = None) -> dict[str, Any]:
    memory = memory_snapshot()
    disk = disk_snapshot()
    load = load_snapshot(cpu_sampler.percent() if cpu_sampler is not None else 0.0)
    uptime_seconds = read_uptime_seconds()
    return {
        "hostname": socket.gethostname(),
        "operatingSystem": operating_system_name(),
        "kernel": platform.release(),
        "architecture": platform.machine(),
        "suggestedUser": suggested_login_user(),
        "cpuCount": os.cpu_count() or 1,
        "cpuPercent": load["percent"],
        "load1": load["load1"],
        "memory": memory,
        "disk": disk,
        "uptimeSeconds": uptime_seconds,
        "uptimeLabel": format_uptime(uptime_seconds),
        "topProcesses": process_snapshot(),
    }


def suggested_login_user() -> str:
    candidates = []
    for account in pwd.getpwall():
        shell = str(account.pw_shell or "")
        if account.pw_uid >= 1000 and account.pw_uid < 65534 and not shell.endswith(("nologin", "false")):
            candidates.append(account.pw_name)
    return sorted(candidates)[0] if candidates else ""


def operating_system_name() -> str:
    values = read_key_value_file(Path("/etc/os-release"))
    return str(values.get("PRETTY_NAME") or platform.platform()).strip('"')


def load_snapshot(cpu_percent: float = 0.0) -> dict[str, Any]:
    try:
        load1 = float(Path("/proc/loadavg").read_text(encoding="utf-8").split()[0])
    except (OSError, ValueError, IndexError):
        load1 = 0.0
    return {"load1": round(load1, 2), "percent": round(max(0.0, min(100.0, cpu_percent)), 1)}


def read_cpu_times() -> tuple[int, int] | None:
    try:
        fields = Path("/proc/stat").read_text(encoding="utf-8").splitlines()[0].split()
        if not fields or fields[0] != "cpu" or len(fields) < 5:
            return None
        values = [int(value) for value in fields[1:9]]
    except (OSError, ValueError, IndexError):
        return None
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle


def memory_snapshot() -> dict[str, Any]:
    values: dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            key, raw = line.split(":", 1)
            values[key] = int(raw.strip().split()[0]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    used = max(0, total - available)
    return byte_summary(total, used)


def disk_snapshot(path: Path | str = "/") -> dict[str, Any]:
    try:
        usage = shutil.disk_usage(path)
    except OSError:
        return byte_summary(0, 0)
    return byte_summary(usage.total, usage.used)


def byte_summary(total: int, used: int) -> dict[str, Any]:
    free = max(0, total - used)
    percent = round(used / total * 100, 1) if total else 0.0
    return {"totalBytes": total, "usedBytes": used, "freeBytes": free, "percent": percent}


def read_uptime_seconds() -> int:
    try:
        return max(0, int(float(Path("/proc/uptime").read_text(encoding="utf-8").split()[0])))
    except (OSError, ValueError, IndexError):
        return 0


def format_uptime(seconds: int) -> str:
    days, remainder = divmod(max(0, seconds), 86400)
    hours = remainder // 3600
    if days:
        return f"{days}d {hours}h"
    minutes = remainder // 60
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def process_snapshot(limit: int = 5) -> list[dict[str, Any]]:
    try:
        completed = run_command(
            ["ps", "-eo", "pid=,comm=,%cpu=,%mem=", "--sort=-%cpu"], timeout=5
        )
    except ControlHelperError:
        return []
    if completed.returncode != 0:
        return []
    processes = []
    for line in completed.stdout.splitlines()[:limit]:
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        try:
            pid = int(fields[0])
            cpu = max(0.0, float(fields[2]))
            memory = max(0.0, float(fields[3]))
        except ValueError:
            continue
        processes.append(
            {"pid": pid, "name": fields[1][:80], "cpuPercent": cpu, "memoryPercent": memory}
        )
    return processes


def vps_update_snapshot() -> dict[str, Any]:
    result = {
        "installed": __version__,
        "latest": __version__,
        "status": "current",
        "message": "Ready to check the official releases.",
        "updatedAt": "",
        "automaticApply": True,
    }
    try:
        loaded = json.loads(UPDATE_STATUS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return result
    if not isinstance(loaded, dict):
        return result
    status = str(loaded.get("status") or "")
    if status in {"current", "scheduled", "running", "complete", "failed"}:
        result["status"] = status
    version = str(loaded.get("latestVersion") or "")
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        result["latest"] = version
    result["message"] = str(loaded.get("message") or result["message"])[:240]
    result["updatedAt"] = str(loaded.get("updatedAt") or "")[:64]
    return result


def write_vps_update_status(status: str, version: str, message: str) -> None:
    UPDATE_STATUS_PATH.parent.mkdir(parents=True, exist_ok=True)
    body = {
        "status": status,
        "latestVersion": version.removeprefix("v"),
        "message": message[:240],
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".update-status.", dir=UPDATE_STATUS_PATH.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(body, handle, separators=(",", ":"))
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, UPDATE_STATUS_PATH)
    finally:
        temporary.unlink(missing_ok=True)


def sftpgo_snapshot() -> dict[str, Any]:
    installed = bool(shutil.which("sftpgo") or Path("/lib/systemd/system/sftpgo.service").exists())
    service = systemd_snapshot("sftpgo.service") if installed else disabled_service_snapshot()
    values = read_key_value_file(SFTPGO_ENV_PATH, include_comments=True)
    sftp_access = normalized_saved_access(values.get("TATER_SFTPGO_SFTP_ACCESS"), "private")
    ftp_access = normalized_saved_access(values.get("TATER_SFTPGO_FTP_ACCESS"), "disabled")
    webdav_access = normalized_saved_access(values.get("TATER_SFTPGO_WEBDAV_ACCESS"), "disabled")
    webdav_domain = str(values.get("TATER_SFTPGO_WEBDAV_DOMAIN") or "")
    storage_cap = storage_cap_gb()
    storage = disk_snapshot(SFTPGO_STORAGE_ROOT if SFTPGO_STORAGE_ROOT.exists() else "/")
    endpoints = []
    if installed:
        endpoints.append(
            endpoint("WebAdmin", f"http://{WIREGUARD_HOST}:8080/web/admin", "wireguard")
        )
    if installed and sftp_access != "disabled":
        endpoints.insert(0, endpoint("SFTP", f"sftp://{WIREGUARD_HOST}:2022", "wireguard"))
    if installed and ftp_access != "disabled":
        endpoints.append(endpoint("FTP", f"ftp://{WIREGUARD_HOST}:2121", "wireguard"))
    if installed and webdav_access != "disabled":
        endpoints.append(endpoint("WebDAV", f"http://{WIREGUARD_HOST}:10080/", "wireguard"))
    if installed and webdav_access == "https" and webdav_domain:
        endpoints.append(endpoint("WebDAV HTTPS", f"https://{webdav_domain}/", "public"))
    return {
        "id": "sftpgo",
        "name": "SFTPGo",
        "installed": installed,
        "version": command_version(["sftpgo", "--version"]) if installed else "",
        "service": service,
        "settings": {
            "sftpAccess": sftp_access,
            "ftpAccess": ftp_access,
            "webdavAccess": webdav_access,
            "webdavDomain": webdav_domain,
            "maxStorageGb": storage_cap,
            "ports": {"sftp": 2022, "ftp": 2121, "ftpPassive": "50000-50100", "webdav": 10080, "webAdmin": 8080},
        },
        "storage": {**storage, "capGb": storage_cap},
        "endpoints": endpoints,
    }


def znc_snapshot() -> dict[str, Any]:
    unit = znc_unit_name()
    installed = bool(shutil.which("znc") or unit)
    username = unit.removeprefix("znc-").removesuffix(".service") if unit else ""
    data_dir = ""
    config_path: Path | None = None
    if username:
        try:
            data_dir = str(Path(pwd.getpwnam(username).pw_dir) / ".znc")
            config_path = Path(data_dir) / "configs" / "znc.conf"
        except KeyError:
            pass
    config = parse_znc_config(config_path) if config_path else {}
    irc_port = int(config.get("ircPort") or 6697)
    web_port = int(config.get("webPort") or 6698)
    endpoints = []
    if installed:
        endpoints = [
            endpoint("IRC", f"irc://{WIREGUARD_HOST}:{irc_port}", "wireguard"),
            endpoint("WebAdmin", f"http://{WIREGUARD_HOST}:{web_port}/", "wireguard"),
        ]
    return {
        "id": "znc",
        "name": "ZNC",
        "installed": installed,
        "version": command_version(["znc", "--version"]) if installed else "",
        "service": systemd_snapshot(unit) if unit else disabled_service_snapshot(),
        "settings": {
            "user": username,
            "dataDir": data_dir,
            "ircPort": irc_port,
            "webPort": web_port,
            "adminUser": str(config.get("adminUser") or ""),
            "networkCount": int(config.get("networkCount") or 0),
            "hasConfig": bool(config_path and config_path.is_file()),
        },
        "endpoints": endpoints,
    }


def parse_znc_config(path: Path | None) -> dict[str, Any]:
    if not path or not path.is_file():
        return {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return {}
    listeners: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    admin_user = ""
    networks = 0
    for raw in lines:
        line = raw.strip()
        user_match = re.fullmatch(r"<User\s+([^>]+)>", line, re.IGNORECASE)
        if user_match and not admin_user:
            admin_user = user_match.group(1).strip()
        if re.fullmatch(r"<Network\s+[^>]+>", line, re.IGNORECASE):
            networks += 1
        if re.fullmatch(r"<Listener(?:\s+[^>]*)?>", line, re.IGNORECASE):
            current = {}
            continue
        if line.lower() == "</listener>" and current is not None:
            listeners.append(current)
            current = None
            continue
        if current is not None and "=" in line:
            key, value = line.split("=", 1)
            current[key.strip().lower()] = value.strip()
    irc_port = 0
    web_port = 0
    for listener in listeners:
        try:
            port = int(listener.get("port") or 0)
        except ValueError:
            continue
        if listener.get("allowweb", "").lower() == "true" and listener.get("allowirc", "").lower() == "false":
            web_port = port
        elif listener.get("allowirc", "true").lower() != "false":
            irc_port = port
    return {
        "adminUser": admin_user,
        "networkCount": networks,
        "ircPort": irc_port or 6697,
        "webPort": web_port or 6698,
    }


def znc_unit_name() -> str:
    units = sorted(ZNC_UNIT_DIR.glob("znc-*.service"))
    for unit in units:
        username = unit.stem.removeprefix("znc-")
        if re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
            return unit.name
    return ""


def systemd_snapshot(unit: str) -> dict[str, Any]:
    active = read_command(["systemctl", "is-active", unit]).strip()
    enabled = read_command(["systemctl", "is-enabled", unit]).strip()
    return {
        "unit": unit,
        "active": active == "active",
        "status": active or "unknown",
        "enabled": enabled == "enabled",
    }


def disabled_service_snapshot() -> dict[str, Any]:
    return {"unit": "", "active": False, "status": "not-installed", "enabled": False}


def endpoint(label: str, url: str, scope: str) -> dict[str, str]:
    return {"label": label, "url": url, "scope": scope}


def storage_cap_gb() -> int | None:
    try:
        size = SFTPGO_STORAGE_IMAGE.stat().st_size
    except OSError:
        return None
    gib = 1024**3
    return max(1, (size + gib - 1) // gib)


def command_version(command: list[str]) -> str:
    output = read_command(command).splitlines()
    if not output:
        return ""
    match = re.search(r"\b(\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9.-]+)?)\b", output[0])
    return match.group(1) if match else output[0][:80]


def read_command(command: list[str]) -> str:
    try:
        completed = subprocess.run(command, text=True, capture_output=True, timeout=8, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return (completed.stdout or completed.stderr).strip()


def run_mutation(command: list[str], environment: dict[str, str] | None = None) -> str:
    completed = run_command(command, environment=environment)
    output = combined_output(completed)
    if completed.returncode != 0:
        tail = output[-4000:] if output else f"exit code {completed.returncode}"
        raise ControlHelperError(f"Managed command failed: {tail}")
    return output


def run_command(
    command: list[str],
    timeout: float = APP_OPERATION_TIMEOUT_SECONDS,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            stdin=subprocess.DEVNULL,
            env=environment or safe_environment(),
        )
    except subprocess.TimeoutExpired as error:
        raise ControlHelperError("Managed command timed out") from error
    except OSError as error:
        raise ControlHelperError(f"Managed command could not start: {error}") from error


def combined_output(completed: subprocess.CompletedProcess[str]) -> str:
    output = "\n".join(part.strip() for part in (completed.stdout, completed.stderr) if part and part.strip())
    return output[-MAX_COMMAND_OUTPUT_CHARS:]


def safe_environment() -> dict[str, str]:
    return {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "DEBIAN_FRONTEND": "noninteractive",
    }


def read_key_value_file(path: Path, include_comments: bool = False) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return values
    for raw in lines:
        line = raw.strip()
        if include_comments and line.startswith("# TATER_"):
            line = line[2:].strip()
        elif not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def normalize_app(value: Any) -> str:
    app = str(value or "").strip().lower()
    if app not in {"sftpgo", "znc"}:
        raise ControlHelperError("App is not managed by Tater Tunnel")
    return app


def display_app_name(app: str) -> str:
    return "SFTPGo" if app == "sftpgo" else "ZNC"


def normalize_access(protocol: str, value: Any, default: str) -> str:
    access = str(value or default).strip().lower()
    if access not in VALID_ACCESS[protocol]:
        raise ControlHelperError(f"{protocol.upper()} access mode is invalid")
    return access


def normalized_saved_access(value: Any, default: str) -> str:
    normalized = str(value or default).strip().lower()
    return normalized if normalized in {"disabled", "private", "public", "https"} else default


def normalize_linux_username(value: Any) -> str:
    username = str(value or "").strip()
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
        raise ControlHelperError("Linux username is invalid")
    return username


def normalize_required_domain(value: Any, label: str) -> str:
    domain = normalize_optional_domain(value)
    if not domain:
        raise ControlHelperError(f"{label} is required")
    return domain


def normalize_optional_domain(value: Any) -> str:
    domain = str(value or "").strip().lower().rstrip(".")
    if not domain:
        return ""
    if len(domain) > 253 or not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", domain):
        raise ControlHelperError("Domain name is invalid")
    if "." not in domain or ".." in domain:
        raise ControlHelperError("Domain name is invalid")
    return domain


def normalize_int(value: Any, label: str, minimum: int, maximum: int, default: int) -> int:
    if value in {None, ""}:
        return default
    try:
        number = int(str(value))
    except ValueError as error:
        raise ControlHelperError(f"{label} must be a number") from error
    if not minimum <= number <= maximum:
        raise ControlHelperError(f"{label} must be between {minimum} and {maximum}")
    return number


def normalize_optional_int(value: Any, label: str, minimum: int, maximum: int) -> int | None:
    if value in {None, ""}:
        return None
    return normalize_int(value, label, minimum, maximum, minimum)


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


class ControlRequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        try:
            self._require_allowed_peer()
            raw = self.rfile.readline(MAX_REQUEST_BYTES + 1)
            if len(raw) > MAX_REQUEST_BYTES:
                raise ControlHelperError("Control request is too large")
            request = json.loads(raw.decode("utf-8"))
            if not isinstance(request, dict) or not isinstance(request.get("payload") or {}, dict):
                raise ControlHelperError("Control request is invalid")
            result = self.server.service.execute(
                str(request.get("operation") or ""), request.get("payload") or {}
            )
            response = {"ok": True, "result": result}
        except (ControlHelperError, json.JSONDecodeError, UnicodeDecodeError) as error:
            response = {"ok": False, "error": str(error)}
        except Exception as error:
            print(f"Control helper unexpected error: {error}")
            response = {"ok": False, "error": "VPS control helper failed"}
        body = json.dumps(response, separators=(",", ":")).encode("utf-8") + b"\n"
        self.wfile.write(body[:MAX_RESPONSE_BYTES])

    def _require_allowed_peer(self) -> None:
        allowed_uid = self.server.allowed_uid
        if allowed_uid is None or not hasattr(socket, "SO_PEERCRED"):
            return
        credentials = self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        _pid, uid, _gid = struct.unpack("3i", credentials)
        if uid not in {0, allowed_uid}:
            raise ControlHelperError("Control client is not allowed")


class ControlServer(ThreadingUnixServer):
    def __init__(self, path: Path, service: ControlHelperService, allowed_uid: int | None):
        self.path = path
        self.service = service
        self.allowed_uid = allowed_uid
        path.parent.mkdir(parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        super().__init__(str(path), ControlRequestHandler)
        os.chmod(path, 0o660)

    def server_close(self) -> None:
        super().server_close()
        self.path.unlink(missing_ok=True)


def allowed_uid_for(username: str) -> int | None:
    try:
        return pwd.getpwnam(username).pw_uid
    except KeyError:
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the root-only Tater Tunnel control helper")
    parser.add_argument("--socket", default=DEFAULT_SOCKET_PATH, type=Path)
    parser.add_argument("--install-dir", default=DEFAULT_INSTALL_DIR, type=Path)
    parser.add_argument("--allowed-user", default="tater-tunnel")
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        parser.error("The control helper must run as root")
    allowed_uid = allowed_uid_for(args.allowed_user)
    if allowed_uid is None:
        parser.error(f"Allowed control user does not exist: {args.allowed_user}")
    service = ControlHelperService(args.install_dir)
    server = ControlServer(args.socket, service, allowed_uid)
    print(f"Tater Tunnel control helper listening on {args.socket}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
