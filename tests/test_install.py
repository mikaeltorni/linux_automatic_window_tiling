import json
import shutil
import subprocess

import pytest

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def _extract_function(source, function_name):
    """Slice a named JavaScript function out of source by brace matching.

    Tests evaluate only the pure function body so they do not depend on Node's
    module handling matching the GNOME Shell runtime.
    """
    marker = f"function {function_name}("
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
    raise AssertionError(f"could not locate end of {function_name}")


def _choose_grid(window_count, width, height, preferred_width):
    """Run the extension's chooseGrid via node and return its result."""
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is required to evaluate chooseGrid")

    source = (ROOT / "layout.js").read_text(encoding="utf-8")
    function_source = _extract_function(source, "chooseGrid")
    script = f"""
{function_source}
const result = chooseGrid(
    {window_count},
    {{ x: 0, y: 0, width: {width}, height: {height} }},
    {json.dumps(preferred_width)},
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


def _calculate_tile_rect(index, rows, columns, width, height, x=0, y=0):
    """Run the extension's calculateTileRect via node and return its result."""
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is required to evaluate calculateTileRect")

    source = (ROOT / "layout.js").read_text(encoding="utf-8")
    function_source = _extract_function(source, "calculateTileRect")
    script = f"""
{function_source}
const result = calculateTileRect(
    {index},
    {rows},
    {columns},
    {{ x: {x}, y: {y}, width: {width}, height: {height} }},
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
    layout_source = (ROOT / "layout.js").read_text(encoding="utf-8")

    assert "getWindowApplicationId" in source
    assert "global.workspace_manager.get_active_workspace()" in source
    assert "win.get_monitor() !== monitorIndex" in source
    assert "workspace.get_work_area_for_monitor(monitorIndex)" in source
    assert "win.move_resize_frame(true, tile.x, tile.y, tile.width, tile.height)" in source
    assert "getApplicationPreferredWidth" in source
    assert "from './layout.js'" in source
    assert "preferredWidth: 1300" in source
    assert "if (windowCount === 2)" in layout_source
    assert "return { rows: 1, columns: 2 };" in layout_source
    assert "workArea.width >= workArea.height" not in layout_source


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
    assert '"$SCRIPT_DIR/layout.js"' in installer


def test_preferred_width_drives_three_columns_on_4k():
    # 4K width (3840px) with a 1300px preferred width places three windows
    # side by side: ceil(3840 / 1300) == 3.
    assert _choose_grid(3, 3840, 2160, 1300) == {"rows": 1, "columns": 3}


def test_preferred_width_wraps_extra_windows_to_new_rows():
    # A fourth window stacks onto a second row while the preferred column count
    # stays at three.
    assert _choose_grid(4, 3840, 2160, 1300) == {"rows": 2, "columns": 3}
    assert _choose_grid(7, 3840, 2160, 1300) == {"rows": 3, "columns": 3}


def test_preferred_width_never_exceeds_window_count():
    # Two windows use two columns, not three columns with an empty cell.
    assert _choose_grid(2, 3840, 2160, 1300) == {"rows": 1, "columns": 2}


def test_two_tiles_expand_to_fill_available_width():
    left = _calculate_tile_rect(0, 1, 2, 3840, 2160)
    right = _calculate_tile_rect(1, 1, 2, 3840, 2160)

    assert left == {"x": 0, "y": 0, "width": 1920, "height": 2160}
    assert right == {"x": 1920, "y": 0, "width": 1920, "height": 2160}
    assert left["width"] + right["width"] == 3840


def test_without_preferred_width_falls_back_to_aspect_grid():
    # No preferred width: two windows tile side by side.
    assert _choose_grid(2, 3840, 2160, None) == {"rows": 1, "columns": 2}


def test_non_positive_preferred_width_uses_balanced_grid():
    assert _choose_grid(4, 3840, 2160, 0) == {"rows": 2, "columns": 2}
    assert _choose_grid(4, 3840, 2160, -1) == {"rows": 2, "columns": 2}


def test_tile_rect_preserves_work_area_offset():
    assert _calculate_tile_rect(1, 1, 2, 1000, 800, x=50, y=30) == {
        "x": 550,
        "y": 30,
        "width": 500,
        "height": 800,
    }


def test_tile_rects_cover_uneven_work_area_without_gaps():
    tiles = [
        _calculate_tile_rect(index, 1, 3, 1000, 800)
        for index in range(3)
    ]

    assert [tile["width"] for tile in tiles] == [333, 333, 334]
    assert tiles[0]["x"] == 0
    assert tiles[1]["x"] == tiles[0]["x"] + tiles[0]["width"]
    assert tiles[2]["x"] == tiles[1]["x"] + tiles[1]["width"]
    assert tiles[2]["x"] + tiles[2]["width"] == 1000
