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


def load_config(force_reload: bool = False) -> dict[str, str]:
    """Load and cache config from defaults.conf."""
    global _config_cache
    if _config_cache is not None and not force_reload:
        return _config_cache

    config: dict[str, str] = {}
    config_path = _get_config_path()

    if config_path.is_file():
        lines = config_path.read_text().splitlines()
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if not line or line.startswith("#"):
                i += 1
                continue
            match = _KV_PATTERN.match(line)
            if match:
                key = match.group(1)
                raw = match.group(2).strip()
                # Handle multiline quoted values (opening quote without closing on same line)
                if raw and raw[0] in ('"', "'"):
                    quote_char = raw[0]
                    if len(raw) < 2 or raw[-1] != quote_char:
                        # Multiline: collect until closing quote
                        parts = [raw[1:]]
                        i += 1
                        while i < len(lines):
                            part = lines[i]
                            if part.rstrip().endswith(quote_char):
                                parts.append(part.rstrip()[:-1])
                                break
                            parts.append(part)
                            i += 1
                        config[key] = "\n".join(parts)
                    else:
                        config[key] = raw[1:-1]
                else:
                    config[key] = raw
            i += 1

    _config_cache = config
    return config


def get(key: str, default: str = "") -> str:
    """Get a single config value."""
    return load_config().get(key, default)
