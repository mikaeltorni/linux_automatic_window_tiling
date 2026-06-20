"""Tests for gsettings string-array helpers used by install.sh."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "lib" / "gsettings_strv.py"


def load_module():
    spec = importlib.util.spec_from_file_location("tiling_gsettings_strv", MODULE_PATH)
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


def test_installer_uses_extracted_parser():
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")

    assert "lib/gsettings_strv.py" in installer
    assert "python3 - <<'PY'" not in installer
