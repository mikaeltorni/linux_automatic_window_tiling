#!/usr/bin/env bash
# awt_bin.sh — Resolve and invoke the awt-tools Rust helper.
#
# Sourced by install.sh / lib/window_count_setup.sh after SCRIPT_DIR is set.
# Builds the binary on demand via scripts/build_awt_tools.sh.
#
# Public functions:
#   ensure_awt_bin  — build/locate dist/awt-tools; sets AWT_BIN
#   awt_bin         — ensure_awt_bin then run it with "$@"

# ensure_awt_bin — Locate or build dist/awt-tools; export AWT_BIN.
ensure_awt_bin() {
  local build_script bin
  build_script="${SCRIPT_DIR:?SCRIPT_DIR unset}/scripts/build_awt_tools.sh"
  if [ -n "${AWT_BIN:-}" ] && [ -x "$AWT_BIN" ]; then
    return 0
  fi
  if [ ! -x "$build_script" ]; then
    if declare -F msg >/dev/null 2>&1; then
      msg "Missing build helper: $build_script"
    else
      printf 'Missing build helper: %s\n' "$build_script" >&2
    fi
    return 1
  fi
  bin="$(bash "$build_script" --print)" || return 1
  AWT_BIN="$bin"
  export AWT_BIN
}

# awt_bin — Run the helper CLI.
awt_bin() {
  ensure_awt_bin || return 1
  "$AWT_BIN" "$@"
}
