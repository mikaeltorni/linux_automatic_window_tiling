"""Public hotkey regressions for observed X11 client size constraints."""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


def run_hotkey(binding, count, portrait=False, infeasible=False, modern=False):
    """Run the real lifecycle and hotkey with terminal and oversized X11 clients.

    Parameters: binding - public keybinding name; count - number of windows;
    portrait - use a portrait monitor with a configured 900px minimum tile height.
    infeasible - include an oversized client and maximized/fullscreen/minimized states.
    modern - expose only the GNOME 49+ maximization API and start with a maximized window.
    Returns: the original and resulting frames and states after two public hotkey invocations.
    """
    print(f"binding={binding}, count={count}, portrait={portrait}, infeasible={infeasible}, modern={modern}")
    node = shutil.which("node")
    if node is None:
        pytest.skip("node is required for the extension hotkey regression")
    modules = []
    for filename in ("layout.js", "windows.js", "extension.js"):
        source = (ROOT / filename).read_text()
        source = re.sub(r"^import[\s\S]*?;\n", "", source, flags=re.MULTILINE)
        modules.append(source.replace("export default class", "class").replace("export function", "function"))
    stubs = r'''
const console = { log: () => {}, warn: () => {}, error: message => { throw new Error(message); } };
const Meta = { WindowType: { NORMAL: 1 }, KeyBindingFlags: { NONE: 0 } };
const Shell = { ActionMode: { NORMAL: 1 } };
const handlers = new Map();
const Main = { wm: {
  addKeybinding: (key, settings, flags, modes, handler) => handlers.set(key, handler),
  removeKeybinding: key => handlers.delete(key),
} };
const settings = { get_strv: () => ['kitty:1300'], get_int: () => PORTRAIT_MINIMUM };
const Extension = class {};
Extension.prototype.getSettings = () => settings;
const Gio = {
  DBusExportedObject: { wrapJSObject: () => ({ export: () => {}, unexport: () => {} }) },
  DBus: { session: {} }, BusNameOwnerFlags: { NONE: 0 },
  bus_own_name_on_connection: () => 1, bus_unown_name: () => {},
};
const workArea = { x: 66, y: 32, width: AREA_WIDTH, height: AREA_HEIGHT };
const infeasible = INFEASIBLE;
const workspace = { get_work_area_for_monitor: () => workArea, list_windows: () => windows };
const makeWindow = id => {
  const window = {
    frame: { x: id === 1 ? 66 : 358, y: id === 1 ? 32 : 37, width: 474, height: 731 },
    maximized: 0, fullscreen: false, minimized: false,
    get_gtk_application_id: () => infeasible && id === 4 ? FINAL_APP_ID : 'org.gnome.terminal',
    get_monitor: () => 0, get_workspace: () => workspace,
    get_stable_sequence: () => id, get_window_type: () => Meta.WindowType.NORMAL,
    is_skip_taskbar: () => false, allows_resize: () => true, allows_move: () => true,
    get_maximized: () => window.maximized,
    unmaximize: () => { window.maximized = 0; },
    maximize: flags => { window.maximized = flags; window.frame = { ...workArea }; },
    unmake_fullscreen: () => { window.fullscreen = false; },
    make_fullscreen: () => {
      window.fullscreen = true;
      window.frame = { x: 0, y: 0, width: 1024, height: 768 };
    },
    unminimize: () => { window.minimized = false; },
    minimize: () => { window.minimized = true; },
    get_frame_rect: () => ({ ...window.frame }),
    // Observed VM behavior: resizing honors terminal increments/minimums, but
    // the combined request leaves the old position until an explicit move.
    move_resize_frame: (user, x, y, width, height) => {
      window.frame.width = Math.max(354, Math.floor((width - 14) / 10) * 10 + 14);
      window.frame.height = Math.max(93, Math.floor((height - 49) / 22) * 22 + 49);
      if (infeasible && id === 4) {
        window.frame.width = Math.max(360, width);
        window.frame.height = Math.max(380, height);
      }
    },
    move_frame: (user, x, y) => { window.frame.x = x; window.frame.y = y; },
    raise_and_make_recent_on_workspace: () => {},
  };
  return window;
};
const windows = Array.from({ length: WINDOW_COUNT }, (_, index) => makeWindow(index + 1));
if (infeasible) {
  windows[1].maximize(3);
  windows[2].make_fullscreen();
  windows[3].minimize();
}
if (MODERN_API) {
  if (!infeasible) windows[0].maximize(3);
  for (const window of windows) {
    const maximize = window.maximize;
    window.get_maximize_flags = window.get_maximized;
    delete window.get_maximized;
    window.set_maximize_flags = flags => maximize(flags);
    window.set_unmaximize_flags = flags => { window.maximized &= ~flags; };
    window.maximize = (...args) => {
      if (args.length) throw new Error('GNOME 49 maximize takes no flags');
      maximize(3);
    };
    window.unmaximize = (...args) => {
      if (args.length) throw new Error('GNOME 49 unmaximize takes no flags');
      window.maximized = 0;
    };
    window.allows_resize = () => window.maximized === 0;
    window.resizeable = true;
  }
}
const state = () => windows.map(window => ({
  maximized: window.maximized, fullscreen: window.fullscreen, minimized: window.minimized,
}));
const initial = windows.map(window => ({ ...window.frame }));
const initialStates = state();
global.display = { focus_window: windows[0] };
global.workspace_manager = { get_active_workspace: () => workspace };
'''.replace("WINDOW_COUNT", str(count)).replace("AREA_WIDTH", str(1500 if portrait else 958)).replace("AREA_HEIGHT", str(3840 if portrait else 736)).replace("PORTRAIT_MINIMUM", str(900 if portrait else 0)).replace("INFEASIBLE", str(infeasible).lower()).replace("MODERN_API", str(modern).lower()).replace("FINAL_APP_ID", json.dumps("org.gnome.Nautilus" if binding == "tile-all-windows" else "org.gnome.terminal"))
    invocation = f'''
const extension = new AutomaticWindowTilingExtension();
extension.enable();
handlers.get({json.dumps(binding)})();
const first = windows.map(window => ({{ ...window.frame }}));
const firstStates = state();
handlers.get({json.dumps(binding)})();
const second = windows.map(window => ({{ ...window.frame }}));
const secondStates = state();
extension.disable();
process.stdout.write(JSON.stringify({{ initial, initialStates, first, firstStates, second, secondStates }}));
'''
    completed = subprocess.run(
        [node, "-e", stubs + "\n" + "\n".join(modules) + invocation],
        capture_output=True, text=True, check=True,
    )
    result = json.loads(completed.stdout)
    print(result)
    return result


@pytest.mark.parametrize("binding", ["tile-focused-application-windows", "tile-all-windows"])
@pytest.mark.parametrize("count", [2, 3])
def test_hotkeys_place_constrained_terminals_without_overlap_and_cycle(binding, count):
    """Place both hotkey modes into feasible cells and rotate on a second press.

    Parameters: binding - public handler selected during enable; count - two or three VM terminals.
    Returns: None.
    """
    print(f"binding={binding}, count={count}")
    result = run_hotkey(binding, count)
    height = 731 if count == 2 else 357
    first = [
        {"x": 66, "y": 32, "width": 474, "height": height},
        {"x": 545, "y": 32, "width": 474, "height": height},
    ]
    if count == 3:
        first.append({"x": 66, "y": 400, "width": 474, "height": height})
    assert result["first"] == first
    assert result["second"] == first[-1:] + first[:-1]
    print(None)


@pytest.mark.parametrize("binding", ["tile-focused-application-windows", "tile-all-windows"])
def test_hotkeys_preserve_a_feasible_configured_portrait_grid(binding):
    """Retain the configured portrait row count when client sizes already fit.

    Parameters: binding - public handler selected during enable.
    Returns: None.
    """
    print(f"binding={binding}")
    result = run_hotkey(binding, 5, portrait=True)
    first = [
        {"x": 66, "y": 32, "width": 744, "height": 951},
        {"x": 816, "y": 32, "width": 744, "height": 951},
        {"x": 66, "y": 992, "width": 744, "height": 951},
        {"x": 816, "y": 992, "width": 744, "height": 951},
        {"x": 66, "y": 1952, "width": 744, "height": 951},
    ]
    assert result["first"] == first
    assert result["second"] == first[-1:] + first[:-1]
    print(None)


@pytest.mark.parametrize("binding", ["tile-focused-application-windows", "tile-all-windows"])
@pytest.mark.parametrize("modern", [False, True])
def test_infeasible_hotkeys_restore_original_geometry_and_window_states(binding, modern):
    """Preserve the original layout and states when client minimums cannot fit.

    Parameters: binding - same-app or mixed-app public handler; modern - GNOME 49+ API shape.
    Returns: None.
    """
    print(f"binding={binding}, modern={modern}")
    result = run_hotkey(binding, 4, infeasible=True, modern=modern)
    assert result["initialStates"] == [
        {"maximized": 0, "fullscreen": False, "minimized": False},
        {"maximized": 3, "fullscreen": False, "minimized": False},
        {"maximized": 0, "fullscreen": True, "minimized": False},
        {"maximized": 0, "fullscreen": False, "minimized": True},
    ]
    assert result["first"] == result["initial"]
    assert result["second"] == result["initial"]
    assert result["firstStates"] == result["initialStates"]
    assert result["secondStates"] == result["initialStates"]
    print(None)


@pytest.mark.parametrize("binding", ["tile-focused-application-windows", "tile-all-windows"])
def test_modern_maximized_windows_tile_and_cycle_through_both_hotkeys(binding):
    """Support GNOME 49+ maximization flags without calling removed signatures.

    Parameters: binding - public keybinding selected during the real enable lifecycle.
    Returns: None.
    """
    print(f"binding={binding}")
    result = run_hotkey(binding, 2, modern=True)
    expected = [
        {"x": 66, "y": 32, "width": 474, "height": 731},
        {"x": 545, "y": 32, "width": 474, "height": 731},
    ]
    assert result["first"] == expected
    assert result["second"] == expected[::-1]
    assert all(state["maximized"] == 0 for state in result["secondStates"])
    print(None)


@pytest.mark.parametrize("arguments", [
    [],
    ["--expect-unchanged", "--key", "super+y"],
    ["--expect-unchanged", "--key", "super+y", "--windows", "invalid"],
    ["--unknown", "--key", "super+y", "--windows", "1", "2"],
])
def test_vm_checker_rejects_malformed_arguments_before_desktop_access(arguments):
    """Reject malformed checker commands without invoking any desktop utilities.

    Parameters: arguments - missing, unknown or incorrectly typed CLI arguments.
    Returns: None.
    """
    print(f"arguments={arguments}")
    completed = subprocess.run(
        [sys.executable, str(ROOT / "tests/check_vm_tiling.py"), *arguments],
        capture_output=True, text=True,
    )
    assert completed.returncode == 2, (arguments, completed.stdout, completed.stderr)
    assert "usage:" in completed.stderr, (arguments, completed.stderr)
    print(None)
