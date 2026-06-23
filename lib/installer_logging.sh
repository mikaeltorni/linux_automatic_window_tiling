#!/usr/bin/env bash
#
# Centralized Bash logging for the automatic window tiling installer.
#
# Functions:
#   installer_log - emit timestamped installer diagnostics to stderr.

# Emit a timestamped installer status line to stderr.
# Arguments: $@ - human-readable status message.
# Returns: 0.
installer_log() {
  printf '%s automatic-window-tiling installer: %s\n' "$(date -Is)" "$*" >&2
}
