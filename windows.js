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
 *   both resizing and moving, including resizable maximized windows that can
 *   be restored before placement; false otherwise.
 */
function canTileWindow(win) {
  if (!win || typeof win.move_resize_frame !== 'function') {
    return false;
  }
  if (typeof win.allows_resize === 'function' && !win.allows_resize()) {
    // Mutter's allows_resize() is false while fully maximized. The resizeable
    // property describes the underlying capability independently of that state;
    // prepareWindow() will restore accepted windows before moving them.
    const maximized = typeof win.get_maximized === 'function' && win.get_maximized();
    if (!maximized || !win.resizeable || typeof win.unmaximize !== 'function') {
      return false;
    }
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
 * The raw identity keeps distinct WM_CLASS values (for example plain `kitty`
 * versus per-provider `kitty-agent-*` model icons). Same-application tiling
 * groups related terminals via {@link getTileGroupKey} instead of collapsing
 * those classes here, so dock/task-switcher icons stay distinct.
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
 * Normalize an application identity for same-app tiling group membership.
 *
 * Strips the identity source prefix (`wm-class:…`) and maps the kitty terminal
 * family onto a single group key so plain `kitty` and provider-icon classes
 * such as `kitty-agent-cca` / `kitty-agent-ga` tile together under Super+T.
 * Other applications keep their exact lowercased name so unrelated apps never
 * share a tile set.
 *
 * The family rule is prefix-based (`kitty` or `kitty-…`) rather than an
 * enumeration of launcher keys, so new agent brands co-tile without extension
 * changes. Icons remain distinct because real WM_CLASS values are unchanged.
 *
 * @param {string|null|undefined} applicationId - Identifier from
 *   {@link getWindowApplicationId}, or a bare application name.
 * @returns {string|null} Group key used for tile-candidate and preferred-width
 *   matching, or null when the input is not a usable string.
 */
export function getTileGroupKey(applicationId) {
  if (typeof applicationId !== 'string' || !applicationId.trim()) {
    return null;
  }
  const name = applicationId.includes(':')
    ? applicationId.slice(applicationId.indexOf(':') + 1).trim()
    : applicationId.trim();
  if (!name) {
    return null;
  }
  // Kitty terminals (plain + per-provider model icons launched as kitty-agent-*).
  if (name === 'kitty' || name.startsWith('kitty-')) {
    return 'kitty';
  }
  return name;
}

/**
 * Decide whether a window belongs in the tiling set.
 *
 * A candidate must be movable/resizable, live on the target monitor and
 * workspace, be visible in the taskbar, and be a normal top-level window. When
 * an application identity is supplied, the candidate must also share its tile
 * group (exact identity for most apps; the kitty terminal family for plain
 * kitty and `kitty-agent-*` provider icons). Omitting the identity selects all
 * eligible applications on that monitor.
 *
 * @param {Meta.Window} win - Window to test.
 * @param {Meta.Workspace} workspace - Active workspace constraint.
 * @param {number} monitorIndex - Monitor index constraint.
 * @param {string|null} [applicationId=null] - Focused window's application
 *   identity, or null to include every eligible application.
 * @returns {boolean} True when the window should be tiled.
 */
export function isTileCandidate(win, workspace, monitorIndex, applicationId = null) {
  if (!canTileWindow(win)) {
    return false;
  }
  if (applicationId != null) {
    const focusedGroup = getTileGroupKey(applicationId);
    const windowGroup = getTileGroupKey(getWindowApplicationId(win));
    if (!focusedGroup || windowGroup !== focusedGroup) {
      return false;
    }
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
 * Resize a window to its cell and explicitly finish moving its frame origin.
 *
 * X11 clients can accept a constrained size while retaining their old origin
 * after a combined request. Reassert the frame position after resizing.
 * Parameters: win - eligible window; tile - requested x, y, width and height.
 * Returns: the accepted frame rectangle, or null when it cannot be read.
 */
export function placeWindowInTile(win, tile) {
  console.log('placeWindowInTile parameters', { win, tile });
  prepareWindow(win);
  win.move_resize_frame(true, tile.x, tile.y, tile.width, tile.height);
  if (typeof win.move_frame === 'function') {
    win.move_frame(true, tile.x, tile.y);
  }
  const result = typeof win.get_frame_rect === 'function' ? win.get_frame_rect() : null;
  console.log(result);
  return result;
}

/**
 * Capture the geometry and states a tiling attempt may change.
 * Parameters: win - eligible window to snapshot before any placement.
 * Returns: the original frame, maximization flags, fullscreen and minimized states.
 */
export function captureWindowState(win) {
  console.log('captureWindowState parameters', { win });
  const result = {
    frame: typeof win.get_frame_rect === 'function' ? win.get_frame_rect() : null,
    maximized: typeof win.get_maximized === 'function' ? win.get_maximized() : 0,
    fullscreen: typeof win.is_fullscreen === 'function' ? win.is_fullscreen() : Boolean(win.fullscreen),
    minimized: Boolean(win.minimized),
  };
  console.log(result);
  return result;
}

/**
 * Restore a window after client limits reject every candidate grid.
 * Parameters: win - eligible window; state - snapshot taken before the attempt.
 * Returns: undefined after restoring its frame and previous window states.
 */
export function restoreWindowState(win, state) {
  console.log('restoreWindowState parameters', { win, state });
  if (state.frame) {
    placeWindowInTile(win, state.frame);
  }
  if (state.maximized && typeof win.maximize === 'function') {
    win.maximize(state.maximized);
  }
  if (state.fullscreen && typeof win.make_fullscreen === 'function') {
    win.make_fullscreen();
  }
  if (state.minimized && typeof win.minimize === 'function') {
    win.minimize();
  }
  console.log(undefined);
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
