from __future__ import annotations

import base64
import json
import os
import subprocess
import tempfile
import unittest
from http import HTTPStatus
from pathlib import Path
from unittest.mock import patch

from tater_tunnel.config_store import ConfigStore
from tater_tunnel.home_agent import AgentError, HomeAgentService
from tater_tunnel.vps_agent import VpsAgentService, VpsConfigStore
from tater_tunnel.wireguard import KeyPair
from tater_tunnel.wireguard_runtime import (
    WIREGUARD_MTU,
    CommandRunner,
    WireGuardSystemRuntime,
    render_home_agent_config,
)


PRIVATE_KEY = base64.b64encode(b"k" * 32).decode("ascii")
HOME_PUBLIC_KEY = base64.b64encode(b"h" * 32).decode("ascii")
VPS_PUBLIC_KEY = base64.b64encode(b"v" * 32).decode("ascii")


class RecordingRunner:
    def __init__(self):
        self.calls: list[tuple[list[str], str | None]] = []

    def which(self, command: str) -> str | None:
        return f"/usr/bin/{command}" if command in {"wg", "ip"} else None

    def system(self) -> str:
        return "Linux"

    def run(
        self,
        command: list[str],
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self.calls.append((command, input_text))
        return subprocess.CompletedProcess(command, 0, "", "")


class WireGuardRuntimeTests(unittest.TestCase):
    @patch("tater_tunnel.wireguard_runtime.subprocess.run")
    def test_system_commands_return_a_bounded_timeout(self, run):
        run.side_effect = subprocess.TimeoutExpired(["wg", "show"], 2)

        completed = CommandRunner().run(["wg", "show"])

        self.assertEqual(completed.returncode, 124)
        self.assertIn("timed out", completed.stderr)

    def test_health_survives_a_live_diagnostics_timeout(self):
        class KeyProvider:
            def generate_keypair(self):
                return KeyPair(PRIVATE_KEY, HOME_PUBLIC_KEY, "test")

        class VpsClient:
            def claim(self, base_url, payload):
                return {
                    "vpsWireGuard": {
                        "publicKey": VPS_PUBLIC_KEY,
                        "address": "10.88.0.1/24",
                        "network": "10.88.0.0/24",
                        "homeAllowedIp": "10.88.0.2/32",
                        "listenPort": 51888,
                    },
                    "management": {
                        "url": "http://10.88.0.1:4174",
                        "token": "management-secret",
                    },
                }

            def health(self, base_url, token):
                return {"status": "ok", "claimed": True, "peerCount": 0}

            def wireguard(self, base_url, token):
                raise AgentError(HTTPStatus.BAD_GATEWAY, "VPS diagnostics timed out")

            def add_peer(self, base_url, payload, token):
                return {"status": "ok"}

        class HomeRuntime:
            backend = "test"

            def apply(self, state, endpoint):
                return {"backend": self.backend, "lastAction": "applied"}

            def reset(self):
                return {"backend": self.backend, "lastAction": "reset"}

        class AccessManager:
            def sync(self, routes):
                return {"listeners": [], "errors": {}}

        with tempfile.TemporaryDirectory() as directory:
            service = HomeAgentService(
                ConfigStore(Path(directory) / "home.json"),
                key_provider=KeyProvider(),
                vps_client=VpsClient(),
                wireguard_runtime=HomeRuntime(),
                access_manager=AccessManager(),
            )
            service.pair_vps(
                {"vpsAddress": "tunnel.example.com", "pairingCode": "RIGHT-CODE"}
            )
            enrollment = service.add_device(
                {"person": "Tater Person", "name": "Phone", "type": "Phone"}
            )["enrollment"]

            state = service.check_health()["state"]

        self.assertEqual(state["vpsAgent"]["health"]["status"], "ok")
        self.assertIn("timed out", state["vpsAgent"]["diagnosticsWarning"])
        self.assertIn(f"MTU = {WIREGUARD_MTU}", enrollment["wireguardConfig"])

    def test_home_agent_config_uses_safe_tunnel_mtu(self):
        config = render_home_agent_config(
            {
                "homeAgent": {"wireguard": {"privateKey": PRIVATE_KEY}},
                "vpsAgent": {
                    "wireguard": {
                        "publicKey": VPS_PUBLIC_KEY,
                        "homeAllowedIp": "10.88.0.2/32",
                        "network": "10.88.0.0/24",
                    }
                },
            },
            "tunnel.example.com:51888",
        )

        self.assertIn(f"MTU = {WIREGUARD_MTU}", config)

    def test_vps_peer_mutation_response_stays_below_tunnel_mtu(self):
        class KeyProvider:
            def generate_keypair(self):
                return KeyPair(PRIVATE_KEY, VPS_PUBLIC_KEY, "test")

        class Runtime:
            backend = "test"

            def apply(self, state):
                return {"backend": self.backend, "lastAction": "applied"}

        with tempfile.TemporaryDirectory() as directory:
            service = VpsAgentService(
                VpsConfigStore(Path(directory) / "vps.json", "RIGHT-CODE"),
                key_provider=KeyProvider(),
                wireguard_runtime=Runtime(),
            )
            service.claim(
                {
                    "pairingCode": "RIGHT-CODE",
                    "homeAgent": {"transport": "wireguard", "publicKey": HOME_PUBLIC_KEY},
                },
                "203.0.113.10",
            )
            response = service.add_peer(
                {
                    "id": "phone",
                    "name": "Phone",
                    "publicKey": base64.b64encode(b"d" * 32).decode("ascii"),
                    "allowedIp": "10.88.0.10/32",
                }
            )

        self.assertEqual(
            response,
            {"status": "ok", "peer": {"id": "phone", "allowedIp": "10.88.0.10/32"}},
        )
        self.assertLess(len(json.dumps(response)), WIREGUARD_MTU)

    def test_bootstrap_keeps_its_managed_source_updateable(self):
        root = Path(__file__).parents[1]
        setup = (root / "scripts" / "tater-vps-setup.sh").read_text(encoding="utf-8")

        self.assertIn("status --porcelain --untracked-files=all", setup)
        self.assertIn("Existing modified source preserved", setup)
        self.assertTrue(os.access(root / "scripts" / "audit-vps-security.sh", os.X_OK))

    def test_optional_service_access_boundaries(self):
        root = Path(__file__).parents[1]
        setup = (root / "scripts" / "tater-vps-setup.sh").read_text(encoding="utf-8")
        audit = (root / "scripts" / "audit-vps-security.sh").read_text(
            encoding="utf-8"
        )
        sftpgo = (root / "scripts" / "install-sftpgo.sh").read_text(encoding="utf-8")
        znc = (root / "scripts" / "install-znc.sh").read_text(encoding="utf-8")

        self.assertNotIn("--open-sftp-firewall", setup + sftpgo)
        self.assertNotIn("--open-firewall", setup + znc)
        self.assertNotIn("ZNC DNS-only hostname", setup)
        self.assertNotIn("SFTP DNS-only hostname", setup)
        self.assertIn("allow in on tater0 from 10.88.0.0/24", znc)
        self.assertIn("deny in to any port", znc)
        self.assertIn("--public-sftp", setup + sftpgo)
        self.assertIn("--sftp-access", setup + sftpgo)
        self.assertIn("--ftp-access", setup + sftpgo)
        self.assertIn("--webdav-access", setup + sftpgo)
        self.assertIn("--webdav-domain", setup + sftpgo)
        self.assertIn("Create or update the WebDAV DNS record with a Cloudflare API token", setup)
        self.assertIn('--record "$sftpgo_webdav_domain"', setup)
        self.assertIn('cloudflare_args+=(--record "$sftpgo_webdav_domain")', setup)
        self.assertIn("--passwordbox", setup)
        self.assertIn("show_cloudflare_progress", setup)
        self.assertIn('export CLOUDFLARE_API_TOKEN="$token"', setup)
        self.assertNotIn(
            'show_progress_handoff "Cloudflare DNS progress will appear below."',
            setup,
        )
        self.assertIn("--checklist", setup)
        self.assertIn('selected="${selected//\\\"/}"', setup)
        self.assertIn('selected="${selected//$\'\\n\'/ }"', setup)
        self.assertIn('confirm "Enable SFTP on 2022/tcp" no', setup)
        self.assertIn('if [ "$sftpgo_sftp_access" != "disabled" ]', setup)
        self.assertIn('if [ "$sftpgo_webdav_access" != "disabled" ]', setup)
        self.assertIn("Allow SFTP from the public internet", setup)
        self.assertIn("Make WebDAV available externally with automatic HTTPS", setup)
        self.assertIn('configure_tcp_access "$SFTP_ACCESS"', sftpgo)
        self.assertIn('configure_tcp_access "$FTP_ACCESS"', sftpgo)
        self.assertIn('configure_tcp_access "$WEBDAV_ACCESS"', sftpgo)
        self.assertIn("SFTPGO_FTPD__PASSIVE_PORT_RANGE__START", sftpgo)
        self.assertIn("SFTPGO_FTPD__DISABLE_ACTIVE_MODE=true", sftpgo)
        self.assertIn("SFTPGO_WEBDAVD__BINDINGS__0__PORT", sftpgo)
        self.assertIn("SFTPGO_WEBDAVD__BINDINGS__0__PROXY_ALLOWED", sftpgo)
        self.assertIn("verify_requested_listeners", sftpgo)
        self.assertIn("wait_for_tcp_listener", sftpgo)
        self.assertIn("verify_webdav_https", sftpgo)
        self.assertIn('"https://$WEBDAV_DOMAIN/"', sftpgo)
        self.assertIn("verify_sftpgo_selection_applied", setup)
        self.assertIn("managed_sftpgo_webdav_domain", setup)
        self.assertIn('read -r -a selected_items <<< "$selected"', setup)
        self.assertIn('dialog_message "SFTPGo ready"', setup)
        self.assertIn("sftpgo-webdav.caddy", setup + sftpgo)
        self.assertIn("reverse_proxy 127.0.0.1:$WEBDAV_PORT", sftpgo)
        self.assertIn("header_up Host {host}", sftpgo)
        self.assertNotIn('sftpgo_webdav_access="public"', setup)
        self.assertIn("Block public SFTPGo", sftpgo)
        self.assertIn("SFTPGO_HTTPD__BINDINGS__0__ADDRESS=0.0.0.0", sftpgo)
        self.assertIn('configure_tcp_access private "$WEB_PORT" WebAdmin', sftpgo)
        self.assertIn('"Block public SFTPGo $label"', sftpgo)
        self.assertIn('WEB_LISTEN_PORT="6698"', znc)
        self.assertIn("ZNC WebAdmin private WireGuard", znc)
        self.assertIn("Block public ZNC WebAdmin", znc)
        self.assertIn("migrate_installed_znc_webadmin", setup)
        self.assertIn("/etc/caddy/tater-sites/znc-web.caddy", setup)
        self.assertIn("has_tcp_deny_rule", audit)
        self.assertIn('^ufw deny( in)? (${port}|${port}/tcp)', audit)
        self.assertIn("has_broad_tcp_allow_rule", audit)

    def test_vps_setup_uses_focused_terminal_completion(self):
        setup = (
            Path(__file__).parents[1] / "scripts" / "tater-vps-setup.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("TATER TUNNEL // VPS SETUP CONSOLE", setup)
        self.assertIn('apt-get install -y ca-certificates dialog git', setup)
        self.assertIn("--item-help", setup)
        self.assertIn("--programbox", setup)
        self.assertIn('tail --pid="$command_pid"', setup)
        self.assertIn('wait "$command_pid"', setup)
        self.assertNotIn('"$@" 2>&1 | dialog --clear', setup)
        self.assertIn("run_menu_action run_sftpgo_install", setup)
        self.assertIn("run_menu_action run_full_install", setup)
        self.assertIn(
            'confirm "Repair Tater-managed security rules before auditing"',
            setup,
        )
        self.assertIn(
            'apply_update_hardening "$listen_port" "$wg_management_access"',
            setup,
        )
        self.assertIn("Setup console closed.", setup)
        self.assertNotIn("No changes made.", setup)
        self.assertIn('export DIALOGRC="$DIALOG_THEME_FILE"', setup)
        self.assertIn("screen_color = (WHITE,BLACK,OFF)", setup)
        self.assertIn("title_color = (YELLOW,BLACK,ON)", setup)
        self.assertNotIn("title_color = (RED,BLACK,ON)", setup)
        self.assertIn("--checklist", setup)
        self.assertIn("ONE-TIME PAIRING CODE", setup)
        self.assertIn('show_pairing_completion "$domain" "$final_pairing_code"', setup)
        self.assertNotIn("VPS Agent service:", setup)
        self.assertNotIn("WireGuard port:", setup)
        self.assertNotIn("authorized_keys", setup)
        self.assertNotIn("ssh-copy-id", setup)

        readme = (Path(__file__).parents[1] / "README.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("ssh-copy-id YOUR_USER@YOUR_VPS", readme)
        self.assertIn("PasswordAuthentication no", readme)
        self.assertIn("KbdInteractiveAuthentication no", readme)
        self.assertIn("PermitRootLogin no", readme)

    def test_sftpgo_menu_passes_selected_webdav_mode_to_installer(self):
        setup = Path(__file__).parents[1] / "scripts" / "tater-vps-setup.sh"

        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "args.txt"
            harness = f'''
set -Eeuo pipefail
source "{setup}"
DIALOG_ENABLED=0
CAPTURE="{capture}"
require_root_for_install() {{ :; }}
clear_screen() {{ :; }}
print_logo() {{ :; }}
select_sftpgo_protocols() {{
  sftpgo_sftp_access="private"
  sftpgo_ftp_access="disabled"
  sftpgo_webdav_access="private"
}}
installed_tater_domain() {{ printf '%s' 'tunnel.example.com'; }}
choose_sftpgo_access() {{
  sftpgo_webdav_access="https"
  sftpgo_webdav_domain="files.example.com"
  sftpgo_insecure_public="0"
}}
confirm() {{
  case "$1" in
    "Install or update SFTPGo now") return 0 ;;
    *) return 1 ;;
  esac
}}
show_progress_handoff() {{
  shift
  printf '%s\n' "$@" > "$CAPTURE"
}}
verify_sftpgo_selection_applied() {{
  printf 'verified:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >> "$CAPTURE"
}}
run_sftpgo_install >/dev/null
'''
            completed = subprocess.run(
                ["bash", "-c", harness],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                capture.read_text(encoding="utf-8").splitlines(),
                [
                    str(setup.parent / "install-sftpgo.sh"),
                    "--sftp-access",
                    "private",
                    "--ftp-access",
                    "disabled",
                    "--webdav-access",
                    "https",
                    "--webdav-domain",
                    "files.example.com",
                    "verified:private:disabled:https:files.example.com",
                ],
            )
    def test_vps_service_allows_only_agent_tcp_and_wireguard_udp(self):
        installer = (
            Path(__file__).parents[1] / "scripts" / "install-vps-agent.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("SocketBindDeny=any", installer)
        self.assertIn("SocketBindAllow=tcp:$LISTEN_PORT", installer)
        self.assertIn("SocketBindAllow=udp:51888", installer)

    def test_system_runtime_passes_syncconf_over_stdin(self):
        state = {
            "claimed": True,
            "wireguardPort": 51888,
            "interface": {
                "address": "10.88.0.1/24",
                "network": "10.88.0.0/24",
                "wireguard": {
                    "privateKey": PRIVATE_KEY,
                    "publicKey": VPS_PUBLIC_KEY,
                },
            },
            "homeAgent": {
                "id": "home-agent",
                "publicKey": HOME_PUBLIC_KEY,
                "allowedIp": "10.88.0.2/32",
            },
            "peers": [],
        }

        with tempfile.TemporaryDirectory() as directory:
            runner = RecordingRunner()
            config_path = Path(directory) / "tater0.conf"
            runtime = WireGuardSystemRuntime(config_path, runner=runner)
            runtime.apply(state)

            syncconf_calls = [
                call for call in runner.calls if call[0][:2] == ["wg", "syncconf"]
            ]
            self.assertEqual(len(syncconf_calls), 1)
            command, input_text = syncconf_calls[0]
            self.assertEqual(command, ["wg", "syncconf", "tater0", "/dev/stdin"])
            self.assertIn(f"PrivateKey = {PRIVATE_KEY}", input_text or "")
            self.assertNotIn("Address =", input_text or "")
            self.assertNotIn("MTU =", input_text or "")
            self.assertIn(f"MTU = {WIREGUARD_MTU}", config_path.read_text(encoding="utf-8"))
            self.assertIn(
                (["ip", "link", "set", "mtu", str(WIREGUARD_MTU), "dev", "tater0"], None),
                runner.calls,
            )
            self.assertEqual(list(config_path.parent.glob("*.setconf.*")), [])


if __name__ == "__main__":
    unittest.main()
