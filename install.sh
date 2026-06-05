#!/usr/bin/env bash
set -euo pipefail

EXTENSION_ID="automatic-window-tiling@local"
SCHEMA_ID="org.gnome.shell.extensions.automatic-window-tiling"
BINDING_KEY="tile-focused-application-windows"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  sudo bash install.sh '<Super>t'
  sudo bash install.sh --binding '<Control><Alt>t'
EOF
}

parse_binding() {
  if [[ "${1:-}" == "--binding" ]]; then
    [[ $# -eq 2 ]] || return 1
    printf '%s\n' "$2"
    return
  fi

  [[ $# -eq 1 ]] || return 1
  printf '%s\n' "$1"
}

gsettings_array() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "['%s']\n" "$value"
}

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

main() {
  local binding
  if ! binding="$(parse_binding "$@")" || [[ -z "$binding" ]]; then
    usage >&2
    return 2
  fi

  TARGET_USER="${SUDO_USER:-${TARGET_USER:-$USER}}"
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

  command -v glib-compile-schemas >/dev/null 2>&1 || {
    printf 'glib-compile-schemas is required (package: libglib2.0-bin).\n' >&2
    return 1
  }

  install -d "$target_dir/schemas"
  install -m 0644 "$SCRIPT_DIR/extension.js" "$SCRIPT_DIR/metadata.json" "$target_dir/"
  install -m 0644 \
    "$SCRIPT_DIR/schemas/org.gnome.shell.extensions.automatic-window-tiling.gschema.xml" \
    "$target_dir/schemas/"
  glib-compile-schemas --strict "$target_dir/schemas"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "$TARGET_USER:$TARGET_USER" "$target_dir"
  fi

  run_as_target gsettings --schemadir "$target_dir/schemas" set \
    "$SCHEMA_ID" "$BINDING_KEY" "$(gsettings_array "$binding")"
  run_as_target gsettings set org.gnome.shell disable-user-extensions false

  local enabled
  enabled="$(run_as_target gsettings get org.gnome.shell enabled-extensions)"
  run_as_target env CURRENT_EXTENSIONS="$enabled" EXTENSION_ID="$EXTENSION_ID" python3 - <<'PY'
import ast
import os
import subprocess

raw = os.environ["CURRENT_EXTENSIONS"].strip()
if raw.startswith("@as "):
    raw = raw[4:].strip()
try:
    extensions = ast.literal_eval(raw)
except (SyntaxError, ValueError):
    extensions = []
if not isinstance(extensions, list):
    extensions = []

extension_id = os.environ["EXTENSION_ID"]
if extension_id not in extensions:
    extensions.append(extension_id)
subprocess.run(
    ["gsettings", "set", "org.gnome.shell", "enabled-extensions", repr(extensions)],
    check=True,
)
PY

  run_as_target gnome-extensions enable "$EXTENSION_ID" 2>/dev/null || true
  printf 'Installed %s with binding %s.\n' "$EXTENSION_ID" "$binding"
  printf 'Log out and back in if GNOME Shell has not loaded the extension.\n'
}

main "$@"
