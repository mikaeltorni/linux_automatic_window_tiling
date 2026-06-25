#!/usr/bin/env bash
#
# install.sh — Install the Automatic Window Tiling GNOME Shell extension.
#
# Deploys the extension into the target user's local GNOME Shell extensions
# directory, compiles its gsettings schema, and enables it. The core install
# always runs so tiling works no matter which optional components are selected.
# Each customizable behavior (the tiling accelerator, per-application preferred
# widths, and portrait-monitor stacking) is a selectable component routed through
# the shared installer component framework, so a clean install reproduces the
# built-in behavior while every part stays fully customizable.
#
# Usage:
#   bash install.sh                          # interactive component menu (TTY)
#   bash install.sh '<Super>t'               # legacy: deploy + default components
#   bash install.sh --binding '<Control><Alt>t'
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

# Separate the legacy binding argument from the component-framework arguments.
# A single bare positional or `--binding <accel>` selects the tiling accelerator
# (preserving the interface linux_hotkey_setup calls); everything else is passed
# through to component_main. Populates FRAMEWORK_ARGS, AWT_BINDING, and
# AWT_BINDING_EXPLICIT.
# Arguments: the script's "$@".
# Returns: 0 on success; 2 when --binding is missing its value.
parse_binding() {
  FRAMEWORK_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binding)
        [[ $# -ge 2 ]] || { usage >&2; return 2; }
        AWT_BINDING="$2"; AWT_BINDING_EXPLICIT=1; shift 2 ;;
      --binding=*)
        AWT_BINDING="${1#*=}"; AWT_BINDING_EXPLICIT=1; shift ;;
      --select)
        FRAMEWORK_ARGS+=("$1" "${2:-}"); shift 2 ;;
      --)
        shift ;;
      -*)
        FRAMEWORK_ARGS+=("$1"); shift ;;
      *)
        AWT_BINDING="$1"; AWT_BINDING_EXPLICIT=1; shift ;;
    esac
  done
  return 0
}

# Print usage instructions to stdout.
# Arguments: none.
# Returns: 0.
usage() {
  cat <<'EOF'
Usage:
  bash install.sh                      Interactive component menu (TTY)
  bash install.sh '<Super>t'           Deploy and install default components
  bash install.sh --binding '<Control><Alt>t'
  bash install.sh --default            All default-on components, no prompt
  bash install.sh --all                Every component, no prompt
  bash install.sh --select a,b,c       Only the listed component ids
  bash install.sh --list-components    List components as id<TAB>label<TAB>default
EOF
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

# Load the shared installer component framework from a sibling checkout of
# linux_installation_scripts_functions, falling back to an on-demand download so
# a standalone clean install works without that checkout present.
# Returns: 0 once isc_activate_components is available.
load_component_framework() {
  local d
  for d in "${ISC_FUNCTIONS_DIR:-}" \
           "$SCRIPT_DIR/../linux_installation_scripts_functions" \
           "$HOME/projects/linux_installation_scripts_functions"; do
    [[ -n "$d" && -f "$d/component_loader.sh" ]] && { source "$d/component_loader.sh"; break; }
  done
  declare -F isc_load_helpers >/dev/null 2>&1 || \
    source <(curl -fsSL "https://raw.githubusercontent.com/mikaeltorni/linux_installation_scripts_functions/${ISC_FUNCTIONS_REF:-master}/component_loader.sh")
  isc_load_helpers
  isc_activate_components
}

# Orchestrate the installation: parse arguments, resolve the target user, deploy
# the extension core, then route the customizable components through the shared
# component framework.
# Arguments: the script's "$@".
# Returns: 0 on success; 1 on environment errors; 2 on bad arguments.
main() {
  parse_binding "$@" || return $?

  # A delegated invocation (linux_hotkey_setup) passes only the tiling binding
  # and no component selection. With no selection flag, component_main drops into
  # its interactive submenu on a TTY (stdin is the parent installer's terminal)
  # and blocks forever, hanging the whole master run. The documented contract for
  # a bare binding is "deploy and install default components", so when a binding
  # was given explicitly and no framework selection was supplied, run defaults
  # non-interactively.
  if [[ -n "${AWT_BINDING_EXPLICIT:-}" && ${#FRAMEWORK_ARGS[@]} -eq 0 ]]; then
    FRAMEWORK_ARGS=(--default)
  fi

  resolve_target || return 1

  # Load the shared framework first, then our install steps, so this
  # repository's self-contained run_as_target/gsettings_array win over the
  # shared helpers' implementations regardless of source order.
  load_component_framework
  # shellcheck source=lib/tiling_setup.sh
  source "$SCRIPT_DIR/lib/tiling_setup.sh"
  awt_install_core || return 1

  # shellcheck source=installer/components.sh
  source "$SCRIPT_DIR/installer/components.sh"
  component_main "${FRAMEWORK_ARGS[@]}"

  printf 'Installed %s.\n' "$EXTENSION_ID"
  printf 'Log out and back in if GNOME Shell has not loaded the extension.\n'
}

# Listing/help must print only their own output (the master installer parses
# --list-components); skip the core deploy and completion message for those.
case "${1:-}" in
  --list-components|--detect|--help|-h|--uninstall|--uninstall=*)
    load_component_framework
    source "$SCRIPT_DIR/lib/tiling_setup.sh"
    source "$SCRIPT_DIR/installer/components.sh"
    # --detect/--uninstall reach into the target user's gsettings via
    # run_as_target, so resolve the session globals first (best-effort; harmless
    # for the pure --list-components/--help output).
    resolve_target || true
    component_main "$@"
    exit $?
    ;;
esac

main "$@"
