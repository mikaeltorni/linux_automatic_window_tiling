#!/usr/bin/env bash
# install.sh — deploy the shared installer component framework as modules.
#
# This repository (linux_installation_scripts_functions) is the single source of
# truth for the installer component-selection framework. Every other setup
# repository loads these files; this installer makes them available as installable
# modules in the same component-based way the rest of the installation_scripts
# chain does.
#
# CORE (always installed, never deselectable): the bootstrap loader and the
# logging helpers — installed unconditionally so the framework core works no
# matter which optional modules are chosen.
# OPTIONAL (default-on): the menu engine, the per-repository runtime, and the
# shared install-time helpers — each a selectable component (installer/components.sh).
#
# Usage:
#   bash install.sh                  # interactive submenu on a TTY, else defaults
#   bash install.sh --default        # core + all default-on modules, no prompts
#   bash install.sh --all            # core + every module, no prompts
#   bash install.sh --select menu    # core + exactly these module ids
#   bash install.sh --list-components # print: id<TAB>label<TAB>default
#
# Destination (override with ISC_INSTALL_DIR): the framework download cache,
# which is component_loader.sh's offline resolution fallback, so a consuming
# installer resolves the framework even with no source checkout present.

set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="/run/user/${TARGET_UID}"
DISPLAY_VAL="${DISPLAY:-:0}"
USER_BUS="unix:path=${RUNTIME_DIR}/bus"

# Where to deploy the framework. Default to the loader's offline download cache
# so installing this repo populates the resolution-step-#5 fallback.
ISC_INSTALL_DIR="${ISC_INSTALL_DIR:-${XDG_CACHE_HOME:-$TARGET_HOME/.cache}/installation_scripts/components}"

# Load the shared install-time helpers (msg/run_as_target/need_cmd) and logging.
# These files live right here, so source them directly — no resolution needed.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/installer_helpers.sh"

# Framework-deployment functions and the optional-module manifest.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/framework_install.sh"

# Activate the component runtime from this very checkout, then load the manifest.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/component_loader.sh"
ISC_FUNCTIONS_DIR="$SCRIPT_DIR" isc_activate_components
# shellcheck source=/dev/null
source "$SCRIPT_DIR/installer/components.sh"

main() {
  # CORE first, always — independent of the optional selection — so the
  # framework core is present no matter what the user chooses.
  isc_install_core
  # OPTIONAL default-on modules, via the shared component runtime.
  component_main "$@"
  isc_install_summary
  msg "Shared installer component framework deployment complete."
}

# Listing/help must print only their own output (the master installer parses
# --list-components) and must not deploy anything.
case "${1:-}" in
  --list-components|--detect|--export-selection|--list-configurable-components|--list-select-configure-components|--list-component-config-values|--help|-h) component_main "$@"; exit $? ;;
esac

main "$@"
