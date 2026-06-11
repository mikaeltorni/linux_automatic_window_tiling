import json
import shutil
import subprocess

import pytest

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def _extract_choose_grid(source):
    """Slice the chooseGrid function body out of extension.js by brace matching.

    extension.js imports gi:// modules at the top, so it cannot be imported by
    node directly; we evaluate just this pure function instead.
    """
    marker = "function chooseGrid("
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
            if depth == 0:
                return source[start : end + 1]
    raise AssertionError("could not locate end of chooseGrid")


def _choose_grid(window_count, width, height, max_width):
    """Run the extension's chooseGrid via node and return its result."""
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is required to evaluate chooseGrid")

    function_source = _extract_choose_grid(
        (ROOT / "extension.js").read_text(encoding="utf-8")
    )
    script = f"""
{function_source}
const result = chooseGrid(
    {window_count},
    {{ x: 0, y: 0, width: {width}, height: {height} }},
    {json.dumps(max_width)},
);
console.log(JSON.stringify(result));
"""
    completed = subprocess.run(
        [node, "-e", script],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout.strip())


def test_extension_filters_by_application_workspace_and_monitor():
    source = (ROOT / "extension.js").read_text(encoding="utf-8")

    assert "getWindowApplicationId" in source
    assert "global.workspace_manager.get_active_workspace()" in source
    assert "win.get_monitor() !== monitorIndex" in source
    assert "workspace.get_work_area_for_monitor(monitorIndex)" in source
    assert "win.move_resize_frame(true, cellX, cellY, cellWidth, cellHeight)" in source
    assert "getApplicationMaxDimensions" in source
    assert "maxWidth: 1300" in source
    assert "if (windowCount === 2)" in source
    assert "return { rows: 1, columns: 2 };" in source
    assert "workArea.width >= workArea.height" not in source


def test_schema_has_no_hard_coded_binding():
    schema = (
        ROOT
        / "schemas"
        / "org.gnome.shell.extensions.automatic-window-tiling.gschema.xml"
    ).read_text(encoding="utf-8")

    assert '<key name="tile-focused-application-windows"' in schema
    assert "<default>[]</default>" in schema
    assert "&lt;Super&gt;t" not in schema


def test_installer_requires_and_applies_binding_argument():
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")

    assert 'parse_binding "$@"' in installer
    assert '"--binding"' in installer
    assert "gsettings_array" in installer
    assert '"$SCHEMA_ID" "$BINDING_KEY"' in installer
    assert 'TARGET_USER="${SUDO_USER:-${TARGET_USER:-$USER}}"' in installer
    assert 'if [[ "$(id -u)" -eq "$TARGET_UID" ]]' in installer


def test_max_width_drives_three_columns_on_4k():
    # 4K width (3840px) with the 1300px cap must place three windows side by
    # side: ceil(3840 / 1300) == 3, each cell 1280px wide (under the cap).
    assert _choose_grid(3, 3840, 2160, 1300) == {"rows": 1, "columns": 3}


def test_max_width_wraps_extra_windows_to_new_rows():
    # A fourth window cannot fit a fourth column under the cap, so it stacks
    # onto a second row while the column count stays at three.
    assert _choose_grid(4, 3840, 2160, 1300) == {"rows": 2, "columns": 3}
    assert _choose_grid(7, 3840, 2160, 1300) == {"rows": 3, "columns": 3}


def test_max_width_never_exceeds_window_count():
    # Two windows under a wide cap use two columns, not three empty ones.
    assert _choose_grid(2, 3840, 2160, 1300) == {"rows": 1, "columns": 2}


def test_without_max_width_falls_back_to_aspect_grid():
    # No cap: two windows tile side by side via the aspect-ratio heuristic.
    assert _choose_grid(2, 3840, 2160, None) == {"rows": 1, "columns": 2}
