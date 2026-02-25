"""Tests for lib/config.py — config loader for defaults.conf."""

import os
from pathlib import Path
from unittest.mock import patch

import pytest

import lib.config as config_mod
from lib.config import load_config, get, _get_config_path, _KV_PATTERN


@pytest.fixture(autouse=True)
def _reset_cache():
    """Reset config cache before and after each test."""
    config_mod._config_cache = None
    yield
    config_mod._config_cache = None


class TestKVPattern:
    """Tests for the _KV_PATTERN regex."""

    def test_simple_key_value(self):
        m = _KV_PATTERN.match("FOO=bar")
        assert m
        assert m.group(1) == "FOO"
        assert m.group(2) == "bar"

    def test_quoted_value(self):
        m = _KV_PATTERN.match('FOO="bar baz"')
        assert m
        assert m.group(1) == "FOO"
        assert m.group(2) == '"bar baz"'

    def test_single_quoted(self):
        m = _KV_PATTERN.match("FOO='bar baz'")
        assert m
        assert m.group(2) == "'bar baz'"

    def test_underscore_key(self):
        m = _KV_PATTERN.match("MY_VAR_2=value")
        assert m
        assert m.group(1) == "MY_VAR_2"

    def test_lowercase_key_no_match(self):
        m = _KV_PATTERN.match("lowercase=value")
        assert m is None

    def test_empty_value(self):
        m = _KV_PATTERN.match("FOO=")
        assert m
        assert m.group(2) == ""

    def test_comment_no_match(self):
        m = _KV_PATTERN.match("# this is a comment")
        assert m is None

    def test_empty_line_no_match(self):
        m = _KV_PATTERN.match("")
        assert m is None

    def test_starts_with_number_no_match(self):
        m = _KV_PATTERN.match("1BAD=value")
        assert m is None


class TestGetConfigPath:
    """Tests for _get_config_path()."""

    def test_uses_yato_path_env(self, monkeypatch, tmp_path):
        monkeypatch.setenv("YATO_PATH", str(tmp_path))
        result = _get_config_path()
        assert result == tmp_path / "config" / "defaults.conf"

    def test_fallback_to_file_location(self, monkeypatch):
        monkeypatch.delenv("YATO_PATH", raising=False)
        result = _get_config_path()
        expected = Path(config_mod.__file__).parent.parent / "config" / "defaults.conf"
        assert result == expected


class TestLoadConfig:
    """Tests for load_config()."""

    def test_simple_key_value(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text('FOO="bar"\nBAZ=qux\n')
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result = load_config()
        assert result["FOO"] == "bar"
        assert result["BAZ"] == "qux"

    def test_comments_and_blanks_skipped(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("# comment\n\nFOO=val\n")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result = load_config()
        assert result == {"FOO": "val"}

    def test_multiline_quoted_value(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        content = 'MULTI="line1\nline2\nline3"\nOTHER=x\n'
        (config_dir / "defaults.conf").write_text(content)
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result = load_config()
        assert "line1" in result["MULTI"]
        assert "line2" in result["MULTI"]
        assert "line3" in result["MULTI"]
        assert result["OTHER"] == "x"

    def test_single_quote_multiline(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        content = "MULTI='line1\nline2\nline3'\nOTHER=x\n"
        (config_dir / "defaults.conf").write_text(content)
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result = load_config()
        assert "line1" in result["MULTI"]
        assert result["OTHER"] == "x"

    def test_caching(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("FOO=1\n")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result1 = load_config()
        # Modify file — should still return cached
        (config_dir / "defaults.conf").write_text("FOO=2\n")
        result2 = load_config()
        assert result1 is result2
        assert result2["FOO"] == "1"

    def test_force_reload(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("FOO=1\n")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        load_config()
        (config_dir / "defaults.conf").write_text("FOO=2\n")
        result = load_config(force_reload=True)
        assert result["FOO"] == "2"

    def test_missing_config_file(self, tmp_path, monkeypatch):
        monkeypatch.setenv("YATO_PATH", str(tmp_path))
        result = load_config(force_reload=True)
        assert result == {}

    def test_empty_config_file(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result = load_config(force_reload=True)
        assert result == {}

    def test_unquoted_value(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("FOO=raw_value\n")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result = load_config(force_reload=True)
        assert result["FOO"] == "raw_value"

    def test_value_with_equals(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text('URL="host=localhost port=5432"\n')
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result = load_config(force_reload=True)
        assert result["URL"] == "host=localhost port=5432"

    def test_malformed_line_ignored(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("not a valid line\nFOO=ok\n")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        result = load_config(force_reload=True)
        assert result == {"FOO": "ok"}


class TestGet:
    """Tests for get()."""

    def test_existing_key(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("MY_KEY=hello\n")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        assert get("MY_KEY") == "hello"

    def test_missing_key_returns_default(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("FOO=bar\n")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        assert get("MISSING") == ""
        assert get("MISSING", "fallback") == "fallback"

    def test_empty_default(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text("")
        monkeypatch.setenv("YATO_PATH", str(tmp_path))

        assert get("NOPE") == ""
