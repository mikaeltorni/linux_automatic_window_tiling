#!/usr/bin/env bash
# installer_helpers.sh - Shared install-time helpers (single source of truth).
#
# This repository (linux_installation_scripts_functions) owns the reusable
# installer helpers that every setup repository previously redefined on its own
# (run_as_target, msg, need_cmd, apt_install, linked-repository auth gating, the
# sudo-skip reporting, and the session-bus / root guards). Consuming installers
# resolve and source this file via isc_load_helpers (component_loader.sh) instead
# of vendoring a copy, so a fix here reaches every standalone installer.
#
# Contract: the caller must define TARGET_USER, TARGET_HOME, RUNTIME_DIR,
# USER_BUS, and DISPLAY_VAL before invoking run_as_target/ensure_session_bus.
# A repository may still define repo-specific helpers (e.g. desktop-file lookup)
# in its own lib; this file holds only what was duplicated everywhere.
#
# Safe to source standalone: it loads the centralized logger when available and
# provides a no-op fallback when it is absent, so logging never aborts an
# installer.

if [[ -n "${ISC_HELPERS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
ISC_HELPERS_SOURCED=1

# Prefer the shared file logger from this framework checkout. Some older
# consuming repositories still provide their own log LEVEL MESSAGE helper; keep
# that as a compatibility input/output while routing this file's own diagnostics
# through the centralized isc_log_* API.
if ! declare -F isc_log >/dev/null 2>&1; then
  _isc_helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _isc_helpers_dir=""
  if [[ -n "$_isc_helpers_dir" && -f "$_isc_helpers_dir/component_logging.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_isc_helpers_dir/component_logging.sh"
  fi
  unset _isc_helpers_dir
fi
if ! declare -F isc_log >/dev/null 2>&1; then
  if declare -F log >/dev/null 2>&1; then
    isc_log() { log "$@"; }
  else
    isc_log() { :; }
  fi
fi
if ! declare -F isc_log_verbose >/dev/null 2>&1; then
  isc_log_verbose() { isc_log verbose "$@"; }
  isc_log_debug()   { isc_log debug   "$@"; }
  isc_log_info()    { isc_log info    "$@"; }
  isc_log_warn()    { isc_log warn    "$@"; }
  isc_log_error()   { isc_log error   "$@"; }
fi
if ! declare -F log >/dev/null 2>&1; then
  log() { isc_log "$@"; }
fi

# msg - Print a user-facing status line ("==> text") to stdout.
#   Args: $* - message text. Returns: 0.
msg() { printf "\n==> %s\n" "$*"; }

# safe_system_action - Run the framework-owned audible countdown before a
# destructive system action. Args: $1 - reboot or poweroff. Returns only when
# the helper is missing, cancelled, or the system action fails.
safe_system_action() {
  local action="$1"
  local helper="${ISC_COMPONENT_LIB_DIR:-}/safe_system_action.sh"
  if [[ ! -f "$helper" ]]; then
    isc_log_error "safe system action helper missing: $helper"
    msg "ERROR: refusing $action because safe_system_action.sh is unavailable"
    return 1
  fi
  isc_log_warn "starting guarded system action: $action"
  bash "$helper" "$action"
}

# need_cmd - Test whether a command is available on PATH.
#   Args: $1 - command name. Returns: 0 if present, non-zero otherwise.
need_cmd() { isc_log_debug "need_cmd: checking for '$1'"; command -v "$1" >/dev/null 2>&1; }

# is_root - Test whether the script runs with root privileges.
#   Args: none. Returns: 0 when root, non-zero otherwise.
is_root() { isc_log_debug "is_root: euid=$(id -u)"; [ "$(id -u)" -eq 0 ]; }

# installer_auth_enabled - Test whether authenticated/private Git network
# operations are explicitly allowed for this run.
#   Args: none. Returns: 0 when INSTALLER_AUTH=1, non-zero otherwise.
installer_auth_enabled() { [[ "${INSTALLER_AUTH:-0}" == "1" ]]; }

# ensure_linked_repository - Ensure a linked setup repository checkout exists.
#
# Existing sibling checkouts are used as-is by default, avoiding private GitHub
# credential prompts. Passing --auth through the master/framework runtime sets
# INSTALLER_AUTH=1, which permits non-prompting git pull for existing checkouts
# and non-prompting git clone for missing checkouts.
#
# Args:
#   $1 - Human label used in messages.
#   $2 - Checkout directory path.
#   $3 - Git clone URL.
#
# Returns:
#   0 when the checkout exists or was cloned; 1 when missing with auth disabled
#   or when clone/update setup fails.
ensure_linked_repository() {
  local label="$1"
  local repo_dir="$2"
  local repo_url="$3"

  if [[ -d "$repo_dir/.git" ]]; then
    if installer_auth_enabled; then
      msg "Updating existing ${label} repository"
      isc_log_info "git pull linked repository: ${repo_dir}"
      run_as_target env GIT_TERMINAL_PROMPT=0 git -C "$repo_dir" pull || true
    else
      msg "Using existing ${label} repository (pass --auth to update)"
      isc_log_info "using linked repository without git pull: ${repo_dir}"
    fi
    return 0
  fi

  if ! installer_auth_enabled; then
    msg "WARN: ${label} repository not found at '${repo_dir}'; pass --auth or set INSTALLER_AUTH=1 to clone it"
    isc_log_warn "linked repository missing and auth disabled: ${label} at ${repo_dir}"
    return 1
  fi

  msg "Cloning ${label} repository"
  run_as_target mkdir -p "$(dirname "$repo_dir")"
  isc_log_info "git clone linked repository: ${repo_url} -> ${repo_dir}"
  run_as_target env GIT_TERMINAL_PROMPT=0 git clone "$repo_url" "$repo_dir"
}

# Root-only steps skipped during a non-root run; reported at the end.
SUDO_REQUIRED_STEPS=()

# note_sudo_required - Record a skipped root-only step for the final report.
#   Args: $1 - human-readable description. Returns: 0.
note_sudo_required() {
  SUDO_REQUIRED_STEPS+=("$1")
  isc_log_warn "root-only step deferred: $1"
  msg "SKIP (requires sudo): $1"
}

# report_sudo_required - Print all root-only steps skipped this run, if any.
#   Args: none. Returns: 0.
report_sudo_required() {
  [ "${#SUDO_REQUIRED_STEPS[@]}" -eq 0 ] && return 0
  isc_log_warn "root-only steps still pending: ${SUDO_REQUIRED_STEPS[*]}"
  msg "The following steps still require root and were skipped:"
  printf '    - %s\n' "${SUDO_REQUIRED_STEPS[@]}"
  msg "Apply them with: sudo bash install.sh"
}

# apt_install - Ensure one or more apt packages are installed (idempotent).
#   Skips already-present packages and only refreshes the cache when something is
#   missing. When not root, records the step via note_sudo_required and returns 0
#   so a sudo-free run still completes.
#   Args: $@ - apt package names. Returns: 0 on success/deferral; non-zero when
#     apt-get is unavailable or the install fails.
apt_install() {
  local pkg missing=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    isc_log_debug "apt_install: all packages already installed: $*"
    return 0
  fi

  if ! need_cmd apt-get; then
    isc_log_error "apt_install: apt-get not available; cannot install ${missing[*]}"
    return 1
  fi

  if ! is_root; then
    note_sudo_required "apt install ${missing[*]}"
    return 0
  fi

  isc_log_info "Installing apt packages: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || \
    isc_log_warn "apt_install: 'apt-get update' failed; attempting install anyway"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# run_as_target - Run a command as TARGET_USER with that user's desktop session
#   environment (HOME, XDG_RUNTIME_DIR, D-Bus, DISPLAY) populated so that
#   gsettings/systemctl --user calls reach the live session. Uses sudo only when
#   the current user differs from the target, keeping the installer sudo-free in
#   the common standalone case.
#   Args: $@ - command and arguments. Returns: the command's exit status.
run_as_target() {
  isc_log_debug "run_as_target: $*"
  local command_path="${PATH:-}"
  local system_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  local path_entry
  local IFS=:

  # sudo can provide a minimal PATH; keep caller entries but guarantee common
  # system command directories for git, env, bash, mkdir, and sudo.
  for path_entry in $system_path; do
    case ":${command_path}:" in
      *":${path_entry}:"*) ;;
      *) command_path="${command_path:+${command_path}:}${path_entry}" ;;
    esac
  done

  if [ "$(PATH="$command_path" id -un)" = "$TARGET_USER" ]; then
    isc_log_debug "run_as_target: executing directly as $TARGET_USER"
    PATH="$command_path" env \
      HOME="$TARGET_HOME" \
      PATH="$command_path" \
      USER="$TARGET_USER" \
      LOGNAME="$TARGET_USER" \
      SUDO_USER= \
      SUDO_UID= \
      SUDO_GID= \
      XDG_RUNTIME_DIR="$RUNTIME_DIR" \
      DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
      DISPLAY="$DISPLAY_VAL" \
      "$@"
  else
    isc_log_debug "run_as_target: executing via sudo as $TARGET_USER"
    PATH="$command_path" sudo -H -u "$TARGET_USER" env \
      HOME="$TARGET_HOME" \
      PATH="$command_path" \
      USER="$TARGET_USER" \
      LOGNAME="$TARGET_USER" \
      SUDO_USER= \
      SUDO_UID= \
      SUDO_GID= \
      XDG_RUNTIME_DIR="$RUNTIME_DIR" \
      DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
      DISPLAY="$DISPLAY_VAL" \
      "$@"
  fi
}

# ensure_root - Abort unless running as root. For installers whose work is
#   inherently root-only (e.g. apt package installation).
#   Args: none. Exits 1 when not root.
ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    isc_log_error "Please run with sudo: sudo bash $0"
    echo "Please run with sudo: sudo bash $0"
    exit 1
  fi
}

# ensure_session_bus - Abort if the target user has no live D-Bus session bus
#   (required for gsettings/systemctl --user to affect the running desktop).
#   Args: none. Exits 1 when the session bus socket is missing.
ensure_session_bus() {
  if [ ! -S "${RUNTIME_DIR}/bus" ]; then
    isc_log_error "No user session bus at ${RUNTIME_DIR}/bus"
    cat <<EOF
No user session bus at ${RUNTIME_DIR}/bus.
Open a terminal in ${TARGET_USER}'s *logged-in desktop* session and run:
  sudo bash $0
EOF
    exit 1
  fi
}
