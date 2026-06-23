"""Tests for gsettings string-array helpers used by install.sh."""

from __future__ import annotations

import importlib.util
import logging
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "lib" / "gsettings_strv.py"
LOGGING_MODULE_PATH = ROOT / "lib" / "logging_utils.py"


def load_module():
    if str(MODULE_PATH.parent) not in sys.path:
        sys.path.insert(0, str(MODULE_PATH.parent))
    spec = importlib.util.spec_from_file_location("tiling_gsettings_strv", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def load_logging_module():
    spec = importlib.util.spec_from_file_location(
        "tiling_logging_utils", LOGGING_MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_append_strv_handles_gsettings_prefix_and_deduplicates():
    mod = load_module()

    assert mod.append_strv("@as ['automatic-window-tiling@local']", "automatic-window-tiling@local") == [
        "automatic-window-tiling@local"
    ]
    assert mod.append_strv("@as ['one']", "two") == ["one", "two"]


def test_append_strv_handles_invalid_existing_values():
    mod = load_module()

    assert mod.append_strv("not an array", "automatic-window-tiling@local") == [
        "automatic-window-tiling@local"
    ]


def test_cli_formats_updated_array_from_current_environment(monkeypatch):
    monkeypatch.setenv("CURRENT", "@as ['one']")

    completed = subprocess.run(
        [sys.executable, str(MODULE_PATH), "two"],
        check=True,
        text=True,
        capture_output=True,
    )

    assert completed.stdout.strip() == "['one', 'two']"
    assert completed.stderr.strip() == ""


def test_logging_utils_is_idempotent_and_traces_calls(tmp_path):
    mod = load_logging_module()
    logger_name = "test_gsettings_logging"

    logger = logging.getLogger(logger_name)
    logger.handlers.clear()
    first = mod.get_logger(logger_name, "test_gsettings_logging.log")
    second = mod.get_logger(logger_name, "test_gsettings_logging.log")

    assert first is second
    assert len(first.handlers) == 1

    @mod.log_call(first)
    def sample(value, suffix="x"):
        return f"{value}-{suffix}"

    assert sample("a", suffix="b") == "a-b"
    for handler in first.handlers:
        handler.flush()

    log_text = (ROOT / ".log" / "test_gsettings_logging.log").read_text(
        encoding="utf-8"
    )
    assert "ENTER test_gsettings_strv.py" in log_text
    assert "value='a', suffix='b'" in log_text
    assert "EXIT test_gsettings_strv.py" in log_text
    assert "-> 'a-b'" in log_text


def test_installer_uses_extracted_parser():
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")

    assert "lib/gsettings_strv.py" in installer
    assert "python3 - <<'PY'" not in installer


def test_python_logging_is_centralized():
    helper = MODULE_PATH.read_text(encoding="utf-8")

    assert "from logging_utils import get_logger, log_call" in helper
    assert "LOGGER = get_logger(" in helper
    assert "@log_call(LOGGER)" in helper
    assert "def configure_logging" not in helper
    assert "StreamHandler" not in helper
