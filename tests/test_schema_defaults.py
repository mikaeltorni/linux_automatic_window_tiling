"""Tests that the gschema defaults match the installer's documented defaults.

The extension core is always installed, but every *component* is optional. When
a component is deselected the installer never writes its gsettings key, so the
extension falls back to the gschema `<default>`. That default must therefore
reproduce the same behavior the installer would have written — otherwise
deselecting an "optional tuning knob" silently disables core functionality.

Components:
  - parse_schema_defaults(): reads the gschema XML into {key: default-literal}.
  - parse_script_defaults(): reads the `AWT_*` fallbacks from lib/tiling_setup.sh.
  - test_schema_defaults_match_script_defaults(): the two must agree for every
    key the installer manages.

Usage:
  python3 -m pytest tests/test_schema_defaults.py
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = (
    ROOT
    / "schemas"
    / "org.gnome.shell.extensions.automatic-window-tiling.gschema.xml"
)
SETUP_PATH = ROOT / "lib" / "tiling_setup.sh"

# gsettings key -> (shell variable holding the installer default, key type)
MANAGED_KEYS = {
    "tile-focused-application-windows": ("AWT_BINDING", "as"),
    "application-preferred-widths": ("AWT_APP_WIDTHS", "as"),
    "portrait-minimum-tile-height": ("AWT_PORTRAIT_MIN_HEIGHT", "i"),
}


def parse_schema_defaults() -> dict[str, str]:
    """Return {key-name: default literal} for every key in the gschema XML."""
    root = ET.parse(SCHEMA_PATH).getroot()
    defaults: dict[str, str] = {}
    for key in root.iter("key"):
        name = key.get("name")
        default = key.find("default")
        if name is not None and default is not None and default.text is not None:
            defaults[name] = default.text.strip()
    return defaults


def parse_script_defaults() -> dict[str, str]:
    """Return {AWT_* variable: fallback value} from lib/tiling_setup.sh."""
    text = SETUP_PATH.read_text(encoding="utf-8")
    found: dict[str, str] = {}
    for var, _type in MANAGED_KEYS.values():
        match = re.search(rf'^{var}="\$\{{{var}:-(.*)\}}"$', text, re.MULTILINE)
        assert match, f"no default assignment found for {var} in {SETUP_PATH}"
        found[var] = match.group(1)
    return found


def as_schema_literal(value: str, key_type: str) -> str:
    """Render an installer default the way the gschema `<default>` spells it."""
    if key_type == "as":
        # The installer takes a comma-separated list; the schema takes a GVariant
        # string array. An empty installer value means "no entries".
        items = [item for item in value.split(",") if item]
        return "[" + ", ".join(f"'{item}'" for item in items) + "]"
    return value


def test_schema_defaults_match_script_defaults() -> None:
    """A deselected component must leave the documented default in place."""
    schema_defaults = parse_schema_defaults()
    script_defaults = parse_script_defaults()

    mismatches = []
    for key, (var, key_type) in MANAGED_KEYS.items():
        assert key in schema_defaults, f"{key} missing from {SCHEMA_PATH}"
        expected = as_schema_literal(script_defaults[var], key_type)
        actual = schema_defaults[key]
        if actual != expected:
            mismatches.append(
                f"{key}: schema default {actual!r} != installer default "
                f"{expected!r} (from {var})"
            )

    assert not mismatches, (
        "gschema defaults drifted from the installer defaults, so deselecting "
        "the matching component changes behavior:\n  " + "\n  ".join(mismatches)
    )


def test_binding_default_is_a_real_accelerator() -> None:
    """The keybinding is the extension's only trigger; it must not default to []."""
    schema_defaults = parse_schema_defaults()
    binding = schema_defaults["tile-focused-application-windows"]
    assert binding not in ("[]", "@as []"), (
        "tile-focused-application-windows defaults to an empty accelerator, so "
        "an install that deselects the 'keybinding' component leaves the "
        "always-on extension core inert"
    )
