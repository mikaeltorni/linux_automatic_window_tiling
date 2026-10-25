#!/usr/bin/env bash
# component_runtime.sh - Shared per-repository installer component runtime.
#
# This is the single source of truth for the standalone installer contract every
# child repository implements. A repository's install.sh sources its step
# libraries, declares a component manifest, and calls component_main "$@". This
# runtime then provides a uniform command-line interface that both humans and
# the master installer rely on:
#
#   install.sh                 # interactive submenu on a TTY, else defaults
#   install.sh --default       # install every default-on component, no prompts
#   install.sh --all           # install every component, no prompts
#   install.sh --select a,b,c  # install exactly these component ids, no prompts
#   install.sh --list-components  # print "id\tlabel\tdefault[\tsection]" lines
#   install.sh --help          # usage
#
# The manifest is an array named ISC_COMPONENTS whose entries are
# "id|label|default|function[|detect_fn[|uninstall_fn[|section[|requires]]]]", where default is "on"
# or "off" and function is the shell function that installs that component
# (already defined by the repository's sourced libraries). The trailing four
# fields are optional:
#
#   detect_fn    - returns 0 when the component is already installed on this
#                  machine, non-zero otherwise. When omitted, the runtime falls
#                  back to an install receipt (a marker file written
#                  automatically after the component's install function
#                  succeeds), so detection works for every component with no
#                  per-component code.
#   uninstall_fn - reverses the component's installation. When omitted, the
#                  component cannot be uninstalled from the menu (only its
#                  receipt is cleared). When present, the runtime runs it and
#                  then clears the receipt.
#   section      - optional visual heading in the component menu.
#   requires     - optional comma-separated component ids. A dependent can be
#                  selected only when every requirement is selected in the same
#                  run or detected as already installed.
#
#   ISC_REPO_NAME="linux_configuration_setup"
#   ISC_REPO_LABEL="GNOME desktop configuration"
#   ISC_COMPONENTS=(
#     "dark_mode|Dark mode and themes|on|configure_dark_mode|detect_dark_mode|uninstall_dark_mode"
#     "easyeffects|EasyEffects EQ presets|off|configure_easyeffects_autostart"
#   )
#   component_main "$@"
#
# The master installer discovers components with --list-components and drives
# installation with --select, so disabled repositories are skipped and partially
# selected repositories install only their chosen components. It discovers
# install state with --detect, reverses components with --uninstall, and
# re-applies configuration of already-installed components with --reconfigure
# (an idempotent re-run of the install functions).
#
# Usage:
#   source "<dir>/component_runtime.sh"

if [[ -n "${ISC_RUNTIME_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
ISC_RUNTIME_SOURCED=1

# Ensure the centralized logging helpers exist. Source component_logging.sh from
# next to this runtime when present, otherwise define silent no-op stubs so every
# isc_log* call below is always safe (logging must never abort an installer).
if ! declare -F isc_log >/dev/null 2>&1; then
  _isc_rt_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _isc_rt_dir=""
  if [[ -n "$_isc_rt_dir" && -f "$_isc_rt_dir/component_logging.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_isc_rt_dir/component_logging.sh"
  fi
  unset _isc_rt_dir
fi
if ! declare -F isc_log >/dev/null 2>&1; then
  isc_log()         { :; }
  isc_log_verbose() { :; }
  isc_log_debug()   { :; }
  isc_log_info()    { :; }
  isc_log_warn()    { :; }
  isc_log_error()   { :; }
fi

# Fallback status printer if the repository did not define msg().
if ! declare -F msg >/dev/null 2>&1; then
  msg() { printf "\n==> %s\n" "$*"; }
fi

###############################################################################
# Manifest accessors
###############################################################################

# Echo the field at index $2 (0-based) of the manifest entry for id $1.
#
# Arguments:
#   $1 - component id to look up.
#   $2 - field index: 0=id, 1=label, 2=default, 3=function, 4=detect,
#        5=uninstall, 6=section, 7=requires, 8=nested configurator,
#        9=config status function, 10="select_configure" when toggling the
#        component on in a menu must immediately open its nested configurator
#        (used for components that cannot install without a typed setting,
#        e.g. a repository name).
#
# Returns:
#   0 and prints the requested field when the id exists; 1 when no entry matches.
_isc_field() {
  local want_id="$1" field="$2" entry id label def fn detect uninstall section requires configure status select_configure
  for entry in "${ISC_COMPONENTS[@]}"; do
    IFS='|' read -r id label def fn detect uninstall section requires configure status select_configure <<<"$entry"
    if [[ "$id" == "$want_id" ]]; then
      case "$field" in
        0) printf '%s' "$id" ;;
        1) printf '%s' "$label" ;;
        2) printf '%s' "$def" ;;
        3) printf '%s' "$fn" ;;
        4) printf '%s' "$detect" ;;
        5) printf '%s' "$uninstall" ;;
        6) printf '%s' "$section" ;;
        7) printf '%s' "$requires" ;;
        8) printf '%s' "$configure" ;;
        9) printf '%s' "$status" ;;
        10) printf '%s' "$select_configure" ;;
      esac
      return 0
    fi
  done
  return 1
}

###############################################################################
# Install receipts and detection
###############################################################################

# Echo the directory that holds this repository's install receipts.
#
# Receipts are small marker files (one per installed component id) that let the
# runtime report install state and drive reconfigure/uninstall without requiring
# a hand-written detect function for every component. The location follows the
# XDG state convention and can be overridden with ISC_RECEIPT_DIR for tests.
#
# Returns:
#   0; prints the receipt directory path for ISC_REPO_NAME.
_isc_receipt_dir() {
  local state_home
  if [[ -n "${ISC_RECEIPT_DIR:-}" ]]; then
    printf '%s/%s' "$ISC_RECEIPT_DIR" "${ISC_REPO_NAME:-installer}"
    return 0
  fi
  state_home="${XDG_STATE_HOME:-}"
  if [[ -z "$state_home" ]]; then
    # Setup installers can run as root while applying user-level work through
    # run_as_target. Component receipts describe the target user's install state,
    # so default them to TARGET_HOME instead of /root when no explicit XDG state
    # override is present.
    state_home="${TARGET_HOME:-$HOME}/.local/state"
  fi
  local base="${state_home}/isc/receipts"
  printf '%s/%s' "$base" "${ISC_REPO_NAME:-installer}"
}

# Record that component id $1 is installed by writing its receipt file.
#
# Failures are non-fatal: a missing receipt only degrades detection to whatever
# the component's detect function reports, so installation must never abort here.
#
# Arguments:
#   $1 - component id to mark installed.
_isc_mark_installed() {
  local id="$1" dir
  dir="$(_isc_receipt_dir)"
  if mkdir -p "$dir" 2>/dev/null; then
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" >"$dir/$id" 2>/dev/null || true
    isc_log_debug "wrote install receipt for '$id' in $dir"
  else
    isc_log_warn "could not create receipt dir $dir for '$id' (detection degraded)"
  fi
}

# Remove the install receipt for component id $1 (used on uninstall).
#
# Arguments:
#   $1 - component id whose receipt should be cleared.
_isc_clear_receipt() {
  local id="$1" dir
  dir="$(_isc_receipt_dir)"
  rm -f "$dir/$id" 2>/dev/null || true
  isc_log_debug "cleared install receipt for '$id'"
}

# Decide whether component id $1 is installed on this machine.
#
# Uses the component's detect function (manifest field 4) as the authoritative
# live result when defined. Falls back to an install receipt only when no custom
# detector exists, so stale receipts never mask a removed or broken feature.
#
# Arguments:
#   $1 - component id to test.
#
# Returns:
#   0 when the component is installed, 1 otherwise.
_isc_is_installed() {
  local id="$1" detect dir
  detect="$(_isc_field "$id" 4)"
  if [[ -n "$detect" ]] && declare -F "$detect" >/dev/null 2>&1; then
    "$detect"
    return $?
  fi
  dir="$(_isc_receipt_dir)"
  [[ -f "$dir/$id" ]]
}

# Print "id<TAB>installed|absent" for every component, in manifest order.
# Consumed by the master installer to mark install state in the aggregate menu.
#
# Returns:
#   0; prints one tab-separated state line per component.
_isc_detect_all() {
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if _isc_is_installed "$id"; then
      printf '%s\tinstalled\n' "$id"
    else
      printf '%s\tabsent\n' "$id"
    fi
  done < <(_isc_all_ids)
}

# Remove converted component IDs in reverse manifest order; preserve receipt-only removal.
# Parameters: $@ - converted component identifiers. Returns: zero on success, two on rejection, one on execution failure.
_isc_uninstall_components() {
  printf 'arguments=%s\n' "$*" >&2
  local selected=" " id_argument
  _isc_validate_ids "$@" || { printf '2\n' >&2; return 2; }
  for id_argument in "$@"; do selected+="$id_argument "; done
  local i entry id label def fn detect un ran=0
  local -a order=() failed=()
  isc_log_info "uninstall requested ids:${selected}"
  for entry in "${ISC_COMPONENTS[@]}"; do
    IFS='|' read -r id label def fn detect un <<<"$entry"
    order+=("$id")
  done
  for (( i=${#order[@]}-1; i>=0; i-- )); do
    id="${order[$i]}"
    [[ "$selected" == *" $id "* ]] || continue
    label="$(_isc_field "$id" 1)"
    un="$(_isc_field "$id" 5)"
    ran=$((ran + 1))
    if [[ -z "$un" ]]; then
      isc_log_warn "component '$id' has no uninstall function — clearing receipt only"
      msg "[$ISC_REPO_NAME] '$label' ($id) has no uninstall step — clearing its install record only."
      _isc_clear_receipt "$id"
      continue
    fi
    if ! declare -F "$un" >/dev/null 2>&1; then
      isc_log_warn "uninstall function '$un' for '$id' is not defined — skipping"
      msg "WARN: uninstall function '$un' for component '$id' is not defined — skipping"
      failed+=("$id")
      continue
    fi
    isc_log_info "uninstalling component: $label ($id) via $un"
    msg "[$ISC_REPO_NAME] Uninstalling component: $label ($id)"
    if ! "$un"; then
      isc_log_error "uninstall of '$id' failed (continuing)"
      msg "WARN: uninstall of '$id' failed (continuing)"
      failed+=("$id")
    else
      _isc_clear_receipt "$id"
      isc_log_info "component '$id' uninstalled"
    fi
  done
  if (( ran == 0 )); then
    msg "[$ISC_REPO_NAME] No components selected to uninstall — nothing to do."
  fi
  if (( ${#failed[@]} > 0 )); then
    msg "[$ISC_REPO_NAME] Components with uninstall failures: ${failed[*]}"
    printf '%s\n' 1 >&2
    return 1
  fi
  printf '%s\n' 0 >&2
  return 0
}

# Echo all component ids in manifest order, one per line.
#
# Arguments:
#   none (reads the ISC_COMPONENTS manifest).
#
# Returns:
#   0; prints every component id on its own line.
_isc_all_ids() {
  local entry id rest
  for entry in "${ISC_COMPONENTS[@]}"; do
    IFS='|' read -r id rest <<<"$entry"
    printf '%s\n' "$id"
  done
}

# Echo the ids whose default field is "on", in manifest order, one per line.
#
# Arguments:
#   none (reads the ISC_COMPONENTS manifest).
#
# Returns:
#   0; prints each default-on component id on its own line.
_isc_default_ids() {
  local entry id label def rest
  for entry in "${ISC_COMPONENTS[@]}"; do
    IFS='|' read -r id label def rest <<<"$entry"
    [[ "$def" == "on" ]] && printf '%s\n' "$id"
  done
}

###############################################################################
# Sub-commands
###############################################################################

# Print "id<TAB>label<TAB>default[<TAB>section[<TAB>requires]]" for every
# component. Consumed
# by the master installer to build the aggregate menu without sourcing internals.
#
# Arguments:
#   none (reads the ISC_COMPONENTS manifest).
#
# Returns:
#   0; prints one tab-separated line per component.
_isc_list_components() {
  local entry id label def fn detect uninstall section requires configure
  for entry in "${ISC_COMPONENTS[@]}"; do
    IFS='|' read -r id label def fn detect uninstall section requires configure <<<"$entry"
    if [[ -n "$requires" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$def" "$section" "$requires"
    elif [[ -n "$section" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$id" "$label" "$def" "$section"
    else
      printf '%s\t%s\t%s\n' "$id" "$label" "$def"
    fi
  done
}

# List component ids that expose repository-owned nested configuration screens.
_isc_list_configurable_components() {
  local id configure
  while IFS= read -r id; do
    configure="$(_isc_field "$id" 8)"
    [[ -n "$configure" ]] && printf '%s\n' "$id"
  done < <(_isc_all_ids)
  return 0
}

# List component ids whose nested configurator must open immediately when the
# component is toggled on in a menu (manifest field 10 = "select_configure").
_isc_list_select_configure_components() {
  local id
  while IFS= read -r id; do
    [[ "$(_isc_field "$id" 10)" == "select_configure" ]] && printf '%s\n' "$id"
  done < <(_isc_all_ids)
  return 0
}

# Print ``id<TAB>friendly current value`` for editable components whose tenth
# manifest field names a side-effect-free status function.
_isc_list_component_config_values() {
  local id status value
  while IFS= read -r id; do
    status="$(_isc_field "$id" 9)"
    [[ -n "$status" ]] || continue
    declare -F "$status" >/dev/null 2>&1 || continue
    value="$("$status" 2>/dev/null || true)"
    [[ -n "$value" ]] && printf '%s\t%s\n' "$id" "$value"
  done < <(_isc_all_ids)
}

# Run one component's nested configurator without installing the component.
_isc_configure_component() {
  local id="$1" configure
  configure="$(_isc_field "$id" 8)" || {
    isc_log_error "unknown component requested for nested configuration: $id"
    return 2
  }
  if [[ -z "$configure" ]] || ! declare -F "$configure" >/dev/null 2>&1; then
    isc_log_error "component '$id' has no callable nested configurator"
    return 2
  fi
  isc_log_info "running nested configurator component=$id function=$configure"
  "$configure"
}

# Decide whether every requirement for component id $1 is either selected in
# the current operation or already installed. This mirrors the interactive
# menu guard for explicit --select/--default/--all invocations.
#
# Arguments:
#   $1 - dependent component id.
#   $2 - normalized successfully-completed id string padded with spaces.
#
# Returns:
#   0 when all requirements are satisfied; 1 otherwise.
_isc_requirements_satisfied() {
  local id="$1" completed="$2" raw requirement
  raw="$(_isc_field "$id" 7)"
  [[ -z "$raw" ]] && return 0
  for requirement in ${raw//,/ }; do
    [[ -n "$requirement" ]] || continue
    if [[ "$completed" == *" $requirement "* ]] || _isc_is_installed "$requirement"; then
      continue
    fi
    return 1
  done
  return 0
}

# Install converted IDs in manifest order after validating the complete selection.
# Core runs for empty selections. Derived selections skip unavailable prerequisites;
# explicit selections report them as failures. Component failures do not stop siblings.
# Parameters: $1 - strict/derived origin; remaining arguments - converted component IDs.
# Returns: zero on success, one for component failures, two for rejected input or core failure.
_isc_install_components() {
  printf 'arguments=%s\n' "$*" >&2
  local selected=" " id_argument
  local strictness="$1"; shift
  _isc_validate_ids "$@" || { printf '2\n' >&2; return 2; }
  for id_argument in "$@"; do selected+="$id_argument "; done
  local completed=" "
  local entry id label def fn detect uninstall section requires requirement ran=0
  local -a failed=()
  isc_log_info "run_selected requested ids:${selected}"
  # Install the repository core before anything else, regardless of selection.
  if [[ -n "${ISC_CORE:-}" ]] && declare -F "$ISC_CORE" >/dev/null 2>&1; then
    isc_log_info "running core install '$ISC_CORE'"
    if ! "$ISC_CORE"; then
      isc_log_error "core install '$ISC_CORE' failed — not installing components"
      msg "ERROR: [$ISC_REPO_NAME] core install '$ISC_CORE' failed — aborting" >&2
      printf '%s\n' 2 >&2
      return 2
    fi
  elif [[ -n "${ISC_CORE:-}" ]]; then
    isc_log_warn "core install function '$ISC_CORE' is not defined — skipping"
    msg "WARN: core install function '$ISC_CORE' is not defined — skipping" >&2
  fi
  for entry in "${ISC_COMPONENTS[@]}"; do
    IFS='|' read -r id label def fn detect uninstall section requires <<<"$entry"
    [[ "$selected" == *" $id "* ]] || continue
    if ! _isc_requirements_satisfied "$id" "$completed"; then
      for requirement in ${requires//,/ }; do
        if [[ "$completed" != *" $requirement "* ]] && ! _isc_is_installed "$requirement"; then
          break
        fi
      done
      msg "WARN: component '$id' requires component '$requirement' to be selected or installed — skipping"
      if [[ "$strictness" == "strict" ]]; then
        isc_log_error "component '$id' requires unavailable component '$requirement'"
        failed+=("$id")
      else
        isc_log_warn "skipping '$id': requirement '$requirement' is not selected or installed"
      fi
      continue
    fi
    # Run the optional one-time preflight (e.g. ensuring the session bus) just
    # before the first real component, so an empty/unmatched selection is a
    # genuine no-op.
    if (( ran == 0 )) && [[ -n "${ISC_PREFLIGHT:-}" ]] \
       && declare -F "$ISC_PREFLIGHT" >/dev/null 2>&1; then
      isc_log_debug "running preflight '$ISC_PREFLIGHT'"
      "$ISC_PREFLIGHT" || {
        isc_log_warn "preflight '$ISC_PREFLIGHT' reported a problem (continuing)"
        msg "WARN: preflight '$ISC_PREFLIGHT' reported a problem (continuing)"
      }
    fi
    ran=$((ran + 1))
    if [[ -z "$fn" ]]; then
      isc_log_warn "component '$id' has no install function — skipping"
      msg "WARN: component '$id' has no install function — skipping"
      continue
    fi
    if ! declare -F "$fn" >/dev/null 2>&1; then
      isc_log_warn "install function '$fn' for component '$id' is not defined — skipping"
      msg "WARN: install function '$fn' for component '$id' is not defined — skipping"
      failed+=("$id")
      continue
    fi
    isc_log_info "installing component: $label ($id) via $fn"
    msg "[$ISC_REPO_NAME] Installing component: $label ($id)"
    if ! "$fn"; then
      isc_log_error "component '$id' failed (continuing)"
      msg "WARN: component '$id' failed (continuing)"
      failed+=("$id")
    else
      isc_log_info "component '$id' completed"
      _isc_mark_installed "$id"
      completed+="$id "
    fi
  done
  # Optional postflight (e.g. audits, sudo-required summaries) after components.
  if (( ran > 0 )) && [[ -n "${ISC_POSTFLIGHT:-}" ]] \
     && declare -F "$ISC_POSTFLIGHT" >/dev/null 2>&1; then
    isc_log_debug "running postflight '$ISC_POSTFLIGHT'"
    "$ISC_POSTFLIGHT" || {
      isc_log_warn "postflight '$ISC_POSTFLIGHT' reported a problem (continuing)"
      msg "WARN: postflight '$ISC_POSTFLIGHT' reported a problem (continuing)"
    }
  fi

  if (( ran == 0 )); then
    isc_log_info "no components selected — nothing to do"
    msg "[$ISC_REPO_NAME] No components selected — nothing to do."
  fi
  if (( ${#failed[@]} > 0 )); then
    isc_log_error "components with failures: ${failed[*]}"
    msg "[$ISC_REPO_NAME] Components with failures: ${failed[*]}"
    printf '%s\n' 1 >&2
    return 1
  fi
  isc_log_info "run_selected completed successfully ($ran component(s))"
  printf '%s\n' 0 >&2
  return 0
}

# Load installation_config.sh from the framework directory when available.
_isc_load_config_module() {
  declare -F isc_config_apply_active >/dev/null 2>&1 && return 0
  local here dir
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for dir in "${ISC_COMPONENT_LIB_DIR:-}" "$here"; do
    [[ -n "$dir" && -f "$dir/installation_config.sh" ]] || continue
    ISC_CONFIG_REPO_ROOT="${SCRIPT_DIR:-$PWD}"
    # shellcheck source=/dev/null
    source "$dir/installation_config.sh" && return 0
  done
  isc_log_warn "installation_config.sh not found — config flags disabled"
  return 1
}

# Populate standalone component state, including headless export fields.
# Parameters: none. Returns: zero after preparing all shared state arrays.
_isc_prepare_selection_state() {
  printf 'parameters=none\n' >&2
  local repo="${ISC_REPO_NAME:-repo}" id def
  if ! declare -p CM_REPOS >/dev/null 2>&1; then
    declare -gA CM_REPO_LABEL CM_REPO_ENABLED CM_REPO_AWARE
    declare -gA CM_COMP_IDS CM_COMP_LABEL CM_COMP_SECTION CM_COMP_REQUIRES CM_COMP_ON
    declare -gA CM_COMP_INSTALLED CM_COMP_UNINSTALL
    declare -gA CM_COMP_FAVORITE_ELIGIBLE CM_COMP_FAVORITE_ON CM_COMP_FAVORITE_DESKTOPS
    declare -gA CM_COMP_STARTUP_ELIGIBLE CM_COMP_STARTUP_ON CM_COMP_STARTUP_SPECS
    declare -gA CM_COMP_WORKSPACE_ELIGIBLE CM_COMP_WORKSPACE CM_COMP_WORKSPACE_SPECS
    declare -gA CM_COMP_STICKY_ELIGIBLE CM_COMP_STICKY_ON CM_COMP_STICKY_SPECS
    declare -gA CM_COMP_MONITOR_ELIGIBLE CM_COMP_MONITOR
    declare -gA CM_COMP_CONFIGURE_ELIGIBLE CM_COMP_CONFIG_VALUE CM_COMP_CONFIGURE_ON_SELECT
    declare -ga CM_REPOS
  fi
  CM_REPOS=("$repo")
  CM_REPO_LABEL[$repo]="${ISC_REPO_LABEL:-$repo}"
  CM_REPO_ENABLED[$repo]=1
  local ids=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    ids+="$id "
    CM_COMP_LABEL[$repo|$id]="$(_isc_field "$id" 1)"
    CM_COMP_SECTION[$repo|$id]="$(_isc_field "$id" 6)"
    CM_COMP_REQUIRES[$repo|$id]="$(_isc_field "$id" 7)"
    if [[ -n "$(_isc_field "$id" 8)" ]]; then
      CM_COMP_CONFIGURE_ELIGIBLE[$repo|$id]=1
    else
      CM_COMP_CONFIGURE_ELIGIBLE[$repo|$id]=0
    fi
    if [[ "$(_isc_field "$id" 10)" == "select_configure" ]]; then
      CM_COMP_CONFIGURE_ON_SELECT[$repo|$id]=1
    else
      CM_COMP_CONFIGURE_ON_SELECT[$repo|$id]=0
    fi
    CM_COMP_CONFIG_VALUE[$repo|$id]=""
    local status_fn
    status_fn="$(_isc_field "$id" 9)"
    if [[ -n "$status_fn" ]] && declare -F "$status_fn" >/dev/null 2>&1; then
      CM_COMP_CONFIG_VALUE[$repo|$id]="$("$status_fn" 2>/dev/null || true)"
    fi
    CM_COMP_UNINSTALL[$repo|$id]=0
    CM_COMP_FAVORITE_ELIGIBLE[$repo|$id]=0
    CM_COMP_FAVORITE_ON[$repo|$id]=0
    CM_COMP_STARTUP_ELIGIBLE[$repo|$id]=0
    CM_COMP_STARTUP_ON[$repo|$id]=0
    CM_COMP_WORKSPACE_ELIGIBLE[$repo|$id]=0
    CM_COMP_WORKSPACE[$repo|$id]=0
    CM_COMP_STICKY_ELIGIBLE[$repo|$id]=0
    CM_COMP_STICKY_ON[$repo|$id]=0
    if [[ "${ISC_EXPORT_MANIFEST_DEFAULTS:-0}" == "1" ]]; then
      CM_COMP_INSTALLED[$repo|$id]=0
      def="$(_isc_field "$id" 2)"
      [[ "$def" == "on" ]] && CM_COMP_ON[$repo|$id]=1 || CM_COMP_ON[$repo|$id]=0
    elif _isc_is_installed "$id"; then
      CM_COMP_INSTALLED[$repo|$id]=1
      CM_COMP_ON[$repo|$id]=0
    else
      CM_COMP_INSTALLED[$repo|$id]=0
      def="$(_isc_field "$id" 2)"
      [[ "$def" == "on" ]] && CM_COMP_ON[$repo|$id]=1 || CM_COMP_ON[$repo|$id]=0
    fi
  done < <(_isc_all_ids)
  CM_COMP_IDS[$repo]="${ids% }"
  # The menu module (owner of cm_reconcile_dependencies) is only loaded for
  # interactive runs; a missing function must not fail this helper, or callers
  # running under `set -e` (every child install.sh) abort in the no-TTY path.
  if declare -F cm_reconcile_dependencies >/dev/null 2>&1; then
    cm_reconcile_dependencies "$repo"
  fi
  printf '0\n' >&2
  return 0
}

# Print usage.
_isc_usage() {
  cat <<EOF
${ISC_REPO_NAME:-installer} — component-based installer

Usage:
  bash install.sh                 Interactive component selection (TTY), else defaults
  bash install.sh --config NAME   Load installation_configs/NAME (default: default.json)
  bash install.sh --default       Install all default-on components, no prompts
  bash install.sh --all           Install every component, no prompts
  bash install.sh --select a,b,c  Install exactly these component ids, no prompts
  bash install.sh --reconfigure a,b,c  Re-apply config of these (idempotent re-run)
  bash install.sh --uninstall a,b,c    Uninstall exactly these component ids
  bash install.sh --auth          Allow authenticated Git clone/pull in components
  bash install.sh --list-components  List: id<TAB>label<TAB>default[<TAB>section[<TAB>requires]]
  bash install.sh --list-configurable-components  List ids with nested detail screens
  bash install.sh --list-select-configure-components  List ids that configure on select
  bash install.sh --list-component-config-values  List editable ids and current values
  bash install.sh --configure-component ID  Open one nested detail screen
  bash install.sh --detect        Show install state as: id<TAB>installed|absent
  bash install.sh --export-selection  Export resolved selection as JSON (side-effect free)
  bash install.sh --help          Show this help

Components:
$(_isc_list_components | sed 's/^/  /')
EOF
}

###############################################################################
# Interactive submenu (standalone, on a TTY)
###############################################################################

# Locate and source the shared menu engine, downloading it if necessary.
#
# Looks next to this runtime file first (the vendored copy), then falls back to
# downloading from the installation_scripts repository. Returns non-zero if the
# engine could not be made available.
_isc_load_menu() {
  declare -F cm_single_submenu >/dev/null 2>&1 && return 0
  local here menu
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Prefer the directory resolved by component_loader.sh, then this file's own
  # directory (the two are normally the same vendored/cloned location).
  local dir
  for dir in "${ISC_COMPONENT_LIB_DIR:-}" "$here"; do
    [[ -n "$dir" && -f "$dir/component_menu.sh" ]] || continue
    isc_log_debug "sourcing menu engine from local dir: $dir"
    # shellcheck source=/dev/null
    source "$dir/component_menu.sh" && return 0
  done
  local raw="${ISC_MENU_RAW_URL:-https://raw.githubusercontent.com/mikaeltorni/linux_installation_scripts_functions/master/component_menu.sh}"
  isc_log_debug "menu engine not found locally — downloading from $raw"
  local tmp
  tmp="$(mktemp 2>/dev/null)" || { isc_log_error "mktemp failed while fetching menu engine"; return 1; }
  if command -v curl >/dev/null 2>&1 && curl -fsSL "$raw" -o "$tmp" 2>/dev/null; then
    # shellcheck source=/dev/null
    source "$tmp" && { rm -f "$tmp"; return 0; }
  elif command -v wget >/dev/null 2>&1 && wget -qO "$tmp" "$raw" 2>/dev/null; then
    # shellcheck source=/dev/null
    source "$tmp" && { rm -f "$tmp"; return 0; }
  fi
  rm -f "$tmp"
  isc_log_error "could not load menu engine (no local copy and download failed)"
  return 1
}

# Build the CM_* arrays for this single repo and run the submenu.
#
# Echoes the selected ids (newline-separated) on stdout and returns 0 when the
# user accepted, or returns 1 when cancelled / the menu was unavailable.
_isc_interactive_select() {
  if ! _isc_load_menu; then
    isc_log_warn "interactive menu unavailable — caller will fall back to defaults"
    return 2
  fi
  local repo="${ISC_REPO_NAME:-repo}" id def
  CM_REPOS=("$repo")
  CM_REPO_LABEL[$repo]="${ISC_REPO_LABEL:-$repo}"
  CM_REPO_ENABLED[$repo]=1
  local ids=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    ids+="$id "
    CM_COMP_LABEL[$repo|$id]="$(_isc_field "$id" 1)"
    CM_COMP_SECTION[$repo|$id]="$(_isc_field "$id" 6)"
    CM_COMP_REQUIRES[$repo|$id]="$(_isc_field "$id" 7)"
    if [[ -n "$(_isc_field "$id" 8)" ]]; then
      CM_COMP_CONFIGURE_ELIGIBLE[$repo|$id]=1
    else
      CM_COMP_CONFIGURE_ELIGIBLE[$repo|$id]=0
    fi
    if [[ "$(_isc_field "$id" 10)" == "select_configure" ]]; then
      CM_COMP_CONFIGURE_ON_SELECT[$repo|$id]=1
    else
      CM_COMP_CONFIGURE_ON_SELECT[$repo|$id]=0
    fi
    CM_COMP_CONFIG_VALUE[$repo|$id]=""
    local status_fn
    status_fn="$(_isc_field "$id" 9)"
    if [[ -n "$status_fn" ]] && declare -F "$status_fn" >/dev/null 2>&1; then
      CM_COMP_CONFIG_VALUE[$repo|$id]="$("$status_fn" 2>/dev/null || true)"
    fi
    CM_COMP_UNINSTALL[$repo|$id]=0
    # Reflect live install state so the menu can show installed/reconfigure
    # markers and offer uninstall. Already-installed components default to
    # "leave as-is" (off) so a re-run never silently re-applies them; absent
    # components default to the manifest's default-on flag.
    if _isc_is_installed "$id"; then
      CM_COMP_INSTALLED[$repo|$id]=1
      CM_COMP_ON[$repo|$id]=0
    else
      CM_COMP_INSTALLED[$repo|$id]=0
      def="$(_isc_field "$id" 2)"
      [[ "$def" == "on" ]] && CM_COMP_ON[$repo|$id]=1 || CM_COMP_ON[$repo|$id]=0
    fi
  done < <(_isc_all_ids)
  CM_COMP_IDS[$repo]="${ids% }"
  _isc_menu_configure_callback() {
    local callback_repo="$1" callback_id="$2" status_fn
    [[ "$callback_repo" == "$repo" ]] || return 2
    _isc_configure_component "$callback_id" || return $?
    status_fn="$(_isc_field "$callback_id" 9)"
    if [[ -n "$status_fn" ]] && declare -F "$status_fn" >/dev/null 2>&1; then
      CM_COMP_CONFIG_VALUE[$repo|$callback_id]="$("$status_fn" 2>/dev/null || true)"
    fi
  }
  CM_CONFIGURE_CALLBACK=_isc_menu_configure_callback
  declare -F cm_reconcile_dependencies >/dev/null 2>&1 && cm_reconcile_dependencies "$repo"

  if cm_single_submenu "$repo"; then
    isc_log_info "interactive selection accepted for repo '$repo'"
    ISC_SELECTED_APPLY=""
    ISC_SELECTED_UNINSTALL=""
    for id in ${CM_COMP_IDS[$repo]}; do
      if [[ "${CM_COMP_UNINSTALL[$repo|$id]:-0}" == "1" ]]; then
        ISC_SELECTED_UNINSTALL+="$id "
      elif [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then
        ISC_SELECTED_APPLY+="$id "
      fi
    done
    ISC_SELECTED_APPLY="${ISC_SELECTED_APPLY% }"
    ISC_SELECTED_UNINSTALL="${ISC_SELECTED_UNINSTALL% }"
    return 0
  fi
  isc_log_info "interactive selection cancelled for repo '$repo'"
  return 1
}

###############################################################################
# Entry point
###############################################################################

# Normalize one public component list into converted identifier arguments.
# Parameters: $1 - raw comma/whitespace list. Returns: zero and _ISC_IDS, or two for malformed syntax.
_isc_parse_ids() {
  printf 'raw_ids=%s\n' "$1" >&2
  local raw="$1" id
  _ISC_IDS=()
  if [[ "$raw" == ,* || "$raw" == *, || "$raw" =~ ,[[:space:]]*, ]]; then
    printf 'ERROR: malformed component list: %s\n2\n' "$raw" >&2
    return 2
  fi
  raw="${raw//,/ }"
  raw="${raw//$'\n'/ }"
  read -r -a _ISC_IDS <<< "$raw"
  for id in "${_ISC_IDS[@]}"; do
    if [[ ! "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ ]]; then
      printf 'ERROR: malformed component identifier: %s\n2\n' "$id" >&2
      return 2
    fi
  done
  printf 'ids=%s status=0\n' "${_ISC_IDS[*]}" >&2
  return 0
}

# Accept only distinct converted component IDs present in this manifest.
# Parameters: $@ - converted identifiers. Returns: zero, or two before mutation on invalid IDs/resources.
_isc_validate_ids() {
  printf 'ids=%s\n' "$*" >&2
  local id entry manifest_id rest found
  local -A seen=()
  if ! declare -p ISC_COMPONENTS >/dev/null 2>&1 || [[ ${#ISC_COMPONENTS[@]} -eq 0 ]]; then
    printf 'ERROR: ISC_COMPONENTS manifest is not defined\n2\n' >&2
    return 2
  fi
  for id in "$@"; do
    found=0
    for entry in "${ISC_COMPONENTS[@]}"; do
      IFS='|' read -r manifest_id rest <<< "$entry"
      [[ "$id" != "$manifest_id" ]] || found=1
    done
    if [[ "$found" == 0 || -n "${seen[$id]:-}" ]]; then
      printf 'ERROR: unknown or duplicate component: %s\n2\n' "$id" >&2
      return 2
    fi
    seen[$id]=1
  done
  printf '0\n' >&2
  return 0
}

# Parse the entire command before routing any operation; reuse a prepared parse.
# Parameters: $@ - raw installer arguments. Returns: zero and converted ISC_ARGUMENT_* globals, or two.
isc_parse_arguments() {
  printf 'arguments=%s\n' "$*" >&2
  local key token value mode="" origin=derived config="" auth=0 list=""
  printf -v key '%q ' "$@"
  key="$#:$key"
  if [[ "${_ISC_ARGUMENT_KEY:-unset}" == "$key" ]]; then
    printf '0\n' >&2
    return 0
  fi
  while (( $# )); do
    token="$1"; shift
    case "$token" in
      --auth) auth=1; continue ;;
      --config|--select|--reconfigure|--uninstall|--configure-component)
        if (( $# == 0 )) || [[ "$1" == --* ]]; then
          printf 'ERROR: missing value for %s\n2\n' "$token" >&2
          return 2
        fi
        value="$1"; shift
        ;;
      --config=*|--select=*|--reconfigure=*|--uninstall=*|--configure-component=*)
        value="${token#*=}"; token="${token%%=*}" ;;
      --default|--all|--list-components|--list-configurable-components|--list-select-configure-components|--list-component-config-values|--detect|--export-selection|--help|-h)
        value="" ;;
      *) printf 'ERROR: unknown option or argument: %s\n2\n' "$token" >&2; return 2 ;;
    esac
    if [[ "$token" == --config ]]; then
      if [[ -z "$value" || -n "$config" ]]; then
        printf 'ERROR: config needs one nonempty value\n2\n' >&2
        return 2
      fi
      config="$value"
      continue
    fi
    if [[ -n "$mode" ]]; then
      printf 'ERROR: conflicting installer modes\n2\n' >&2
      return 2
    fi
    case "$token" in
      --default) mode=default ;;
      --all) mode=all ;;
      --select|--reconfigure) mode=select; origin=strict; list="$value" ;;
      --uninstall) mode=uninstall; list="$value" ;;
      -h) mode=--help ;;
      *) mode="$token"; list="$value" ;;
    esac
    if [[ "$token" == --configure-component && ( -z "$value" || "$value" == *[,$' \t\n']* ) ]]; then
      printf 'ERROR: configure-component requires one identifier\n2\n' >&2
      return 2
    fi
  done
  _isc_parse_ids "$list" || { printf '2\n' >&2; return 2; }
  ISC_ARGUMENT_MODE="$mode"
  ISC_ARGUMENT_ORIGIN="$origin"
  ISC_ARGUMENT_CONFIG="$config"
  ISC_ARGUMENT_AUTH="$auth"
  ISC_ARGUMENT_IDS=("${_ISC_IDS[@]}")
  _ISC_ARGUMENT_KEY="$key"
  printf 'mode=%s origin=%s config=%s auth=%s ids=%s status=0\n' "$mode" "$origin" "$config" "$auth" "${ISC_ARGUMENT_IDS[*]}" >&2
  return 0
}

# Resolve a manifest-derived default or complete selection as an argument array.
# Parameters: $1 - default/all selector. Returns: zero and _ISC_DERIVED_IDS.
_isc_resolve_derived_ids() {
  printf 'selector=%s\n' "$1" >&2
  local entry id label default rest
  _ISC_DERIVED_IDS=()
  for entry in "${ISC_COMPONENTS[@]}"; do
    IFS='|' read -r id label default rest <<< "$entry"
    if [[ "$1" == all || "$default" == on ]]; then
      _ISC_DERIVED_IDS+=("$id")
    fi
  done
  printf 'ids=%s status=0\n' "${_ISC_DERIVED_IDS[*]}" >&2
  return 0
}

# Preserve the legacy public list entrypoint while passing converted IDs to installation.
# Parameters: $1 - raw component list; $2 - optional strict/derived origin. Returns: operation exit status.
_isc_run_selected() {
  printf 'raw_ids=%s origin=%s\n' "$1" "${2:-derived}" >&2
  local rc
  _isc_parse_ids "$1" || { printf '2\n' >&2; return 2; }
  _isc_install_components "${2:-derived}" "${_ISC_IDS[@]}"; rc=$?
  printf '%s\n' "$rc" >&2
  return "$rc"
}

# Preserve the legacy public list entrypoint while passing converted IDs to removal.
# Parameters: $1 - raw component list. Returns: operation exit status.
_isc_uninstall_selected() {
  printf 'raw_ids=%s\n' "$1" >&2
  local rc
  _isc_parse_ids "$1" || { printf '2\n' >&2; return 2; }
  _isc_uninstall_components "${_ISC_IDS[@]}"; rc=$?
  printf '%s\n' "$rc" >&2
  return "$rc"
}

# Route read-only and removal requests before an owner's separately managed core.
# Parameters: $@ - raw installer arguments. Returns: one for installation, otherwise exits with the handled status.
isc_route_readonly_args() {
  printf 'arguments=%s\n' "$*" >&2
  local rc
  isc_parse_arguments "$@" || { rc=$?; printf '%s\n' "$rc" >&2; exit "$rc"; }
  _isc_route_prepared "$ISC_ARGUMENT_MODE" "$ISC_ARGUMENT_ORIGIN" "$ISC_ARGUMENT_CONFIG" "$ISC_ARGUMENT_AUTH" "${ISC_ARGUMENT_IDS[@]}"; rc=$?
  printf '%s\n' "$rc" >&2
  return "$rc"
}

# Validate a converted request before an owner performs its separately managed core.
# Parameters: $1 - mode; $2 - origin; $3 - config; $4 - auth; remaining - converted IDs.
# Returns: one for installation; handled requests exit with their operation status.
_isc_route_prepared() {
  printf 'mode=%s origin=%s config=%s auth=%s ids=%s\n' "$1" "$2" "$3" "$4" "${*:5}" >&2
  local rc
  _isc_validate_ids "${@:5}" || { rc=$?; printf '%s\n' "$rc" >&2; exit "$rc"; }
  case "$1" in
    --*|uninstall)
      _isc_apply_request "$@"; rc=$?
      printf '%s\n' "$rc" >&2
      exit "$rc"
      ;;
  esac
  printf '1\n' >&2
  return 1
}

# Dispatch one completely parsed installer request.
# Parameters: $@ - raw installer arguments. Returns: selected operation exit status.
component_main() {
  printf 'arguments=%s\n' "$*" >&2
  local rc
  isc_parse_arguments "$@" || { rc=$?; printf '%s\n' "$rc" >&2; return "$rc"; }
  _isc_apply_request "$ISC_ARGUMENT_MODE" "$ISC_ARGUMENT_ORIGIN" "$ISC_ARGUMENT_CONFIG" "$ISC_ARGUMENT_AUTH" "${ISC_ARGUMENT_IDS[@]}"; rc=$?
  printf '%s\n' "$rc" >&2
  return "$rc"
}

# Apply converted options and invoke installation, removal or read-only operations.
# Parameters: $1 - mode; $2 - origin; $3 - config; $4 - auth; remaining - converted IDs. Returns: operation status.
_isc_apply_request() {
  printf 'mode=%s origin=%s config=%s auth=%s ids=%s\n' "$1" "$2" "$3" "$4" "${*:5}" >&2
  local mode="$1" origin="$2" config="$3" auth="$4" rc=0
  shift 4
  _isc_validate_ids "$@" || { printf '2\n' >&2; return 2; }
  if [[ -n "$config" ]]; then
    ISC_CONFIG_NAME="$config"; ISC_CONFIG_EXPLICIT=1
    export ISC_CONFIG_NAME ISC_CONFIG_EXPLICIT
  fi
  if [[ "$auth" == 1 ]]; then INSTALLER_AUTH=1; export INSTALLER_AUTH; fi
  case "$mode" in
    --list-components) _isc_list_components ;;
    --list-configurable-components) _isc_list_configurable_components ;;
    --list-select-configure-components) _isc_list_select_configure_components ;;
    --list-component-config-values) _isc_list_component_config_values ;;
    --configure-component) _isc_configure_component "$@" ;;
    --detect) _isc_detect_all ;;
    --help) _isc_usage ;;
    --export-selection)
      local bootstrap_mode="manifest"
      [[ "${ISC_CONFIG_EXPLICIT:-0}" == "1" ]] && bootstrap_mode="config_export"
      _isc_prepare_selection_state
      if _isc_load_config_module; then
        isc_bootstrap_selection "$bootstrap_mode"
        isc_config_export_json "standalone" "${ISC_REPO_NAME:-repo}" "/dev/stdout"
      fi
      ;;
    default|all)
      _isc_resolve_derived_ids "$mode"
      _isc_install_components "$origin" "${_ISC_DERIVED_IDS[@]}"; rc=$?
      printf '%s\n' "$rc" >&2
      return "$rc"
      ;;
    select)    _isc_install_components "$origin" "$@"; rc=$?; printf '%s\n' "$rc" >&2; return "$rc" ;;
    uninstall) _isc_uninstall_components "$@"; rc=$?; printf '%s\n' "$rc" >&2; return "$rc" ;;
    "")
      # No mode requested. Use the interactive submenu on a real terminal,
      # otherwise apply the active installation config (default.json when unset).
      _isc_prepare_selection_state
      if _isc_load_config_module; then
        isc_bootstrap_selection config_active
      fi
      if [[ -t 0 && -t 1 ]]; then
        local rc apply_rc=0 uninstall_rc=0
        if ! _isc_load_menu; then
          isc_log_warn "interactive menu unavailable — using config selection"
          msg "Interactive menu unavailable — using installation config selection."
        else
          local repo="${ISC_REPO_NAME:-repo}" id
          # Configure the selected repository component.
          # Parameters: $1 - repository; $2 - component. Returns: callback exit status.
          _isc_menu_configure_callback() {
            printf 'repository=%s component=%s\n' "$1" "$2" >&2
            local callback_repo="$1" callback_id="$2" status_fn
            [[ "$callback_repo" == "$repo" ]] || { printf '2\n' >&2; return 2; }
            _isc_configure_component "$callback_id" || { local callback_rc=$?; printf '%s\n' "$callback_rc" >&2; return "$callback_rc"; }
            status_fn="$(_isc_field "$callback_id" 9)"
            if [[ -n "$status_fn" ]] && declare -F "$status_fn" >/dev/null 2>&1; then
              CM_COMP_CONFIG_VALUE[$repo|$callback_id]="$("$status_fn" 2>/dev/null || true)"
            fi
            printf '0\n' >&2
            return 0
          }
          CM_CONFIGURE_CALLBACK=_isc_menu_configure_callback
          if cm_single_submenu "$repo"; then rc=0; else rc=$?; fi
          if (( rc != 0 )); then
            isc_log_info "selection cancelled — nothing changed"
            msg "Selection cancelled — nothing changed."
            printf '0\n' >&2
            return 0
          fi
        fi
        if _isc_load_config_module; then
          isc_config_prompt_save "standalone" "${ISC_REPO_NAME:-repo}"
        fi
        local -a apply_ids=() uninstall_ids=()
        for id in ${CM_COMP_IDS[$repo]:-}; do
          if [[ "${CM_COMP_UNINSTALL[$repo|$id]:-0}" == "1" ]]; then
            uninstall_ids+=("$id")
          elif [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then
            apply_ids+=("$id")
          fi
        done
        ISC_SELECTED_APPLY="${apply_ids[*]}"
        ISC_SELECTED_UNINSTALL="${uninstall_ids[*]}"
        if (( ${#uninstall_ids[@]} )); then
          _isc_uninstall_components "${uninstall_ids[@]}" || uninstall_rc=$?
        fi
        if (( ${#apply_ids[@]} )); then
          _isc_install_components "$origin" "${apply_ids[@]}" || apply_rc=$?
        elif (( ${#uninstall_ids[@]} == 0 )); then
          # A blank selection is still an install: the operation runs the
          # repository's ISC_CORE hook, so
          # deselecting every row in the menu yields a core-only install rather
          # than a repo that was never installed at all.
          _isc_install_components "$origin" || apply_rc=$?
        fi
        (( apply_rc != 0 || uninstall_rc != 0 )) && { printf '1\n' >&2; return 1; }
        printf '0\n' >&2
        return 0
      else
        isc_log_info "no TTY — applying installation config selection"
        local repo="${ISC_REPO_NAME:-repo}" id
        local -a apply_ids=() uninstall_ids=()
        for id in ${CM_COMP_IDS[$repo]:-}; do
          if [[ "${CM_COMP_UNINSTALL[$repo|$id]:-0}" == "1" ]]; then
            uninstall_ids+=("$id")
          elif [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then
            apply_ids+=("$id")
          fi
        done
        if (( ${#uninstall_ids[@]} )); then
          _isc_uninstall_components "${uninstall_ids[@]}" || { rc=$?; printf '%s\n' "$rc" >&2; return "$rc"; }
        fi
        if (( ${#apply_ids[@]} )); then
          _isc_install_components "$origin" "${apply_ids[@]}"; rc=$?; printf '%s\n' "$rc" >&2; return "$rc"
        fi
        if (( ${#uninstall_ids[@]} )); then
          msg "[$ISC_REPO_NAME] No components selected — nothing to do."
          printf '0\n' >&2
          return 0
        fi
        # Blank config selection: still install the core (see the TTY branch).
        _isc_install_components "$origin"; rc=$?; printf '%s\n' "$rc" >&2; return "$rc"
      fi
      ;;
  esac
  rc=$?
  printf '%s\n' "$rc" >&2
  return "$rc"
}
