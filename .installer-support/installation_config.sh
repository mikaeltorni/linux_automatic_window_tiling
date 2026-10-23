#!/usr/bin/env bash
# installation_config.sh - Shared JSON installation-config helpers.
#
# Bridges the Bash CM_* selection arrays and installation_configs/*.json via
# installation_config.py. Both the master orchestrator and standalone installers
# source this module after populating CM_* state.
#
# Usage:
#   source "<framework>/installation_config.sh"
#   isc_config_serialize_standalone "$repo" >state.blob
#   isc_config_apply_file "installation_configs/default.json"

if [[ -n "${ISC_CONFIG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
ISC_CONFIG_SOURCED=1

if ! declare -F isc_log >/dev/null 2>&1; then
  _isc_cfg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _isc_cfg_dir=""
  if [[ -n "$_isc_cfg_dir" && -f "$_isc_cfg_dir/component_logging.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_isc_cfg_dir/component_logging.sh"
  fi
  unset _isc_cfg_dir
fi
if ! declare -F isc_log >/dev/null 2>&1; then
  isc_log()         { :; }
  isc_log_verbose() { :; }
  isc_log_debug()   { :; }
  isc_log_info()    { :; }
  isc_log_warn()    { :; }
  isc_log_error()   { :; }
fi

# Active config basename (default.json when unset) and repo root for resolution.
ISC_CONFIG_NAME="${ISC_CONFIG_NAME:-default.json}"
ISC_CONFIG_REPO_ROOT="${ISC_CONFIG_REPO_ROOT:-}"

# Resolved path to installation_config.py (set by isc_config_activate).
ISC_CONFIG_PY=""

# isc_config_activate - locate installation_config.py next to this module.
isc_config_activate() {
  [[ -n "$ISC_CONFIG_PY" && -f "$ISC_CONFIG_PY" ]] && return 0
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/installation_config.py" ]]; then
    ISC_CONFIG_PY="$here/installation_config.py"
    isc_log_debug "installation config python module: $ISC_CONFIG_PY"
    return 0
  fi
  if [[ -n "${ISC_COMPONENT_LIB_DIR:-}" && -f "${ISC_COMPONENT_LIB_DIR}/installation_config.py" ]]; then
    ISC_CONFIG_PY="${ISC_COMPONENT_LIB_DIR}/installation_config.py"
    return 0
  fi
  isc_log_error "installation_config.py not found"
  return 1
}

# isc_config_dir - echo the installation_configs directory for the active repo.
isc_config_dir() {
  local root="${ISC_CONFIG_REPO_ROOT:-${SCRIPT_DIR:-.}}"
  printf '%s/installation_configs' "$root"
}

# isc_config_resolve - echo the absolute path for a config basename.
isc_config_resolve() {
  local name="${1:-${ISC_CONFIG_NAME:-default.json}}"
  name="${name##*/}"
  printf '%s/%s' "$(isc_config_dir)" "$name"
}

# isc_config_bin - the Rust installation-config command, when this checkout built it.
isc_config_bin() {
  local here bin
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  command -v cargo >/dev/null 2>&1 || return 1
  for bin in "$here/target/release/installation-config" "$here/dist/installation-config"; do
    if [[ -x "$bin" ]]; then
      printf '%s\n' "$bin"
      return 0
    fi
  done
  return 1
}

# isc_config_python - run installation config export/apply/diff/roundtrip.
# Cargo uses the release binary. A PATH without cargo keeps the Python module.
isc_config_python() {
  local bin
  if bin="$(isc_config_bin)"; then
    "$bin" "$@"
    return $?
  fi
  isc_config_activate || return 1
  python3 "$ISC_CONFIG_PY" "$@"
}

# _isc_config_desired_on REPO ID - Translate ephemeral menu action state into
# persisted desired-presence state. Installed components left untouched have
# CM_COMP_ON=0 in the menu, but remain enabled in configuration documents.
_isc_config_desired_on() {
  local repo="$1" id="$2"
  if [[ "${CM_COMP_INSTALLED[$repo|$id]:-0}" == "1" \
        && "${CM_COMP_UNINSTALL[$repo|$id]:-0}" != "1" ]]; then
    printf '1'
  else
    printf '%s' "${CM_COMP_ON[$repo|$id]:-0}"
  fi
}

# isc_config_serialize_standalone - write intermediate state for one repo.
# Arguments: $1 repo id. Remaining args: output path (default stdout).
isc_config_serialize_standalone() {
  local repo="$1" out="${2:-}" id
  {
    printf 'scope=standalone\n'
    printf 'repo_name=%s\n' "$repo"
    printf 'repo:%s:%s\n' "$repo" "${CM_REPO_ENABLED[$repo]:-1}"
    for id in ${CM_COMP_IDS[$repo]:-}; do
      printf 'comp\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$repo" "$id" \
        "$(_isc_config_desired_on "$repo" "$id")" \
        "${CM_COMP_UNINSTALL[$repo|$id]:-0}" \
        "${CM_COMP_FAVORITE_ON[$repo|$id]:-0}" \
        "${CM_COMP_STARTUP_ON[$repo|$id]:-0}" \
        "${CM_COMP_WORKSPACE[$repo|$id]:-0}" \
        "${CM_COMP_STICKY_ON[$repo|$id]:-0}" \
        "${CM_COMP_MONITOR[$repo|$id]:-0}" \
        "${CM_COMP_CONFIG_VALUE[$repo|$id]:-}"
    done
  } >"${out:-/dev/stdout}"
}

# isc_config_serialize_master - write intermediate state for the aggregate menu.
# Arguments: $1 output path (default stdout).
isc_config_serialize_master() {
  local out="${1:-/dev/stdout}" repo id
  {
    printf 'scope=master\n'
    for repo in "${CM_REPOS[@]}"; do
      printf 'repo:%s:%s\n' "$repo" "${CM_REPO_ENABLED[$repo]:-0}"
      for id in ${CM_COMP_IDS[$repo]:-}; do
        printf 'comp\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$repo" "$id" \
          "$(_isc_config_desired_on "$repo" "$id")" \
          "${CM_COMP_UNINSTALL[$repo|$id]:-0}" \
          "${CM_COMP_FAVORITE_ON[$repo|$id]:-0}" \
          "${CM_COMP_STARTUP_ON[$repo|$id]:-0}" \
          "${CM_COMP_WORKSPACE[$repo|$id]:-0}" \
          "${CM_COMP_STICKY_ON[$repo|$id]:-0}" \
          "${CM_COMP_MONITOR[$repo|$id]:-0}" \
          "${CM_COMP_CONFIG_VALUE[$repo|$id]:-}"
      done
    done
  } >"$out"
}

# isc_config_apply_state_file - read intermediate state into CM_* arrays.
# Arguments: $1 state file path.
isc_config_apply_state_file() {
  local state_file="$1" line scope="" repo_name="" repo="" id monitor_v=""
  local on=0 uninstall=0 favorite=0 startup=0 workspace=0 sticky=0 monitor=0 config_value=""
  [[ -f "$state_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      scope=*)
        scope="${line#scope=}"
        ;;
      repo_name=*)
        repo_name="${line#repo_name=}"
        ;;
      repo:*)
        IFS=':' read -r _ repo _ <<<"$line"
        local enabled="${line##*:}"
        CM_REPO_ENABLED[$repo]="$enabled"
        ;;
      comp$'\t'*)
        IFS=$'\t' read -r _ comp_repo comp_id on_v uninstall_v favorite_v startup_v workspace_v sticky_v monitor_v config_value <<<"$line"
        # A config document records desired presence. For an already-installed
        # component, `on: 1` therefore means "keep installed", not "queue a
        # reconfigure". Reconfigure is an ephemeral menu action selected with
        # SPACE/[r] and must never be restored from default.json.
        if [[ "${CM_COMP_INSTALLED[$comp_repo|$comp_id]:-0}" == "1" ]]; then
          CM_COMP_ON[$comp_repo|$comp_id]=0
        else
          CM_COMP_ON[$comp_repo|$comp_id]="${on_v:-0}"
        fi
        CM_COMP_UNINSTALL[$comp_repo|$comp_id]="${uninstall_v:-0}"
        CM_COMP_FAVORITE_ON[$comp_repo|$comp_id]="${favorite_v:-0}"
        CM_COMP_STARTUP_ON[$comp_repo|$comp_id]="${startup_v:-0}"
        CM_COMP_WORKSPACE[$comp_repo|$comp_id]="${workspace_v:-0}"
        CM_COMP_STICKY_ON[$comp_repo|$comp_id]="${sticky_v:-0}"
        # Documents written before the [m] action carry no monitor field; the
        # repository's own default (e.g. Spotify/Discord on display 1) then
        # stays in force instead of being reset to "unpinned".
        if [[ -n "${monitor_v:-}" ]]; then
          CM_COMP_MONITOR[$comp_repo|$comp_id]="$monitor_v"
        fi
        # Repository status functions report authoritative live values during
        # discovery. Config JSON stores a snapshot for diff/export purposes;
        # only use it when the repository cannot report a current value.
        if [[ -z "${CM_COMP_CONFIG_VALUE[$comp_repo|$comp_id]:-}" ]]; then
          CM_COMP_CONFIG_VALUE[$comp_repo|$comp_id]="${config_value:-}"
        fi
        ;;
    esac
  done <"$state_file"
  if [[ "$scope" == "standalone" && -n "$repo_name" ]]; then
    CM_REPOS=("$repo_name")
    CM_REPO_ENABLED[$repo_name]="${CM_REPO_ENABLED[$repo_name]:-1}"
  fi
  isc_log_info "applied installation config state from $state_file (scope=$scope)"
  return 0
}

# Export current component state to a path or the existing stdout stream.
# Parameters: scope - master or standalone; repo - standalone repository name; out - JSON path or /dev/stdout.
# Returns: the export status, or one if temporary-state creation fails.
isc_config_export_json() {
  printf 'scope=%s, repo=%s, out=%s\n' "$1" "${2:-}" "$3" >&2
  local scope="$1" repo="${2:-}" out="$3" state rc=0
  local -a output_args=()
  state="$(mktemp)" || { printf '1\n' >&2; return 1; }
  if [[ "$scope" == "master" ]]; then
    isc_config_serialize_master "$state"
  else
    isc_config_serialize_standalone "$repo" "$state"
  fi
  # Reopening /dev/stdout truncates a regular file shared with the caller.
  # Omitting --output makes both config backends write the existing stream.
  if [[ "$out" != /dev/stdout ]]; then
    output_args=(--output "$out")
  fi
  isc_config_python export --state-file "$state" "${output_args[@]}" || rc=$?
  rm -f "$state"
  printf '%s\n' "$rc" >&2
  return "$rc"
}

# isc_config_is_explicit_empty - return 0 when the JSON document means "no selection".
# Arguments: $1 json path.
isc_config_is_explicit_empty() {
  local json="$1" bin
  if bin="$(isc_config_bin)"; then
    "$bin" is-empty --config "$json" >/dev/null 2>&1
    return $?
  fi
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); scope=d.get("scope","standalone"); empty=(not (d.get("repos") or {}) if scope=="master" else not (d.get("components") or {})); sys.exit(0 if empty else 1)' "$json" 2>/dev/null
}

# isc_config_finalize_apply - zero unspecified repos/components after empty.json apply.
# Populated configs (default.json, custom saves) leave unspecified entries unchanged.
# Arguments: $1 json path.
isc_config_finalize_apply() {
  local json="$1" repo id scope comps bin enabled
  isc_config_is_explicit_empty "$json" || return 0
  if bin="$(isc_config_bin)"; then
    scope="$("$bin" scope --config "$json" 2>/dev/null || echo standalone)"
  else
    scope="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("scope","standalone"))' "$json" 2>/dev/null || echo standalone)"
  fi
  if [[ "$scope" == "master" ]]; then
    for repo in "${CM_REPOS[@]}"; do
      if bin="$(isc_config_bin)"; then
        enabled="$("$bin" repo-enabled --config "$json" --repo "$repo" 2>/dev/null || echo 0)"
      else
        enabled="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=sys.argv[2]; print(1 if (d.get("repos") or {}).get(r, {}).get("enabled") else 0)' "$json" "$repo" 2>/dev/null || echo 0)"
      fi
      if [[ "$enabled" != "1" ]]; then
        CM_REPO_ENABLED[$repo]=0
      fi
      if bin="$(isc_config_bin)"; then
        comps="$("$bin" component-ids --config "$json" --repo "$repo" 2>/dev/null || true)"
      else
        comps="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=sys.argv[2]; print(" ".join((d.get("repos") or {}).get(r, {}).get("components") or {}))' "$json" "$repo" 2>/dev/null || true)"
      fi
      for id in ${CM_COMP_IDS[$repo]:-}; do
        if [[ " $comps " != *" $id "* ]]; then
          CM_COMP_ON[$repo|$id]=0
          CM_COMP_UNINSTALL[$repo|$id]=0
        fi
      done
    done
  else
    local repo_name="${ISC_REPO_NAME:-${CM_REPOS[0]:-}}"
    if bin="$(isc_config_bin)"; then
      comps="$("$bin" component-ids --config "$json" 2>/dev/null || true)"
    else
      comps="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join((d.get("components") or {})))' "$json" 2>/dev/null || true)"
    fi
    for id in ${CM_COMP_IDS[$repo_name]:-}; do
      if [[ " $comps " != *" $id "* ]]; then
        CM_COMP_ON[$repo_name|$id]=0
        CM_COMP_UNINSTALL[$repo_name|$id]=0
      fi
    done
  fi
}

# isc_config_apply_json_file - load a JSON config into CM_* arrays.
# Arguments: $1 json path.
isc_config_apply_json_file() {
  local json="$1" state rc=0
  [[ -f "$json" ]] || { isc_log_error "config not found: $json"; return 1; }
  state="$(mktemp)" || return 1
  if ! isc_config_python apply --config "$json" --state-file "$state"; then
    rm -f "$state"
    return 1
  fi
  isc_config_apply_state_file "$state" || rc=1
  isc_config_finalize_apply "$json"
  rm -f "$state"
  return $rc
}

# isc_config_load_baseline - load the active config as the diff baseline copy.
# Sets ISC_CONFIG_BASELINE_JSON to a temp file holding the baseline document.
isc_config_load_baseline() {
  local config_path
  config_path="$(isc_config_resolve "${ISC_CONFIG_NAME:-default.json}")"
  if [[ ! -f "$config_path" ]]; then
    isc_log_warn "baseline config missing: $config_path — using empty document"
    ISC_CONFIG_BASELINE_JSON="$(mktemp)" || return 1
    printf '{"schema_version":1,"scope":"master","repos":{}}\n' >"$ISC_CONFIG_BASELINE_JSON"
    return 0
  fi
  ISC_CONFIG_BASELINE_JSON="$(mktemp)" || return 1
  cp "$config_path" "$ISC_CONFIG_BASELINE_JSON"
  isc_log_info "loaded config baseline: $config_path"
  return 0
}

# isc_config_diff_current - print human-readable diff vs the stored baseline.
# Arguments: $1 scope; $2 repo (standalone only).
isc_config_diff_current() {
  local scope="$1" repo="${2:-}" current state baseline="${ISC_CONFIG_BASELINE_JSON:-}"
  [[ -n "$baseline" && -f "$baseline" ]] || return 1
  state="$(mktemp)" || return 1
  current="$(mktemp)" || { rm -f "$state"; return 1; }
  if [[ "$scope" == "master" ]]; then
    isc_config_serialize_master "$state"
  else
    isc_config_serialize_standalone "$repo" "$state"
  fi
  isc_config_python export --state-file "$state" --output "$current" \
    && isc_config_python diff --baseline "$baseline" --current "$current"
  local rc=$?
  rm -f "$state" "$current"
  return $rc
}

# isc_config_save_current - write current selection to a named config file.
# Arguments: $1 scope; $2 repo (standalone only); $3 output basename.
isc_config_save_current() {
  local scope="$1" repo="${2:-}" name="${3:-${ISC_CONFIG_NAME:-default.json}}"
  local out
  out="$(isc_config_resolve "$name")"
  isc_log_info "saving installation config to $out"
  isc_config_export_json "$scope" "$repo" "$out"
}

# isc_config_prompt_save - after selection, offer save/discard when state changed.
# Arguments: $1 scope; $2 repo (standalone only).
isc_config_prompt_save() {
  local scope="$1" repo="${2:-}" changes choice name
  if [[ ! -t 0 || ! -t 1 ]]; then
    isc_log_debug "non-interactive — skipping config save prompt"
    return 0
  fi
  changes="$(isc_config_diff_current "$scope" "$repo" 2>/dev/null || true)"
  if [[ -z "$changes" ]]; then
    isc_log_info "selection matches baseline config — no save prompt"
    return 0
  fi
  msg "Configuration changed from ${ISC_CONFIG_NAME:-default.json}:"
  while IFS= read -r line; do
    [[ -n "$line" ]] && printf '  %s\n' "$line"
  done <<<"$changes"
  printf '\nSave changes to installation_configs/?\n'
  printf '  [1] Save to current file (%s)\n' "${ISC_CONFIG_NAME:-default.json}"
  printf '  [2] Save as new file (enter name)\n'
  printf '  [3] Discard (do not save)\n'
  printf 'Choice [1/2/3] (default 3): '
  read -r choice || choice="3"
  case "${choice:-3}" in
    1)
      isc_config_save_current "$scope" "$repo" "${ISC_CONFIG_NAME:-default.json}"
      msg "Saved configuration to $(isc_config_resolve "${ISC_CONFIG_NAME:-default.json}")"
      ;;
    2)
      printf 'New config file name (e.g. my-setup.json): '
      read -r name || name=""
      name="${name##*/}"
      [[ -z "$name" ]] && { msg "No name entered — configuration not saved."; return 0; }
      case "$name" in
        *.json) ;;
        *) name="${name}.json" ;;
      esac
      isc_config_save_current "$scope" "$repo" "$name"
      ISC_CONFIG_NAME="$name"
      msg "Saved configuration to $(isc_config_resolve "$name")"
      ;;
    *)
      msg "Configuration changes were not saved."
      ;;
  esac
  return 0
}

# isc_config_parse_arg - handle --config flag from argv; returns whether consumed.
# Sets ISC_CONFIG_NAME. Call before other argument parsing continues.
# Usage: while parsing args, call isc_config_parse_arg and shift when it returns 0.
isc_config_parse_arg() {
  case "${1:-}" in
    --config)
      ISC_CONFIG_NAME="${2:-default.json}"
      return 0
      ;;
    --config=*)
      ISC_CONFIG_NAME="${1#*=}"
      return 0
      ;;
  esac
  return 1
}

# isc_config_apply_active - load and apply the active config into CM_* arrays.
isc_config_apply_active() {
  local path
  path="$(isc_config_resolve "${ISC_CONFIG_NAME:-default.json}")"
  if [[ ! -f "$path" ]]; then
    isc_log_warn "active config not found: $path — keeping discovered defaults"
    return 0
  fi
  isc_config_apply_json_file "$path"
}

# isc_bootstrap_selection - finalize CM_* after discovery/population.
#
# Call after CM_* arrays reflect manifest or installed state. Exactly three
# modes keep config behavior explicit instead of combinatorial env-var guards:
#
#   manifest      - no config apply, no baseline (bare --export-selection,
#                   --default, generator seeding with ISC_EXPORT_MANIFEST_DEFAULTS)
#   config_active - load baseline from ISC_CONFIG_NAME, then apply it (non-TTY
#                   runs and interactive runs before the save prompt)
#   config_export   - apply ISC_CONFIG_NAME only, no baseline (--config with
#                   --export-selection)
#
# Arguments:
#   $1 - mode (manifest|config_active|config_export; default manifest)
isc_bootstrap_selection() {
  local mode="${1:-manifest}"
  case "$mode" in
    manifest)
      isc_log_debug "bootstrap selection: manifest (no config apply)"
      return 0
      ;;
    config_active)
      isc_log_debug "bootstrap selection: config_active (baseline + apply ${ISC_CONFIG_NAME:-default.json})"
      isc_config_load_baseline
      isc_config_apply_active
      ;;
    config_export)
      isc_log_debug "bootstrap selection: config_export (apply ${ISC_CONFIG_NAME:-default.json}, no baseline)"
      isc_config_apply_active
      ;;
    *)
      isc_log_warn "unknown bootstrap mode: $mode — treating as manifest"
      return 0
      ;;
  esac
}
