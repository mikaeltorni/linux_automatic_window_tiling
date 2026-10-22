#!/usr/bin/env bash
# framework_install.sh - Deploy the shared installer component framework.
#
# This repository (linux_installation_scripts_functions) is itself the shared
# framework that every other setup repository loads. To match the rest of the
# installation_scripts chain it ships its own component-based install.sh that
# deploys these files to a stable, network-independent location so a consuming
# installer can always resolve the framework offline (resolution step #5 in
# component_loader.sh, the download cache).
#
# Layout of selectable vs. always-installed files:
#   - CORE (always, never deselectable): the bootstrap loader and the logging
#     helpers. install.sh deploys these unconditionally via isc_install_core so
#     the framework's core works no matter which optional modules are chosen.
#       component_loader.sh    - resolves/activates the framework
#       component_logging.sh   - shared Bash leveled file logger
#       logging_utils.py       - shared Python logging helper
#       safe_system_action.sh  - guarded reboot/poweroff countdown
#   - OPTIONAL (default-on, user-customizable): the menu engine, the per-repo
#     runtime contract, and the shared install-time helpers. Each is one
#     selectable component in installer/components.sh.
#
# Contract: install.sh must define SCRIPT_DIR, TARGET_USER, TARGET_HOME,
# RUNTIME_DIR, USER_BUS, DISPLAY_VAL and ISC_INSTALL_DIR, and must source the
# shared installer_helpers (msg/run_as_target/need_cmd) before calling these.

# isc_deploy_file - Copy one framework file from the checkout into the install
#   directory, owned by the target user, idempotently.
#   Args: $1 - file name relative to SCRIPT_DIR. Returns: 0 on success; 1 when
#   the source file is missing.
isc_deploy_file() {
  local f="$1"
  local src="$SCRIPT_DIR/$f"
  local dst="$ISC_INSTALL_DIR/$f"

  if [ ! -f "$src" ]; then
    isc_log_error "framework source missing: $src"
    msg "WARN: framework source missing: $src"
    return 1
  fi

  # Self-install guard: when the install dir already is this checkout, copying a
  # file onto itself is both pointless and an error.
  if [ "$src" -ef "$dst" ] 2>/dev/null; then
    isc_log_debug "skip self-copy (src and dst are the same file): $f"
    msg "Already in place: $f ($dst)"
    return 0
  fi

  run_as_target mkdir -p "$ISC_INSTALL_DIR"
  run_as_target cp -f "$src" "$dst"
  run_as_target chmod 0644 "$dst"
  isc_log_info "deployed $f -> $dst"
  msg "Installed $f -> $dst"
}

# isc_install_core - Deploy the non-optional core: the bootstrap loader and the
#   logging helpers. install.sh runs this unconditionally (before any optional
#   component) so the framework core is always present regardless of selection.
#   Parameters: none. Returns: 0 when every core file deployed; 1 otherwise.
isc_install_core() {
  printf 'parameters=none\n'
  msg "[$ISC_REPO_NAME] Installing core (loader + logging) to $ISC_INSTALL_DIR"
  run_as_target mkdir -p "$ISC_INSTALL_DIR"
  local rc=0
  isc_deploy_file component_loader.sh  || rc=1
  isc_deploy_file component_logging.sh || rc=1
  isc_deploy_file logging_utils.py     || rc=1
  isc_deploy_file tmux_background_output.py || rc=1
  isc_deploy_file safe_system_action.sh || rc=1
  run_as_target chmod 0755 "$ISC_INSTALL_DIR/safe_system_action.sh" || rc=1
  printf '%s\n' "$rc"
  return "$rc"
}

# isc_install_menu - Deploy the interactive selection menu engine plus the
#   display-monitor layout helper it uses for the [m] per-application monitor
#   action (the menu sources monitor_layout.sh from the same directory).
#   Args: none. Returns: 0 when every file deployed; 1 otherwise.
isc_install_menu() {
  local rc=0
  isc_deploy_file component_menu.sh || rc=1
  isc_deploy_file monitor_layout.sh || rc=1
  isc_deploy_file monitor_layout.py || rc=1
  return "$rc"
}

# isc_install_runtime - Deploy the per-repository installer runtime (optional).
#   Args: none. Returns: isc_deploy_file status.
isc_install_runtime() {
  local rc=0
  isc_deploy_file component_runtime.sh      || rc=1
  isc_deploy_file installation_config.sh    || rc=1
  isc_deploy_file installation_config.py    || rc=1
  return "$rc"
}

# isc_install_helpers - Deploy the shared install-time helpers plus the shared
#   interactive hotkey-capture engine (hotkey_capture.sh + hotkey_capture.py),
#   which isc_load_helpers sources alongside installer_helpers.sh. Deploying them
#   together keeps configurable hotkeys available even on the download-cache path
#   (no sibling checkout). Args: none. Returns: 0 when all deployed; 1 otherwise.
isc_install_helpers() {
  local rc=0
  isc_deploy_file installer_helpers.sh || rc=1
  isc_deploy_file hotkey_capture.sh    || rc=1
  isc_deploy_file hotkey_capture.py    || rc=1
  isc_deploy_file monitor_layout.sh    || rc=1
  isc_deploy_file monitor_layout.py    || rc=1
  isc_deploy_file repeatable_fields.py || rc=1
  isc_install_repeatable_fields_bin || rc=1
  return "$rc"
}

# Build and publish the repeatable-fields command when cargo is available.
# Test installs override ISC_INSTALL_DIR, so they keep the Python module and
# do not write the user bin directory. The build stays outside run_as_target
# because that helper points HOME at the target home and hides rustup.
isc_install_repeatable_fields_bin() {
  local default_dir cargo_bin cargo_home rustup_home built bin_dir
  default_dir="${XDG_CACHE_HOME:-$TARGET_HOME/.cache}/installation_scripts/components"
  [ "$ISC_INSTALL_DIR" = "$default_dir" ] || return 0
  command -v cargo >/dev/null 2>&1 || return 0
  cargo_bin="$(command -v cargo)"
  cargo_home="$(cd "$(dirname "$cargo_bin")/.." && pwd)"
  rustup_home="$(dirname "$cargo_home")/.rustup"
  env CARGO_HOME="${CARGO_HOME:-$cargo_home}" RUSTUP_HOME="${RUSTUP_HOME:-$rustup_home}" \
    cargo build --manifest-path "$SCRIPT_DIR/Cargo.toml" --locked --release || return 1
  built="$SCRIPT_DIR/target/release/repeatable-fields"
  local config_bin="$SCRIPT_DIR/target/release/installation-config"
  local monitor_bin="$SCRIPT_DIR/target/release/monitor-layout"
  local tmux_bin="$SCRIPT_DIR/target/release/tmux-background-output"
  local hotkey_bin="$SCRIPT_DIR/target/release/hotkey-capture"
  [ -x "$built" ] || return 1
  [ -x "$config_bin" ] || return 1
  [ -x "$monitor_bin" ] || return 1
  [ -x "$tmux_bin" ] || return 1
  [ -x "$hotkey_bin" ] || return 1
  mkdir -p "$SCRIPT_DIR/dist"
  install -m 0755 "$built" "$SCRIPT_DIR/dist/repeatable-fields"
  install -m 0755 "$config_bin" "$SCRIPT_DIR/dist/installation-config"
  install -m 0755 "$monitor_bin" "$SCRIPT_DIR/dist/monitor-layout"
  install -m 0755 "$tmux_bin" "$SCRIPT_DIR/dist/tmux-background-output"
  install -m 0755 "$hotkey_bin" "$SCRIPT_DIR/dist/hotkey-capture"
  bin_dir="$TARGET_HOME/.local/bin"
  run_as_target mkdir -p "$bin_dir"
  run_as_target install -m 0755 "$built" "$bin_dir/repeatable-fields"
  run_as_target install -m 0755 "$config_bin" "$bin_dir/installation-config"
  run_as_target install -m 0755 "$monitor_bin" "$bin_dir/monitor-layout"
  run_as_target install -m 0755 "$tmux_bin" "$bin_dir/tmux-background-output"
  run_as_target install -m 0755 "$hotkey_bin" "$bin_dir/hotkey-capture"
}

# isc_install_summary - Report where the framework was installed and how
#   consumers resolve it. Runs once after the selected components.
#   Args: none. Returns: 0.
isc_install_summary() {
  msg "Shared framework installed to: $ISC_INSTALL_DIR"
  msg "Consuming installers resolve it automatically (sibling checkout first,"
  msg "then this download cache). To force this copy explicitly, export:"
  msg "  ISC_FUNCTIONS_DIR=$ISC_INSTALL_DIR"
  if declare -F report_sudo_required >/dev/null 2>&1; then
    report_sudo_required || true
  fi
}
