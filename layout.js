/**
 * Pure grid layout calculations for automatic window tiling.
 *
 * This module has no GNOME Shell dependencies so its geometry can be tested
 * independently from the extension runtime.
 */

/**
 * Classify a positive value used by grid dimensions and size preferences.
 * Parameters: value - converted dimension or optional preference.
 * Returns: whether a positive value was supplied.
 */
export function isPositive(value) {
  console.log('isPositive parameters', { value });
  const result = value != null && value > 0;
  console.log(result);
  return result;
}

/**
 * Accept a nonempty window set and usable work area before placement.
 * Parameters: windowCount - selected window count; workArea - monitor rectangle.
 * Returns: whether the count and both work-area dimensions are positive.
 */
export function canTileWorkArea(windowCount, workArea) {
  console.log('canTileWorkArea parameters', { windowCount, workArea });
  const result = isPositive(windowCount) && isPositive(workArea.width) && isPositive(workArea.height);
  console.log(result);
  return result;
}

/**
 * Compute the grid layout (rows and columns) for a set of windows.
 *
 * When a preferred tile width is configured, the column count is derived from
 * that target density; otherwise a balanced grid is chosen by scoring each
 * candidate row count on empty cells and cell aspect ratio.
 *
 * @param {number} windowCount - Number of windows to place (>= 1).
 * @param {{x: number, y: number, width: number, height: number}} workArea -
 *   Available work area in physical pixels.
 * @param {?number} preferredWidth - Optional target cell width, or null.
 * @param {number} [portraitMinimumTileHeight=0] - Minimum tile height
 *   (physical pixels) used to wrap windows into columns on portrait monitors.
 *   A non-positive value (the default) keeps every window in a single full-
 *   height column stacked top to bottom; a positive value lets a window keep
 *   at least that height before the next window wraps onto a column to the
 *   right.
 * @returns {{rows: number, columns: number}} The chosen grid dimensions.
 * Parameters: windowCount - number of windows; workArea - usable rectangle;
 * preferredWidth - optional target width; portraitMinimumTileHeight - configured portrait wrapping height.
 * Returns: the selected row and column counts.
 */
export function chooseGrid(windowCount, workArea, preferredWidth, portraitMinimumTileHeight = 0) {
  console.log('chooseGrid parameters', { windowCount, workArea, preferredWidth, portraitMinimumTileHeight });
  // Portrait monitors (taller than wide) stack windows top-to-bottom in a
  // single full-width column, matching the natural vertical orientation. A
  // window stops short of the full column only when it would fall below the
  // configurable minimum tile height, at which point the next window wraps onto
  // a column to the right so extra windows stay usable instead of being squeezed
  // into a sliver. The per-application preferred width is a density hint for
  // wide (landscape) monitors only; portrait stacking is governed solely by this
  // configurable minimum.
  if (workArea.height > workArea.width) {
    if (isPositive(portraitMinimumTileHeight)) {
      // Soft minimum tile height (physical pixels): a window is never made
      // shorter than this, so once a column would drop below it the next window
      // wraps into a column to the right. A non-positive minimum (the default)
      // keeps every window in a single, full-width column stacked top to
      // bottom, matching the portrait orientation.
      const maxRows = Math.max(1, Math.floor(workArea.height / portraitMinimumTileHeight));
      const rows = Math.min(windowCount, maxRows);
      const columns = Math.ceil(windowCount / rows);
      const result = { rows, columns };
      console.log(result);
      return result;
    }
    // No minimum: stack every window top-to-bottom in one full-height column.
    const result = { rows: windowCount, columns: 1 };
    console.log(result);
    return result;
  }

  // The preferred width determines how many columns to target, while the
  // resulting cells still divide and consume the full work area. On a 4K
  // display (3840px), a 1300px preference yields three columns.
  if (isPositive(preferredWidth)) {
    // Force balanced grid for perfect-square window counts regardless of preferred width.
    const sqrt = Math.round(Math.sqrt(windowCount));
    if (sqrt * sqrt === windowCount && sqrt > 1) {
      const result = { rows: sqrt, columns: sqrt };
      console.log(result);
      return result;
    }

    const maxColumns = Math.max(1, Math.ceil(workArea.width / preferredWidth));
    const columns = Math.min(windowCount, maxColumns);
    const rows = Math.ceil(windowCount / columns);
    const result = { rows, columns };
    console.log(result);
    return result;
  }

  if (windowCount === 1) {
    const result = { rows: 1, columns: 1 };
    console.log(result);
    return result;
  }
  if (windowCount === 2) {
    const result = { rows: 1, columns: 2 };
    console.log(result);
    return result;
  }

  // Perfect-square counts should always produce balanced grids.
  const sqrt = Math.round(Math.sqrt(windowCount));
  if (sqrt * sqrt === windowCount && sqrt > 1) {
    const result = { rows: sqrt, columns: sqrt };
    console.log(result);
    return result;
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

  const result = { rows: best.rows, columns: best.columns };
  console.log(result);
  return result;
}

/**
 * Record minimum dimensions revealed when a client refuses a smaller cell.
 * Parameters: frame - accepted frame or null; tile - requested cell; minimumSize - limits already observed.
 * Returns: the accumulated width and height lower bounds.
 */
export function minimumSizeAfterPlacement(frame, tile, minimumSize) {
  console.log('minimumSizeAfterPlacement parameters', { frame, tile, minimumSize });
  const result = {
    width: frame && frame.width > tile.width + 1
      ? Math.max(minimumSize.width, frame.width) : minimumSize.width,
    height: frame && frame.height > tile.height + 1
      ? Math.max(minimumSize.height, frame.height) : minimumSize.height,
  };
  console.log(result);
  return result;
}

/**
 * Check whether every window can occupy a cell with the observed size limits.
 * Parameters: grid - candidate dimensions; windowCount - windows to place; workArea - usable rectangle; minimumSize - observed size lower bounds.
 * Returns: whether the grid has enough cells of sufficient size.
 */
function gridFitsWindowSize(grid, windowCount, workArea, minimumSize) {
  console.log('gridFitsWindowSize parameters', { grid, windowCount, workArea, minimumSize });
  const result = grid.rows > 0 && grid.columns > 0
    && grid.rows * grid.columns >= windowCount
    && Math.floor(workArea.width / grid.columns) >= minimumSize.width
    && Math.floor(workArea.height / grid.rows) >= minimumSize.height;
  console.log(result);
  return result;
}

/**
 * Retain the preferred density while making cells fit observed client limits.
 * Parameters: windowCount - windows to place; workArea - usable rectangle; grid - preferred dimensions; minimumSize - observed size lower bounds.
 * Returns: feasible grid dimensions, or null when the windows cannot all fit.
 */
export function constrainGridToWindowSize(windowCount, workArea, grid, minimumSize) {
  console.log('constrainGridToWindowSize parameters', { windowCount, workArea, grid, minimumSize });
  if (gridFitsWindowSize(grid, windowCount, workArea, minimumSize)) {
    console.log(grid);
    return grid;
  }
  const maxColumns = isPositive(minimumSize.width)
    ? Math.max(1, Math.floor(workArea.width / minimumSize.width)) : windowCount;
  const maxRows = isPositive(minimumSize.height)
    ? Math.max(1, Math.floor(workArea.height / minimumSize.height)) : windowCount;
  let columns = Math.min(grid.columns, maxColumns);
  let rows = Math.ceil(windowCount / columns);
  if (rows > maxRows) {
    rows = maxRows;
    columns = Math.ceil(windowCount / rows);
  }
  const candidate = { rows, columns };
  const result = gridFitsWindowSize(candidate, windowCount, workArea, minimumSize) ? candidate : null;
  console.log(result);
  return result;
}

/**
 * Compute the full grid cell assigned to one tiled window.
 *
 * Integer boundaries are calculated from the work-area edges so adjacent
 * cells cover the complete area without rounding gaps.
 *
 * @param {number} index - Zero-based window index.
 * @param {number} rows - Number of grid rows.
 * @param {number} columns - Number of grid columns.
 * @param {{x: number, y: number, width: number, height: number}} workArea -
 *   Available work area in physical pixels.
 * @returns {{x: number, y: number, width: number, height: number}} Tile bounds.
 */
export function calculateTileRect(index, rows, columns, workArea) {
  const row = Math.floor(index / columns);
  const column = index % columns;
  const x1 = workArea.x + Math.floor(column * workArea.width / columns);
  const x2 = workArea.x + Math.floor((column + 1) * workArea.width / columns);
  const y1 = workArea.y + Math.floor(row * workArea.height / rows);
  const y2 = workArea.y + Math.floor((row + 1) * workArea.height / rows);

  return {
    x: x1,
    y: y1,
    width: x2 - x1,
    height: y2 - y1,
  };
}

/**
 * Relative geometry tolerance when deciding whether a window already fills a
 * tile. Window managers and applications with size increments (terminals in
 * particular) land a few pixels off the requested rectangle.
 */
const TILE_MATCH_RELATIVE_TOLERANCE = 0.2;

/** Minimum absolute geometry tolerance in pixels for tile matching. */
const TILE_MATCH_MINIMUM_TOLERANCE = 24;

/**
 * Find the grid cell a window frame currently occupies.
 *
 * A frame matches a cell when its origin and size are within tolerance of the
 * cell rectangle, so windows that only approximate the requested size (size
 * increments, minimum sizes) still count as tiled.
 *
 * @param {{x: number, y: number, width: number, height: number}} frame -
 *   Current window frame in physical pixels.
 * @param {number} cellCount - Number of occupied cells (window count).
 * @param {number} rows - Number of grid rows.
 * @param {number} columns - Number of grid columns.
 * @param {{x: number, y: number, width: number, height: number}} workArea -
 *   Available work area in physical pixels.
 * @returns {number} Zero-based cell index, or -1 when the frame matches none.
 */
function findTileCell(frame, cellCount, rows, columns, workArea) {
  for (let cell = 0; cell < cellCount; cell++) {
    const tile = calculateTileRect(cell, rows, columns, workArea);
    const toleranceX = Math.max(TILE_MATCH_MINIMUM_TOLERANCE, tile.width * TILE_MATCH_RELATIVE_TOLERANCE);
    const toleranceY = Math.max(TILE_MATCH_MINIMUM_TOLERANCE, tile.height * TILE_MATCH_RELATIVE_TOLERANCE);

    if (
      Math.abs(frame.x - tile.x) <= toleranceX
      && Math.abs(frame.y - tile.y) <= toleranceY
      && Math.abs(frame.width - tile.width) <= toleranceX
      && Math.abs(frame.height - tile.height) <= toleranceY
    ) {
      return cell;
    }
  }

  return -1;
}

/**
 * Detect the cell order of windows that are already tiled into the grid.
 *
 * @param {Array<?{x: number, y: number, width: number, height: number}>} frames -
 *   Current window frames, indexed like the window list.
 * @param {number} rows - Number of grid rows.
 * @param {number} columns - Number of grid columns.
 * @param {{x: number, y: number, width: number, height: number}} workArea -
 *   Available work area in physical pixels.
 * @returns {?Array<number>} Window indices keyed by cell index when every
 *   window fills a distinct cell of the grid, otherwise null.
 */
export function detectTiledOrder(frames, rows, columns, workArea) {
  const count = frames.length;
  if (count === 0 || rows * columns < count) {
    return null;
  }

  const order = new Array(count).fill(-1);
  for (let index = 0; index < count; index++) {
    const frame = frames[index];
    if (!frame || !Number.isFinite(frame.x) || !Number.isFinite(frame.y)
      || !Number.isFinite(frame.width) || !Number.isFinite(frame.height)) {
      return null;
    }

    const cell = findTileCell(frame, count, rows, columns, workArea);
    if (cell < 0 || order[cell] !== -1) {
      return null;
    }
    order[cell] = index;
  }

  return order;
}

/**
 * Rotate an existing tile order by one cell.
 *
 * Every window moves into the previous cell and the first window wraps around
 * to the last cell, so repeated triggers cycle through all arrangements.
 *
 * @param {Array<number>} order - Window indices keyed by cell index.
 * @returns {Array<number>} The rotated order.
 */
export function cycleTiledOrder(order) {
  return order.map((_ignored, cell) => order[(cell + 1) % order.length]);
}
