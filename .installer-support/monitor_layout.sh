#!/usr/bin/env bash
# monitor_layout.sh - shared display-monitor discovery for every setup repo.
#
# Single source of truth for the per-application monitor placement feature: the
# master menu's [m] action, and the installers that persist monitor rules, all
# number monitors exactly like the GNOME Settings -> Displays panel. The heavy
# lifting lives in the co-located monitor_layout.py (Mutter DisplayConfig), so
# the numbering logic is implemented once.
#
# Functions:
#   isc_monitor_lib_dir  - directory holding monitor_layout.py.
#   isc_list_monitors    - TSV rows: number connector name primary x y w h.
#   isc_monitor_count    - number of connected monitors (0 when undetectable).
#   isc_monitor_label    - short "N: connector (name)" label for one monitor.
#
# Detection requires a live GNOME session bus. When it is unavailable (TTY
# install, no GNOME yet) every function degrades to "unknown" instead of
# guessing a layout, and callers hide the interactive monitor action while
# still honoring monitor defaults that came from the component manifests.
#
# ISC_MONITOR_LIST overrides detection with literal TSV rows (tests, headless
# runs, and machines whose session bus the installer cannot reach).

# isc_monitor_lib_dir - print the directory that contains monitor_layout.py.
# Prefers the framework dir resolved by component_loader.sh, then this file's
# own directory. Arguments: none. Returns 1 when the helper is missing.
isc_monitor_lib_dir() {
  local dir
  for dir in "${ISC_COMPONENT_LIB_DIR:-}" \
             "${ISC_FUNCTIONS_DIR:-}" \
             "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; do
    [[ -n "$dir" && -f "$dir/monitor_layout.py" ]] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}

# isc_list_monitors - print one TSV row per monitor, in GNOME Displays order:
#   number<TAB>connector<TAB>display name<TAB>primary(0/1)<TAB>x<TAB>y<TAB>width<TAB>height
#
# Runs the query as the desktop user when run_as_target is available (a root
# installer has no session bus of its own). Arguments: none.
# Returns: 0 when at least one monitor was reported; 1 otherwise (no output).
isc_list_monitors() {
  if [[ -n "${ISC_MONITOR_LIST:-}" ]]; then
    printf '%s\n' "$ISC_MONITOR_LIST"
    return 0
  fi
  local dir output
  dir="$(isc_monitor_lib_dir)" || {
    declare -F isc_log_warn >/dev/null 2>&1 && isc_log_warn "monitor_layout.py not found; monitor detection disabled"
    return 1
  }
  local bin=""
  if command -v cargo >/dev/null 2>&1; then
    local candidate
    for candidate in "$dir/target/release/monitor-layout" "$dir/dist/monitor-layout"; do
      [[ -x "$candidate" ]] && bin="$candidate" && break
    done
  fi
  if [[ -n "$bin" ]]; then
    if declare -F run_as_target >/dev/null 2>&1; then
      output="$(run_as_target "$bin" list 2>/dev/null || true)"
    else
      output="$("$bin" list 2>/dev/null || true)"
    fi
  elif declare -F run_as_target >/dev/null 2>&1; then
    output="$(run_as_target python3 "$dir/monitor_layout.py" list 2>/dev/null || true)"
  else
    output="$(python3 "$dir/monitor_layout.py" list 2>/dev/null || true)"
  fi
  [[ -n "$output" ]] || {
    declare -F isc_log_warn >/dev/null 2>&1 && isc_log_warn "monitor detection unavailable (no GNOME session bus?)"
    return 1
  }
  printf '%s\n' "$output"
  return 0
}

# isc_monitor_count - print the number of connected monitors (0 when unknown).
# Arguments: none. Returns: 0 when the count is trustworthy, 1 when unknown.
isc_monitor_count() {
  local rows
  rows="$(isc_list_monitors)" || { printf '0\n'; return 1; }
  printf '%s\n' "$(printf '%s\n' "$rows" | grep -c .)"
  return 0
}

# isc_monitor_label - print a short human label for one monitor number.
# Arguments: $1 - 1-based monitor number. Prints "N: connector (name)" plus a
# " [primary]" suffix, or just the number when detection is unavailable.
isc_monitor_label() {
  local wanted="$1" number connector name primary rest
  while IFS=$'\t' read -r number connector name primary rest; do
    [[ "$number" == "$wanted" ]] || continue
    printf '%s: %s (%s)%s\n' "$number" "$connector" "$name" \
      "$([[ "$primary" == "1" ]] && printf ' [primary]')"
    return 0
  done < <(isc_list_monitors)
  printf '%s\n' "$wanted"
  return 1
}
