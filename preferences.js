/** Parse application-width settings and resolve the tiler's effective preferences. */

import { isPositive } from './layout.js';
import { getTileGroupKey } from './windows.js';

const APP_WIDTHS_KEY = 'application-preferred-widths';
const PORTRAIT_MIN_HEIGHT_KEY = 'portrait-minimum-tile-height';
const DEFAULT_APPLICATION_PREFERRED_WIDTHS = ['kitty:1300'];

/**
 * Parse raw application-width entries into normalized names and numeric widths.
 * Parameters: entries - raw GSettings string-array entries.
 * Returns: converted entries; invalid numeric values remain for the operation to reject.
 */
export function parseApplicationPreferredWidths(entries) {
  console.log('parseApplicationPreferredWidths parameters', { entries });
  const result = [];
  if (!Array.isArray(entries)) {
    console.log(result);
    return result;
  }
  for (const entry of entries) {
    if (typeof entry !== 'string') continue;
    const separator = entry.lastIndexOf(':');
    if (separator <= 0) continue;
    const match = entry.slice(0, separator).trim();
    const preferredWidth = Number.parseInt(entry.slice(separator + 1), 10);
    if (match) result.push({ match, preferredWidth });
  }
  console.log(result);
  return result;
}

/**
 * Accept the finite positive widths supported by application preferences.
 * Parameters: value - converted numeric width.
 * Returns: whether the preference can be used.
 */
function isApplicationWidthValid(value) {
  console.log('isApplicationWidthValid parameters', { value });
  const result = Number.isFinite(value) && isPositive(value);
  console.log(result);
  return result;
}

/**
 * Read and validate effective preferences from the live settings object.
 * Parameters: settings - extension GSettings instance or null for compatibility defaults.
 * Returns: accepted width matchers and the configured portrait wrapping height.
 */
export function readTilingPreferences(settings) {
  console.log('readTilingPreferences parameters', { settings });
  const entries = settings ? settings.get_strv(APP_WIDTHS_KEY) : DEFAULT_APPLICATION_PREFERRED_WIDTHS;
  const widthMatchers = parseApplicationPreferredWidths(entries)
    .filter(entry => isApplicationWidthValid(entry.preferredWidth));
  const portraitMinimumTileHeight = settings ? settings.get_int(PORTRAIT_MIN_HEIGHT_KEY) : 1080;
  const result = { widthMatchers, portraitMinimumTileHeight };
  console.log(result);
  return result;
}

/**
 * Look up a configured width using the same application grouping as selection.
 * Parameters: applicationId - normalized application identity; matchers - accepted width entries.
 * Returns: its configured width, or null when no application preference matches.
 */
export function getApplicationPreferredWidth(applicationId, matchers) {
  console.log('getApplicationPreferredWidth parameters', { applicationId, matchers });
  const groupKey = getTileGroupKey(applicationId);
  if (groupKey) {
    for (const preference of matchers) {
      if (groupKey === preference.match) {
        console.log(preference.preferredWidth);
        return preference.preferredWidth;
      }
    }
  }
  console.log(null);
  return null;
}
