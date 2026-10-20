/** Place selected windows while preserving focus, cycling and rollback behavior. */

import { canTileWorkArea, calculateTileRect, chooseGrid, constrainGridToWindowSize, cycleTiledOrder, detectTiledOrder, minimumSizeAfterPlacement } from './layout.js';
import { getApplicationPreferredWidth, readTilingPreferences } from './preferences.js';
import { captureWindowState, getFocusWindow, getTileGroupKey, getWindowApplicationId, isApplicationWorkspace, isTileAnchor, isTileCandidate, isValidWindowId, parseWindowIds, placeWindowInTile, raiseWindow, restoreWindowState } from './windows.js';

export const LOG_PREFIX = 'automatic-window-tiling';

/** Maintain one extension instance's settings and window-placement operations. */
export class WindowTiler {
  /**
   * Retain the live settings object used by every public operation.
   * Parameters: this - controller instance; settings - extension settings object.
   * Returns: undefined after initializing the instance's settings.
   */
  constructor(settings) {
    console.log('WindowTiler constructor parameters', { 'this': this, settings });
    this._settings = settings;
    console.log(undefined);
  }

  /**
   * Place the selected application or all windows, cycling a feasible layout and restoring a rejected one.
   * Parameters: this - controller instance; mode - log label; anchorWindow - workspace/monitor anchor; applicationId - selected identity or null; background - preserve focus and suppress cycling.
   * Returns: undefined after placement, rejection or an ignored request.
   */
  tileWindowsOnMonitor(mode, anchorWindow, applicationId = null, background = false) {
    console.log('tileWindowsOnMonitor parameters', { 'this': this, mode, anchorWindow, applicationId, background });
    if (!isTileAnchor(anchorWindow)) {
      console.log(LOG_PREFIX + ':', `no tileable focused window; ignoring ${mode} tiling request`);
      console.log(undefined);
      return;
    }

    try {
      const { widthMatchers, portraitMinimumTileHeight } = readTilingPreferences(this._settings);
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
      if (!canTileWorkArea(windows.length, workArea)) {
        console.log(LOG_PREFIX + ':', `nothing to tile (windows=${windows.length} workArea=${workArea.width}x${workArea.height})`);
        console.log(undefined);
        return;
      }

      const preferredWidth = applicationId
        ? getApplicationPreferredWidth(applicationId, widthMatchers)
        : null;
      const tileGroup = applicationId ? getTileGroupKey(applicationId) : 'all-applications';
      console.log(LOG_PREFIX + ':',
        `mode=${mode} applicationId=${applicationId ?? 'all'} tileGroup=${tileGroup} preferredWidth=${preferredWidth} windows=${windows.length} workArea=${workArea.width}x${workArea.height}`,
      );
      let grid = chooseGrid(windows.length, workArea, preferredWidth, portraitMinimumTileHeight);
      const states = windows.map(win => captureWindowState(win));
      const frames = states.map(state => state.frame);
      let minimumSize = { width: 0, height: 0 };
      const attemptedGrids = new Set();
      while (!attemptedGrids.has(`${grid.rows}:${grid.columns}`)) {
        attemptedGrids.add(`${grid.rows}:${grid.columns}`);
        const { rows, columns } = grid;
        const tiledOrder = background ? null : detectTiledOrder(frames, rows, columns, workArea);
        const ordered = tiledOrder
          ? cycleTiledOrder(tiledOrder).map(windowIndex => windows[windowIndex])
          : windows;
        console.log(LOG_PREFIX + ':', `grid=${rows}x${columns} mode=${tiledOrder ? 'cycle' : 'tile'}`);

        for (let index = 0; index < ordered.length; index++) {
          const win = ordered[index];
          const tile = calculateTileRect(index, rows, columns, workArea);
          const frame = placeWindowInTile(win, tile);
          minimumSize = minimumSizeAfterPlacement(frame, tile, minimumSize);
          console.log(LOG_PREFIX + ':', `requested ${tile.x},${tile.y} ${tile.width}x${tile.height} -> actual ${frame ? `${frame.x},${frame.y} ${frame.width}x${frame.height}` : 'unknown'}`);
        }

        const nextGrid = constrainGridToWindowSize(windows.length, workArea, grid, minimumSize);
        if (!nextGrid) {
          windows.forEach((win, index) => restoreWindowState(win, states[index]));
          console.warn(LOG_PREFIX + ':', 'client minimum sizes prevent all windows fitting in the work area; previous window layout restored');
          console.log(undefined);
          return;
        }
        grid = nextGrid;
      }

      if (!background) {
        raiseWindow(anchorWindow, workspace);
      }
    } catch (error) {
      console.error(LOG_PREFIX + ':', `failed to tile application windows: ${error}`);
    }
    console.log(undefined);
  }

  /**
   * Place each available workspace/monitor/application group once without changing focus.
   * Parameters: this - controller instance; identifiers - parsed raw/id records from the public batch parser.
   * Returns: undefined after placement, rejection or an ignored request.
   */
  tileParsedWindowGroups(identifiers) {
    console.log('tileParsedWindowGroups parameters', { 'this': this, identifiers });
    const actors = global.get_window_actors();
    const anchors = new Map();
    for (const { raw: windowId, id: xid } of identifiers) {
      if (!isValidWindowId(xid)) {
        console.warn(LOG_PREFIX + ':', `invalid window id for background tiling: ${windowId}`);
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
      if (!isApplicationWorkspace(workspace, applicationId)) {
        console.warn(LOG_PREFIX + ':', `window unavailable for background tiling: ${windowId}`);
        continue;
      }
      const key = `${workspace.index()}:${anchor.get_monitor()}:${getTileGroupKey(applicationId)}`;
      anchors.set(key, [anchor, applicationId]);
    }
    for (const [anchor, applicationId] of anchors.values()) {
      this.tileWindowsOnMonitor('background application', anchor, applicationId, true);
    }
    console.log(undefined);
  }

  /**
   * Dispatch one public X11 identifier through the shared batch entrypoint.
   * Parameters: this - controller instance; windowId - X11 identifier string supplied over D-Bus.
   * Returns: undefined after placement, rejection or an ignored request.
   */
  tileWindowGroup(windowId) {
    console.log('tileWindowGroup parameters', { 'this': this, windowId });
    this.tileWindowGroups([windowId]);
    console.log(undefined);
  }

  /**
   * Tile every eligible application on the focused monitor.
   * Parameters: this - controller instance; none beyond the controller receiver.
   * Returns: undefined after placement, rejection or an ignored request.
   */
  tileAllWindows() {
    console.log('tileAllWindows parameters', { 'this': this });
    this.tileWindowsOnMonitor('all applications', getFocusWindow());
    console.log(undefined);
  }

  /**
   * Tile the focused application group on its current monitor and workspace.
   * Parameters: this - controller instance; none beyond the controller receiver.
   * Returns: undefined after placement, rejection or an ignored request.
   */
  tileFocusedApplicationWindows() {
    console.log('tileFocusedApplicationWindows parameters', { 'this': this });
    const focusedWindow = getFocusWindow();
    const applicationId = focusedWindow ? getWindowApplicationId(focusedWindow) : null;
    if (!isTileAnchor(focusedWindow, applicationId)) {
      console.log(LOG_PREFIX + ':', 'no tileable focused window; ignoring focused application tiling request');
      console.log(undefined);
      return;
    }
    this.tileWindowsOnMonitor('focused application', focusedWindow, applicationId);
    console.log(undefined);
  }

  /**
   * Parse a public D-Bus batch once before routing converted identifiers.
   * Parameters: this - controller instance; windowIds - public X11 identifier strings.
   * Returns: undefined after dispatching the parsed request.
   */
  tileWindowGroups(windowIds) {
    console.log('tileWindowGroups parameters', { 'this': this, windowIds });
    const identifiers = parseWindowIds(windowIds);
    this.tileParsedWindowGroups(identifiers);
    console.log(undefined);
  }
}
