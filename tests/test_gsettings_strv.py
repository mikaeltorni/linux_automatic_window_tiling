"""Installer contract: gsettings updates go through the Rust helper."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_installer_uses_rust_helper():
    setup = (ROOT / "lib" / "tiling_setup.sh").read_text(encoding="utf-8")
    assert "awt_bin" in setup
    assert "gsettings_strv.py" not in setup
    assert "python3" not in setup
    assert (ROOT / "src" / "gsettings_strv.rs").is_file()
    assert (ROOT / "scripts" / "build_awt_tools.sh").is_file()
