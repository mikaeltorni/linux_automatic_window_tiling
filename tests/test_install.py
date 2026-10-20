import json
import shutil
import subprocess

import pytest

from js_runtime import collect_modules, run_extension

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
    """Evaluate JavaScript and parse the final result after diagnostic prints.

    Parameters: source - runtime functions; body - public invocation and final JSON output.
    Returns: the independently asserted JSON result.
    """
    print(f"source={source}, body={body}")
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is required to evaluate JavaScript helpers")

    completed = subprocess.run(
        [node, "-e", f"{source}\n{body}"],
        capture_output=True,
        text=True,
        check=True,
    )
    result = json.loads(completed.stdout.strip().splitlines()[-1])
    print(result)
    return result


def _run_window_helpers(function_names, body):
    """Evaluate the window module graph with named helpers and GNOME fakes.

    Parameters: function_names - requested window helpers; body - caller-provided JS invocation.
    Returns: the parsed JSON result.
    """
    print(f"function_names={function_names}, body={body}")
    source = WINDOW_MODULE.read_text()
    for name in function_names:
        assert f"function {name}(" in source, name
    functions = "\n".join(collect_modules(WINDOW_MODULE, set()))
    result = _run_javascript(functions, body)
    print(result)
    return result


def _choose_grid(window_count, width, height, preferred_width):
    """Run the actual grid module with a landscape or portrait work area.

    Parameters: window_count - window count; width - work-area width; height - work-area height; preferred_width - optional width preference.
    Returns: the selected grid dimensions.
    """
    print(f"window_count={window_count}, width={width}, height={height}, preferred_width={preferred_width}")
    result = _run_layout_module(
        f"console.log(JSON.stringify(chooseGrid({window_count}, "
        f"{{ x: 0, y: 0, width: {width}, height: {height} }}, {json.dumps(preferred_width)})));"
    )
    print(result)
    return result


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
    """Keep lifecycle, preferences, geometry and platform operations in their owners.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    lifecycle = (ROOT / "extension.js").read_text()
    tiling = (ROOT / "tiling.js").read_text()
    preferences = (ROOT / "preferences.js").read_text()
    layout = (ROOT / "layout.js").read_text()
    windows = WINDOW_MODULE.read_text()
    assert "new WindowTiler(this._settings)" in lifecycle
    assert "this._tiler.tileAllWindows()" in lifecycle
    assert "tile-all-windows" in lifecycle
    assert "Main.wm.removeKeybinding(ALL_TILE_KEY)" in lifecycle
    for call in ("getWindowApplicationId", "getTileGroupKey", "placeWindowInTile(win, tile)",
                 "global.workspace_manager.get_active_workspace()", "workspace.get_work_area_for_monitor(monitorIndex)"):
        assert call in tiling, call
    assert "win.get_monitor() !== monitorIndex" in windows
    assert "win.move_resize_frame(true, tile.x, tile.y, tile.width, tile.height)" in windows
    assert "readTilingPreferences(this._settings)" in tiling
    assert "'kitty:1300'" in preferences
    assert "if (windowCount === 2)" in layout
    assert "const result = { rows: 1, columns: 2 };" in layout
    assert "name.startsWith('kitty-')" in windows
    assert "return 'kitty'" in windows
    print(None)


def test_background_group_tiling_uses_anchor_workspace_without_focus_change():
    """Keep background window routing and focus rules separate from lifecycle registration.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    lifecycle = (ROOT / "extension.js").read_text()
    source = (ROOT / "tiling.js").read_text()
    assert 'name="TileWindowGroup"' in lifecycle
    assert 'name="TileWindowGroups"' in lifecycle
    for call in ("workspace.index()", "anchor.get_monitor()", "anchors.set(key, [anchor, applicationId])",
                 "anchorWindow.get_workspace()", "background ? null : detectTiledOrder", "if (!background)"):
        assert call in source, call
    assert "this._dbusObject.unexport()" in lifecycle
    print(None)


def test_background_batch_groups_actual_workspaces_and_monitors_once():
    """Group parsed background identifiers once for every actual workspace and monitor.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = run_extension("const Extension = class {};", """
const windows = [
  [10, 0, 0], [11, 0, 0], [12, 0, 1], [13, 1, 0],
].map(([id, workspace, monitor]) => ({
  get_description: () => `0x${id.toString(16)}`,
  get_wm_class: () => 'kitty',
  get_workspace: () => ({ index: () => workspace }),
  get_monitor: () => monitor,
}));
global.get_window_actors = () => windows.map(win => ({ get_meta_window: () => win }));
const tiled = [];
const tiler = new WindowTiler(null);
tiler.tileWindowsOnMonitor = (_mode, anchor) => tiled.push(Number(anchor.get_description()));
tiler.tileWindowGroups(['10', '0xb', '12', '13']);
console.log(JSON.stringify(tiled));
""")
    assert result == [11, 12, 13]
    print(None)


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
        [
            "canTileWindow",
            "getWindowApplicationId",
            "getTileGroupKey",
            "isTileCandidate",
        ],
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
const allWindowsCandidate = win => isTileCandidate(win, workspace, 2);
console.log(JSON.stringify({
  accepted: candidate(base),
  wrongApp: candidate({ ...base, get_wm_class: () => 'Other' }),
  otherAppInAllMode: allWindowsCandidate({ ...base, get_wm_class: () => 'Other' }),
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
        "otherAppInAllMode": True,
        "wrongMonitor": False,
        "wrongWorkspace": False,
        "skipped": False,
        "dialog": False,
        "immovable": False,
    }


def test_tile_group_key_maps_kitty_family_and_preserves_other_apps():
    """Kitty + kitty-agent-* share one Super+T group; other apps stay exact."""
    result = _run_window_helpers(
        ["getTileGroupKey"],
        """
console.log(JSON.stringify({
  plain: getTileGroupKey('wm-class:kitty'),
  agentCca: getTileGroupKey('wm-class:kitty-agent-cca'),
  agentGa: getTileGroupKey('wm-class:kitty-agent-ga'),
  bareKitty: getTileGroupKey('kitty'),
  firefox: getTileGroupKey('wm-class:firefox'),
  empty: getTileGroupKey(''),
  missing: getTileGroupKey(null),
}));
""",
    )

    assert result == {
        "plain": "kitty",
        "agentCca": "kitty",
        "agentGa": "kitty",
        "bareKitty": "kitty",
        "firefox": "firefox",
        "empty": None,
        "missing": None,
    }


def test_kitty_family_co_tiles_across_provider_icons_and_excludes_others():
    """Super+T with focus on a model-icon kitty includes every kitty peer.

    Per-provider windows keep distinct WM_CLASS values for dock icons
    (``kitty-agent-cca``, ``kitty-agent-ga``) but still co-tile with plain
    ``kitty``. Unrelated apps never enter the tile set.
    """
    result = _run_window_helpers(
        [
            "canTileWindow",
            "getWindowApplicationId",
            "getTileGroupKey",
            "isTileCandidate",
        ],
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
  get_monitor: () => 0,
  located_on_workspace: candidate => candidate === workspace,
  is_skip_taskbar: () => false,
  get_window_type: () => Meta.WindowType.NORMAL,
};
const win = wmClass => ({ ...base, get_wm_class: () => wmClass });
const peers = {
  plain: win('kitty'),
  agentCca: win('kitty-agent-cca'),
  agentGa: win('kitty-agent-ga'),
  firefox: win('firefox'),
};
const select = focusedId => Object.fromEntries(
  Object.entries(peers).map(([name, candidate]) => [
    name,
    isTileCandidate(candidate, workspace, 0, focusedId),
  ]),
);
console.log(JSON.stringify({
  focusedAgentCca: select('wm-class:kitty-agent-cca'),
  focusedPlain: select('wm-class:kitty'),
  focusedFirefox: select('wm-class:firefox'),
  identities: {
    plain: getWindowApplicationId(peers.plain),
    agentCca: getWindowApplicationId(peers.agentCca),
    agentGa: getWindowApplicationId(peers.agentGa),
    firefox: getWindowApplicationId(peers.firefox),
  },
}));
""",
    )

    assert result["identities"] == {
        "plain": "wm-class:kitty",
        "agentCca": "wm-class:kitty-agent-cca",
        "agentGa": "wm-class:kitty-agent-ga",
        "firefox": "wm-class:firefox",
    }
    assert result["focusedAgentCca"] == {
        "plain": True,
        "agentCca": True,
        "agentGa": True,
        "firefox": False,
    }
    assert result["focusedPlain"] == {
        "plain": True,
        "agentCca": True,
        "agentGa": True,
        "firefox": False,
    }
    # Non-kitty apps still tile only with exact same-app peers.
    assert result["focusedFirefox"] == {
        "plain": False,
        "agentCca": False,
        "agentGa": False,
        "firefox": True,
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


def test_schema_binding_default_matches_installer_default():
    """The schema default is the fallback for a deselected `keybinding` component.

    This test previously required an empty `[]` default so that the installer
    stayed the only source of the accelerator. That made the always-on extension
    core inert whenever the optional `keybinding` component was deselected, so
    the default now mirrors AWT_BINDING instead. The installer remains
    authoritative when the component runs: it is still the only place that
    writes the key, and an explicit --binding/AWT_BINDING override still wins
    (see test_bare_binding_runs_default_components_non_interactively).
    """
    schema = (
        ROOT
        / "schemas"
        / "org.gnome.shell.extensions.automatic-window-tiling.gschema.xml"
    ).read_text(encoding="utf-8")

    assert '<key name="tile-focused-application-windows"' in schema
    assert "<default>['&lt;Super&gt;t']</default>" in schema
    assert '<key name="tile-all-windows"' in schema
    assert "<default>['&lt;Control&gt;&lt;Shift&gt;t']</default>" in schema

    # The installer, not the schema, still performs every write of the key.
    setup = (ROOT / "lib" / "tiling_setup.sh").read_text(encoding="utf-8")
    assert 'AWT_BINDING="${AWT_BINDING:-<Super>t}"' in setup
    assert 'AWT_ALL_BINDING="${AWT_ALL_BINDING:-<Control><Shift>t}"' in setup


def test_schema_exposes_customizable_keys():
    schema = (
        ROOT
        / "schemas"
        / "org.gnome.shell.extensions.automatic-window-tiling.gschema.xml"
    ).read_text(encoding="utf-8")

    assert '<key name="application-preferred-widths"' in schema
    assert "<default>['kitty:1300']</default>" in schema
    assert '<key name="portrait-minimum-tile-height"' in schema
    assert "<default>0</default>" in schema


def test_all_window_binding_is_applied_with_the_existing_binding_component():
    setup = (ROOT / "lib" / "tiling_setup.sh").read_text(encoding="utf-8")

    assert 'ALL_BINDING_KEY="tile-all-windows"' in setup
    assert 'awt_set_strv "$ALL_BINDING_KEY" "$AWT_ALL_BINDING"' in setup
    assert 'awt_reset "$ALL_BINDING_KEY"' in setup
    assert "AWT_ALL_BINDING" in setup


def test_parse_application_preferred_widths_skips_malformed_entries():
    """Preserve effective width preferences when malformed entries are rejected by the operation.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = run_extension("const Extension = class {};", """
const settings = {
  get_strv: () => ['kitty:1300', 'firefox:900', 'nocolon', 'zero:0', 'negative:-5', 'bad:width'],
  get_int: () => 0,
};
console.log(JSON.stringify(readTilingPreferences(settings).widthMatchers));
""")
    assert result == [
        {"match": "kitty", "preferredWidth": 1300},
        {"match": "firefox", "preferredWidth": 900},
    ]
    print(None)


def test_get_application_preferred_width_matches_identifier_suffix():
    """Use the shared kitty group for effective width lookup.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    window_source = WINDOW_MODULE.read_text(encoding="utf-8")
    extension_source = (ROOT / "preferences.js").read_text(encoding="utf-8")
    functions = "\n".join(
        [
            _extract_function(window_source, "getTileGroupKey"),
            _extract_function(extension_source, "getApplicationPreferredWidth"),
        ]
    )
    result = _run_javascript(
        functions,
        """
const matchers = [{ match: 'kitty', preferredWidth: 1300 }];
console.log(JSON.stringify({
  prefixed: getApplicationPreferredWidth('wm-class:kitty', matchers),
  bare: getApplicationPreferredWidth('kitty', matchers),
  agentCca: getApplicationPreferredWidth('wm-class:kitty-agent-cca', matchers),
  agentGa: getApplicationPreferredWidth('wm-class:kitty-agent-ga', matchers),
  other: getApplicationPreferredWidth('wm-class:firefox', matchers),
  nonString: getApplicationPreferredWidth(null, matchers),
}));
""",
    )

    assert result == {
        "prefixed": 1300,
        "bare": 1300,
        "agentCca": 1300,
        "agentGa": 1300,
        "other": None,
        "nonString": None,
    }
    print(None)


def _choose_grid_portrait(window_count, width, height, portrait_min_height):
    """Read portrait wrapping from the actual grid module.

    Parameters: window_count - window count; width - work-area width; height - work-area height; portrait_min_height - optional wrapping height.
    Returns: the selected grid dimensions.
    """
    print(f"window_count={window_count}, width={width}, height={height}, portrait_min_height={portrait_min_height}")
    result = _run_layout_module(
        f"console.log(JSON.stringify(chooseGrid({window_count}, "
        f"{{ x: 0, y: 0, width: {width}, height: {height} }}, null, {json.dumps(portrait_min_height)})));"
    )
    print(result)
    return result


def test_portrait_minimum_height_is_configurable():
    # The default (non-positive minimum) keeps every window in a single,
    # full-height column stacked top to bottom on a portrait monitor.
    assert _choose_grid_portrait(3, 2160, 3840, 0) == {"rows": 3, "columns": 1}
    # Two windows stack as top and bottom, never side by side.
    assert _choose_grid_portrait(2, 2160, 3840, None) == {"rows": 2, "columns": 1}
    # A positive minimum wraps windows into side-by-side columns once a column
    # would fall below that height: 1080px fits 3 rows on a 3840px-tall monitor,
    # so the 4th window wraps to the right.
    assert _choose_grid_portrait(4, 2160, 3840, 1080) == {"rows": 3, "columns": 2}


def test_installer_parses_binding_and_routes_through_component_framework():
    """Keep installer parsing and core execution delegated to their owning layers.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")

    assert 'parse_binding "$@"' in installer
    assert 'source "$SCRIPT_DIR/lib/installer_logging.sh"' in installer
    assert "installer_log" in installer
    assert "--binding" in installer
    assert 'TARGET_USER="${SUDO_USER:-${TARGET_USER:-$USER}}"' in installer
    # Core deployment belongs to the framework's install-only hook.
    assert 'source "$SCRIPT_DIR/lib/tiling_setup.sh"' in installer
    manifest = (ROOT / "installer/components.sh").read_text(encoding="utf-8")
    assert "ISC_CORE=awt_install_core" in manifest
    assert "isc_activate_components" in installer
    assert 'source "$SCRIPT_DIR/installer/components.sh"' in installer
    assert 'operation=component_main' in installer
    assert '"$operation" "${FRAMEWORK_ARGS[@]}"' in installer
    print(None)


def test_bare_binding_runs_default_components_non_interactively():
    """A delegated bare-binding call must not drop into the interactive menu.

    linux_hotkey_setup invokes this installer with only the tiling binding and no
    component selection. Without a selection flag, component_main opens its TTY
    submenu and blocks on keyboard input, hanging the whole master run. A bare or
    explicit binding with no framework selection must therefore default to
    --default and install non-interactively.
    """
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")

    assert "AWT_BINDING_EXPLICIT" in installer
    assert "${#FRAMEWORK_ARGS[@]} -eq 0" in installer
    assert "FRAMEWORK_ARGS=(--default)" in installer


def test_setup_library_deploys_and_applies_settings():
    setup = (ROOT / "lib" / "tiling_setup.sh").read_text(encoding="utf-8")

    assert "gsettings_array" in setup
    assert '"$SCHEMA_ID" "$key"' in setup
    assert 'if [[ "$(id -u)" -eq "$TARGET_UID" ]]' in setup
    assert '"$SCRIPT_DIR/layout.js"' in setup
    assert '"$SCRIPT_DIR/windows.js"' in setup


def test_component_manifest_lists_customizable_features():
    manifest = (ROOT / "installer" / "components.sh").read_text(encoding="utf-8")

    assert 'ISC_REPO_NAME="linux_automatic_window_tiling"' in manifest
    for component_id, function in (
        ("keybinding", "awt_configure_keybinding"),
        ("per_app_widths", "awt_configure_app_widths"),
        ("portrait_stacking", "awt_configure_portrait_stacking"),
    ):
        assert component_id in manifest
        assert function in manifest
    # Every component is default-on so a plain install keeps built-in behavior.
    assert "|off|" not in manifest


def test_installer_logs_meaningful_install_phases():
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")
    setup = (ROOT / "lib" / "tiling_setup.sh").read_text(encoding="utf-8")
    logging_helper = (ROOT / "lib" / "installer_logging.sh").read_text(
        encoding="utf-8"
    )

    assert 'installer_log "resolving target user' in installer
    expected_setup_messages = [
        "installing extension files",
        "compiling gsettings schema",
        "applying accelerator",
        "ensuring user extensions stay enabled",
        "adding $EXTENSION_ID to enabled extensions",
        "dispatching background in-place extension enable",
    ]

    assert "automatic-window-tiling installer:" in logging_helper
    assert "log_step" not in installer
    for message in expected_setup_messages:
        assert f'installer_log "{message}' in setup


def test_in_place_enable_is_non_blocking():
    """The best-effort live enable must never block the installer.

    `gnome-extensions enable` is a synchronous D-Bus call into GNOME Shell and
    can hang for minutes on a fresh install or an unresponsive session, so it is
    dispatched in the background (time-boxed, with stdio detached). The extension
    is already persisted in enabled-extensions and loads on next login.
    """
    setup = (ROOT / "lib" / "tiling_setup.sh").read_text(encoding="utf-8")

    assert "timeout 5 gnome-extensions enable" in setup
    # Must be backgrounded with stdio detached so it cannot hold the pipe open.
    assert ">/dev/null 2>&1 </dev/null &" in setup
    # And must not run a synchronous foreground enable.
    assert "run_as_target gnome-extensions enable" not in setup


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


def test_portrait_monitor_stacks_vertically_by_default():
    # On a portrait monitor windows stack top to bottom in one full-height
    # column; they are never placed side by side unless a positive minimum is set.
    assert _choose_grid_portrait(2, 2160, 3840, None) == {"rows": 2, "columns": 1}
    assert _choose_grid_portrait(3, 2160, 3840, None) == {"rows": 3, "columns": 1}
    # A third window continues below rather than being cut in half: three equal
    # rows, no side-by-side wrap.
    assert _choose_grid_portrait(3, 2160, 3840, 0) == {"rows": 3, "columns": 1}


def test_portrait_monitor_wraps_into_columns_only_with_positive_minimum():
    # With a positive minimum, a column wraps to the right once it would drop
    # below that height, so many windows stay usable instead of becoming slivers.
    assert _choose_grid_portrait(4, 2160, 3840, 1080) == {"rows": 3, "columns": 2}
    assert _choose_grid_portrait(5, 2160, 3840, 1080) == {"rows": 3, "columns": 2}
    assert _choose_grid_portrait(6, 2160, 3840, 1080) == {"rows": 3, "columns": 2}


def test_narrow_portrait_monitor_keeps_single_column():
    # With no minimum a narrow portrait monitor stacks windows vertically.
    assert _choose_grid_portrait(2, 1200, 1920, None) == {"rows": 2, "columns": 1}
    # A positive minimum taller than the monitor allows only one row, so the
    # windows fall back to side by side rather than being squeezed in height.
    assert _choose_grid_portrait(2, 1200, 1920, 1080) == {"rows": 1, "columns": 2}


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


def _run_layout_module(body):
    """Evaluate the whole layout module (exports stripped) plus a test body."""
    source = (ROOT / "layout.js").read_text(encoding="utf-8").replace("export function", "function")
    return _run_javascript(source, body)


def _detect_tiled_order(frames, rows, columns, width, height):
    """Run detectTiledOrder against the given frames and grid."""
    return _run_layout_module(
        f"console.log(JSON.stringify(detectTiledOrder("
        f"{json.dumps(frames)}, {rows}, {columns},"
        f" {{ x: 0, y: 0, width: {width}, height: {height} }})));"
    )


def test_detect_tiled_order_maps_windows_to_their_cells():
    frames = [
        {"x": 500, "y": 0, "width": 500, "height": 800},
        {"x": 0, "y": 0, "width": 500, "height": 800},
    ]

    assert _detect_tiled_order(frames, 1, 2, 1000, 800) == [1, 0]


def test_detect_tiled_order_tolerates_small_size_deviations():
    frames = [
        {"x": 0, "y": 0, "width": 490, "height": 792},
        {"x": 500, "y": 8, "width": 500, "height": 790},
    ]

    assert _detect_tiled_order(frames, 1, 2, 1000, 800) == [0, 1]


def test_detect_tiled_order_returns_null_for_untiled_windows():
    frames = [
        {"x": 0, "y": 0, "width": 1000, "height": 800},
        {"x": 120, "y": 60, "width": 700, "height": 400},
    ]

    assert _detect_tiled_order(frames, 1, 2, 1000, 800) is None


def test_detect_tiled_order_returns_null_when_two_windows_share_a_cell():
    frames = [
        {"x": 0, "y": 0, "width": 500, "height": 800},
        {"x": 0, "y": 0, "width": 500, "height": 800},
    ]

    assert _detect_tiled_order(frames, 1, 2, 1000, 800) is None


def test_cycle_tiled_order_rotates_windows_by_one_cell():
    assert _run_layout_module(
        "console.log(JSON.stringify(cycleTiledOrder([2, 0, 1])));"
    ) == [0, 1, 2]


def test_repeated_cycles_return_to_the_original_order():
    assert _run_layout_module(
        "let order = [0, 1, 2];\n"
        "for (let i = 0; i < 3; i++) { order = cycleTiledOrder(order); }\n"
        "console.log(JSON.stringify(order));"
    ) == [0, 1, 2]


def test_extension_cycles_order_when_windows_are_already_tiled():
    """Keep the tiling operation responsible for matching and rotating existing cells.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    source = (ROOT / "tiling.js").read_text()
    for call in ("detectTiledOrder", "cycleTiledOrder", "const ordered = tiledOrder", "const win = ordered[index];"):
        assert call in source, call
    print(None)


@pytest.mark.parametrize("anchor_maximized,peer_maximized", [(3, 0), (0, 3), (3, 3), (1, 2), (0, 0)])
def test_super_t_tiles_maximized_windows_and_preserves_selection_and_cycling(
    anchor_maximized, peer_maximized,
):
    """Invoke the hotkey handler with realistic state-dependent resize checks.

    Parameters: anchor_maximized - focused window maximize flags; peer_maximized - matching peer flags.
    Returns: None.
    """
    print(f"anchor_maximized={anchor_maximized}, peer_maximized={peer_maximized}")
    result = run_extension("const Extension = class {};", """
const Meta = { WindowType: { NORMAL: 1 }, KeyBindingFlags: { NONE: 0 } };
const Shell = { ActionMode: { NORMAL: 1 }, WindowTracker: { get_default: () => ({ get_window_app: () => null }) } };
const handlers = new Map();
const Main = { wm: {
  addKeybinding: (key, settings, flags, modes, handler) => handlers.set(key, handler),
  removeKeybinding: key => handlers.delete(key),
} };
const Gio = {
  DBusExportedObject: { wrapJSObject: () => ({ export: () => {}, unexport: () => {} }) },
  DBus: { session: {} }, BusNameOwnerFlags: { NONE: 0 },
  bus_own_name_on_connection: () => 1, bus_unown_name: () => {},
};
Extension.prototype.getSettings = () => null;
const workArea = { x: 0, y: 24, width: 2000, height: 1000 };
const calls = [];
const workspace = {
  get_work_area_for_monitor: () => workArea,
  list_windows: () => windows,
};
function makeWindow(id, maximized, options = {}) {
  return {
    maximized,
    resizeable: true,
    frame: maximized ? { ...workArea } : { x: 20, y: 50, width: 600, height: 500 },
    get_maximized() { return this.maximized; },
    allows_resize() { return this.resizeable && this.maximized !== 3; },
    allows_move: () => true,
    unmaximize(flags) {
      calls.push(['unmaximize', id, flags]);
      this.maximized &= ~flags;
    },
    unmake_fullscreen() {},
    unminimize() {},
    move_resize_frame(_userOp, x, y, width, height) {
      if (this.maximized) throw new Error('must unmaximize before placement');
      calls.push(['tile', id]);
      this.frame = { x, y, width, height };
    },
    get_frame_rect() { return this.frame; },
    get_wm_class: () => 'kitty',
    get_monitor: () => 0,
    located_on_workspace: candidate => candidate === workspace,
    is_skip_taskbar: () => false,
    get_window_type: () => Meta.WindowType.NORMAL,
    get_stable_sequence: () => id,
    raise_and_make_recent_on_workspace() { calls.push(['raise', id]); },
    ...options,
  };
}
const anchor = makeWindow(2, ANCHOR_MAXIMIZED);
const peer = makeWindow(1, PEER_MAXIMIZED);
const excluded = [
  makeWindow(3, 3, { get_wm_class: () => 'firefox' }),
  makeWindow(4, 3, { get_monitor: () => 1 }),
  makeWindow(5, 3, { located_on_workspace: () => false }),
  makeWindow(6, 3, { is_skip_taskbar: () => true }),
  makeWindow(7, 3, { get_window_type: () => 2 }),
  makeWindow(8, 3, { resizeable: false }),
  makeWindow(9, 3, { allows_move: () => false }),
];
const windows = [peer, anchor, ...excluded];
global.display = { focus_window: anchor };
global.workspace_manager = { get_active_workspace: () => workspace };
const extension = new AutomaticWindowTilingExtension();
extension.enable();
handlers.get("tile-focused-application-windows")();
const first = [anchor.frame, peer.frame];
const firstCalls = calls.slice();
calls.length = 0;
handlers.get("tile-focused-application-windows")();
extension.disable();
console.log(JSON.stringify({
  first,
  firstCalls,
  second: [anchor.frame, peer.frame],
  secondCalls: calls,
  states: [anchor.maximized, peer.maximized],
  excludedStates: excluded.map(win => win.maximized),
}));
""".replace("ANCHOR_MAXIMIZED", str(anchor_maximized)).replace("PEER_MAXIMIZED", str(peer_maximized)),
    )
    left = {"x": 0, "y": 24, "width": 1000, "height": 1000}
    right = {"x": 1000, "y": 24, "width": 1000, "height": 1000}
    assert result["first"] == [left, right]
    expected_calls = []
    for window_id, flags in [(2, anchor_maximized), (1, peer_maximized)]:
        if flags:
            expected_calls.append(["unmaximize", window_id, flags])
        expected_calls.append(["tile", window_id])
    assert result["firstCalls"] == expected_calls + [["raise", 2]]
    assert result["second"] == [right, left]
    assert result["secondCalls"] == [["tile", 1], ["tile", 2], ["raise", 2]]
    assert result["states"] == [0, 0]
    assert result["excludedStates"] == [3] * 7
    print(None)
