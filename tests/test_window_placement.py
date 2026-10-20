"""Public hotkey regressions for the observed GNOME Terminal X11 geometry."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


def run_hotkey(binding, count, portrait=False):
    """Run the real extension lifecycle and hotkey with constrained X11 windows.

    Parameters: binding - public keybinding name; count - number of terminal windows;
    portrait - use a portrait monitor with a configured 900px minimum tile height.
    Returns: the frames after the first and second public hotkey invocations.
    """
    print(f"binding={binding}, count={count}, portrait={portrait}")
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
const workspace = { get_work_area_for_monitor: () => workArea, list_windows: () => windows };
const makeWindow = id => {
  const window = {
    frame: { x: id === 1 ? 66 : 358, y: id === 1 ? 32 : 37, width: 474, height: 731 },
    get_gtk_application_id: () => 'org.gnome.terminal',
    get_monitor: () => 0, get_workspace: () => workspace,
    get_stable_sequence: () => id, get_window_type: () => Meta.WindowType.NORMAL,
    is_skip_taskbar: () => false, allows_resize: () => true, allows_move: () => true,
    get_maximized: () => 0, unmake_fullscreen: () => {}, unminimize: () => {},
    get_frame_rect: () => ({ ...window.frame }),
    // Observed VM behavior: resizing honors terminal increments/minimums, but
    // the combined request leaves the old position until an explicit move.
    move_resize_frame: (user, x, y, width, height) => {
      window.frame.width = Math.max(354, Math.floor((width - 14) / 10) * 10 + 14);
      window.frame.height = Math.max(93, Math.floor((height - 49) / 22) * 22 + 49);
    },
    move_frame: (user, x, y) => { window.frame.x = x; window.frame.y = y; },
    raise_and_make_recent_on_workspace: () => {},
  };
  return window;
};
const windows = Array.from({ length: WINDOW_COUNT }, (_, index) => makeWindow(index + 1));
global.display = { focus_window: windows[0] };
global.workspace_manager = { get_active_workspace: () => workspace };
'''.replace("WINDOW_COUNT", str(count)).replace("AREA_WIDTH", str(1500 if portrait else 958)).replace("AREA_HEIGHT", str(3840 if portrait else 736)).replace("PORTRAIT_MINIMUM", str(900 if portrait else 0))
    invocation = f'''
const extension = new AutomaticWindowTilingExtension();
extension.enable();
handlers.get({json.dumps(binding)})();
const first = windows.map(window => ({{ ...window.frame }}));
handlers.get({json.dumps(binding)})();
const second = windows.map(window => ({{ ...window.frame }}));
extension.disable();
process.stdout.write(JSON.stringify({{ first, second }}));
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
