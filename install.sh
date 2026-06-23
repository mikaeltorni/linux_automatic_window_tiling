#!/usr/bin/env bash
#
# install.sh — Install the Automatic Window Tiling GNOME Shell extension.
#
# Copies the extension into the target user's local GNOME Shell extensions
# directory, compiles its gsettings schema, applies the requested keyboard
# accelerator, and enables the extension. Works run directly as the desktop
# user or through sudo (deriving the target from SUDO_USER).
#
# Functions:
#   usage           - print invocation help.
#   parse_binding   - validate args and echo the chosen accelerator.
#   gsettings_array - render a single value as a gsettings string array literal.
#   run_as_target   - run a command in the target user's session environment.
#   main            - orchestrate the full installation.
#
# Usage:
#   bash install.sh '<Super>t'              # sudo-free, run as the desktop user
#   sudo bash install.sh '<Super>t'         # also supported (clean-install chain)
#   sudo bash install.sh --binding '<Control><Alt>t'
set -euo pipefail

EXTENSION_ID="automatic-window-tiling@local"
SCHEMA_ID="org.gnome.shell.extensions.automatic-window-tiling"
BINDING_KEY="tile-focused-application-windows"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/installer_logging.sh"

# Print usage instructions to stdout.
# Arguments: none.
# Returns: 0.
usage() {
  cat <<'EOF'
Usage:
  bash install.sh '<Super>t'
  sudo bash install.sh '<Super>t'
  sudo bash install.sh --binding '<Control><Alt>t'
EOF
}

# Validate command-line arguments and emit the chosen accelerator.
# Accepts either a single positional accelerator or `--binding <accelerator>`.
# Arguments: the script's "$@".
# Output: the accelerator string on stdout.
# Returns: 0 on success; 1 when the arguments are malformed.
parse_binding() {
  if [[ "${1:-}" == "--binding" ]]; then
    [[ $# -eq 2 ]] || return 1
    printf '%s\n' "$2"
    return
  fi

  [[ $# -eq 1 ]] || return 1
  printf '%s\n' "$1"
}

# Render a single value as a gsettings string-array literal, escaping
# backslashes and single quotes so the result is safe to pass to `gsettings set`.
# Arguments: $1 - the raw accelerator value.
# Output: the literal `['<escaped-value>']` on stdout.
# Returns: 0.
gsettings_array() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "['%s']\n" "$value"
}

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

# Orchestrate the installation: parse the accelerator, resolve the target user,
# copy extension files, compile the schema, apply the binding, and enable the
# extension.
# Arguments: the script's "$@" (the accelerator specification).
# Returns: 0 on success; 1 on environment errors; 2 on bad arguments.
main() {
  local binding
  if ! binding="$(parse_binding "$@")" || [[ -z "$binding" ]]; then
    usage >&2
    return 2
  fi

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
  local target_dir="$TARGET_HOME/.local/share/gnome-shell/extensions/$EXTENSION_ID"
  installer_log "installing extension files to $target_dir"

  command -v glib-compile-schemas >/dev/null 2>&1 || {
    printf 'glib-compile-schemas is required (package: libglib2.0-bin).\n' >&2
    return 1
  }

  install -d "$target_dir/schemas"
  install -m 0644 \
    "$SCRIPT_DIR/extension.js" \
    "$SCRIPT_DIR/layout.js" \
    "$SCRIPT_DIR/metadata.json" \
    "$SCRIPT_DIR/windows.js" \
    "$target_dir/"
  install -m 0644 \
    "$SCRIPT_DIR/schemas/org.gnome.shell.extensions.automatic-window-tiling.gschema.xml" \
    "$target_dir/schemas/"
  installer_log "compiling gsettings schema"
  glib-compile-schemas --strict "$target_dir/schemas"
  if [[ "$(id -u)" -eq 0 ]]; then
    installer_log "setting extension ownership to $TARGET_USER:$TARGET_USER"
    chown -R "$TARGET_USER:$TARGET_USER" "$target_dir"
  fi

  installer_log "applying accelerator for $BINDING_KEY"
  run_as_target gsettings --schemadir "$target_dir/schemas" set \
    "$SCHEMA_ID" "$BINDING_KEY" "$(gsettings_array "$binding")"
  installer_log "ensuring user extensions stay enabled"
  run_as_target gsettings set org.gnome.shell disable-user-extensions false

  local enabled enabled_with_extension
  installer_log "adding $EXTENSION_ID to enabled extensions"
  enabled="$(run_as_target gsettings get org.gnome.shell enabled-extensions)"
  enabled_with_extension="$(CURRENT="$enabled" python3 "$SCRIPT_DIR/lib/gsettings_strv.py" "$EXTENSION_ID")"
  run_as_target gsettings set org.gnome.shell enabled-extensions "$enabled_with_extension"

  installer_log "requesting in-place extension enable if GNOME already knows the extension"
  run_as_target gnome-extensions enable "$EXTENSION_ID" 2>/dev/null || true
  printf 'Installed %s with binding %s.\n' "$EXTENSION_ID" "$binding"
  printf 'Log out and back in if GNOME Shell has not loaded the extension.\n'
}

main "$@"
