/**
 * Pure grid layout calculations for automatic window tiling.
 *
 * This module has no GNOME Shell dependencies so its geometry can be tested
 * independently from the extension runtime.
 */

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
 * @returns {{rows: number, columns: number}} The chosen grid dimensions.
 */
export function chooseGrid(windowCount, workArea, preferredWidth) {
  // The preferred width determines how many columns to target, while the
  // resulting cells still divide and consume the full work area. On a 4K
  // display (3840px), a 1300px preference yields three columns.
  if (preferredWidth != null && preferredWidth > 0) {
    const maxColumns = Math.max(1, Math.ceil(workArea.width / preferredWidth));
    const columns = Math.min(windowCount, maxColumns);
    const rows = Math.ceil(windowCount / columns);
    return { rows, columns };
  }

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
