"""
Config loader for Yato defaults.conf.

Parses shell-style KEY=VALUE (or KEY="VALUE") configuration from config/defaults.conf.
Locates the config file relative to YATO_PATH env var, or falls back to the project root
(determined from this file's location).
"""

import os
import re
from pathlib import Path
from typing import Optional

_config_cache: Optional[dict[str, str]] = None

# Pattern matches: KEY=VALUE or KEY="VALUE" or KEY='VALUE'
_KV_PATTERN = re.compile(r'^([A-Z_][A-Z0-9_]*)=(.*)$')


def _get_config_path() -> Path:
    """Resolve the path to config/defaults.conf."""
    yato_path = os.environ.get("YATO_PATH")
    if yato_path:
        return Path(yato_path) / "config" / "defaults.conf"
    # Fall back to project root (lib/ is one level below root)
    return Path(__file__).parent.parent / "config" / "defaults.conf"


def _parse_value(raw: str) -> str:
    """Strip surrounding quotes from a value."""
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ('"', "'"):
        return raw[1:-1]
    return raw


def load_config(force_reload: bool = False) -> dict[str, str]:
    """Load and cache config from defaults.conf."""
    global _config_cache
    if _config_cache is not None and not force_reload:
        return _config_cache

    config: dict[str, str] = {}
    config_path = _get_config_path()

    if config_path.is_file():
        for line in config_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            match = _KV_PATTERN.match(line)
            if match:
                config[match.group(1)] = _parse_value(match.group(2))

    _config_cache = config
    return config


def get(key: str, default: str = "") -> str:
    """Get a single config value."""
    return load_config().get(key, default)
