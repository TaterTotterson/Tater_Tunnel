#!/usr/bin/env python3
"""Install and manage the allow-listed container apps exposed by Tater Tunnel."""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


CONFIG_ROOT = Path("/etc/tater-tunnel-control/apps")
STATE_ROOT = Path("/var/lib/tater-tunnel-control/apps")
CADDY_DIR = Path("/etc/caddy/tater-sites")
WIREGUARD_ADDRESS = "10.88.0.1"
WIREGUARD_NETWORK = "10.88.0.0/24"

APP_DEFINITIONS: dict[str, dict[str, Any]] = {
    "uptime-kuma": {
        "name": "Uptime Kuma",
        "image": "louislam/uptime-kuma:2.5.5",
        "container": "tater-uptime-kuma",
        "port": 3001,
        "containerPort": 3001,
    },
    "ntfy": {
        "name": "ntfy",
        "image": "binwiederhier/ntfy:v2.37.2",
        "container": "tater-ntfy",
        "port": 2586,
        "containerPort": 80,
    },
    "forgejo": {
        "name": "Forgejo",
        "image": "codeberg.org/forgejo/forgejo:17.0.2",
        "container": "tater-forgejo",
        "port": 3000,
        "containerPort": 3000,
        "sshPort": 2222,
    },
    "matrix": {
        "name": "Matrix Synapse",
        "image": "ghcr.io/element-hq/synapse:v1.165.0",
        "container": "tater-matrix",
        "port": 8008,
        "containerPort": 8008,
        "postgresImage": "postgres:17-alpine",
    },
}


class ManagedAppError(RuntimeError):
    pass


def run(
    command: list[str],
    *,
    input_text: str | None = None,
    timeout: int = 1800,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        completed = subprocess.run(
            command,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env={
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "DEBIAN_FRONTEND": "noninteractive",
            },
        )
    except subprocess.TimeoutExpired as error:
        raise ManagedAppError(f"Managed command timed out: {command[0]}") from error
    except OSError as error:
        raise ManagedAppError(f"Command could not run: {command[0]}") from error
    if check and completed.returncode != 0:
        output = "\n".join(
            value.strip() for value in (completed.stdout, completed.stderr) if value.strip()
        )
        raise ManagedAppError(output[-5000:] or f"Command failed with exit code {completed.returncode}")
    return completed


def atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path: Path) -> dict[str, Any]:
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def normalize_app(value: str) -> str:
    app = value.strip().lower()
    if app not in APP_DEFINITIONS:
        raise ManagedAppError("App is not managed by Tater Tunnel")
    return app


def normalize_access(value: Any) -> str:
    access = str(value or "private").strip().lower()
    if access not in {"private", "public"}:
        raise ManagedAppError("Access must be private or public")
    return access


def normalize_domain(value: Any, *, required: bool = False) -> str:
    domain = str(value or "").strip().lower().rstrip(".")
    if not domain and not required:
        return ""
    if (
        not domain
        or len(domain) > 253
        or "." not in domain
        or ".." in domain
        or not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", domain)
    ):
        raise ManagedAppError("A valid dedicated hostname is required")
    return domain


def normalize_username(value: Any, label: str = "Administrator") -> str:
    username = str(value or "").strip()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,31}", username):
        raise ManagedAppError(f"{label} username is invalid")
    return username


def normalize_email(value: Any) -> str:
    email = str(value or "").strip().lower()
    if len(email) > 254 or not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email):
        raise ManagedAppError("Administrator email is invalid")
    return email


def require_password(value: Any) -> str:
    password = str(value or "")
    if len(password) < 12 or len(password) > 1024 or any(character in password for character in "\r\n\0"):
        raise ManagedAppError("Administrator password must be 12 to 1024 characters")
    return password


def ensure_root() -> None:
    if os.geteuid() != 0:
        raise ManagedAppError("Run the managed app installer as root")


def compose_prefix() -> list[str]:
    if run(["docker", "compose", "version"], check=False, timeout=20).returncode == 0:
        return ["docker", "compose"]
    if shutil.which("docker-compose"):
        return ["docker-compose"]
    raise ManagedAppError("Docker Compose is not installed")


def ensure_docker() -> None:
    if not shutil.which("docker"):
        if not shutil.which("apt-get"):
            raise ManagedAppError("Docker must be installed on this Debian or Ubuntu VPS")
        run(["apt-get", "update"])
        run(["apt-get", "install", "-y", "docker.io"])
    run(["systemctl", "enable", "--now", "docker"])
    if run(["docker", "compose", "version"], check=False, timeout=20).returncode != 0:
        installed = False
        for package in ("docker-compose-v2", "docker-compose-plugin", "docker-compose"):
            if run(["apt-get", "install", "-y", package], check=False).returncode == 0:
                installed = True
                break
        if not installed:
            raise ManagedAppError("Docker Compose could not be installed")
    compose_prefix()
    run(["docker", "info"], timeout=30)
    if not shutil.which("nft"):
        run(["apt-get", "install", "-y", "nftables"])
    guard = Path(__file__).resolve().with_name("app-network-guard.sh")
    atomic_write(
        Path("/etc/systemd/system/tater-tunnel-container-guard.service"),
        "[Unit]\nDescription=Tater private container firewall\nBefore=docker.service\n"
        "PartOf=docker.service\n\n[Service]\nType=oneshot\n"
        f"ExecStart=/bin/bash {guard}\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target docker.service\n",
        0o644,
    )
    run(["systemctl", "daemon-reload"], timeout=30)
    run(["systemctl", "enable", "--now", "tater-tunnel-container-guard"], timeout=30)
    run(["bash", str(guard)], timeout=30)


def app_paths(app: str) -> tuple[Path, Path, Path, Path]:
    config_dir = CONFIG_ROOT / app
    state_dir = STATE_ROOT / app
    return config_dir, state_dir, config_dir / "settings.json", config_dir / "compose.json"


def private_ports(host_port: int, container_port: int) -> list[str]:
    return [
        f"127.0.0.1:{host_port}:{container_port}",
        f"{WIREGUARD_ADDRESS}:{host_port}:{container_port}",
    ]


def uptime_has_admin(state_dir: Path) -> bool:
    database = state_dir / "data" / "kuma.db"
    if not database.is_file():
        return False
    try:
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=2)
        try:
            row = connection.execute('SELECT COUNT(*) FROM "user"').fetchone()
        finally:
            connection.close()
    except sqlite3.Error:
        return False
    return bool(row and int(row[0]) > 0)


def base_service(image: str, container: str, ports: list[str], volumes: list[str]) -> dict[str, Any]:
    return {
        "image": image,
        "container_name": container,
        "restart": "unless-stopped",
        "init": True,
        "ports": ports,
        "volumes": volumes,
        "security_opt": ["no-new-privileges:true"],
        "logging": {
            "driver": "json-file",
            "options": {"max-size": "10m", "max-file": "3"},
        },
    }


def hash_ntfy_password(image: str, password: str) -> str:
    run(["docker", "pull", image])
    completed = run(
        ["docker", "run", "--rm", "-i", image, "user", "hash"],
        input_text=f"{password}\n{password}\n",
        timeout=120,
    )
    match = re.search(r"\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}", completed.stdout + completed.stderr)
    if not match:
        raise ManagedAppError("ntfy did not return a password hash")
    return match.group(0)


def build_uptime(
    request: dict[str, Any], existing: dict[str, Any], config_dir: Path, state_dir: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    definition = APP_DEFINITIONS["uptime-kuma"]
    access = normalize_access(request.get("access"))
    domain = normalize_domain(request.get("domain"), required=access == "public")
    setup_complete = uptime_has_admin(state_dir)
    if access == "public" and not setup_complete:
        raise ManagedAppError(
            "Install Uptime Kuma with WireGuard-only access first, create its administrator, then enable public HTTPS"
        )
    data_dir = state_dir / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    service = base_service(
        definition["image"],
        definition["container"],
        private_ports(definition["port"], definition["containerPort"]),
        [f"{data_dir}:/app/data"],
    )
    settings = {
        "access": access,
        "domain": domain,
        "image": definition["image"],
        "version": definition["image"].rsplit(":", 1)[1],
        "port": definition["port"],
        "setupComplete": setup_complete,
    }
    return {"services": {"uptime-kuma": service}}, settings


def build_ntfy(
    request: dict[str, Any], existing: dict[str, Any], config_dir: Path, state_dir: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    definition = APP_DEFINITIONS["ntfy"]
    access = normalize_access(request.get("access"))
    domain = normalize_domain(request.get("domain"), required=access == "public")
    admin_user = normalize_username(request.get("adminUser") or existing.get("adminUser"))
    admin_hash = str(existing.get("adminHash") or "")
    password = str(request.get("adminPassword") or "")
    if password:
        admin_hash = hash_ntfy_password(definition["image"], require_password(password))
    if not admin_hash:
        raise ManagedAppError("An administrator password is required for the first ntfy installation")
    data_dir = state_dir / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    base_url = f"https://{domain}" if access == "public" else f"http://{WIREGUARD_ADDRESS}:{definition['port']}"
    config = "\n".join(
        [
            f"base-url: {json.dumps(base_url)}",
            'listen-http: ":80"',
            'cache-file: "/var/lib/ntfy/cache.db"',
            'cache-duration: "12h"',
            'auth-file: "/var/lib/ntfy/auth.db"',
            'auth-default-access: "deny-all"',
            "enable-login: true",
            "enable-signup: false",
            f"behind-proxy: {'true' if access == 'public' else 'false'}",
            'attachment-cache-dir: "/var/lib/ntfy/attachments"',
            "attachment-total-size-limit: \"1G\"",
            "attachment-file-size-limit: \"20M\"",
            "auth-users:",
            f"  - {json.dumps(f'{admin_user}:{admin_hash}:admin')}",
            "",
        ]
    )
    atomic_write(config_dir / "server.yml", config)
    service = base_service(
        definition["image"],
        definition["container"],
        private_ports(definition["port"], definition["containerPort"]),
        [f"{data_dir}:/var/lib/ntfy", f"{config_dir / 'server.yml'}:/etc/ntfy/server.yml:ro"],
    )
    service["command"] = ["serve"]
    settings = {
        "access": access,
        "domain": domain,
        "adminUser": admin_user,
        "adminHash": admin_hash,
        "hasAdmin": True,
        "image": definition["image"],
        "version": definition["image"].rsplit(":", 1)[1].removeprefix("v"),
        "port": definition["port"],
    }
    return {"services": {"ntfy": service}}, settings


def build_forgejo(
    request: dict[str, Any], existing: dict[str, Any], config_dir: Path, state_dir: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    definition = APP_DEFINITIONS["forgejo"]
    access = normalize_access(request.get("access"))
    domain = normalize_domain(request.get("domain"), required=access == "public")
    ssh_access = str(request.get("sshAccess") or existing.get("sshAccess") or "private").lower()
    if ssh_access not in {"private", "public"}:
        raise ManagedAppError("Forgejo SSH access must be private or public")
    if ssh_access == "public" and access != "public":
        raise ManagedAppError("Forgejo public SSH requires a public HTTPS hostname")
    admin_user = normalize_username(request.get("adminUser") or existing.get("adminUser"))
    admin_email = normalize_email(request.get("adminEmail") or existing.get("adminEmail"))
    has_admin = bool(existing.get("hasAdmin"))
    if not has_admin:
        require_password(request.get("adminPassword"))
    data_dir = state_dir / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    root_url = f"https://{domain}/" if access == "public" else f"http://{WIREGUARD_ADDRESS}:{definition['port']}/"
    ssh_domain = domain if ssh_access == "public" else WIREGUARD_ADDRESS
    ports = private_ports(definition["port"], definition["containerPort"])
    ports.append(
        f"0.0.0.0:{definition['sshPort']}:22"
        if ssh_access == "public"
        else f"{WIREGUARD_ADDRESS}:{definition['sshPort']}:22"
    )
    service = base_service(
        definition["image"], definition["container"], ports, [f"{data_dir}:/data"]
    )
    service["environment"] = {
        "USER_UID": "1000",
        "USER_GID": "1000",
        "FORGEJO__database__DB_TYPE": "sqlite3",
        "FORGEJO__server__DOMAIN": domain or WIREGUARD_ADDRESS,
        "FORGEJO__server__ROOT_URL": root_url,
        "FORGEJO__server__HTTP_PORT": "3000",
        "FORGEJO__server__SSH_DOMAIN": ssh_domain,
        "FORGEJO__server__SSH_PORT": str(definition["sshPort"]),
        "FORGEJO__server__SSH_LISTEN_PORT": "22",
        "FORGEJO__server__LFS_START_SERVER": "true",
        "FORGEJO__service__DISABLE_REGISTRATION": "true",
        "FORGEJO__service__REQUIRE_SIGNIN_VIEW": "true",
        "FORGEJO__openid__ENABLE_OPENID_SIGNIN": "false",
        "FORGEJO__openid__ENABLE_OPENID_SIGNUP": "false",
        "FORGEJO__repository__DEFAULT_PRIVATE": "private",
        "FORGEJO__repository__ENABLE_PUSH_CREATE_USER": "false",
        "FORGEJO__session__COOKIE_SECURE": "true" if access == "public" else "false",
        "FORGEJO__security__INSTALL_LOCK": "true",
    }
    settings = {
        "access": access,
        "domain": domain,
        "sshAccess": ssh_access,
        "adminUser": admin_user,
        "adminEmail": admin_email,
        "hasAdmin": has_admin,
        "image": definition["image"],
        "version": definition["image"].rsplit(":", 1)[1],
        "port": definition["port"],
        "sshPort": definition["sshPort"],
    }
    return {"services": {"forgejo": service}}, settings


SYNAPSE_CONFIG_EDITOR = r"""
import json, sys, yaml
from pathlib import Path
payload = json.load(sys.stdin)
path = Path('/data/homeserver.yaml')
config = yaml.safe_load(path.read_text()) or {}
config['database'] = {
  'name': 'psycopg2',
  'args': {
    'user': 'synapse', 'password': payload['postgresPassword'],
    'database': 'synapse', 'host': 'postgres', 'port': 5432,
    'cp_min': 5, 'cp_max': 10,
  },
}
config['listeners'] = [{
  'port': 8008, 'tls': False, 'type': 'http', 'x_forwarded': True,
  'bind_addresses': ['0.0.0.0'],
  'resources': [{'names': ['client', 'federation'], 'compress': False}],
}]
config['public_baseurl'] = payload['publicBaseUrl']
config['enable_registration'] = False
config['enable_registration_without_verification'] = False
config['allow_guest_access'] = False
config['allow_public_rooms_without_auth'] = False
config['allow_public_rooms_over_federation'] = False
config['url_preview_enabled'] = False
config['max_upload_size'] = '50M'
config['report_stats'] = False
config['registration_shared_secret'] = payload['registrationSecret']
if payload['public']:
    config.pop('federation_domain_whitelist', None)
else:
    config['federation_domain_whitelist'] = []
path.write_text(yaml.safe_dump(config, sort_keys=False))
"""


def prepare_synapse_config(
    definition: dict[str, Any], state_dir: Path, settings: dict[str, Any]
) -> None:
    data_dir = state_dir / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    homeserver = data_dir / "homeserver.yaml"
    if not homeserver.exists():
        run(["docker", "pull", definition["image"]])
        run(
            [
                "docker", "run", "--rm",
                "-e", f"SYNAPSE_SERVER_NAME={settings['serverName']}",
                "-e", "SYNAPSE_REPORT_STATS=no",
                "-v", f"{data_dir}:/data",
                definition["image"], "generate",
            ]
        )
    payload = {
        "postgresPassword": settings["postgresPassword"],
        "registrationSecret": settings["registrationSecret"],
        "publicBaseUrl": settings["publicBaseUrl"],
        "public": settings["access"] == "public",
    }
    run(
        [
            "docker", "run", "--rm", "-i", "--entrypoint", "python",
            "-v", f"{data_dir}:/data", definition["image"], "-c", SYNAPSE_CONFIG_EDITOR,
        ],
        input_text=json.dumps(payload),
        timeout=180,
    )


def build_matrix(
    request: dict[str, Any], existing: dict[str, Any], config_dir: Path, state_dir: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    definition = APP_DEFINITIONS["matrix"]
    access = normalize_access(request.get("access"))
    server_name = normalize_domain(request.get("serverName") or existing.get("serverName"), required=True)
    if existing.get("serverName") and server_name != existing.get("serverName"):
        raise ManagedAppError("The Matrix server name is permanent and cannot be changed")
    domain = normalize_domain(request.get("domain") or server_name, required=access == "public")
    if access == "public" and domain != server_name:
        raise ManagedAppError("The first Matrix release requires the public hostname to match the server name")
    admin_user = normalize_username(request.get("adminUser") or existing.get("adminUser"))
    has_admin = bool(existing.get("hasAdmin"))
    if not has_admin:
        require_password(request.get("adminPassword"))
    postgres_password = str(existing.get("postgresPassword") or secrets.token_urlsafe(36))
    registration_secret = str(existing.get("registrationSecret") or secrets.token_urlsafe(48))
    public_base_url = f"https://{domain}/" if access == "public" else f"http://{WIREGUARD_ADDRESS}:{definition['port']}/"
    settings = {
        "access": access,
        "domain": domain if access == "public" else "",
        "serverName": server_name,
        "adminUser": admin_user,
        "hasAdmin": has_admin,
        "postgresPassword": postgres_password,
        "registrationSecret": registration_secret,
        "publicBaseUrl": public_base_url,
        "image": definition["image"],
        "version": definition["image"].rsplit(":", 1)[1].removeprefix("v"),
        "port": definition["port"],
        "federation": access == "public",
    }
    prepare_synapse_config(definition, state_dir, settings)
    data_dir = state_dir / "data"
    postgres_dir = state_dir / "postgres"
    postgres_dir.mkdir(parents=True, exist_ok=True)
    synapse = base_service(
        definition["image"],
        definition["container"],
        private_ports(definition["port"], definition["containerPort"]),
        [f"{data_dir}:/data"],
    )
    synapse["environment"] = {"SYNAPSE_CONFIG_PATH": "/data/homeserver.yaml"}
    synapse["depends_on"] = {"postgres": {"condition": "service_healthy"}}
    postgres = {
        "image": definition["postgresImage"],
        "container_name": "tater-matrix-postgres",
        "restart": "unless-stopped",
        "environment": {
            "POSTGRES_USER": "synapse",
            "POSTGRES_PASSWORD": postgres_password,
            "POSTGRES_DB": "synapse",
            "POSTGRES_INITDB_ARGS": "--encoding=UTF8 --locale=C",
        },
        "volumes": [f"{postgres_dir}:/var/lib/postgresql/data"],
        "healthcheck": {
            "test": ["CMD-SHELL", "pg_isready -U synapse"],
            "interval": "5s", "timeout": "5s", "retries": 20,
        },
        "security_opt": ["no-new-privileges:true"],
        "logging": {
            "driver": "json-file",
            "options": {"max-size": "10m", "max-file": "3"},
        },
    }
    return {"services": {"postgres": postgres, "synapse": synapse}}, settings


BUILDERS = {
    "uptime-kuma": build_uptime,
    "ntfy": build_ntfy,
    "forgejo": build_forgejo,
    "matrix": build_matrix,
}


def caddy_text(app: str, settings: dict[str, Any]) -> str:
    if settings.get("access") != "public":
        return ""
    domain = normalize_domain(settings.get("domain"), required=True)
    port = int(APP_DEFINITIONS[app]["port"])
    if app == "matrix":
        return f"""{domain} {{
    encode zstd gzip
    handle /.well-known/matrix/server {{
        header Content-Type application/json
        respond `{{\"m.server\":\"{domain}:443\"}}` 200
    }}
    handle /.well-known/matrix/client {{
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond `{{\"m.homeserver\":{{\"base_url\":\"https://{domain}\"}}}}` 200
    }}
    handle {{
        reverse_proxy 127.0.0.1:{port}
    }}
}}
"""
    if app != "ntfy":
        return f"""{domain} {{
    encode zstd gzip
    reverse_proxy 127.0.0.1:{port}
}}
"""
    return f"""{domain} {{
    encode zstd gzip
    reverse_proxy 127.0.0.1:{port} {{
        flush_interval -1
    }}
}}
"""


def apply_caddy(app: str, settings: dict[str, Any], enabled: bool = True) -> None:
    snippet = CADDY_DIR / f"tater-app-{app}.caddy"
    desired = caddy_text(app, settings) if enabled else ""
    previous = snippet.read_text(encoding="utf-8") if snippet.exists() else None
    if desired:
        if not shutil.which("caddy") or not Path("/etc/caddy/Caddyfile").exists():
            raise ManagedAppError("Caddy is required before an app can be opened to the web")
        atomic_write(snippet, desired, 0o644)
    else:
        snippet.unlink(missing_ok=True)
    if not shutil.which("caddy") or not Path("/etc/caddy/Caddyfile").exists():
        return
    validation = run(
        ["caddy", "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"],
        check=False,
        timeout=30,
    )
    if validation.returncode != 0:
        if previous is None:
            snippet.unlink(missing_ok=True)
        else:
            atomic_write(snippet, previous, 0o644)
        raise ManagedAppError((validation.stderr or validation.stdout).strip() or "Caddy validation failed")
    run(["systemctl", "reload", "caddy"], timeout=30)


def delete_ufw_rule(arguments: list[str]) -> None:
    while run(["ufw", "--force", "delete", *arguments], check=False, timeout=20).returncode == 0:
        pass


def apply_firewall(app: str, settings: dict[str, Any], enabled: bool = True) -> None:
    if not shutil.which("ufw"):
        return
    status = run(["ufw", "status"], check=False, timeout=20).stdout.lower()
    if "status: active" not in status:
        return
    port = str(APP_DEFINITIONS[app]["port"])
    private_rule = [
        "allow", "in", "on", "tater0", "from", WIREGUARD_NETWORK,
        "to", WIREGUARD_ADDRESS, "port", port, "proto", "tcp",
    ]
    deny_rule = ["deny", "in", "to", "any", "port", port, "proto", "tcp"]
    delete_ufw_rule(private_rule)
    delete_ufw_rule(deny_rule)
    if enabled:
        run(["ufw", *private_rule, "comment", f"{APP_DEFINITIONS[app]['name']} private WireGuard"])
        run(["ufw", *deny_rule, "comment", f"Block direct public {APP_DEFINITIONS[app]['name']}"])

    if app == "forgejo":
        ssh_port = str(APP_DEFINITIONS[app]["sshPort"])
        ssh_private = [
            "allow", "in", "on", "tater0", "from", WIREGUARD_NETWORK,
            "to", WIREGUARD_ADDRESS, "port", ssh_port, "proto", "tcp",
        ]
        ssh_public = ["allow", ssh_port + "/tcp"]
        ssh_deny = ["deny", "in", "to", "any", "port", ssh_port, "proto", "tcp"]
        for rule in (ssh_private, ssh_public, ssh_deny):
            delete_ufw_rule(rule)
        if enabled and settings.get("sshAccess") == "public":
            run(["ufw", *ssh_public, "comment", "Forgejo public SSH"])
        elif enabled:
            run(["ufw", *ssh_private, "comment", "Forgejo private SSH"])
            run(["ufw", *ssh_deny, "comment", "Block public Forgejo SSH"])


def wait_for_http(url: str, timeout: int = 180) -> None:
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=4) as response:
                if response.status < 500:
                    return
        except (OSError, urllib.error.URLError) as error:
            last_error = str(error)
        time.sleep(2)
    raise ManagedAppError(f"App did not become ready at {url}: {last_error}")


def post_install(app: str, request: dict[str, Any], settings: dict[str, Any]) -> None:
    definition = APP_DEFINITIONS[app]
    health_path = "/_matrix/client/versions" if app == "matrix" else "/"
    wait_for_http(f"http://127.0.0.1:{definition['port']}{health_path}")
    if app == "uptime-kuma":
        settings["setupComplete"] = uptime_has_admin(app_paths(app)[1])
    elif app == "forgejo" and not settings.get("hasAdmin"):
        password = require_password(request.get("adminPassword"))
        run(
            [
                "docker", "exec", "--user", "git", definition["container"],
                "forgejo", "admin", "user", "create",
                "--username", settings["adminUser"],
                "--password", password,
                "--email", settings["adminEmail"],
                "--admin", "--must-change-password=false",
            ],
            timeout=120,
        )
        settings["hasAdmin"] = True
    elif app == "matrix" and not settings.get("hasAdmin"):
        password = require_password(request.get("adminPassword"))
        run(
            [
                "docker", "exec", "-i", definition["container"],
                "register_new_matrix_user", "-u", settings["adminUser"], "-a",
                "-c", "/data/homeserver.yaml", "http://localhost:8008",
            ],
            input_text=f"{password}\n{password}\n",
            timeout=120,
        )
        settings["hasAdmin"] = True


def compose(app: str, compose_path: Path, *arguments: str) -> None:
    run([*compose_prefix(), "-p", f"tater-{app}", "-f", str(compose_path), *arguments])


def enable_app_service(app: str, compose_path: Path) -> None:
    prefix = compose_prefix()
    executable = shutil.which(prefix[0])
    if not executable:
        raise ManagedAppError("Docker Compose executable is unavailable")
    command = " ".join([executable, *prefix[1:], "-p", f"tater-{app}", "-f", str(compose_path)])
    atomic_write(
        Path(f"/etc/systemd/system/tater-tunnel-app-{app}.service"),
        f"[Unit]\nDescription=Tater managed {APP_DEFINITIONS[app]['name']}\n"
        "Requires=docker.service tater-tunnel-vps.service tater-tunnel-container-guard.service\n"
        "After=docker.service tater-tunnel-vps.service tater-tunnel-container-guard.service\n"
        "PartOf=docker.service tater-tunnel-vps.service\n\n[Service]\nType=oneshot\n"
        f"ExecStart={command} up -d --remove-orphans\nExecStop={command} stop\n"
        "RemainAfterExit=yes\nTimeoutStartSec=300\n\n[Install]\n"
        "WantedBy=multi-user.target docker.service tater-tunnel-vps.service\n",
        0o644,
    )
    run(["systemctl", "daemon-reload"], timeout=30)
    run(["systemctl", "enable", "--now", f"tater-tunnel-app-{app}"], timeout=300)


def configure(app: str, settings_file: Path) -> None:
    ensure_root()
    ensure_docker()
    request = read_json(settings_file)
    if not request:
        raise ManagedAppError("Managed app settings are missing")
    config_dir, state_dir, saved_path, compose_path = app_paths(app)
    config_dir.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(config_dir, 0o700)
    os.chmod(state_dir, 0o700)
    existing = read_json(saved_path)
    compose_config, saved = BUILDERS[app](request, existing, config_dir, state_dir)
    saved["enabled"] = True
    atomic_write(compose_path, json.dumps(compose_config, indent=2) + "\n")
    # Preserve generated database credentials even when startup needs a retry.
    atomic_write(saved_path, json.dumps(saved, indent=2) + "\n")
    compose(app, compose_path, "pull")
    compose(app, compose_path, "up", "-d", "--remove-orphans")
    post_install(app, request, saved)
    atomic_write(saved_path, json.dumps(saved, indent=2) + "\n")
    apply_firewall(app, saved)
    apply_caddy(app, saved)
    enable_app_service(app, compose_path)
    print(f"{APP_DEFINITIONS[app]['name']} is installed and running.")


def action(app: str, requested_action: str) -> None:
    ensure_root()
    _config_dir, _state_dir, saved_path, compose_path = app_paths(app)
    settings = read_json(saved_path)
    if not settings or not compose_path.exists():
        raise ManagedAppError(f"{APP_DEFINITIONS[app]['name']} is not installed")
    if requested_action == "start":
        enable_app_service(app, compose_path)
        compose(app, compose_path, "up", "-d")
        apply_firewall(app, settings)
        apply_caddy(app, settings)
    elif requested_action == "restart":
        compose(app, compose_path, "restart")
    elif requested_action == "disable":
        run(["systemctl", "disable", "--now", f"tater-tunnel-app-{app}"], check=False, timeout=120)
        compose(app, compose_path, "stop")
        apply_caddy(app, settings, enabled=False)
        apply_firewall(app, settings, enabled=False)
    else:
        raise ManagedAppError("Service action is not allowed")
    if requested_action in {"start", "disable"}:
        settings["enabled"] = requested_action == "start"
        atomic_write(saved_path, json.dumps(settings, indent=2) + "\n")
    print(f"{APP_DEFINITIONS[app]['name']} action complete: {requested_action}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("configure", "action"))
    parser.add_argument("--app", required=True, choices=tuple(APP_DEFINITIONS))
    parser.add_argument("--settings-file", type=Path)
    parser.add_argument("--action", choices=("start", "restart", "disable"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        app = normalize_app(args.app)
        if args.command == "configure":
            if not args.settings_file:
                raise ManagedAppError("--settings-file is required")
            configure(app, args.settings_file)
        else:
            if not args.action:
                raise ManagedAppError("--action is required")
            action(app, args.action)
    except ManagedAppError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
