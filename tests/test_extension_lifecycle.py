"""Characterize public D-Bus placement and resource teardown before refactoring."""

from js_runtime import run_extension


def test_dbus_batch_preserves_focus_groups_once_and_releases_lifecycle_resources():
    """Keep background placement stable while cleaning every registered resource.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    stubs = r'''
const console = { log: () => {}, warn: () => {}, error: message => { throw new Error(message); } };
const Meta = { WindowType: { NORMAL: 1 }, KeyBindingFlags: { NONE: 0 } };
const Shell = { ActionMode: { NORMAL: 1 } };
const handlers = new Map();
const registered = [];
const Main = { wm: {
  addKeybinding: (key, settings, flags, mode, handler) => { registered.push(key); handlers.set(key, handler); },
  removeKeybinding: key => handlers.delete(key),
} };
const settings = { get_strv: () => ['kitty:1300'], get_int: () => 0 };
const Extension = class {};
Extension.prototype.getSettings = () => settings;
let dbus;
let exported = false;
const unowned = [];
const Gio = {
  DBusExportedObject: { wrapJSObject: (xml, callbacks) => {
    dbus = callbacks;
    return { export: () => { exported = true; }, unexport: () => { exported = false; } };
  } },
  DBus: { session: {} }, BusNameOwnerFlags: { NONE: 0 },
  bus_own_name_on_connection: () => 9, bus_unown_name: id => unowned.push(id),
};
const areas = [
  { x: 0, y: 32, width: 1200, height: 800 },
  { x: 1200, y: 32, width: 1200, height: 800 },
];
const raises = [];
const moves = { 10: 0, 11: 0, 12: 0, 13: 0 };
const workspaces = [0, 1].map(index => ({
  index: () => index,
  get_work_area_for_monitor: monitor => areas[monitor],
  list_windows: () => windows.filter(window => window.workspace === index),
}));
const windows = [10, 11, 12, 13].map(id => {
  const window = {
    workspace: id === 12 ? 1 : 0,
    frame: { x: 20, y: 50, width: 200, height: 100 },
    get_gtk_application_id: () => id === 13 ? 'org.mozilla.firefox' : 'org.gnome.terminal',
    get_monitor: () => id === 12 ? 1 : 0,
    get_workspace: () => workspaces[window.workspace],
    get_description: () => `0x${id.toString(16)}`,
    get_stable_sequence: () => id, get_window_type: () => 1,
    allows_move: () => true, allows_resize: () => true, is_skip_taskbar: () => false,
    get_maximized: () => 0, unmake_fullscreen: () => {}, unminimize: () => {},
    get_frame_rect: () => ({ ...window.frame }),
    move_resize_frame: (user, x, y, width, height) => {
      moves[id]++;
      window.frame = { x, y, width, height };
    },
    move_frame: (user, x, y) => { window.frame.x = x; window.frame.y = y; },
    raise_and_make_recent_on_workspace: () => raises.push(id),
  };
  return window;
});
global.display = { focus_window: windows[2] };
global.workspace_manager = { get_active_workspace: () => workspaces[1] };
global.get_window_actors = () => windows.map(window => ({ get_meta_window: () => window }));
'''
    invocation = r'''
const extension = new AutomaticWindowTilingExtension();
extension.enable();
const active = { exported, handlers: handlers.size };
dbus.TileWindowGroup('10');
const first = windows.map(window => ({ ...window.frame }));
dbus.TileWindowGroup('10');
const repeated = windows.map(window => ({ ...window.frame }));
dbus.TileWindowGroups(['10', '10', '12', 'invalid', '0']);
const batch = windows.map(window => ({ ...window.frame }));
extension.disable();
process.stdout.write(JSON.stringify({
  registered, active, first, repeated, batch, moves, raises,
  focused: global.display.focus_window.get_stable_sequence(),
  activeWorkspace: global.workspace_manager.get_active_workspace().index(),
  disabled: { exported, handlers: handlers.size, unowned },
}));
'''
    result = run_extension(stubs, invocation)
    original = {"x": 20, "y": 50, "width": 200, "height": 100}
    first = [
        {"x": 0, "y": 32, "width": 600, "height": 800},
        {"x": 600, "y": 32, "width": 600, "height": 800},
        original, original,
    ]
    assert result["registered"] == ["tile-focused-application-windows", "tile-all-windows"]
    assert result["active"] == {"exported": True, "handlers": 2}
    assert result["first"] == first
    assert result["repeated"] == first
    assert result["batch"] == first[:2] + [
        {"x": 1200, "y": 32, "width": 1200, "height": 800}, original,
    ]
    assert result["moves"] == {"10": 3, "11": 3, "12": 1, "13": 0}
    assert result["raises"] == []
    assert result["focused"] == 12 and result["activeWorkspace"] == 1
    assert result["disabled"] == {"exported": False, "handlers": 0, "unowned": [9]}
    print(None)


def test_reenabled_extension_reads_its_current_settings_without_shared_state():
    """Apply live width changes and keep separate extension settings independent.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    stubs = r'''
const console = { log: () => {}, warn: () => {}, error: message => { throw new Error(message); } };
const Meta = { WindowType: { NORMAL: 1 }, KeyBindingFlags: { NONE: 0 } };
const Shell = { ActionMode: { NORMAL: 1 } };
const handlers = new Map();
const Main = { wm: {
  addKeybinding: (key, settings, flags, mode, handler) => handlers.set(key, handler),
  removeKeybinding: key => handlers.delete(key),
} };
const Extension = class {};
const Gio = {
  DBusExportedObject: { wrapJSObject: () => ({ export: () => {}, unexport: () => {} }) },
  DBus: { session: {} }, BusNameOwnerFlags: { NONE: 0 },
  bus_own_name_on_connection: () => 1, bus_unown_name: () => {},
};
const workArea = { x: 0, y: 0, width: 3000, height: 1000 };
const workspace = { get_work_area_for_monitor: () => workArea, list_windows: () => windows };
const windows = [0, 1, 2].map(id => {
  const window = {
    frame: { x: 0, y: 0, width: 300, height: 300 },
    get_wm_class: () => 'kitty', get_monitor: () => 0,
    get_stable_sequence: () => id, get_window_type: () => 1,
    allows_move: () => true, allows_resize: () => true, is_skip_taskbar: () => false,
    get_frame_rect: () => ({ ...window.frame }),
    move_resize_frame: (user, x, y, width, height) => { window.frame = { x, y, width, height }; },
  };
  return window;
});
global.display = { focus_window: windows[0] };
global.workspace_manager = { get_active_workspace: () => workspace };
'''
    invocation = r'''
let width = 1500;
const firstExtension = new AutomaticWindowTilingExtension();
firstExtension.getSettings = () => ({ get_strv: () => [`kitty:${width}`], get_int: () => 0 });
firstExtension.enable();
handlers.get('tile-focused-application-windows')();
const initial = windows.map(window => ({ ...window.frame }));
width = 3000;
handlers.get('tile-focused-application-windows')();
const updated = windows.map(window => ({ ...window.frame }));
const secondExtension = new AutomaticWindowTilingExtension();
secondExtension.getSettings = () => ({ get_strv: () => ['kitty:1000'], get_int: () => 0 });
secondExtension.enable();
handlers.get('tile-focused-application-windows')();
const separate = windows.map(window => ({ ...window.frame }));
secondExtension.disable();
firstExtension.enable();
handlers.get('tile-focused-application-windows')();
const reenabled = windows.map(window => ({ ...window.frame }));
firstExtension.disable();
process.stdout.write(JSON.stringify({ initial, updated, separate, reenabled }));
'''
    result = run_extension(stubs, invocation)
    assert result["initial"] == [
        {"x": 0, "y": 0, "width": 1500, "height": 500},
        {"x": 1500, "y": 0, "width": 1500, "height": 500},
        {"x": 0, "y": 500, "width": 1500, "height": 500},
    ]
    assert result["updated"] == [
        {"x": 0, "y": 0, "width": 3000, "height": 333},
        {"x": 0, "y": 333, "width": 3000, "height": 333},
        {"x": 0, "y": 666, "width": 3000, "height": 334},
    ]
    assert result["separate"] == [
        {"x": 0, "y": 0, "width": 1000, "height": 1000},
        {"x": 1000, "y": 0, "width": 1000, "height": 1000},
        {"x": 2000, "y": 0, "width": 1000, "height": 1000},
    ]
    assert result["reenabled"] == result["updated"]
    print(None)
