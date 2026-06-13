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
        "schemaVersion": 1,
        "paired": False,
        "vps": "",
        "mode": "safe",
        "wireguardPort": 51888,
        "lastCheck": "",
        "routes": {
            "taterServices": True,
            "localNetwork": False,
        },
        "homeAgent": {
            "relay": None,
            "wireguard": None,
            "runtime": None,
        },
        "vpsAgent": None,
        "devices": [],
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
                os.replace(temp_name, self.path)
            finally:
                if os.path.exists(temp_name):
                    os.unlink(temp_name)

            return deepcopy(merged)

    def reset(self) -> dict[str, Any]:
        return self.save(default_state())

    def _merge_defaults(self, state: dict[str, Any]) -> dict[str, Any]:
        merged = default_state()
        merged.update({key: value for key, value in state.items() if key not in {"routes", "homeAgent"}})
        merged["routes"].update(state.get("routes", {}))
        merged["homeAgent"].update(state.get("homeAgent", {}))
        return merged
