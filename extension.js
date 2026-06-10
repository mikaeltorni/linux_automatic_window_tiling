import Shell from 'gi://Shell';
import Meta from 'gi://Meta';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const TILE_KEY = 'tile-focused-application-windows';

function getFocusWindow() {
  const win = global.display.focus_window;
  const skipTaskbar = typeof win?.is_skip_taskbar === 'function'
    ? win.is_skip_taskbar()
    : win?.skip_taskbar;

  return win && !skipTaskbar ? win : null;
}

function canTileWindow(win) {
  if (!win || typeof win.move_resize_frame !== 'function') {
    return false;
  }
  if (typeof win.allows_resize === 'function' && !win.allows_resize()) {
    return false;
  }
  if (typeof win.allows_move === 'function' && !win.allows_move()) {
    return false;
  }
  return true;
}

function getWindowApplicationId(win) {
  const identityMethods = [
    ['gtk-application-id', 'get_gtk_application_id'],
    ['sandboxed-app-id', 'get_sandboxed_app_id'],
    ['wm-class', 'get_wm_class'],
    ['wm-class-instance', 'get_wm_class_instance'],
  ];
  for (const [prefix, method] of identityMethods) {
    const value = typeof win[method] === 'function' ? win[method]() : null;
    if (typeof value === 'string' && value.trim()) {
      return `${prefix}:${value.trim().toLowerCase()}`;
    }
  }

  const app = Shell.WindowTracker.get_default().get_window_app(win);
  const appId = app ? app.get_id() : null;
  return typeof appId === 'string' && appId.trim()
    ? `app:${appId.trim().toLowerCase()}`
    : null;
}

function isTileCandidate(win, workspace, monitorIndex, applicationId) {
  if (!canTileWindow(win) || getWindowApplicationId(win) !== applicationId) {
    return false;
  }
  if (typeof win.get_monitor !== 'function' || win.get_monitor() !== monitorIndex) {
    return false;
  }
  if (typeof win.located_on_workspace === 'function' && !win.located_on_workspace(workspace)) {
    return false;
  }

  const skipTaskbar = typeof win.is_skip_taskbar === 'function'
    ? win.is_skip_taskbar()
    : win.skip_taskbar;
  if (skipTaskbar) {
    return false;
  }

  return typeof win.get_window_type !== 'function'
    || win.get_window_type() === Meta.WindowType.NORMAL;
}

function chooseGrid(windowCount, workArea) {
  if (windowCount === 1) {
    return { rows: 1, columns: 1 };
  }
  if (windowCount === 2) {
    return { rows: 1, columns: 2 };
  }

  let best = null;
  for (let rows = 1; rows <= windowCount; rows++) {
    const columns = Math.ceil(windowCount / rows);
    const emptyCells = rows * columns - windowCount;
    const cellWidth = workArea.width / columns;
    const cellHeight = workArea.height / rows;
    const shapePenalty = Math.abs(Math.log(cellWidth / cellHeight));
    const score = emptyCells * 2 + shapePenalty;

    if (!best || score < best.score) {
      best = { rows, columns, score };
    }
  }

  return { rows: best.rows, columns: best.columns };
}

function prepareWindow(win) {
  if (typeof win.get_maximized === 'function') {
    const maximized = win.get_maximized();
    if (maximized) {
      win.unmaximize(maximized);
    }
  }
  if (typeof win.unmake_fullscreen === 'function') {
    win.unmake_fullscreen();
  }
  if (typeof win.unminimize === 'function') {
    win.unminimize();
  }
}

function raiseWindow(win, workspace) {
  if (typeof win.raise_and_make_recent_on_workspace === 'function') {
    win.raise_and_make_recent_on_workspace(workspace);
  } else if (typeof win.raise_and_make_recent === 'function') {
    win.raise_and_make_recent();
  }
}

function tileFocusedApplicationWindows() {
  const focusedWindow = getFocusWindow();
  const applicationId = focusedWindow ? getWindowApplicationId(focusedWindow) : null;
  if (!focusedWindow || !applicationId || typeof focusedWindow.get_monitor !== 'function') {
    return;
  }

  try {
    const workspace = global.workspace_manager.get_active_workspace();
    const monitorIndex = focusedWindow.get_monitor();
    const workArea = workspace.get_work_area_for_monitor(monitorIndex);
    const windows = workspace.list_windows()
      .filter(win => isTileCandidate(win, workspace, monitorIndex, applicationId))
      .sort((left, right) => left.get_stable_sequence() - right.get_stable_sequence());

    const focusedIndex = windows.indexOf(focusedWindow);
    if (focusedIndex > 0) {
      windows.splice(focusedIndex, 1);
      windows.unshift(focusedWindow);
    }
    if (windows.length === 0 || workArea.width <= 0 || workArea.height <= 0) {
      return;
    }

    const { rows, columns } = chooseGrid(windows.length, workArea);
    for (let index = 0; index < windows.length; index++) {
      const win = windows[index];
      const row = Math.floor(index / columns);
      const column = index % columns;
      const x1 = workArea.x + Math.floor(column * workArea.width / columns);
      const x2 = workArea.x + Math.floor((column + 1) * workArea.width / columns);
      const y1 = workArea.y + Math.floor(row * workArea.height / rows);
      const y2 = workArea.y + Math.floor((row + 1) * workArea.height / rows);

      prepareWindow(win);
      win.move_resize_frame(true, x1, y1, x2 - x1, y2 - y1);
    }

    raiseWindow(focusedWindow, workspace);
  } catch (error) {
    console.error(`automatic-window-tiling: failed to tile application windows: ${error}`);
  }
}

export default class AutomaticWindowTilingExtension extends Extension {
  enable() {
    this._settings = this.getSettings();
    Main.wm.addKeybinding(
      TILE_KEY,
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      tileFocusedApplicationWindows,
    );
  }

  disable() {
    Main.wm.removeKeybinding(TILE_KEY);
    this._settings = null;
  }
}
