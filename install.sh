#!/usr/bin/env bash
#
# install.sh — Install the Automatic Window Tiling GNOME Shell extension.
#
# Deploys the extension into the target user's local GNOME Shell extensions
# directory, compiles its gsettings schema, and enables it. The core install
# always runs so tiling works no matter which optional components are selected.
# Each customizable behavior (the tiling accelerators, per-application preferred
# widths, and portrait-monitor stacking) is a selectable component routed through
# the shared installer component framework, so a clean install reproduces the
# built-in behavior while every part stays fully customizable.
#
# Usage:
#   bash install.sh                          # interactive component menu (TTY)
#   bash install.sh '<Super>t'               # legacy: deploy + default components
#   bash install.sh --binding '<Control><Alt>t'
#   bash install.sh --binding '<Super>t' --all-binding '<Super><Shift>t'
#   bash install.sh --default                # all default-on components, no prompt
#   bash install.sh --all                    # every component, no prompt
#   bash install.sh --select keybinding      # only the listed components
#   bash install.sh --list-components        # machine-readable component list
#   sudo bash install.sh '<Super>t'          # also supported (clean-install chain)
set -euo pipefail

EXTENSION_ID="automatic-window-tiling@local"
SCHEMA_ID="org.gnome.shell.extensions.automatic-window-tiling"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/installer_logging.sh"

# Parse binding options away from component-framework arguments while preserving
# the legacy positional focused-app accelerator. Environment overrides count as
# explicit values so interactive capture cannot replace them.
# Parameters: "$@" - raw installer arguments. Returns: 0 with binding globals,
# standalone selector/action and intact framework arguments; 2 for malformed input.
parse_binding() {
  printf 'parse_binding parameters=%s\n' "$*" >&2
  FRAMEWORK_ARGS=()
  AWT_STANDALONE=0
  AWT_STANDALONE_ACTION=install
  [[ -n "${AWT_BINDING:-}" ]] && AWT_BINDING_EXPLICIT=1
  [[ -n "${AWT_ALL_BINDING:-}" ]] && AWT_ALL_BINDING_EXPLICIT=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --standalone)
        AWT_STANDALONE=1; shift ;;
      --binding)
        if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
          usage >&2
          printf 'parse_binding return=2\n' >&2
          return 2
        fi
        AWT_BINDING="$2"; AWT_BINDING_EXPLICIT=1; shift 2 ;;
      --binding=*)
        if [[ -z "${1#*=}" ]]; then
          usage >&2
          printf 'parse_binding return=2\n' >&2
          return 2
        fi
        AWT_BINDING="${1#*=}"; AWT_BINDING_EXPLICIT=1; shift ;;
      --all-binding)
        if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
          usage >&2
          printf 'parse_binding return=2\n' >&2
          return 2
        fi
        AWT_ALL_BINDING="$2"; AWT_ALL_BINDING_EXPLICIT=1; shift 2 ;;
      --all-binding=*)
        if [[ -z "${1#*=}" ]]; then
          usage >&2
          printf 'parse_binding return=2\n' >&2
          return 2
        fi
        AWT_ALL_BINDING="${1#*=}"; AWT_ALL_BINDING_EXPLICIT=1; shift ;;
      --select|--reconfigure|--uninstall|--config|--configure-component)
        if [[ $# -lt 2 || "${2:-}" == -* ]]; then
          usage >&2
          printf 'parse_binding return=2\n' >&2
          return 2
        fi
        FRAMEWORK_ARGS+=("$1" "${2:-}"); shift 2 ;;
      --)
        shift ;;
      -*)
        FRAMEWORK_ARGS+=("$1"); shift ;;
      *)
        AWT_BINDING="$1"; AWT_BINDING_EXPLICIT=1; shift ;;
    esac
  done
  if [[ "$AWT_STANDALONE" == 1 ]]; then
    for argument in "${FRAMEWORK_ARGS[@]}"; do
      case "$argument" in
        --help|-h) AWT_STANDALONE_ACTION=help ;;
        --default|--all) ;;
        *)
          printf 'Standalone mode accepts binding options, --default, --all and --help; component controls require bundle mode.\n' >&2
          printf 'parse_binding return=2\n' >&2
          return 2 ;;
      esac
    done
    FRAMEWORK_ARGS=()
  fi
  printf 'parse_binding return=0\n' >&2
  return 0
}

# Print the installer's supported command forms.
# Parameters: none. Returns: 0 after writing usage to stdout.
usage() {
  printf 'usage parameters=none\n' >&2
  cat <<'EOF'
Usage:
  bash install.sh --standalone         Install without the shared framework
  bash install.sh --standalone --binding '<Super>y' --all-binding '<Super><Shift>y'
  bash install.sh                      Interactive component menu (TTY)
  bash install.sh '<Super>t'           Deploy and install default components
  bash install.sh --binding '<Control><Alt>t'
  bash install.sh --binding '<Super>t' --all-binding '<Super><Shift>t'
  bash install.sh --default            All default-on components, no prompt
  bash install.sh --all                Every component, no prompt
  bash install.sh --select a,b,c       Only the listed component ids
  bash install.sh --list-components    List components as id<TAB>label<TAB>default
EOF
  printf 'usage return=0\n' >&2
}

# Resolve the desktop target user and export the session globals the install
# steps in lib/tiling_setup.sh rely on (TARGET_*, RUNTIME_DIR, USER_BUS,
# DISPLAY_VALUE, TARGET_DIR).
# Returns: 0 on success; 1 when the target user cannot be resolved.
resolve_target() {
  TARGET_USER="${SUDO_USER:-${TARGET_USER:-$USER}}"
  installer_log "resolving target user: $TARGET_USER"
  if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    printf 'Set TARGET_USER or run through sudo from the desktop user.\n' >&2
    return 1
  fi

  TARGET_UID="$(id -u "$TARGET_USER")"
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  RUNTIME_DIR="/run/user/$TARGET_UID"
  USER_BUS="unix:path=$RUNTIME_DIR/bus"
  DISPLAY_VALUE="${DISPLAY:-:0}"
  TARGET_DIR="$TARGET_HOME/.local/share/gnome-shell/extensions/$EXTENSION_ID"
  export TARGET_USER TARGET_UID TARGET_HOME RUNTIME_DIR USER_BUS \
    DISPLAY_VALUE TARGET_DIR EXTENSION_ID SCHEMA_ID
}

# Load this public repository's installer support or an explicit caller override.
# Parameters: none; SCRIPT_DIR and optional ISC_FUNCTIONS_DIR locate support.
# Returns: zero after activating helpers and the component runtime.
load_component_framework() {
  printf 'parameters=none\n' >&2
  local directory="${ISC_FUNCTIONS_DIR:-$SCRIPT_DIR/.installer-support}" status=0
  if [[ ! -f "$directory/component_loader.sh" ]]; then
    printf 'Installer support missing: %s\n1\n' "$directory" >&2
    return 1
  fi
  export ISC_COMPONENT_LIB_DIR="$directory"
  source "$directory/component_loader.sh"
  isc_load_helpers || status=$?
  if [[ "$status" == 0 ]]; then
    isc_activate_components || status=$?
  fi
  printf '%s\n' "$status" >&2
  return "$status"
}

# Parse once and route standalone installation or framework-owned actions.
# Parameters: "$@" - raw installer arguments. Returns: 0 after a successful
# installation or framework action; nonzero for parser, environment or framework errors.
main() {
  printf 'main parameters=%s\n' "$*" >&2
  local result operation=component_main
  parse_binding "$@" || {
    result=$?
    printf 'main return=%s\n' "$result" >&2
    return "$result"
  }
  if [[ "$AWT_STANDALONE_ACTION" == help ]]; then
    usage
    printf 'main return=0\n' >&2
    return 0
  fi

  # A delegated invocation (linux_hotkey_setup) passes only the tiling binding
  # and no component selection. With no selection flag, component_main drops into
  # its interactive submenu on a TTY (stdin is the parent installer's terminal)
  # and blocks forever, hanging the whole master run. The documented contract for
  # a bare binding is "deploy and install default components", so when a binding
  # was given explicitly and no framework selection was supplied, run defaults
  # non-interactively.
  if [[ "$AWT_STANDALONE" == 0 && -n "${AWT_BINDING_EXPLICIT:-}${AWT_ALL_BINDING_EXPLICIT:-}" \
    && ${#FRAMEWORK_ARGS[@]} -eq 0 ]]; then
    FRAMEWORK_ARGS=(--default)
  fi

  resolve_target || { printf 'main return=1\n' >&2; return 1; }

  # The framework invokes ISC_CORE only for installation. Queries, invalid
  # commands and uninstall must never deploy or enable the extension first.
  if [[ "$AWT_STANDALONE" == 1 ]]; then
    operation=awt_install_standalone
  else
    load_component_framework
  fi
  # shellcheck source=lib/awt_bin.sh
  source "$SCRIPT_DIR/lib/awt_bin.sh"
  # shellcheck source=lib/tiling_setup.sh
  source "$SCRIPT_DIR/lib/tiling_setup.sh"
  # shellcheck source=installer/components.sh
  source "$SCRIPT_DIR/installer/components.sh"
  if "$operation" "${FRAMEWORK_ARGS[@]}"; then
    result=0
  else
    result=$?
    printf 'main return=%s\n' "$result" >&2
    return "$result"
  fi

  if [[ "${AWT_CORE_INSTALLED:-0}" == 1 ]]; then
    printf 'Installed %s.\n' "$EXTENSION_ID"
    printf 'Log out and back in if GNOME Shell has not loaded the extension.\n'
  fi
  printf 'main return=0\n' >&2
  return 0
}

main "$@"
