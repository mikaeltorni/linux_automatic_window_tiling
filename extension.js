/**
 * extension.js — GNOME Shell extension entry point for automatic window tiling.
 *
 * Tiles windows on the focused window's current workspace and monitor into a
 * balanced grid. The original accelerator limits the set to the focused
 * application's tile group; a second accelerator includes every eligible
 * application on that monitor.
 *
 * Functions/Classes:
 * - log: centralized, level-aware logging helper with a consistent prefix.
 * - getApplicationPreferredWidth: per-application layout width lookup.
 * - tileFocusedApplicationWindows: same-application tiling handler.
 * - tileWindowGroup: background same-application tiling by X11 window id.
 * - tileAllWindows: all-application tiling handler for the focused monitor.
 * - AutomaticWindowTilingExtension: extension lifecycle (enable/disable).
 *
 * Usage: bound to an accelerator via the bundled gsettings schema; pressing the
 * accelerator invokes one of the two tiling handlers.
 */

import Shell from 'gi://Shell';
import Meta from 'gi://Meta';
import Gio from 'gi://Gio';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { calculateTileRect, chooseGrid, cycleTiledOrder, detectTiledOrder } from './layout.js';
import {
  getFocusWindow,
  getTileGroupKey,
  getWindowApplicationId,
  isTileCandidate,
  prepareWindow,
  raiseWindow,
} from './windows.js';

const TILE_KEY = 'tile-focused-application-windows';
const ALL_TILE_KEY = 'tile-all-windows';
const APP_WIDTHS_KEY = 'application-preferred-widths';
const PORTRAIT_MIN_HEIGHT_KEY = 'portrait-minimum-tile-height';
const LOG_PREFIX = 'automatic-window-tiling';
const DBUS_BUS_NAME = 'org.gnome.shell.extensions.AutomaticWindowTiling';
const DBUS_OBJECT_PATH = '/org/gnome/shell/extensions/automatic_window_tiling';
const DBUS_INTERFACE_XML = `
<node name="/org/gnome/shell/extensions/automatic_window_tiling">
  <interface name="org.gnome.shell.extensions.AutomaticWindowTiling">
    <method name="TileWindowGroup">
      <arg type="s" name="windowId" direction="in"/>
    </method>
    <method name="TileWindowGroups">
      <arg type="as" name="windowIds" direction="in"/>
    </method>
  </interface>
</node>`;

// Live extension settings, populated on enable() so the keybinding handler can
// read the user-customized per-application widths and portrait packing minimum.
let extensionSettings = null;

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

// Default per-application preferred widths, used when the gsettings key is
// unavailable (for example outside the Shell during tests). The installer seeds
// the same default into the `application-preferred-widths` schema key, where it
// becomes fully user-customizable. The value controls grid density but is not a
// hard size cap: when fewer windows are present, their cells expand to consume
// the full work area.
const DEFAULT_APPLICATION_PREFERRED_WIDTHS = ['kitty:1300'];

/**
 * Parse `application-preferred-widths` entries into matchers.
 *
 * Each entry has the form `application-name:width-in-pixels`. Malformed entries
 * (missing colon, non-positive or non-numeric width) are skipped so a bad
 * customization never breaks tiling.
 *
 * @param {string[]} entries - Raw `name:width` strings from gsettings.
 * @returns {Array<{match: string, preferredWidth: number}>} Parsed matchers.
 */
function parseApplicationPreferredWidths(entries) {
  const matchers = [];
  if (!Array.isArray(entries)) {
    return matchers;
  }
  for (const entry of entries) {
    if (typeof entry !== 'string') {
      continue;
    }
    const separator = entry.lastIndexOf(':');
    if (separator <= 0) {
      continue;
    }
    const match = entry.slice(0, separator).trim();
    const preferredWidth = Number.parseInt(entry.slice(separator + 1), 10);
    if (match && Number.isFinite(preferredWidth) && preferredWidth > 0) {
      matchers.push({ match, preferredWidth });
    }
  }
  return matchers;
}

/**
 * Look up the configured layout width for an application identifier.
 *
 * The identifier may be prefixed by its identity source (for example
 * `wm-class:kitty` or `wm-class:kitty-agent-cca`). Matching uses the same
 * tile-group key as Super+T candidate selection, so the configured `kitty:…`
 * preferred width applies to plain kitty and every per-provider model-icon
 * class without listing each launcher key.
 *
 * @param {string} applicationId - Identifier from getWindowApplicationId.
 * @param {Array<{match: string, preferredWidth: number}>} matchers - Parsed
 *   per-application width preferences.
 * @returns {number|null} The preferred tile width, or null when no preference
 *   is configured or the input is not a string.
 */
function getApplicationPreferredWidth(applicationId, matchers) {
  const groupKey = getTileGroupKey(applicationId);
  if (!groupKey) {
    return null;
  }
  for (const preference of matchers) {
    if (groupKey === preference.match) {
      return preference.preferredWidth;
    }
  }
  return null;
}

/**
 * Tile a selected set of windows on the anchor window's workspace and monitor.
 *
 * When `applicationId` is set, collects that application's tile-group peers
 * (plain kitty and per-provider `kitty-agent-*` windows share one group; other
 * apps stay exact-identity only). When it is null, collects every eligible
 * taskbar-visible normal window on the focused monitor. The latter deliberately
 * ignores per-application width preferences so mixed applications receive one
 * balanced grid sized to the monitor as a whole.
 *
 * Windows are ordered with the anchor window first, and each is moved into its
 * full cell. When the windows already fill the grid, the current on-screen
 * order is rotated by one cell instead of being re-applied, so repeatedly
 * tapping either accelerator cycles through the possible arrangements.
 *
 * @param {string} mode - Log label describing the tiling mode.
 * @param {Meta.Window|null} anchorWindow - Window selecting the tile group and monitor.
 * @param {string|null} applicationId - Anchor application identity for the
 *   original same-application mode, or null for all applications.
 * @param {boolean} background - Use the anchor workspace and preserve focus/order.
 * @returns {void}
 */
function tileWindowsOnMonitor(mode, anchorWindow, applicationId = null, background = false) {
  if (!anchorWindow || typeof anchorWindow.get_monitor !== 'function') {
    log.info(`no tileable focused window; ignoring ${mode} tiling request`);
    return;
  }

  try {
    const widthMatchers = parseApplicationPreferredWidths(
      extensionSettings ? extensionSettings.get_strv(APP_WIDTHS_KEY) : DEFAULT_APPLICATION_PREFERRED_WIDTHS,
    );
    const portraitMinimumTileHeight = extensionSettings
      ? extensionSettings.get_int(PORTRAIT_MIN_HEIGHT_KEY)
      : 1080;
    const workspace = background
      ? anchorWindow.get_workspace()
      : global.workspace_manager.get_active_workspace();
    const monitorIndex = anchorWindow.get_monitor();
    const workArea = workspace.get_work_area_for_monitor(monitorIndex);
    const windows = workspace.list_windows()
      .filter(win => isTileCandidate(win, workspace, monitorIndex, applicationId))
      .sort((left, right) => left.get_stable_sequence() - right.get_stable_sequence());

    const focusedIndex = windows.indexOf(anchorWindow);
    if (focusedIndex > 0) {
      windows.splice(focusedIndex, 1);
      windows.unshift(anchorWindow);
    }
    if (windows.length === 0 || workArea.width <= 0 || workArea.height <= 0) {
      log.info(`nothing to tile (windows=${windows.length} workArea=${workArea.width}x${workArea.height})`);
      return;
    }

    const preferredWidth = applicationId
      ? getApplicationPreferredWidth(applicationId, widthMatchers)
      : null;
    const tileGroup = applicationId ? getTileGroupKey(applicationId) : 'all-applications';
    log.info(
      `mode=${mode} applicationId=${applicationId ?? 'all'} tileGroup=${tileGroup} preferredWidth=${preferredWidth} windows=${windows.length} workArea=${workArea.width}x${workArea.height}`,
    );
    const { rows, columns } = chooseGrid(windows.length, workArea, preferredWidth, portraitMinimumTileHeight);
    const frames = windows.map(win => (typeof win.get_frame_rect === 'function' ? win.get_frame_rect() : null));
    const tiledOrder = background ? null : detectTiledOrder(frames, rows, columns, workArea);
    const ordered = tiledOrder
      ? cycleTiledOrder(tiledOrder).map(windowIndex => windows[windowIndex])
      : windows;
    log.info(`grid=${rows}x${columns} mode=${tiledOrder ? 'cycle' : 'tile'}`);

    for (let index = 0; index < ordered.length; index++) {
      const win = ordered[index];
      const tile = calculateTileRect(index, rows, columns, workArea);

      prepareWindow(win);
      win.move_resize_frame(true, tile.x, tile.y, tile.width, tile.height);
      const frame = typeof win.get_frame_rect === 'function' ? win.get_frame_rect() : null;
      log.info(`requested ${tile.width}x${tile.height} -> actual ${frame ? `${frame.width}x${frame.height}` : 'unknown'}`);
    }

    if (!background) {
      raiseWindow(anchorWindow, workspace);
    }
  } catch (error) {
    log.error(`failed to tile application windows: ${error}`);
  }
}

/** Tile each actual workspace/monitor represented by X11 windows once. */
function tileWindowGroups(windowIds) {
  const actors = global.get_window_actors();
  const anchors = new Map();
  for (const windowId of windowIds) {
    const xid = /^(?:0x[0-9a-f]+|[0-9]+)$/i.test(windowId) ? Number(windowId) : NaN;
    if (!Number.isSafeInteger(xid) || xid <= 0) {
      log.warn(`invalid window id for background tiling: ${windowId}`);
      continue;
    }
    // Mutter exposes X11 IDs in get_description() as "0x..."; Wayland
    // descriptions use a different format and cannot match these IDs.
    const anchor = actors
      .map(actor => actor.get_meta_window())
      .find(win => win && typeof win.get_description === 'function' &&
        /^0x[0-9a-f]+$/i.test(win.get_description()) && Number(win.get_description()) === xid);
    const applicationId = anchor ? getWindowApplicationId(anchor) : null;
    const workspace = anchor?.get_workspace();
    if (!workspace || !applicationId) {
      log.warn(`window unavailable for background tiling: ${windowId}`);
      continue;
    }
    const key = `${workspace.index()}:${anchor.get_monitor()}:${getTileGroupKey(applicationId)}`;
    anchors.set(key, [anchor, applicationId]);
  }
  for (const [anchor, applicationId] of anchors.values()) {
    tileWindowsOnMonitor('background application', anchor, applicationId, true);
  }
}

/** Tile the supplied X11 window's application peers without changing focus. */
function tileWindowGroup(windowId) {
  tileWindowGroups([windowId]);
}

/**
 * Keybinding handler: tile all eligible applications on the focused monitor.
 *
 * The focused window supplies the target monitor and active workspace; the
 * candidate filter then includes every movable, resizable, normal taskbar
 * window in that same monitor/workspace, regardless of application identity.
 *
 * @returns {void}
 */
function tileAllWindows() {
  tileWindowsOnMonitor('all applications', getFocusWindow());
}

/**
 * Keybinding handler: tile windows matching the focused application.
 *
 * @returns {void}
 */
function tileFocusedApplicationWindows() {
  const focusedWindow = getFocusWindow();
  const applicationId = focusedWindow ? getWindowApplicationId(focusedWindow) : null;
  if (!focusedWindow || !applicationId || typeof focusedWindow.get_monitor !== 'function') {
    log.info('no tileable focused window; ignoring focused application tiling request');
    return;
  }
  tileWindowsOnMonitor('focused application', focusedWindow, applicationId);
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
   * Activate the extension: load settings and bind both tiling accelerators.
   * @returns {void}
   */
  enable() {
    this._settings = this.getSettings();
    extensionSettings = this._settings;
    Main.wm.addKeybinding(
      TILE_KEY,
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      tileFocusedApplicationWindows,
    );
    Main.wm.addKeybinding(
      ALL_TILE_KEY,
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      tileAllWindows,
    );
    this._dbusObject = Gio.DBusExportedObject.wrapJSObject(
      DBUS_INTERFACE_XML,
      { TileWindowGroup: tileWindowGroup, TileWindowGroups: tileWindowGroups },
    );
    this._dbusObject.export(Gio.DBus.session, DBUS_OBJECT_PATH);
    this._dbusOwnerId = Gio.bus_own_name_on_connection(
      Gio.DBus.session, DBUS_BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null,
    );
    log.info('enabled; focused-application and all-window tiling keybindings registered');
  }

  /**
   * Deactivate the extension: remove the keybinding and release settings.
   * @returns {void}
   */
  disable() {
    if (this._dbusOwnerId) {
      Gio.bus_unown_name(this._dbusOwnerId);
      this._dbusOwnerId = null;
    }
    if (this._dbusObject) {
      this._dbusObject.unexport();
      this._dbusObject = null;
    }
    Main.wm.removeKeybinding(TILE_KEY);
    Main.wm.removeKeybinding(ALL_TILE_KEY);
    extensionSettings = null;
    this._settings = null;
    log.info('disabled; tiling keybinding removed');
  }
}
