from __future__ import annotations

import json
import os
import tempfile
import threading
from copy import deepcopy
from pathlib import Path
from typing import Any


def default_state() -> dict[str, Any]:
    return {
        "schemaVersion": 2,
        "paired": False,
        "migrationRequired": False,
        "vps": "",
        "wireguardPort": 51888,
        "lastCheck": "",
        "homeAgent": {
            "wireguard": None,
            "runtime": None,
        },
        "management": None,
        "vpsAgent": None,
        "devices": [],
        "accessRoutes": {},
    }


class ConfigStore:
    def __init__(self, path: Path | str):
        self.path = Path(path)
        self._lock = threading.RLock()

    def load(self) -> dict[str, Any]:
        with self._lock:
            if not self.path.exists():
                return default_state()

            with self.path.open("r", encoding="utf-8") as handle:
                loaded = json.load(handle)

            return self._merge_defaults(loaded)

    def save(self, state: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            merged = self._merge_defaults(state)
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
                os.chmod(temp_name, 0o600)
                os.replace(temp_name, self.path)
            finally:
                if os.path.exists(temp_name):
                    os.unlink(temp_name)

            return deepcopy(merged)

    def reset(self) -> dict[str, Any]:
        return self.save(default_state())

    def _merge_defaults(self, state: dict[str, Any]) -> dict[str, Any]:
        old_home_agent = state.get("homeAgent") or {}
        retired_state = (
            int(state.get("schemaVersion") or 0) != 2
            or "relay" in old_home_agent
            or state.get("mode") is not None
            or state.get("routes") is not None
        )
        incomplete_claim = bool(state.get("paired")) and not (
            old_home_agent.get("wireguard")
            and (state.get("management") or {}).get("token")
            and (state.get("management") or {}).get("url")
        )
        if retired_state or incomplete_claim:
            clean = default_state()
            clean["migrationRequired"] = True
            return clean

        merged = default_state()
        merged.update({key: value for key, value in state.items() if key != "homeAgent"})
        merged["schemaVersion"] = 2
        merged["homeAgent"].update(state.get("homeAgent", {}))

        for device in merged.get("devices", []):
            if isinstance(device, dict):
                device.pop("token", None)
        return merged
