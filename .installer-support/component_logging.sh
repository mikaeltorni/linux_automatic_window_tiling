#!/usr/bin/env bash
# component_logging.sh - Centralized, dependency-free logging for the shared
# installer component framework.
#
# This is the single source of truth for leveled logging across the framework
# (component_loader.sh, component_runtime.sh, component_menu.sh) and the
# standalone installers that consume it. It is intentionally dependency-free so
# it works on a fresh Ubuntu install before any package is added, and every
# message is written to a log file rather than the terminal so logging never
# corrupts the interactive TUI rendered by component_menu.sh.
#
# Log levels (ascending severity): verbose < debug < info < warn < error.
# A message is recorded only when its level is at or above ISC_LOG_LEVEL.
#
# Functions:
#   isc_log LEVEL MESSAGE   - write one leveled, timestamped, tagged log line
#   isc_log_verbose MESSAGE - shorthand for: isc_log verbose MESSAGE
#   isc_log_debug   MESSAGE - shorthand for: isc_log debug   MESSAGE
#   isc_log_info    MESSAGE - shorthand for: isc_log info    MESSAGE
#   isc_log_warn    MESSAGE - shorthand for: isc_log warn    MESSAGE
#   isc_log_error   MESSAGE - shorthand for: isc_log error   MESSAGE
#   isc_log_file            - echo the resolved absolute log file path
#
# Environment overrides:
#   ISC_LOG_DIR    - directory that holds log files
#                    (default: ${SCRIPT_DIR:-$PWD}/.log, i.e. the consuming
#                    repository root's .log/ directory)
#   ISC_LOG_NAME   - log file name within ISC_LOG_DIR
#                    (default: installer_components.log)
#   ISC_LOG_LEVEL  - minimum level to record (default: debug)
#   ISC_LOG_TAG    - context tag added to each line
#                    (default: $ISC_REPO_NAME, else "framework")
#
# Usage:
#   source "<dir>/component_logging.sh"
#   isc_log_info "starting installer"
#   isc_log_error "curl failed for $url"

# Guard against double-sourcing so repeated source calls are harmless.
if [[ -n "${ISC_LOGGING_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
ISC_LOGGING_SOURCED=1

# _isc_log_severity - map a textual log level to a numeric severity so levels
# can be compared against the configured threshold.
#
# Arguments:
#   $1 - level name (verbose|debug|info|warn|error); unknown values map to info.
#
# Returns:
#   0; prints the numeric severity (0=verbose .. 4=error) on stdout.
_isc_log_severity() {
  case "$1" in
    verbose) printf '0' ;;
    debug)   printf '1' ;;
    info)    printf '2' ;;
    warn)    printf '3' ;;
    error)   printf '4' ;;
    *)       printf '2' ;;
  esac
}

# isc_log_file - resolve and echo the absolute path of the active log file.
#
# Arguments:
#   none.
#
# Returns:
#   0; prints "<ISC_LOG_DIR>/<ISC_LOG_NAME>" on stdout.
isc_log_file() {
  local dir="${ISC_LOG_DIR:-${SCRIPT_DIR:-$PWD}/.log}"
  printf '%s/%s' "$dir" "${ISC_LOG_NAME:-installer_components.log}"
}

# isc_log - write a single timestamped, leveled, tagged line to the log file.
#
# The message is dropped silently when its level is below ISC_LOG_LEVEL. The
# log directory is created on demand. All failures (e.g. a read-only filesystem)
# are swallowed so logging can never abort an installer.
#
# Arguments:
#   $1  - log level (verbose|debug|info|warn|error).
#   $2.. - message text; remaining arguments are joined with spaces.
#
# Returns:
#   0 always (logging is best-effort and never fails the caller).
isc_log() {
  local level="$1"; shift
  local message="$*"
  local threshold="${ISC_LOG_LEVEL:-debug}"
  (( $(_isc_log_severity "$level") < $(_isc_log_severity "$threshold") )) && return 0

  local dir file timestamp tag
  dir="${ISC_LOG_DIR:-${SCRIPT_DIR:-$PWD}/.log}"
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/${ISC_LOG_NAME:-installer_components.log}"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  tag="${ISC_LOG_TAG:-${ISC_REPO_NAME:-framework}}"
  printf '%s [%-7s] [%s] %s\n' "$timestamp" "${level^^}" "$tag" "$message" \
    >>"$file" 2>/dev/null || true
  return 0
}

# Level shorthands. Each forwards its arguments to isc_log with a fixed level.
#
# Arguments:
#   $@ - message text passed through to isc_log.
#
# Returns:
#   0 always.
isc_log_verbose() { isc_log verbose "$@"; }
isc_log_debug()   { isc_log debug   "$@"; }
isc_log_info()    { isc_log info    "$@"; }
isc_log_warn()    { isc_log warn    "$@"; }
isc_log_error()   { isc_log error   "$@"; }
