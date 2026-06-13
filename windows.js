/**
 * GNOME Shell window selection and state management for automatic tiling.
 *
 * This module owns application identity, tile eligibility, and the state
 * transitions needed before and after a window is moved into a tile.
 */

import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

/**
 * Resolve the currently focused window when it is eligible for tiling.
 *
 * Windows that skip the taskbar (panels, docks, notifications) are ignored.
 *
 * @returns {Meta.Window|null} The focused taskbar window, or null when there is
 *   no focus or it should be skipped.
 */
export function getFocusWindow() {
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
export function canTileWindow(win) {
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
export function getWindowApplicationId(win) {
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
export function isTileCandidate(win, workspace, monitorIndex, applicationId) {
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
export function prepareWindow(win) {
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
export function raiseWindow(win, workspace) {
  if (typeof win.raise_and_make_recent_on_workspace === 'function') {
    win.raise_and_make_recent_on_workspace(workspace);
  } else if (typeof win.raise_and_make_recent === 'function') {
    win.raise_and_make_recent();
  }
}
