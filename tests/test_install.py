import json
import shutil
import subprocess

import pytest

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WINDOW_MODULE = ROOT / "windows.js"


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


def _run_javascript(source, body):
    """Evaluate JavaScript source plus a test body and return parsed JSON."""
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is required to evaluate JavaScript helpers")

    completed = subprocess.run(
        [node, "-e", f"{source}\n{body}"],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout.strip())


def _run_window_helpers(function_names, body):
    """Evaluate selected window helpers with caller-provided GNOME fakes."""
    source = WINDOW_MODULE.read_text(encoding="utf-8")
    functions = "\n".join(
        _extract_function(source, function_name)
        for function_name in function_names
    )
    return _run_javascript(functions, body)


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
    window_source = WINDOW_MODULE.read_text(encoding="utf-8")

    assert "getWindowApplicationId" in source
    assert "global.workspace_manager.get_active_workspace()" in source
    assert "win.get_monitor() !== monitorIndex" in window_source
    assert "workspace.get_work_area_for_monitor(monitorIndex)" in source
    assert "win.move_resize_frame(true, tile.x, tile.y, tile.width, tile.height)" in source
    assert "getApplicationPreferredWidth" in source
    assert "from './layout.js'" in source
    assert "from './windows.js'" in source
    assert "parseApplicationPreferredWidths" in source
    assert "'kitty:1300'" in source
    assert "if (windowCount === 2)" in layout_source
    assert "return { rows: 1, columns: 2 };" in layout_source
    assert "workArea.width >= workArea.height" not in layout_source


def test_get_focus_window_rejects_missing_and_taskbar_skipping_windows():
    result = _run_window_helpers(
        ["getFocusWindow"],
        """
const valid = { skip_taskbar: false };
global.display = { focus_window: null };
const missing = getFocusWindow();
global.display.focus_window = { is_skip_taskbar: () => true };
const skippedByMethod = getFocusWindow();
global.display.focus_window = { skip_taskbar: true };
const skippedByProperty = getFocusWindow();
global.display.focus_window = valid;
const accepted = getFocusWindow();
console.log(JSON.stringify({
  missing: missing === null,
  skippedByMethod: skippedByMethod === null,
  skippedByProperty: skippedByProperty === null,
  accepted: accepted === valid,
}));
""",
    )

    assert result == {
        "missing": True,
        "skippedByMethod": True,
        "skippedByProperty": True,
        "accepted": True,
    }


def test_can_tile_window_requires_move_and_resize_capabilities():
    result = _run_window_helpers(
        ["canTileWindow"],
        """
const movable = {
  move_resize_frame() {},
  allows_resize: () => true,
  allows_move: () => true,
};
console.log(JSON.stringify({
  missing: canTileWindow(null),
  noMoveResize: canTileWindow({}),
  fixedSize: canTileWindow({ ...movable, allows_resize: () => false }),
  fixedPosition: canTileWindow({ ...movable, allows_move: () => false }),
  movable: canTileWindow(movable),
}));
""",
    )

    assert result == {
        "missing": False,
        "noMoveResize": False,
        "fixedSize": False,
        "fixedPosition": False,
        "movable": True,
    }


def test_window_application_id_uses_priority_normalization_and_app_fallback():
    result = _run_window_helpers(
        ["getWindowApplicationId"],
        """
const Shell = {
  WindowTracker: {
    get_default: () => ({
      get_window_app: win => win.trackedApp ?? null,
    }),
  },
};
const preferred = {
  get_gtk_application_id: () => '  Org.Example.App  ',
  get_wm_class: () => 'Ignored',
};
const fallback = {
  trackedApp: { get_id: () => '  Fallback.Desktop  ' },
};
const unknown = {};
console.log(JSON.stringify({
  preferred: getWindowApplicationId(preferred),
  fallback: getWindowApplicationId(fallback),
  unknown: getWindowApplicationId(unknown),
}));
""",
    )

    assert result == {
        "preferred": "gtk-application-id:org.example.app",
        "fallback": "app:fallback.desktop",
        "unknown": None,
    }


def test_tile_candidate_enforces_application_monitor_workspace_and_window_type():
    result = _run_window_helpers(
        ["canTileWindow", "getWindowApplicationId", "isTileCandidate"],
        """
const Meta = { WindowType: { NORMAL: 1 } };
const Shell = {
  WindowTracker: {
    get_default: () => ({ get_window_app: () => null }),
  },
};
const workspace = {};
const base = {
  move_resize_frame() {},
  allows_resize: () => true,
  allows_move: () => true,
  get_wm_class: () => 'Kitty',
  get_monitor: () => 2,
  located_on_workspace: candidate => candidate === workspace,
  is_skip_taskbar: () => false,
  get_window_type: () => Meta.WindowType.NORMAL,
};
const candidate = win => isTileCandidate(
  win,
  workspace,
  2,
  'wm-class:kitty',
);
console.log(JSON.stringify({
  accepted: candidate(base),
  wrongApp: candidate({ ...base, get_wm_class: () => 'Other' }),
  wrongMonitor: candidate({ ...base, get_monitor: () => 1 }),
  wrongWorkspace: candidate({
    ...base,
    located_on_workspace: () => false,
  }),
  skipped: candidate({ ...base, is_skip_taskbar: () => true }),
  dialog: candidate({ ...base, get_window_type: () => 2 }),
  immovable: candidate({ ...base, allows_move: () => false }),
}));
""",
    )

    assert result == {
        "accepted": True,
        "wrongApp": False,
        "wrongMonitor": False,
        "wrongWorkspace": False,
        "skipped": False,
        "dialog": False,
        "immovable": False,
    }


def test_prepare_window_clears_blocking_states():
    result = _run_window_helpers(
        ["prepareWindow"],
        """
const calls = [];
prepareWindow({
  get_maximized: () => 3,
  unmaximize: state => calls.push(['unmaximize', state]),
  unmake_fullscreen: () => calls.push(['unmake_fullscreen']),
  unminimize: () => calls.push(['unminimize']),
});
prepareWindow({
  get_maximized: () => 0,
  unmaximize: state => calls.push(['unexpected', state]),
});
console.log(JSON.stringify(calls));
""",
    )

    assert result == [
        ["unmaximize", 3],
        ["unmake_fullscreen"],
        ["unminimize"],
    ]


def test_raise_window_prefers_workspace_api_and_supports_fallback():
    result = _run_window_helpers(
        ["raiseWindow"],
        """
const calls = [];
const workspace = { id: 'active' };
raiseWindow({
  raise_and_make_recent_on_workspace: candidate => {
    calls.push(['workspace', candidate.id]);
  },
  raise_and_make_recent: () => calls.push(['unexpected']),
}, workspace);
raiseWindow({
  raise_and_make_recent: () => calls.push(['fallback']),
}, workspace);
raiseWindow({}, workspace);
console.log(JSON.stringify(calls));
""",
    )

    assert result == [["workspace", "active"], ["fallback"]]


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
    assert 'source "$SCRIPT_DIR/lib/installer_logging.sh"' in installer
    assert "installer_log" in installer
    assert '"--binding"' in installer
    assert "gsettings_array" in installer
    assert '"$SCHEMA_ID" "$BINDING_KEY"' in installer
    assert 'TARGET_USER="${SUDO_USER:-${TARGET_USER:-$USER}}"' in installer
    assert 'if [[ "$(id -u)" -eq "$TARGET_UID" ]]' in installer
    assert '"$SCRIPT_DIR/layout.js"' in installer
    assert '"$SCRIPT_DIR/windows.js"' in installer


def test_installer_logs_meaningful_install_phases():
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")
    logging_helper = (ROOT / "lib" / "installer_logging.sh").read_text(
        encoding="utf-8"
    )

    expected_messages = [
        "resolving target user",
        "installing extension files",
        "compiling gsettings schema",
        "applying accelerator",
        "ensuring user extensions stay enabled",
        "adding $EXTENSION_ID to enabled extensions",
        "requesting in-place extension enable",
    ]

    assert "automatic-window-tiling installer:" in logging_helper
    assert "log_step" not in installer
    for message in expected_messages:
        assert f'installer_log "{message}' in installer


def test_preferred_width_drives_three_columns_on_4k():
    # 4K width (3840px) with a 1300px preferred width places three windows
    # side by side: ceil(3840 / 1300) == 3.
    assert _choose_grid(3, 3840, 2160, 1300) == {"rows": 1, "columns": 3}


def test_preferred_width_wraps_extra_windows_to_new_rows():
    # Perfect-square counts stay balanced even when preferred width would allow
    # a wider grid with empty cells.
    assert _choose_grid(4, 3840, 2160, 1300) == {"rows": 2, "columns": 2}
    # Non-square counts keep the preferred column density and wrap rows.
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


def test_portrait_monitor_packs_columns_at_minimum_width():
    # On a 2160px-wide portrait monitor two 1080px columns fit, so the first two
    # windows sit side by side. The per-application preferred width does not
    # tighten portrait packing.
    assert _choose_grid(2, 2160, 3840, 1300) == {"rows": 1, "columns": 2}
    assert _choose_grid(2, 2160, 3840, None) == {"rows": 1, "columns": 2}
    # A third window wraps onto a second row within the two-column grid.
    assert _choose_grid(3, 2160, 3840, 1300) == {"rows": 2, "columns": 2}


def test_portrait_monitor_grows_into_sensible_grid_for_many_windows():
    # Beyond four windows the two-column grid keeps growing rows rather than
    # collapsing into a single tall column.
    assert _choose_grid(4, 2160, 3840, None) == {"rows": 2, "columns": 2}
    assert _choose_grid(5, 2160, 3840, None) == {"rows": 3, "columns": 2}
    assert _choose_grid(6, 2160, 3840, None) == {"rows": 3, "columns": 2}


def test_narrow_portrait_monitor_keeps_single_column():
    # A portrait monitor too narrow for two 1080px columns stays single-column.
    assert _choose_grid(2, 1200, 1920, None) == {"rows": 2, "columns": 1}


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
