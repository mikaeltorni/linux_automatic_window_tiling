#!/usr/bin/env bash
#
# tiling_setup.sh — install steps for the Automatic Window Tiling extension.
#
# The core install (awt_install_core) deploys the extension and enables it so
# tiling always works, regardless of which optional components the user selects.
# Each selectable component then writes its GSettings key(s) so its behavior is
# fully customizable without editing the extension source.
#
# Functions:
#   run_as_target            - run a command in the target user's session.
#   gsettings_array          - render one value as a gsettings string-array literal.
#   awt_set_strv             - write a string-array key on the bundled schema.
#   awt_install_core         - deploy, compile, and enable the extension (always).
#   awt_configure_keybinding - apply both tiling accelerators (AWT_BINDING and
#                              AWT_ALL_BINDING).
#   awt_configure_app_widths - set per-application preferred widths (AWT_APP_WIDTHS).
#   awt_configure_portrait_stacking - set the portrait minimum tile height.
#
# Required globals (exported by install.sh before sourcing this file):
#   SCRIPT_DIR TARGET_USER TARGET_UID TARGET_HOME RUNTIME_DIR USER_BUS
#   DISPLAY_VALUE EXTENSION_ID SCHEMA_ID TARGET_DIR

EXTENSION_ID="${EXTENSION_ID:-automatic-window-tiling@local}"
SCHEMA_ID="${SCHEMA_ID:-org.gnome.shell.extensions.automatic-window-tiling}"
BINDING_KEY="tile-focused-application-windows"
ALL_BINDING_KEY="tile-all-windows"
APP_WIDTHS_KEY="application-preferred-widths"
PORTRAIT_MIN_HEIGHT_KEY="portrait-minimum-tile-height"

# Defaults preserve the extension's built-in behavior. Override via the
# environment to customize a clean or scripted install.
AWT_BINDING="${AWT_BINDING:-<Super>t}"
AWT_ALL_BINDING="${AWT_ALL_BINDING:-<Control><Shift>t}"
AWT_APP_WIDTHS="${AWT_APP_WIDTHS:-kitty:1300}"
AWT_PORTRAIT_MIN_HEIGHT="${AWT_PORTRAIT_MIN_HEIGHT:-0}"

# Run a command inside the target user's session environment (HOME, D-Bus,
# display, runtime dir). Executes directly when already that user, otherwise
# re-enters through `sudo -H -u`.
# Arguments: $@ - the command and its arguments to execute.
# Returns: the wrapped command's exit status.
run_as_target() {
  local -a environment=(
    "HOME=$TARGET_HOME"
    "USER=$TARGET_USER"
    "LOGNAME=$TARGET_USER"
    "XDG_RUNTIME_DIR=$RUNTIME_DIR"
    "DBUS_SESSION_BUS_ADDRESS=$USER_BUS"
    "DISPLAY=$DISPLAY_VALUE"
  )

  if [[ "$(id -u)" -eq "$TARGET_UID" ]]; then
    env "${environment[@]}" "$@"
  else
    sudo -H -u "$TARGET_USER" env "${environment[@]}" "$@"
  fi
}

# Render a single value as a gsettings string-array literal, escaping
# backslashes and single quotes so the result is safe to pass to `gsettings set`.
# Arguments: $@ - raw values to include in the array.
# Output: the literal `['<escaped>', ...]` on stdout.
# Returns: 0.
gsettings_array() {
  local value out="" sep=""
  for value in "$@"; do
    value="${value//\\/\\\\}"
    value="${value//\'/\\\'}"
    out+="${sep}'${value}'"
    sep=", "
  done
  printf '[%s]\n' "$out"
}

# Set a string-array key on the bundled schema in the target user's session.
# Arguments: $1 - key name; $2.. - array values.
# Returns: the gsettings exit status.
awt_set_strv() {
  local key="$1"; shift
  run_as_target gsettings --schemadir "$TARGET_DIR/schemas" set \
    "$SCHEMA_ID" "$key" "$(gsettings_array "$@")"
}

# awt_install_core — deploy the extension, compile its schema, and enable it.
# Always runs so the core tiling action works no matter which optional
# components are chosen. Idempotent: re-running overwrites files in place.
# Returns: 0 on success; 1 on missing tooling.
awt_install_core() {
  installer_log "installing extension files to $TARGET_DIR"
  command -v glib-compile-schemas >/dev/null 2>&1 || {
    printf 'glib-compile-schemas is required (package: libglib2.0-bin).\n' >&2
    return 1
  }

  install -d "$TARGET_DIR/schemas"
  install -m 0644 \
    "$SCRIPT_DIR/extension.js" \
    "$SCRIPT_DIR/layout.js" \
    "$SCRIPT_DIR/metadata.json" \
    "$SCRIPT_DIR/windows.js" \
    "$TARGET_DIR/"
  install -m 0644 \
    "$SCRIPT_DIR/schemas/org.gnome.shell.extensions.automatic-window-tiling.gschema.xml" \
    "$TARGET_DIR/schemas/"
  installer_log "compiling gsettings schema"
  glib-compile-schemas --strict "$TARGET_DIR/schemas"
  if [[ "$(id -u)" -eq 0 ]]; then
    installer_log "setting extension ownership to $TARGET_USER:$TARGET_USER"
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_DIR"
  fi

  installer_log "ensuring user extensions stay enabled"
  run_as_target gsettings set org.gnome.shell disable-user-extensions false

  local enabled enabled_with_extension
  installer_log "adding $EXTENSION_ID to enabled extensions"
  enabled="$(run_as_target gsettings get org.gnome.shell enabled-extensions)"
  enabled_with_extension="$(CURRENT="$enabled" awt_bin "$EXTENSION_ID")"
  run_as_target gsettings set org.gnome.shell enabled-extensions "$enabled_with_extension"

  # Best-effort in-place enable, dispatched in the BACKGROUND so it can never
  # block the installer. `gnome-extensions enable` is a synchronous D-Bus call
  # into GNOME Shell; against the session bus this runs under it can hang for
  # minutes on a fresh install (the running Shell has not loaded the just-copied
  # extension, or this is not the live session's bus). The enabled-extensions
  # write above already persists the choice — a live Shell auto-loads it on that
  # change, otherwise it activates on next login — so fire the live enable
  # detached and time-boxed purely as a convenience and continue immediately.
  # stdin/out/err are redirected so the backgrounded job never holds the
  # installer's pipe open.
  installer_log "dispatching background in-place extension enable (non-blocking)"
  run_as_target sh -c 'timeout 5 gnome-extensions enable "$1" >/dev/null 2>&1 </dev/null &' _ "$EXTENSION_ID" || true
}

# Apply the focused-app and monitor-wide accelerators through the shared capture
# helper when no scripted value was supplied; write both GSettings keys.
# Parameters: none; values come from AWT_BINDING, AWT_ALL_BINDING and the shared
# capture helper. Returns: the status from the final GSettings write.
awt_configure_keybinding() {
  printf 'awt_configure_keybinding parameters=none\n' >&2
  local result
  if [[ -z "${AWT_BINDING_EXPLICIT:-}" ]] && declare -F isc_capture_hotkey >/dev/null 2>&1; then
    AWT_BINDING="$(isc_capture_hotkey TILING_HOTKEY "$AWT_BINDING" "automatic window tiling")"
  elif [[ -t 0 && -z "${AWT_BINDING_EXPLICIT:-}" ]]; then
    local typed
    read -r -p "Tiling accelerator [${AWT_BINDING}]: " typed || typed=""
    [[ -n "$typed" ]] && AWT_BINDING="$typed"
  fi
  if [[ -z "${AWT_ALL_BINDING_EXPLICIT:-}" ]] && declare -F isc_capture_hotkey >/dev/null 2>&1; then
    AWT_ALL_BINDING="$(isc_capture_hotkey TILING_ALL_HOTKEY "$AWT_ALL_BINDING" "monitor-wide window tiling")"
  elif [[ -t 0 && -z "${AWT_ALL_BINDING_EXPLICIT:-}" ]]; then
    local typed_all
    read -r -p "Monitor-wide tiling accelerator [${AWT_ALL_BINDING}]: " typed_all || typed_all=""
    [[ -n "$typed_all" ]] && AWT_ALL_BINDING="$typed_all"
  fi
  installer_log "applying accelerator $AWT_BINDING for $BINDING_KEY"
  awt_set_strv "$BINDING_KEY" "$AWT_BINDING"
  installer_log "applying accelerator $AWT_ALL_BINDING for $ALL_BINDING_KEY"
  awt_set_strv "$ALL_BINDING_KEY" "$AWT_ALL_BINDING"
  result=$?
  printf 'awt_configure_keybinding return=%s\n' "$result" >&2
  return "$result"
}

# awt_configure_app_widths — set per-application preferred tile widths from the
# comma/space-separated AWT_APP_WIDTHS list (entries of the form name:width).
# Returns: the gsettings exit status.
awt_configure_app_widths() {
  local -a widths=()
  local entry
  for entry in ${AWT_APP_WIDTHS//,/ }; do
    [[ -n "$entry" ]] && widths+=("$entry")
  done
  installer_log "applying per-application preferred widths: ${widths[*]:-<none>}"
  awt_set_strv "$APP_WIDTHS_KEY" "${widths[@]}"
}

# awt_configure_portrait_stacking — set the portrait minimum tile height from
# AWT_PORTRAIT_MIN_HEIGHT (0 or less means pure single-column vertical stacking).
# Returns: the gsettings exit status.
awt_configure_portrait_stacking() {
  installer_log "applying portrait minimum tile height: $AWT_PORTRAIT_MIN_HEIGHT"
  run_as_target gsettings --schemadir "$TARGET_DIR/schemas" set \
    "$SCHEMA_ID" "$PORTRAIT_MIN_HEIGHT_KEY" "$AWT_PORTRAIT_MIN_HEIGHT"
}

###############################################################################
# Detection and uninstall (component lifecycle)
###############################################################################
# Each component writes one key on the bundled extension's GSettings schema. A
# component is "installed" when that schema is present (so the key applies);
# uninstalling resets the key to the schema default. The mandatory extension
# deploy/enable is core and is never removed by a component uninstall.

# awt_schema_dir: resolve the deployed extension schema dir without relying on
# globals that are only set during the core install pass.
awt_schema_dir() {
  printf '%s\n' "${TARGET_HOME:-$HOME}/.local/share/gnome-shell/extensions/$EXTENSION_ID/schemas"
}

# awt_schema_present: true when the bundled extension schema is readable.
awt_schema_present() {
  run_as_target gsettings --schemadir "$(awt_schema_dir)" \
    get "$SCHEMA_ID" "$BINDING_KEY" >/dev/null 2>&1
}

# awt_reset: reset one extension schema key to its default. Best-effort.
awt_reset() {
  run_as_target gsettings --schemadir "$(awt_schema_dir)" \
    reset "$SCHEMA_ID" "$1" 2>/dev/null || true
}

detect_awt_keybinding()        { awt_schema_present; }
detect_awt_app_widths()        { awt_schema_present; }
detect_awt_portrait_stacking() { awt_schema_present; }

uninstall_awt_keybinding()        { installer_log "resetting $BINDING_KEY and $ALL_BINDING_KEY"; awt_reset "$BINDING_KEY"; awt_reset "$ALL_BINDING_KEY"; }
uninstall_awt_app_widths()        { installer_log "resetting $APP_WIDTHS_KEY";        awt_reset "$APP_WIDTHS_KEY"; }
uninstall_awt_portrait_stacking() { installer_log "resetting $PORTRAIT_MIN_HEIGHT_KEY"; awt_reset "$PORTRAIT_MIN_HEIGHT_KEY"; }
