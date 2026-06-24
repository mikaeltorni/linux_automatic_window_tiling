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
import {
  getFocusWindow,
  getWindowApplicationId,
  isTileCandidate,
  prepareWindow,
  raiseWindow,
} from './windows.js';

const TILE_KEY = 'tile-focused-application-windows';
const APP_WIDTHS_KEY = 'application-preferred-widths';
const PORTRAIT_MIN_WIDTH_KEY = 'portrait-minimum-tile-width';
const LOG_PREFIX = 'automatic-window-tiling';

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
 * `wm-class:kitty`); only the suffix after the first colon is matched against
 * the configured application names.
 *
 * @param {string} applicationId - Identifier from getWindowApplicationId.
 * @param {Array<{match: string, preferredWidth: number}>} matchers - Parsed
 *   per-application width preferences.
 * @returns {number|null} The preferred tile width, or null when no preference
 *   is configured or the input is not a string.
 */
function getApplicationPreferredWidth(applicationId, matchers) {
  if (typeof applicationId !== 'string') {
    return null;
  }
  const name = applicationId.includes(':')
    ? applicationId.slice(applicationId.indexOf(':') + 1)
    : applicationId;
  for (const preference of matchers) {
    if (name === preference.match) {
      return preference.preferredWidth;
    }
  }
  return null;
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
    const widthMatchers = parseApplicationPreferredWidths(
      extensionSettings ? extensionSettings.get_strv(APP_WIDTHS_KEY) : DEFAULT_APPLICATION_PREFERRED_WIDTHS,
    );
    const portraitMinimumTileWidth = extensionSettings
      ? extensionSettings.get_int(PORTRAIT_MIN_WIDTH_KEY)
      : 1080;
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

    const preferredWidth = getApplicationPreferredWidth(applicationId, widthMatchers);
    log.info(`applicationId=${applicationId} preferredWidth=${preferredWidth} windows=${windows.length} workArea=${workArea.width}x${workArea.height}`);
    const { rows, columns } = chooseGrid(windows.length, workArea, preferredWidth, portraitMinimumTileWidth);
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
    extensionSettings = this._settings;
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
    extensionSettings = null;
    this._settings = null;
    log.info('disabled; tiling keybinding removed');
  }
}
