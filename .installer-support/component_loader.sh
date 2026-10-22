#!/usr/bin/env bash
# component_loader.sh - Resolve and activate the shared installer component
# framework from a single source of truth.
#
# This repository (linux_installation_scripts_functions) owns the reusable
# installer selection framework: component_menu.sh (the pure-Bash TUI) and
# component_runtime.sh (the per-repository --list-components/--select/--default
# contract). Consuming repositories do NOT vendor copies of those files; instead
# each repository's install.sh sources this loader and calls
# isc_activate_components, which locates the framework next to a sibling
# checkout of this repository or downloads it on demand. Editing the framework
# here updates every standalone installer automatically.
#
# Resolution order for the library directory:
#   1. $ISC_COMPONENT_LIB_DIR        (explicit override)
#   2. $ISC_FUNCTIONS_DIR            (explicit path to this repo)
#   3. $ISC_LOADER_DIR               (the directory this loader was sourced from)
#   4. $SCRIPT_DIR/../linux_installation_scripts_functions   (sibling checkout)
#   5. $HOME/projects/linux_installation_scripts_functions   (default checkout)
#   6. download into $XDG_CACHE_HOME/installation_scripts/components
#
# Usage (from a consuming install.sh):
#   source "<sibling-or-curled>/component_loader.sh"
#   isc_activate_components            # sources the runtime (and menu on demand)
#   source "$SCRIPT_DIR/installer/components.sh"
#   component_main "$@"

if [[ -n "${ISC_LOADER_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
ISC_LOADER_SOURCED=1

# ISC_LOADER_DIR - the directory this loader was sourced from, when it is a real
# on-disk checkout. Consumers source this file by absolute path after locating it
# themselves, so its own location is the most reliable pointer back to the rest
# of the framework: it needs no environment hint and survives checkouts outside
# ~/projects as well as root/sudo runs where $HOME changes. It is empty when the
# loader was piped in (curl | bash), where BASH_SOURCE is not a real directory.
ISC_LOADER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || ISC_LOADER_DIR=""
if [[ -n "$ISC_LOADER_DIR" && ! -f "$ISC_LOADER_DIR/component_loader.sh" ]]; then
  ISC_LOADER_DIR=""
fi
export ISC_LOADER_DIR

# Ensure the centralized logging helpers exist. Source component_logging.sh from
# next to this loader when present, otherwise define silent no-op stubs so every
# isc_log* call below is always safe (logging must never abort an installer).
if ! declare -F isc_log >/dev/null 2>&1; then
  if [[ -n "$ISC_LOADER_DIR" && -f "$ISC_LOADER_DIR/component_logging.sh" ]]; then
    # shellcheck source=/dev/null
    source "$ISC_LOADER_DIR/component_logging.sh"
  fi
fi
if ! declare -F isc_log >/dev/null 2>&1; then
  isc_log()         { :; }
  isc_log_verbose() { :; }
  isc_log_debug()   { :; }
  isc_log_info()    { :; }
  isc_log_warn()    { :; }
  isc_log_error()   { :; }
fi

# Repository identity and download location. Override ISC_FUNCTIONS_REF to pin a
# branch/tag, or ISC_FUNCTIONS_RAW for a private mirror.
ISC_FUNCTIONS_REPO="${ISC_FUNCTIONS_REPO:-linux_installation_scripts_functions}"
ISC_FUNCTIONS_REF="${ISC_FUNCTIONS_REF:-master}"
ISC_FUNCTIONS_RAW="${ISC_FUNCTIONS_RAW:-https://raw.githubusercontent.com/mikaeltorni/linux_automatic_window_tiling/master/.installer-support}"

# isc_component_lib_dir - echo a directory that contains both component_menu.sh
# and component_runtime.sh, downloading them into a cache directory when no
# local checkout is available.
#
# Parameters: none. Returns: directory on success; nonzero on failure.
isc_component_lib_dir() {
  printf 'parameters=none\n' >&2
  local d cache f
  for d in \
      "${ISC_COMPONENT_LIB_DIR:-}" \
      "${ISC_FUNCTIONS_DIR:-}" \
      "${ISC_LOADER_DIR:-}" \
      "${SCRIPT_DIR:-}/../${ISC_FUNCTIONS_REPO}" \
      "${HOME}/projects/${ISC_FUNCTIONS_REPO}"; do
    [[ -n "$d" && -f "$d/component_runtime.sh" && -f "$d/component_menu.sh" ]] || continue
    isc_log_debug "resolved component library from local checkout: $d"
    ( cd "$d" && pwd )
    printf '0\n' >&2
    return 0
  done

  cache="${XDG_CACHE_HOME:-$HOME/.cache}/installation_scripts/components"
  mkdir -p "$cache" 2>/dev/null || { isc_log_error "cannot create cache dir: $cache"; printf '1\n' >&2; return 1; }
  # Logging, installer helpers, and repeatable_fields.py are downloaded opportunistically
  # (they are not part of the existence gate above) so older checkouts without
  # them still resolve.
  for f in component_logging.sh installer_helpers.sh safe_system_action.sh tmux_background_output.py repeatable_fields.py installation_config.py installation_config.sh component_menu.sh component_runtime.sh; do
    if [[ ! -f "$cache/$f" || "${ISC_FUNCTIONS_REFRESH:-0}" == "1" ]]; then
      isc_log_debug "downloading $f from $ISC_FUNCTIONS_RAW"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$ISC_FUNCTIONS_RAW/$f" -o "$cache/$f" \
          || { isc_log_error "curl failed for $f"; printf '1\n' >&2; return 1; }
      elif command -v wget >/dev/null 2>&1; then
        wget -qO "$cache/$f" "$ISC_FUNCTIONS_RAW/$f" \
          || { isc_log_error "wget failed for $f"; printf '1\n' >&2; return 1; }
      else
        isc_log_error "neither curl nor wget available to download $f"
        printf '1\n' >&2
        return 1
      fi
    fi
  done
  isc_log_debug "resolved component library from download cache: $cache"
  printf '%s' "$cache"
  printf '0\n' >&2
}

# isc_activate_components - resolve the framework and source component_runtime.sh
# so component_main and the menu become available. Exports ISC_COMPONENT_LIB_DIR
# so the runtime can locate component_menu.sh from the same place.
#
# Returns:
#   0 on success; non-zero (with an error message) when the framework could not
#   be loaded.
isc_activate_components() {
  local dir
  dir="$(isc_component_lib_dir)" || {
    isc_log_error "could not resolve installer component framework (${ISC_FUNCTIONS_REPO})"
    echo "ERROR: could not resolve installer component framework (${ISC_FUNCTIONS_REPO})." >&2
    echo "       Clone ${ISC_FUNCTIONS_REPO} next to this repo, set ISC_FUNCTIONS_DIR, or enable network access." >&2
    return 1
  }
  export ISC_COMPONENT_LIB_DIR="$dir"
  isc_log_info "activating component runtime from $dir"
  # shellcheck source=/dev/null
  source "$dir/component_runtime.sh"
}

# isc_load_helpers - resolve the framework and source installer_helpers.sh so the
# shared install-time helpers (run_as_target, msg, need_cmd, apt_install, …)
# become available. Consuming installers call this from install.sh before doing
# any target-user work, instead of defining their own copies. Idempotent.
#
# Returns:
#   0 on success; non-zero (with an error message) when the helpers could not be
#   loaded.
isc_load_helpers() {
  declare -F run_as_target >/dev/null 2>&1 && [[ -n "${ISC_HELPERS_SOURCED:-}" ]] && return 0
  local dir
  dir="$(isc_component_lib_dir)" || {
    isc_log_error "could not resolve installer helpers (${ISC_FUNCTIONS_REPO})"
    echo "ERROR: could not resolve installer helpers (${ISC_FUNCTIONS_REPO})." >&2
    echo "       Clone ${ISC_FUNCTIONS_REPO} next to this repo, set ISC_FUNCTIONS_DIR, or enable network access." >&2
    return 1
  }
  export ISC_COMPONENT_LIB_DIR="$dir"
  if [[ ! -f "$dir/installer_helpers.sh" ]]; then
    isc_log_error "installer_helpers.sh missing from resolved framework dir: $dir"
    echo "ERROR: installer_helpers.sh missing from ${ISC_FUNCTIONS_REPO}." >&2
    return 1
  fi
  isc_log_info "loading installer helpers from $dir"
  # shellcheck source=/dev/null
  source "$dir/installer_helpers.sh"
  [[ -f "$dir/safe_system_action.sh" ]] && chmod +x "$dir/safe_system_action.sh" 2>/dev/null || true
  # Also expose the shared interactive hotkey-capture helper when present, so
  # every consuming installer can offer configurable hotkeys without vendoring
  # the capture logic. Optional: older framework checkouts simply skip it.
  if [[ -f "$dir/hotkey_capture.sh" ]]; then
    # shellcheck source=/dev/null
    source "$dir/hotkey_capture.sh"
  fi
  # Shared display-monitor discovery (isc_list_monitors) used by installers that
  # persist per-application monitor placement. Optional for older checkouts.
  if [[ -f "$dir/monitor_layout.sh" ]]; then
    # shellcheck source=/dev/null
    source "$dir/monitor_layout.sh"
  fi
  # Python configurators resolve this path through ISC_REPEATABLE_FIELDS_PY.
  # It is optional for compatibility with older cached framework versions.
  [[ -f "$dir/repeatable_fields.py" ]] && \
    export ISC_REPEATABLE_FIELDS_PY="$dir/repeatable_fields.py"
}

# isc_load_menu - source only the TUI engine (component_menu.sh). The master
# installer uses this directly to drive the aggregate two-level menu without
# needing the per-repository runtime.
#
# Returns:
#   0 on success; non-zero when the framework could not be loaded.
isc_load_menu() {
  declare -F cm_aggregate_menu >/dev/null 2>&1 && return 0
  local dir
  dir="$(isc_component_lib_dir)" || {
    isc_log_error "could not resolve installer component framework for menu (${ISC_FUNCTIONS_REPO})"
    echo "ERROR: could not resolve installer component framework (${ISC_FUNCTIONS_REPO})." >&2
    return 1
  }
  export ISC_COMPONENT_LIB_DIR="$dir"
  isc_log_info "loading menu engine from $dir"
  # shellcheck source=/dev/null
  source "$dir/component_menu.sh"
}
