#!/usr/bin/env bash
# hotkey_capture.sh - shared interactive hotkey resolution for every setup repo.
#
# This is the single source of truth for turning a component's default hotkey
# into the accelerator that gets bound. It is deliberately generic: no repo
# hard-codes the capture experience — each one declares a default and calls
# isc_capture_hotkey, which either
#
#   1. honors an explicit environment variable (automated / master runs), or
#   2. opens the interactive press-to-capture UI on a real terminal (the user
#      presses modifiers + one key, Backspace removes the last input, Enter
#      confirms), or
#   3. falls back to the default when neither applies (piped/non-interactive).
#
# The heavy lifting (the press state machine, GTK accelerator conversion, and
# real-time conflict detection) lives in the co-located hotkey_capture.py, so
# the logic is unit-tested once and reused everywhere.
#
# Functions:
#   isc_hotkey_lib_dir            - directory holding hotkey_capture.py.
#   isc_hotkey_to_accelerator     - friendly "super+shift+s" -> "<Super><Shift>s".
#   isc_capture_hotkey            - resolve one hotkey (env / capture / default).
#   isc_prompt_hotkey_field       - type, validate, and persist one accelerator.
#   isc_prompt_modifier_field     - type and persist exactly one modifier.
#
# Consumers may set ISC_HOTKEY_CONFLICTS_FN to the name of a function that
# prints "identifier<TAB>accelerator" candidate lines; the capture UI warns in
# real time which of those a chosen accelerator would unbind.

# isc_hotkey_lib_dir - print the directory that contains hotkey_capture.py.
# Prefers the framework dir resolved by component_loader.sh, then this file's
# own directory. Arguments: none.
isc_hotkey_lib_dir() {
  local dir
  for dir in "${ISC_COMPONENT_LIB_DIR:-}" \
             "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; do
    [[ -n "$dir" && -f "$dir/hotkey_capture.py" ]] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}

# isc_hotkey_bin DIR - print the Rust hotkey-capture path when cargo built it.
isc_hotkey_bin() {
  local dir="$1" candidate
  command -v cargo >/dev/null 2>&1 || return 1
  for candidate in "$dir/target/release/hotkey-capture" "$dir/dist/hotkey-capture"; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

# isc_hotkey_run DIR ARGS... - use the Rust command for accelerator fields.
# Interactive capture stays on the Python engine.
isc_hotkey_run() {
  local dir="$1" bin
  shift
  if bin="$(isc_hotkey_bin "$dir")"; then
    "$bin" "$@"
  else
    python3 "$dir/hotkey_capture.py" "$@"
  fi
}

# isc_hotkey_to_accelerator - convert a friendly spec to a GTK accelerator.
# Passes GTK-form specs (already containing "<") through unchanged.
# Arguments: $1 - friendly ("super+shift+s") or GTK ("<Super><Shift>s") spec.
# Prints the GTK accelerator; returns non-zero on an invalid spec.
isc_hotkey_to_accelerator() {
  local spec="$1" dir
  [[ "$spec" == *"<"* ]] && { printf '%s\n' "$spec"; return 0; }
  dir="$(isc_hotkey_lib_dir)" || { printf '%s\n' "$spec"; return 0; }
  isc_hotkey_run "$dir" accel "$spec"
}

# isc_hotkey_add_modifier ACCELERATOR MODIFIER - print the derived accelerator;
# fails when MODIFIER is already present (which would collide with the base).
isc_hotkey_add_modifier() {
  local accelerator="$1" modifier="$2" dir
  dir="$(isc_hotkey_lib_dir)" || return 1
  isc_hotkey_run "$dir" add-modifier "$accelerator" "$modifier"
}

# isc_normalize_modifier VALUE - validate and print exactly one modifier.
isc_normalize_modifier() {
  local value="$1" dir
  dir="$(isc_hotkey_lib_dir)" || return 1
  isc_hotkey_run "$dir" modifier "$value"
}

# isc_hotkey_field_value CONFIG KEY DEFAULT - resolve env override, persisted
# value, then default (in that order). Prints a GTK accelerator/value.
isc_hotkey_field_value() {
  local config="$1" key="$2" default_value="$3" dir
  if [[ -n "${!key:-}" ]]; then
    printf '%s\n' "${!key}"
    return 0
  fi
  dir="$(isc_hotkey_lib_dir)" || { printf '%s\n' "$default_value"; return 0; }
  isc_hotkey_run "$dir" config-get "$config" "$key" "$default_value"
}

# isc_hotkey_field_status CONFIG KEY DEFAULT - print the current friendly
# ``Super+W`` display value for a persisted accelerator field.
isc_hotkey_field_status() {
  local config="$1" key="$2" default_value="$3" dir value
  dir="$(isc_hotkey_lib_dir)" || return 1
  value="$(isc_hotkey_field_value "$config" "$key" "$default_value")"
  isc_hotkey_run "$dir" display "$value"
}

# isc_modifier_field_status CONFIG KEY DEFAULT - print one current modifier in
# friendly form (Control is displayed as Ctrl).
isc_modifier_field_status() {
  local config="$1" key="$2" default_value="$3" dir value normalized
  dir="$(isc_hotkey_lib_dir)" || return 1
  value="$(isc_hotkey_field_value "$config" "$key" "$default_value")"
  normalized="$(isc_hotkey_run "$dir" modifier "$value")" || return 1
  [[ "$normalized" == "Control" ]] && printf 'Ctrl\n' || printf '%s\n' "$normalized"
}

# _isc_save_hotkey_field CONFIG KEY VALUE - persist a validated field as the
# target user so sudo-launched standalone configurators never create root files.
_isc_save_hotkey_field() {
  local config="$1" key="$2" value="$3" dir bin
  dir="$(isc_hotkey_lib_dir)" || return 1
  if declare -F run_as_target >/dev/null 2>&1; then
    if bin="$(isc_hotkey_bin "$dir")"; then
      run_as_target "$bin" config-set "$config" "$key" "$value"
    else
      run_as_target python3 "$dir/hotkey_capture.py" config-set "$config" "$key" "$value"
    fi
  else
    isc_hotkey_run "$dir" config-set "$config" "$key" "$value"
  fi
}

# isc_prompt_hotkey_field CONFIG KEY LABEL DEFAULT [VALIDATOR] - render an
# inline rebind box, capture many modifiers plus exactly one key via press-to-
# capture, and persist the canonical GTK accelerator. VALIDATOR, when supplied,
# receives the value.
isc_prompt_hotkey_field() {
  local config="$1" key="$2" label="$3" default_value="$4" validator="${5:-}"
  local dir current display captured normalized
  dir="$(isc_hotkey_lib_dir)" || return 1
  current="$(isc_hotkey_field_value "$config" "$key" "$default_value")"
  while true; do
    captured="$(python3 "$dir/hotkey_capture.py" prompt-capture \
      --label "$label" --current "$current" --show-box)" || return 1
    [[ -z "$captured" ]] && return 0
    if [[ "$captured" == *"<"* ]]; then
      normalized="$captured"
    elif ! normalized="$(isc_hotkey_run "$dir" accel "$captured" 2>&1)"; then
      printf '  Invalid hotkey: %s\n' "${normalized#Invalid hotkey: }" >&2
      continue
    fi
    if [[ -n "$validator" ]] && ! "$validator" "$normalized"; then
      continue
    fi
    _isc_save_hotkey_field "$config" "$key" "$normalized" || return 1
    printf '%s\n' "$(isc_hotkey_run "$dir" display "$normalized")"
    return 0
  done
}

# isc_prompt_modifier_field CONFIG KEY LABEL DEFAULT [VALIDATOR] - press-to-
# capture exactly one modifier (Shift/Ctrl/Alt/Super), persisted canonically.
isc_prompt_modifier_field() {
  local config="$1" key="$2" label="$3" default_value="$4" validator="${5:-}"
  local dir current display captured normalized
  dir="$(isc_hotkey_lib_dir)" || return 1
  current="$(isc_hotkey_field_value "$config" "$key" "$default_value")"
  while true; do
    captured="$(python3 "$dir/hotkey_capture.py" prompt-capture \
      --label "$label" --current "$current" --modifier-only --show-box)" || return 1
    [[ -z "$captured" ]] && return 0
    if ! normalized="$(isc_hotkey_run "$dir" modifier "$captured" 2>&1)"; then
      printf '  Invalid modifier: %s\n' "${normalized#Invalid modifier: }" >&2
      continue
    fi
    if [[ -n "$validator" ]] && ! "$validator" "$normalized"; then
      continue
    fi
    _isc_save_hotkey_field "$config" "$key" "$normalized" || return 1
    [[ "$normalized" == "Control" ]] && printf 'Ctrl\n' || printf '%s\n' "$normalized"
    return 0
  done
}

# isc_capture_hotkey - resolve one component hotkey.
# Arguments:
#   $1 - environment variable name that overrides the hotkey (may be empty).
#   $2 - default spec (friendly or GTK; also the value kept on cancel).
#   $3 - human label shown in the prompt.
#   $@ - optional flags: --single-key (one key, no modifiers) and/or --mouse
#        (capture a pointer Back/Forward trigger, printed as "MOD+MOD|EVENT").
# Prints the resolved accelerator/trigger on stdout; prompts go to stderr.
isc_capture_hotkey() {
  local env_var="$1" default_spec="$2" label="$3"; shift 3
  local single_key="" mouse="" arg
  for arg in "$@"; do
    case "$arg" in
      --single-key) single_key="--single-key" ;;
      --mouse)      mouse="--mouse" ;;
    esac
  done

  local dir default_accel
  dir="$(isc_hotkey_lib_dir)" || dir=""

  # Normalize the default to the form the caller ultimately binds.
  if [[ -n "$mouse" ]]; then
    default_accel="$default_spec"
  else
    default_accel="$(isc_hotkey_to_accelerator "$default_spec" 2>/dev/null || printf '%s' "$default_spec")"
  fi

  # 1. Explicit override wins (automated runs / master installer).
  if [[ -n "$env_var" && -n "${!env_var:-}" ]]; then
    if [[ -n "$mouse" ]]; then
      printf '%s\n' "${!env_var}"
    else
      isc_hotkey_to_accelerator "${!env_var}" 2>/dev/null || printf '%s\n' "$default_accel"
    fi
    return 0
  fi

  # 2. Interactive press-to-capture — only when explicitly requested via
  #    ISC_HOTKEY_INTERACTIVE=1. This is deliberately opt-in: a plain install
  #    (including `sudo bash install.sh` and the master run) must apply the shown
  #    defaults non-interactively and never open an evdev grab, so it can never
  #    appear to hang. Users who want to press their own hotkeys export
  #    ISC_HOTKEY_INTERACTIVE=1 (or reconfigure a single component).
  if [[ "${ISC_HOTKEY_INTERACTIVE:-0}" == "1" && -n "$dir" && -t 0 && -t 1 ]] \
     && command -v python3 >/dev/null 2>&1; then
    local candidates=""
    if [[ -n "${ISC_HOTKEY_CONFLICTS_FN:-}" ]] && declare -F "$ISC_HOTKEY_CONFLICTS_FN" >/dev/null 2>&1; then
      candidates="$("$ISC_HOTKEY_CONFLICTS_FN" 2>/dev/null || true)"
    fi
    local chosen
    chosen="$(printf '%s' "$candidates" | python3 "$dir/hotkey_capture.py" capture \
      --label "$label" --default "$default_accel" $single_key $mouse)"
    [[ -n "$chosen" ]] && { printf '%s\n' "$chosen"; return 0; }
  fi

  # 3. Non-interactive fallback: keep the default.
  printf '%s\n' "$default_accel"
}
