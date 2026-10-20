#!/usr/bin/env bash
# awt_bin.sh — Resolve and invoke the awt-tools Rust helper.
#
# Sourced by install.sh after SCRIPT_DIR is set.
# Builds the binary on demand via scripts/build_awt_tools.sh.
#
# Public functions:
#   ensure_awt_bin  — build/locate dist/awt-tools; sets AWT_BIN
#   awt_bin         — ensure_awt_bin then run it with "$@"

# Locate or build dist/awt-tools in the desktop user's environment; export AWT_BIN.
# Parameters: none; SCRIPT_DIR and target context identify the builder/user.
# Returns: 0 with an executable helper, or 1 when build resolution fails.
ensure_awt_bin() {
  printf 'ensure_awt_bin parameters=none\n' >&2
  local build_script bin
  build_script="${SCRIPT_DIR:?SCRIPT_DIR unset}/scripts/build_awt_tools.sh"
  if [ -n "${AWT_BIN:-}" ] && [ -x "$AWT_BIN" ]; then
    printf 'ensure_awt_bin return=0\n' >&2
    return 0
  fi
  if [ ! -x "$build_script" ]; then
    if declare -F msg >/dev/null 2>&1; then
      msg "Missing build helper: $build_script"
    else
      printf 'Missing build helper: %s\n' "$build_script" >&2
    fi
    printf 'ensure_awt_bin return=1\n' >&2
    return 1
  fi
  if [[ "$(id -u)" == 0 ]] && declare -F run_as_target >/dev/null 2>&1; then
    bin="$(run_as_target bash "$build_script" --print)" || {
      printf 'ensure_awt_bin return=1\n' >&2; return 1;
    }
  else
    bin="$(bash "$build_script" --print)" || {
      printf 'ensure_awt_bin return=1\n' >&2; return 1;
    }
  fi
  AWT_BIN="$bin"
  export AWT_BIN
  printf 'ensure_awt_bin return=0\n' >&2
  return 0
}

# awt_bin — Run the helper CLI.
awt_bin() {
  ensure_awt_bin || return 1
  "$AWT_BIN" "$@"
}
