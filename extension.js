/**
 * extension.js — GNOME Shell extension entry point for automatic window tiling.
 *
 * Tiles every window that matches the focused application on the focused
 * window's current workspace and monitor into a balanced grid, triggered by a
 * user-configurable keyboard accelerator.
 *
 * Functions/Classes:
 * - log: centralized, level-aware logging helper with a consistent prefix.
 * - getApplicationPreferredWidth: per-application layout width lookup.
 * - getFocusWindow: resolve the currently focused, tileable window.
 * - canTileWindow: predicate for whether a window may be moved/resized.
 * - getWindowApplicationId: derive a stable application identity for a window.
 * - isTileCandidate: predicate for whether a window belongs in the tiling set.
 * - prepareWindow: clear maximized/fullscreen/minimized state before tiling.
 * - raiseWindow: raise and mark a window as the most recent.
 * - tileFocusedApplicationWindows: keybinding handler that performs the tiling.
 * - AutomaticWindowTilingExtension: extension lifecycle (enable/disable).
 *
 * Usage: bound to an accelerator via the bundled gsettings schema; pressing the
 * accelerator invokes tileFocusedApplicationWindows.
 */

import Shell from 'gi://Shell';
import Meta from 'gi://Meta';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { calculateTileRect, chooseGrid } from './layout.js';

const TILE_KEY = 'tile-focused-application-windows';
const LOG_PREFIX = 'automatic-window-tiling';

/**
 * Centralized logging helper.
 *
 * GNOME Shell routes console output to the systemd journal
 * (`journalctl --user -o cat /usr/bin/gnome-shell`), so each method prefixes
 * messages with a fixed tag and severity to keep logs searchable. Severity
 * methods map onto the console levels available inside the Shell sandbox.
 *
 * @type {{info: function(string): void, warn: function(string): void, error: function(string): void}}
 */
const log = {
  /**
   * Log an informational message.
   * @param {string} message - Human-readable message body.
   * @returns {void}
   */
  info(message) {
    console.log(`${LOG_PREFIX}: ${message}`);
  },
  /**
   * Log a warning message.
   * @param {string} message - Human-readable message body.
   * @returns {void}
   */
  warn(message) {
    console.warn(`${LOG_PREFIX}: ${message}`);
  },
  /**
   * Log an error message.
   * @param {string} message - Human-readable message body.
   * @returns {void}
   */
  error(message) {
    console.error(`${LOG_PREFIX}: ${message}`);
  },
};

// Optional per-application preferred widths. The value controls grid density,
// but is not a hard size cap: when fewer windows are present, their cells
// expand to consume the full work area. Matching is done on the identifier
// suffix so any identity source (wm-class, gtk-application-id, ...) resolving
// to the same application name is covered.
const APPLICATION_PREFERRED_WIDTHS = [
  { match: 'kitty', preferredWidth: 1300 },
];

/**
 * Look up the configured layout width for an application identifier.
 *
 * The identifier may be prefixed by its identity source (for example
 * `wm-class:kitty`); only the suffix after the first colon is matched against
 * the configured application names.
 *
 * @param {string} applicationId - Identifier from getWindowApplicationId.
 * @returns {number|null} The preferred tile width, or null when no preference
 *   is configured or the input is not a string.
 */
function getApplicationPreferredWidth(applicationId) {
  if (typeof applicationId !== 'string') {
    return null;
  }
  const name = applicationId.includes(':')
    ? applicationId.slice(applicationId.indexOf(':') + 1)
    : applicationId;
  for (const preference of APPLICATION_PREFERRED_WIDTHS) {
    if (name === preference.match) {
      return preference.preferredWidth;
    }
  }
  return null;
}

/**
 * Resolve the currently focused window when it is eligible for tiling.
 *
 * Windows that skip the taskbar (panels, docks, notifications) are ignored.
 *
 * @returns {Meta.Window|null} The focused taskbar window, or null when there is
 *   no focus or it should be skipped.
 */
function getFocusWindow() {
  const win = global.display.focus_window;
  const skipTaskbar = typeof win?.is_skip_taskbar === 'function'
    ? win.is_skip_taskbar()
    : win?.skip_taskbar;

  return win && !skipTaskbar ? win : null;
}

/**
 * Determine whether a window can be moved and resized by the tiler.
 *
 * @param {Meta.Window} win - Candidate window.
 * @returns {boolean} True when the window exposes move_resize_frame and permits
 *   both resizing and moving; false otherwise.
 */
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

/**
 * Derive a stable application identity for a window.
 *
 * Identity sources are tried in order of specificity; the first non-empty value
 * is returned, prefixed by its source so callers can compare like-for-like.
 * Falls back to the Shell window tracker's resolved app id.
 *
 * @param {Meta.Window} win - Window to identify.
 * @returns {string|null} A lowercased `source:value` identifier, or null when no
 *   identity could be determined.
 */
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

/**
 * Decide whether a window belongs in the tiling set.
 *
 * A candidate must be movable/resizable, share the target application identity,
 * live on the target monitor and workspace, be visible in the taskbar, and be a
 * normal top-level window.
 *
 * @param {Meta.Window} win - Window to test.
 * @param {Meta.Workspace} workspace - Active workspace constraint.
 * @param {number} monitorIndex - Monitor index constraint.
 * @param {string} applicationId - Application identity to match.
 * @returns {boolean} True when the window should be tiled.
 */
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

/**
 * Clear window states that would prevent precise tiling.
 *
 * Unmaximizes, unfullscreens, and unminimizes the window where the relevant
 * methods are available so a subsequent move_resize_frame takes effect.
 *
 * @param {Meta.Window} win - Window to normalize.
 * @returns {void}
 */
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

/**
 * Raise a window and mark it as the most recently used on its workspace.
 *
 * Prefers the workspace-scoped API and falls back to the global variant when
 * the former is unavailable.
 *
 * @param {Meta.Window} win - Window to raise.
 * @param {Meta.Workspace} workspace - Workspace context for the raise.
 * @returns {void}
 */
function raiseWindow(win, workspace) {
  if (typeof win.raise_and_make_recent_on_workspace === 'function') {
    win.raise_and_make_recent_on_workspace(workspace);
  } else if (typeof win.raise_and_make_recent === 'function') {
    win.raise_and_make_recent();
  }
}

/**
 * Keybinding handler: tile all windows matching the focused application.
 *
 * Collects the focused application's windows on the active workspace and
 * monitor, orders them with the focused window first, computes a grid, and
 * moves each window into its full cell. Errors are caught and logged so a
 * failure never crashes the Shell.
 *
 * @returns {void}
 */
function tileFocusedApplicationWindows() {
  const focusedWindow = getFocusWindow();
  const applicationId = focusedWindow ? getWindowApplicationId(focusedWindow) : null;
  if (!focusedWindow || !applicationId || typeof focusedWindow.get_monitor !== 'function') {
    log.info('no tileable focused window; ignoring tiling request');
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
      log.info(`nothing to tile (windows=${windows.length} workArea=${workArea.width}x${workArea.height})`);
      return;
    }

    const preferredWidth = getApplicationPreferredWidth(applicationId);
    log.info(`applicationId=${applicationId} preferredWidth=${preferredWidth} windows=${windows.length} workArea=${workArea.width}x${workArea.height}`);
    const { rows, columns } = chooseGrid(windows.length, workArea, preferredWidth);
    for (let index = 0; index < windows.length; index++) {
      const win = windows[index];
      const tile = calculateTileRect(index, rows, columns, workArea);

      prepareWindow(win);
      win.move_resize_frame(true, tile.x, tile.y, tile.width, tile.height);
      const frame = typeof win.get_frame_rect === 'function' ? win.get_frame_rect() : null;
      log.info(`requested ${tile.width}x${tile.height} -> actual ${frame ? `${frame.width}x${frame.height}` : 'unknown'}`);
    }

    raiseWindow(focusedWindow, workspace);
  } catch (error) {
    log.error(`failed to tile application windows: ${error}`);
  }
}

/**
 * GNOME Shell extension lifecycle for the automatic window tiler.
 *
 * Registers the tiling keybinding on enable and removes it on disable, reading
 * the accelerator from the extension's gsettings schema.
 *
 * @extends Extension
 */
export default class AutomaticWindowTilingExtension extends Extension {
  /**
   * Activate the extension: load settings and bind the tiling accelerator.
   * @returns {void}
   */
  enable() {
    this._settings = this.getSettings();
    Main.wm.addKeybinding(
      TILE_KEY,
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      tileFocusedApplicationWindows,
    );
    log.info('enabled; tiling keybinding registered');
  }

  /**
   * Deactivate the extension: remove the keybinding and release settings.
   * @returns {void}
   */
  disable() {
    Main.wm.removeKeybinding(TILE_KEY);
    this._settings = null;
    log.info('disabled; tiling keybinding removed');
  }
}
