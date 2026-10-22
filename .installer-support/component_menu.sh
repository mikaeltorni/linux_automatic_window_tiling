#!/usr/bin/env bash
# component_menu.sh - Shared pure-Bash TUI for installer component selection.
#
# This is the single source of truth for the interactive selection menu used by
# the master installer (a two-level repo -> component menu) and by each child
# repository's standalone installer (a single-repo component submenu). It has no
# external dependencies beyond a POSIX terminal and Bash, so it works on a fresh
# Ubuntu install before any packages are added.
#
# The menu operates on a small set of well-known global arrays that the caller
# populates before invoking an entry point:
#
#   CM_REPOS              - ordered array of repo ids (top-level rows)
#   CM_REPO_LABEL[repo]   - human label for a repo row
#   CM_REPO_ENABLED[repo] - 1 when the whole repo is enabled, 0 when disabled
#   CM_COMP_IDS[repo]     - space-separated component ids belonging to a repo
#   CM_COMP_LABEL[repo|id]- human label for a component
#   CM_COMP_SECTION[repo|id] - optional visual section heading
#   CM_COMP_REQUIRES[repo|id] - optional comma/space-separated ids that must be
#                           selected or already installed before this row can
#                           be selected
#   CM_COMP_ON[repo|id]   - 1 when that component is selected, 0 otherwise
#   CM_COMP_INSTALLED[repo|id] - 1 when already installed on this machine
#                           (optional; defaults to 0 — drives the install-state
#                           markers and the reconfigure/uninstall actions)
#   CM_COMP_UNINSTALL[repo|id] - 1 when the user marked an installed component
#                           for removal with the [u] key (optional)
#   CM_COMP_FAVORITE_ELIGIBLE[repo|id] - 1 when a component can be pinned as a
#                           GNOME favourite app from the program menu
#   CM_COMP_FAVORITE_ON[repo|id] - 1 when the component should be included in
#                           the generated favourite-apps list
#   CM_COMP_STARTUP_ELIGIBLE[repo|id] - 1 when a component can be launched
#                           automatically at desktop login
#   CM_COMP_STARTUP_ON[repo|id] - 1 when startup is selected for the component
#   CM_COMP_STICKY_ELIGIBLE[repo|id] - 1 when a component's app can be made
#                           persistent on all workspaces with the [p] action
#   CM_COMP_STICKY_ON[repo|id] - 1 when all-workspaces persistence is selected
#   CM_COMP_CONFIGURE_ELIGIBLE[repo|id] - 1 when RIGHT opens a repository-owned
#                           nested detail/configuration screen
#   CM_COMP_CONFIG_VALUE[repo|id] - current friendly value shown in brackets
#                           beside an editable component (for example Super+W)
#   CM_CONFIGURE_CALLBACK - function name called as callback REPO COMPONENT
#   ISC_MENU_DEBUG       - 1 enables debug-only menu helpers such as [l] state
#                           logging in the aggregate menu
#
# Per-component states shown in the checklist:
#   [ ] absent, will be skipped          [x] absent, will be installed
#   [✓] installed, left as-is            [~] installed, will be reconfigured
#   [✗] installed, will be uninstalled
#   [F] app selected for dock favourites  [S] selected for startup
#   [FS] app selected for both favourite and startup
#   [W<n>] app pinned to workspace n      [P] persistent on all workspaces
# SPACE toggles install/reconfigure, [f] toggles dock favourite selection,
# [s] toggles startup for eligible apps, [1-9] pins an app to a workspace,
# [p] toggles all-workspaces persistence (mutually exclusive with [1-9],
# since a window cannot be both pinned to one workspace and shown on all),
# [u] toggles uninstall, and
# [r] marks every installed component for reconfigure. In aggregate-menu debug
# mode, [l] writes a quiet component state snapshot to the framework log file.
#
# Entry points (all mutate the arrays in place):
#   cm_aggregate_menu     - two-level menu: rows are repos; SPACE enables or
#                           disables a whole repo; RIGHT enters the repo's
#                           component submenu; ENTER accepts; q/Esc cancels.
#   cm_single_submenu REPO- flat component checklist for one repo; ENTER accepts
#                           (returns 0); q/Esc cancels (returns 1).
#
# Usage:
#   source "<dir>/component_menu.sh"
#   ... populate CM_* arrays ...
#   cm_aggregate_menu   # or: cm_single_submenu "<repo>"

# Guard against double-sourcing.
if [[ -n "${CM_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
CM_MENU_SOURCED=1

# Ensure the centralized logging helpers exist. Source component_logging.sh from
# next to this engine when present, otherwise define silent no-op stubs so every
# isc_log* call below is always safe and never corrupts the TUI on the terminal.
if ! declare -F isc_log >/dev/null 2>&1; then
  _cm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _cm_dir=""
  if [[ -n "$_cm_dir" && -f "$_cm_dir/component_logging.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_cm_dir/component_logging.sh"
  fi
  unset _cm_dir
fi
if ! declare -F isc_log >/dev/null 2>&1; then
  isc_log()         { :; }
  isc_log_verbose() { :; }
  isc_log_debug()   { :; }
  isc_log_info()    { :; }
  isc_log_warn()    { :; }
  isc_log_error()   { :; }
fi

# Associative state shared with callers. Declared here so sourcing alone makes
# them available; callers may also declare them, which is harmless.
declare -gA CM_REPO_LABEL CM_REPO_ENABLED CM_COMP_IDS CM_COMP_LABEL CM_COMP_SECTION CM_COMP_REQUIRES CM_COMP_ON 2>/dev/null || true
declare -gA CM_COMP_INSTALLED CM_COMP_UNINSTALL 2>/dev/null || true
declare -gA CM_COMP_FAVORITE_ELIGIBLE CM_COMP_FAVORITE_ON 2>/dev/null || true
declare -gA CM_COMP_STARTUP_ELIGIBLE CM_COMP_STARTUP_ON 2>/dev/null || true
declare -gA CM_COMP_WORKSPACE_ELIGIBLE CM_COMP_WORKSPACE 2>/dev/null || true
declare -gA CM_COMP_STICKY_ELIGIBLE CM_COMP_STICKY_ON 2>/dev/null || true
declare -gA CM_COMP_MONITOR_ELIGIBLE CM_COMP_MONITOR 2>/dev/null || true
declare -gA CM_COMP_CONFIGURE_ELIGIBLE 2>/dev/null || true
declare -gA CM_COMP_CONFIG_VALUE 2>/dev/null || true
declare -gA CM_COMP_CONFIGURE_ON_SELECT 2>/dev/null || true
# Locked components: CM_COMP_LOCKED[repo|id]=1 means the component is
# force-selected and cannot be turned off by the user (SPACE, NONE, or disabling
# the whole repository). Used by the master installer to enforce cross-repository
# runtime dependencies such as tmux (installed by linux_installations_setup but
# required by components in sibling repositories).
declare -gA CM_COMP_LOCKED 2>/dev/null || true
# Optional callback invoked after every toggle action in both the submenu and
# the aggregate menu, so the caller can re-evaluate cross-repository dependency
# locks and update CM_NOTICE. Called with no arguments; reads/writes CM_* state.
declare -g  CM_POST_TOGGLE_CALLBACK="" 2>/dev/null || true
# Optional notice line printed below the item list (above the footer) in both
# the aggregate menu and submenus. Set by the post-toggle callback to surface
# auto-installed dependencies such as "tmux will be installed ...".
declare -g  CM_NOTICE="" 2>/dev/null || true
declare -ga CM_REPOS 2>/dev/null || true
# Display-monitor layout used by the [m] per-application monitor action.
# CM_MONITOR_COUNT is 0 until cm_detect_monitors runs (or when the layout
# cannot be detected), which keeps [m] hidden instead of offering monitors that
# may not exist. CM_MONITOR_CONNECTORS[n] holds the connector name for the menu.
declare -g  CM_MONITOR_COUNT="${CM_MONITOR_COUNT:-0}" 2>/dev/null || true
declare -gA CM_MONITOR_CONNECTORS 2>/dev/null || true

###############################################################################
# Terminal helpers
###############################################################################

# Hide the terminal cursor for clean rendering.
cm_hide_cursor() { printf '\033[?25l'; }

# Restore the terminal cursor.
cm_show_cursor() { printf '\033[?25h'; }

# Clear the screen and move the cursor to the home position.
cm_clear() { printf '\033[2J\033[H'; }

# Read a single keypress and echo a normalized token.
#
# Returns one of: UP DOWN LEFT RIGHT SPACE ENTER ESC QUIT ALL NONE FAVORITE
# STARTUP STICKY MONITOR WORKSPACE<n> UNINSTALL RECONFIG LOG OTHER.
cm_read_key() {
  local key rest
  IFS= read -rsn1 key 2>/dev/null || { echo QUIT; return; }
  case "$key" in
    '')   echo ENTER ;;
    ' ')  echo SPACE ;;
    $'\x1b')
      # Possible escape sequence (arrow keys). Read the rest with a short
      # timeout so a bare Esc is still recognized.
      read -rsn2 -t 0.005 rest 2>/dev/null || rest=''
      case "$rest" in
        '[A'|'OA') echo UP ;;
        '[B'|'OB') echo DOWN ;;
        '[C'|'OC') echo RIGHT ;;
        '[D'|'OD') echo LEFT ;;
        '')        echo ESC ;;
        *)         echo OTHER ;;
      esac
      ;;
    q|Q) echo QUIT ;;
    a|A) echo ALL ;;
    n|N) echo NONE ;;
    f|F) echo FAVORITE ;;
    s|S) echo STARTUP ;;
    p|P) echo STICKY ;;
    m|M) echo MONITOR ;;
    [0-9]) echo "WORKSPACE$key" ;;
    u|U) echo UNINSTALL ;;
    r|R) echo RECONFIG ;;
    l|L) echo LOG ;;
    *)   echo OTHER ;;
  esac
}

###############################################################################
# Install-state helpers
###############################################################################

# Echo the number of installed components for a repo (CM_COMP_INSTALLED==1).
#
# Arguments:
#   $1 - repo id whose installed components are counted.
cm_repo_installed_count() {
  local repo="$1" id count=0
  for id in ${CM_COMP_IDS[$repo]:-}; do
    [[ -n "$id" ]] || continue
    [[ "${CM_COMP_INSTALLED[$repo|$id]:-0}" == "1" ]] && count=$((count + 1))
  done
  printf '%s' "$count"
}

###############################################################################
# Monitor layout helpers
###############################################################################

# Populate CM_MONITOR_COUNT and CM_MONITOR_CONNECTORS from the live display layout.
#
# Sources monitor_layout.sh from the framework directory when isc_list_monitors
# is not already available. Detection failure is not an error: the count stays 0
# and the [m] action stays hidden, so a headless or pre-GNOME install still runs
# the menu (manifest monitor defaults are applied unchanged).
#
# Arguments:
#   None.
# Returns:
#   0 when at least one monitor was detected; 1 otherwise.
cm_detect_monitors() {
  local dir number connector name primary rest rows
  CM_MONITOR_COUNT=0
  CM_MONITOR_CONNECTORS=()
  if ! declare -F isc_list_monitors >/dev/null 2>&1; then
    for dir in "${ISC_COMPONENT_LIB_DIR:-}" \
               "${ISC_FUNCTIONS_DIR:-}" \
               "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; do
      [[ -n "$dir" && -f "$dir/monitor_layout.sh" ]] || continue
      # shellcheck source=/dev/null
      source "$dir/monitor_layout.sh"
      break
    done
  fi
  if ! declare -F isc_list_monitors >/dev/null 2>&1; then
    isc_log_warn "monitor layout helper unavailable; [m] monitor action disabled"
    return 1
  fi
  rows="$(isc_list_monitors)" || {
    isc_log_warn "no display layout detected; [m] monitor action disabled"
    return 1
  }
  while IFS=$'\t' read -r number connector name primary rest; do
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    CM_MONITOR_CONNECTORS[$number]="$connector"
    (( number > CM_MONITOR_COUNT )) && CM_MONITOR_COUNT="$number"
  done <<<"$rows"
  isc_log_info "detected $CM_MONITOR_COUNT monitor(s) for the [m] application monitor action"
  (( CM_MONITOR_COUNT > 0 ))
}

###############################################################################
# Count helpers
###############################################################################

# Echo the number of enabled components for a repo.
#
# Arguments:
#   $1 - repo id whose enabled components are counted.
#
# Returns:
#   0; prints the count of components with CM_COMP_ON set to 1.
cm_repo_on_count() {
  local repo="$1" id count=0
  for id in ${CM_COMP_IDS[$repo]:-}; do
    [[ -n "$id" ]] || continue
    [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]] && count=$((count + 1))
  done
  printf '%s' "$count"
}

# Echo the total number of components for a repo.
#
# Arguments:
#   $1 - repo id whose components are counted.
#
# Returns:
#   0; prints the total number of component ids registered for the repo.
cm_repo_total_count() {
  local repo="$1" id count=0
  for id in ${CM_COMP_IDS[$repo]:-}; do
    [[ -n "$id" ]] && count=$((count + 1))
  done
  printf '%s' "$count"
}

# Copy non-empty component ids for a repo into a caller-provided array.
#
# Arguments:
#   $1 - repo id
#   $2 - name of the destination array variable (nameref)
cm_comp_ids_for_repo() {
  local repo="$1" raw
  local -n _dest="$2"
  _dest=()
  for raw in ${CM_COMP_IDS[$repo]:-}; do
    [[ -n "$raw" ]] && _dest+=("$raw")
  done
}

# Return whether a component is locked (force-selected, cannot be deselected).
# A locked component stays on through SPACE, NONE, and aggregate-repo-disable;
# the master installer uses this to enforce cross-repository runtime deps.
#
# Arguments:
#   $1 - repo id
#   $2 - component id
cm_component_locked() {
  [[ "${CM_COMP_LOCKED[$1|$2]:-0}" == "1" ]]
}

# Return whether a repository has any locked component.
#
# Arguments:
#   $1 - repo id
cm_repo_has_locked() {
  local repo="$1" id
  for id in ${CM_COMP_IDS[$repo]:-}; do
    [[ -n "$id" ]] || continue
    cm_component_locked "$repo" "$id" && return 0
  done
  return 1
}

# Invoke the post-toggle callback when one is registered. The callback re-
# evaluates cross-repository dependency locks (e.g. tmux) and updates CM_NOTICE.
# Called with no arguments; reads/writes the shared CM_* arrays.
cm_run_post_toggle_callback() {
  [[ -n "${CM_POST_TOGGLE_CALLBACK:-}" ]] || return 0
  declare -F "$CM_POST_TOGGLE_CALLBACK" >/dev/null 2>&1 || return 0
  "$CM_POST_TOGGLE_CALLBACK"
}

# Return whether a component's required rows are selected or already installed.
# A requirement marked for uninstall is treated as unavailable immediately.
cm_component_available() {
  local repo="$1" id="$2" raw requirement
  raw="${CM_COMP_REQUIRES[$repo|$id]:-}"
  [[ -z "$raw" ]] && return 0
  for requirement in ${raw//,/ }; do
    [[ -n "$requirement" ]] || continue
    [[ "${CM_COMP_UNINSTALL[$repo|$requirement]:-0}" == "1" ]] && return 1
    if [[ "${CM_COMP_ON[$repo|$requirement]:-0}" != "1" \
       && "${CM_COMP_INSTALLED[$repo|$requirement]:-0}" != "1" ]]; then
      return 1
    fi
  done
  return 0
}

# Clear pending apply state for dependents whose requirements became
# unavailable. Installed components remain removable with [u].
cm_reconcile_dependencies() {
  local repo="$1" id changed=1
  while (( changed )); do
    changed=0
    for id in ${CM_COMP_IDS[$repo]:-}; do
      [[ -n "$id" ]] || continue
      if [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]] && ! cm_component_available "$repo" "$id"; then
        CM_COMP_ON[$repo|$id]=0
        changed=1
      fi
    done
  done
}

# Render the human labels of a component's requirements for its disabled tag.
cm_component_requirement_labels() {
  local repo="$1" id="$2" raw requirement out=""
  raw="${CM_COMP_REQUIRES[$repo|$id]:-}"
  for requirement in ${raw//,/ }; do
    [[ -n "$requirement" ]] || continue
    out="${out:+$out, }${CM_COMP_LABEL[$repo|$requirement]:-$requirement}"
  done
  printf '%s' "$out"
}

# Echo the action/state currently represented by a component's menu flags.
#
# Arguments:
#   $1 - repo id
#   $2 - component id
#
# Returns:
#   0; prints one of installed, absent, pending_install, pending_reconfigure,
#   or pending_uninstall.
cm_component_state() {
  local repo="$1" id="$2"
  if [[ "${CM_COMP_UNINSTALL[$repo|$id]:-0}" == "1" ]]; then
    printf 'pending_uninstall'
  elif [[ "${CM_COMP_INSTALLED[$repo|$id]:-0}" == "1" ]]; then
    if [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then
      printf 'pending_reconfigure'
    else
      printf 'installed'
    fi
  elif [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then
    printf 'pending_install'
  else
    printf 'absent'
  fi
}

# Log a full aggregate-menu state snapshot without writing to the terminal.
#
# The snapshot is intentionally line-oriented so grep/tail can answer what was
# installed, absent, selected, marked for uninstall, or disabled during a debug
# installer run.
#
# Arguments:
#   none; reads the global CM_* arrays.
#
# Returns:
#   0 always.
cm_log_component_state_snapshot() {
  local repo id state label enabled selected total installed favorite startup
  isc_log_info "component state snapshot begin"
  for repo in "${CM_REPOS[@]}"; do
    [[ -n "$repo" ]] || continue
    enabled="${CM_REPO_ENABLED[$repo]:-0}"
    selected="$(cm_repo_on_count "$repo")"
    total="$(cm_repo_total_count "$repo")"
    installed="$(cm_repo_installed_count "$repo")"
    isc_log_info "component_state repo=$repo enabled=$enabled selected=$selected total=$total installed=$installed label=${CM_REPO_LABEL[$repo]:-$repo}"
    for id in ${CM_COMP_IDS[$repo]:-}; do
      [[ -n "$id" ]] || continue
      state="$(cm_component_state "$repo" "$id")"
      label="${CM_COMP_LABEL[$repo|$id]:-$id}"
      favorite="${CM_COMP_FAVORITE_ON[$repo|$id]:-0}"
      startup="${CM_COMP_STARTUP_ON[$repo|$id]:-0}"
      isc_log_info "component_state repo=$repo component=$id label=$label state=$state favorite=$favorite startup=$startup workspace=${CM_COMP_WORKSPACE[$repo|$id]:-0} sticky=${CM_COMP_STICKY_ON[$repo|$id]:-0} monitor=${CM_COMP_MONITOR[$repo|$id]:-0} selected=${CM_COMP_ON[$repo|$id]:-0} installed=${CM_COMP_INSTALLED[$repo|$id]:-0} uninstall=${CM_COMP_UNINSTALL[$repo|$id]:-0}"
    done
  done
  isc_log_info "component state snapshot end"
}

###############################################################################
# Submenu (component checklist for a single repo)
###############################################################################

# Render the component checklist for one repo.
#
# Arguments:
#   $1 - repo id
#   $2 - currently selected row index
#   $3 - title line
#   $4 - footer/help line
cm_render_submenu() {
  local repo="$1" sel="$2" title="$3" footer="$4"
  local -a ids=()
  local i id mark box label on total inst tag term_rows chrome_rows footer_rows
  local favorite startup workspace sticky monitor action_label requirement_labels config_value
  local visible_rows offset end indicators section section_count=0 previous_section=""
  cm_comp_ids_for_repo "$repo" ids
  if (( ${#ids[@]} > 0 )); then
    if (( sel < 0 )); then sel=0; fi
    if (( sel >= ${#ids[@]} )); then sel=$(( ${#ids[@]} - 1 )); fi
  else
    sel=0
  fi
  on="$(cm_repo_on_count "$repo")"
  total="$(cm_repo_total_count "$repo")"
  inst="$(cm_repo_installed_count "$repo")"
  term_rows="${LINES:-}"
  [[ "$term_rows" =~ ^[0-9]+$ ]] || term_rows="$(tput lines 2>/dev/null || printf '24')"
  # Title, status, blank, and footer consume fixed rows; scroll hints add one
  # line each so the selected row never renders past the terminal bottom.
  chrome_rows=4
  footer_rows=2
  # Reserve one line for every named section. This is conservative while
  # scrolling (not every section is visible), but guarantees headings never
  # push the footer beyond the terminal.
  for id in "${ids[@]}"; do
    section="${CM_COMP_SECTION[$repo|$id]:-}"
    if [[ -n "$section" && "$section" != "$previous_section" ]]; then
      section_count=$((section_count + 1))
    fi
    previous_section="$section"
  done
  visible_rows=$((term_rows - chrome_rows - footer_rows - section_count))
  (( visible_rows < 1 )) && visible_rows=1
  offset=0
  if (( sel >= visible_rows )); then
    offset=$((sel - visible_rows + 1))
  fi
  end=$((offset + visible_rows))
  (( end > ${#ids[@]} )) && end=${#ids[@]}
  indicators=0
  (( offset > 0 )) && indicators=$((indicators + 1))
  (( end < ${#ids[@]} )) && indicators=$((indicators + 1))
  if (( indicators > 0 )); then
    visible_rows=$((term_rows - chrome_rows - footer_rows - indicators - section_count))
    (( visible_rows < 1 )) && visible_rows=1
    offset=0
    if (( sel >= visible_rows )); then
      offset=$((sel - visible_rows + 1))
    fi
    end=$((offset + visible_rows))
    (( end > ${#ids[@]} )) && end=${#ids[@]}
  fi
  cm_clear
  printf '  \033[1m%s\033[0m\n' "$title"
  if (( inst > 0 )); then
    printf '  \033[2m%s — %s/%s selected, %s/%s already installed\033[0m\n\n' \
      "${CM_REPO_LABEL[$repo]:-$repo}" "$on" "$total" "$inst" "$total"
  else
    printf '  \033[2m%s — %s/%s selected\033[0m\n\n' "${CM_REPO_LABEL[$repo]:-$repo}" "$on" "$total"
  fi
  if (( offset > 0 )); then
    printf '     \033[2m... %s more above ...\033[0m\n' "$offset"
  fi
  for ((i = offset; i < end; i++)); do
    id="${ids[$i]}"
    section="${CM_COMP_SECTION[$repo|$id]:-}"
    if [[ -n "$section" ]]; then
      previous_section=""
      if (( i > offset )); then
        previous_section="${CM_COMP_SECTION[$repo|${ids[$((i - 1))]}]:-}"
      fi
      if (( i == offset )) || [[ "$section" != "$previous_section" ]]; then
        printf '      \033[1;34m%s\033[0m\n' "$section"
      fi
    fi
    if [[ "$i" == "$sel" ]]; then mark='\033[36m›\033[0m'; else mark=' '; fi
    label="${CM_COMP_LABEL[$repo|$id]:-$id}"
    config_value="${CM_COMP_CONFIG_VALUE[$repo|$id]:-}"
    if [[ "${CM_COMP_CONFIGURE_ELIGIBLE[$repo|$id]:-0}" == "1" && -n "$config_value" ]]; then
      label+=" [$config_value]"
    fi
    tag=''
    favorite="${CM_COMP_FAVORITE_ON[$repo|$id]:-0}"
    startup="${CM_COMP_STARTUP_ON[$repo|$id]:-0}"
    workspace="${CM_COMP_WORKSPACE[$repo|$id]:-0}"
    sticky="${CM_COMP_STICKY_ON[$repo|$id]:-0}"
    monitor="${CM_COMP_MONITOR[$repo|$id]:-0}"
    if [[ "${CM_COMP_UNINSTALL[$repo|$id]:-0}" == "1" ]]; then
      box='[\033[31m✗\033[0m]'; tag=' \033[31m(uninstall)\033[0m'
    elif ! cm_component_available "$repo" "$id"; then
      requirement_labels="$(cm_component_requirement_labels "$repo" "$id")"
      box='[\033[2m-\033[0m]'; tag=" \\033[2m(requires: $requirement_labels)\\033[0m"
    elif [[ "$favorite" == "1" || "$startup" == "1" || "$workspace" =~ ^[1-9]$ || "$sticky" == "1" || "$monitor" =~ ^[1-9]$ ]]; then
      action_label=''
      [[ "$favorite" == "1" ]] && action_label='favourite'
      [[ "$startup" == "1" ]] && action_label="${action_label:+$action_label, }startup"
      [[ "$workspace" =~ ^[1-9]$ ]] && action_label="${action_label:+$action_label, }workspace $workspace"
      [[ "$sticky" == "1" ]] && action_label="${action_label:+$action_label, }all workspaces"
      [[ "$monitor" =~ ^[1-9]$ ]] && action_label="${action_label:+$action_label, }monitor $monitor${CM_MONITOR_CONNECTORS[$monitor]:+ (${CM_MONITOR_CONNECTORS[$monitor]})}"
      box='[\033[36m'
      [[ "$favorite" == "1" ]] && box+='F'
      [[ "$startup" == "1" ]] && box+='S'
      [[ "$workspace" =~ ^[1-9]$ ]] && box+="W$workspace"
      [[ "$sticky" == "1" ]] && box+='P'
      [[ "$monitor" =~ ^[1-9]$ ]] && box+="M$monitor"
      box+='\033[0m]'
      if [[ "${CM_COMP_INSTALLED[$repo|$id]:-0}" == "1" ]]; then
        tag=" \\033[2m(installed, $action_label)\\033[0m"
      else
        tag=" \\033[36m($action_label)\\033[0m"
      fi
    elif [[ "${CM_COMP_INSTALLED[$repo|$id]:-0}" == "1" ]]; then
      if [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then
        box='[\033[33m~\033[0m]'; tag=' \033[33m(reconfigure)\033[0m'
      else
        box='[\033[32m✓\033[0m]'; tag=' \033[2m(installed)\033[0m'
      fi
    else
      if [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then box='[\033[32mx\033[0m]'; else box='[ ]'; fi
    fi
    if [[ "${CM_COMP_CONFIGURE_ELIGIBLE[$repo|$id]:-0}" == "1" ]]; then
      if [[ -n "$config_value" ]]; then
        tag+=" \033[36m(→ edit)\033[0m"
      else
        tag+=" \033[36m(→ details)\033[0m"
      fi
    fi
    # A locked component (force-selected cross-repo dependency) gets a lock
    # marker so the user understands why it cannot be deselected.
    if cm_component_locked "$repo" "$id"; then
      tag+=" \033[33m🔒 (locked)\033[0m"
    fi
    printf '   %b %b %s%b\n' "$mark" "$box" "$label" "$tag"
  done
  if (( end < ${#ids[@]} )); then
    printf '     \033[2m... %s more below ...\033[0m\n' "$((${#ids[@]} - end))"
  fi
  # Print the caller-supplied notice (e.g. tmux auto-install) between the item
  # list and the footer help line.
  if [[ -n "${CM_NOTICE:-}" ]]; then
    printf '\n  %s\n' "$CM_NOTICE"
  fi
  printf '\n  \033[2m%s\033[0m\n' "$footer"
}

# Drive the component checklist for one repo until the user leaves it.
# Print the controls that are meaningful for a repository's current component
# metadata. Optional controls are capability-driven so callers add them by
# returning framework metadata, never by teaching this renderer repository ids.
#
# Arguments:
#   $1 - repo id whose component capabilities are inspected.
#   $2 - "standalone" for an apply action, otherwise an embedded back action.
cm_submenu_footer() {
  local repo="$1" mode="${2:-embedded}" id
  local has_edit=0 has_details=0 has_favorite=0 has_startup=0
  local has_workspace=0 has_sticky=0 has_monitor=0 has_installed=0 footer

  for id in ${CM_COMP_IDS[$repo]:-}; do
    [[ -n "$id" ]] || continue
    if [[ "${CM_COMP_CONFIGURE_ELIGIBLE[$repo|$id]:-0}" == "1" ]]; then
      if [[ -n "${CM_COMP_CONFIG_VALUE[$repo|$id]:-}" ]]; then
        has_edit=1
      else
        has_details=1
      fi
    fi
    [[ "${CM_COMP_FAVORITE_ELIGIBLE[$repo|$id]:-0}" == "1" ]] && has_favorite=1
    [[ "${CM_COMP_STARTUP_ELIGIBLE[$repo|$id]:-0}" == "1" ]] && has_startup=1
    [[ "${CM_COMP_WORKSPACE_ELIGIBLE[$repo|$id]:-0}" == "1" ]] && has_workspace=1
    [[ "${CM_COMP_STICKY_ELIGIBLE[$repo|$id]:-0}" == "1" ]] && has_sticky=1
    [[ "${CM_COMP_MONITOR_ELIGIBLE[$repo|$id]:-0}" == "1" ]] && has_monitor=1
    [[ "${CM_COMP_INSTALLED[$repo|$id]:-0}" == "1" ]] && has_installed=1
  done

  footer='[↑/↓] move'
  if (( has_edit && has_details )); then
    footer+='  [→] edit/details'
  elif (( has_edit )); then
    footer+='  [→] edit'
  elif (( has_details )); then
    footer+='  [→] details'
  fi
  footer+='  [space] toggle'
  (( has_favorite )) && footer+='  [f] favourite'
  (( has_startup )) && footer+='  [s] startup'
  (( has_workspace )) && footer+='  [1-9] workspace'
  (( has_sticky )) && footer+='  [p] all workspaces'
  # [m] cycles through the detected monitors; hidden on a single-monitor (or
  # undetectable) layout where there is nothing to choose between.
  (( has_monitor && CM_MONITOR_COUNT > 1 )) && footer+='  [m] monitor'
  (( has_installed )) && footer+='  [u] uninstall'
  if [[ "$mode" == "standalone" ]]; then
    footer+='  [enter] apply'
  else
    footer+='  [←/enter] back'
  fi
  printf '%s' "$footer"
}

# Drive the component checklist for one repo until the user leaves it.
#
# Arguments:
#   $1 - repo id
#   $2 - "standalone" to make ENTER accept and return 0 / q-Esc return 1, or
#        "embedded" to make ENTER and LEFT return 0 (back to the parent menu).
#
# Returns:
#   0 when accepted / returned to parent; 1 when cancelled in standalone mode.
cm_submenu_loop() {
  local repo="$1" mode="${2:-embedded}"
  local -a ids=()
  local sel=0 key id title footer monitor_next
  cm_comp_ids_for_repo "$repo" ids
  title="Configure components"
  footer="$(cm_submenu_footer "$repo" "$mode")"
  if [[ "$mode" != "standalone" ]]; then
    cm_show_cursor
  fi
  if (( ${#ids[@]} == 0 )); then
    cm_clear
    printf '  \033[1m%s\033[0m\n\n' "$title"
    printf '  \033[2mNo selectable components for %s.\033[0m\n\n' "${CM_REPO_LABEL[$repo]:-$repo}"
    printf '  \033[2m%s\033[0m\n' "$footer"
    cm_read_key >/dev/null
    return 0
  fi
  while true; do
    cm_reconcile_dependencies "$repo"
    (( sel < 0 )) && sel=0
    (( ${#ids[@]} > 0 && sel >= ${#ids[@]} )) && sel=$(( ${#ids[@]} - 1 ))
    cm_render_submenu "$repo" "$sel" "$title" "$footer"
    key="$(cm_read_key)"
    case "$key" in
      UP)    sel=$((sel - 1)) ;;
      DOWN)  sel=$((sel + 1)) ;;
      SPACE)
        id="${ids[$sel]:-}"
        [[ -z "$id" ]] && continue
        cm_component_available "$repo" "$id" || continue
        # A locked component (cross-repo dependency such as tmux) cannot be
        # deselected — SPACE is a no-op when it is already on.
        if cm_component_locked "$repo" "$id" && [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then
          continue
        fi
        # SPACE selects a component to apply (install if absent, reconfigure if
        # installed) and always clears any pending uninstall mark.
        CM_COMP_UNINSTALL[$repo|$id]=0
        if [[ "${CM_COMP_ON[$repo|$id]:-0}" == "1" ]]; then
          CM_COMP_ON[$repo|$id]=0
        else
          CM_COMP_ON[$repo|$id]=1
          # Components flagged select_configure cannot install without a typed
          # setting (e.g. a repository name): open their configurator right
          # here, and revert the toggle when it is cancelled or fails.
          if [[ "${CM_COMP_CONFIGURE_ON_SELECT[$repo|$id]:-0}" == "1" ]] \
             && [[ -n "${CM_CONFIGURE_CALLBACK:-}" ]] \
             && declare -F "$CM_CONFIGURE_CALLBACK" >/dev/null 2>&1; then
            isc_log_info "opening select-configure prompt repo=$repo component=$id"
            if ! "$CM_CONFIGURE_CALLBACK" "$repo" "$id"; then
              isc_log_warn "select-configure cancelled or failed repo=$repo component=$id — reverting toggle"
              CM_COMP_ON[$repo|$id]=0
            fi
            # Re-render immediately so the prompt output is replaced by a
            # fresh submenu frame (same as the RIGHT/edit flow).
            cm_render_submenu "$repo" "$sel" "$title" "$footer"
          fi
        fi
        cm_reconcile_dependencies "$repo"
        cm_run_post_toggle_callback
        ;;
      RIGHT)
        id="${ids[$sel]:-}"
        [[ -n "$id" ]] || continue
        [[ "${CM_COMP_CONFIGURE_ELIGIBLE[$repo|$id]:-0}" == "1" ]] || continue
        [[ -n "${CM_CONFIGURE_CALLBACK:-}" ]] || continue
        declare -F "$CM_CONFIGURE_CALLBACK" >/dev/null 2>&1 || continue
        isc_log_info "opening inline configurator repo=$repo component=$id"
        if "$CM_CONFIGURE_CALLBACK" "$repo" "$id"; then
          CM_COMP_ON[$repo|$id]=1
          CM_COMP_UNINSTALL[$repo|$id]=0
          isc_log_info "inline configurator accepted repo=$repo component=$id"
        else
          isc_log_warn "inline configurator cancelled or failed repo=$repo component=$id"
        fi
        # Re-render immediately so capture UI is replaced by a fresh submenu frame.
        cm_render_submenu "$repo" "$sel" "$title" "$footer"
        ;;
      UNINSTALL)
        id="${ids[$sel]:-}"
        [[ -z "$id" ]] && continue
        # Uninstall only applies to installed components; toggling it clears the
        # apply/reconfigure selection so the two actions never conflict.
        [[ "${CM_COMP_INSTALLED[$repo|$id]:-0}" == "1" ]] || continue
        if [[ "${CM_COMP_UNINSTALL[$repo|$id]:-0}" == "1" ]]; then
          CM_COMP_UNINSTALL[$repo|$id]=0
        else
          CM_COMP_UNINSTALL[$repo|$id]=1
          CM_COMP_ON[$repo|$id]=0
          CM_COMP_FAVORITE_ON[$repo|$id]=0
          CM_COMP_STARTUP_ON[$repo|$id]=0
          CM_COMP_WORKSPACE[$repo|$id]=0
          CM_COMP_STICKY_ON[$repo|$id]=0
          CM_COMP_MONITOR[$repo|$id]=0
        fi
        ;;
      FAVORITE)
        id="${ids[$sel]:-}"
        [[ -z "$id" ]] && continue
        cm_component_available "$repo" "$id" || continue
        [[ "${CM_COMP_FAVORITE_ELIGIBLE[$repo|$id]:-0}" == "1" ]] || continue
        CM_COMP_UNINSTALL[$repo|$id]=0
        if [[ "${CM_COMP_FAVORITE_ON[$repo|$id]:-0}" == "1" ]]; then
          CM_COMP_FAVORITE_ON[$repo|$id]=0
        else
          CM_COMP_FAVORITE_ON[$repo|$id]=1
        fi
        ;;
      STARTUP)
        id="${ids[$sel]:-}"
        [[ -z "$id" ]] && continue
        cm_component_available "$repo" "$id" || continue
        [[ "${CM_COMP_STARTUP_ELIGIBLE[$repo|$id]:-0}" == "1" ]] || continue
        CM_COMP_UNINSTALL[$repo|$id]=0
        if [[ "${CM_COMP_STARTUP_ON[$repo|$id]:-0}" == "1" ]]; then
          CM_COMP_STARTUP_ON[$repo|$id]=0
        else
          CM_COMP_STARTUP_ON[$repo|$id]=1
        fi
        ;;
      STICKY)
        id="${ids[$sel]:-}"
        [[ -z "$id" ]] && continue
        cm_component_available "$repo" "$id" || continue
        [[ "${CM_COMP_STICKY_ELIGIBLE[$repo|$id]:-0}" == "1" ]] || continue
        CM_COMP_UNINSTALL[$repo|$id]=0
        if [[ "${CM_COMP_STICKY_ON[$repo|$id]:-0}" == "1" ]]; then
          CM_COMP_STICKY_ON[$repo|$id]=0
        else
          # A window cannot be pinned to one workspace and shown on all of
          # them at once, so [p] clears any [1-9] assignment (and vice versa).
          CM_COMP_STICKY_ON[$repo|$id]=1
          CM_COMP_WORKSPACE[$repo|$id]=0
        fi
        ;;
      MONITOR)
        id="${ids[$sel]:-}"
        [[ -z "$id" ]] && continue
        cm_component_available "$repo" "$id" || continue
        [[ "${CM_COMP_MONITOR_ELIGIBLE[$repo|$id]:-0}" == "1" ]] || continue
        (( CM_MONITOR_COUNT > 1 )) || continue
        CM_COMP_UNINSTALL[$repo|$id]=0
        # Cycle 0 (no pin - keep the session's own placement) -> 1 .. N -> 0.
        monitor_next=$(( ${CM_COMP_MONITOR[$repo|$id]:-0} + 1 ))
        (( monitor_next > CM_MONITOR_COUNT )) && monitor_next=0
        CM_COMP_MONITOR[$repo|$id]="$monitor_next"
        isc_log_info "monitor action repo=$repo component=$id monitor=$monitor_next"
        ;;
      WORKSPACE[0-9])
        id="${ids[$sel]:-}"
        [[ -z "$id" ]] && continue
        cm_component_available "$repo" "$id" || continue
        [[ "${CM_COMP_WORKSPACE_ELIGIBLE[$repo|$id]:-0}" == "1" ]] || continue
        CM_COMP_UNINSTALL[$repo|$id]=0
        CM_COMP_WORKSPACE[$repo|$id]="${key#WORKSPACE}"
        if [[ "${key#WORKSPACE}" =~ ^[1-9]$ ]]; then
          CM_COMP_STICKY_ON[$repo|$id]=0
        fi
        ;;
      RECONFIG)
        # Mark every installed component for reconfigure (idempotent re-apply).
        for id in "${ids[@]}"; do
          if [[ "${CM_COMP_INSTALLED[$repo|$id]:-0}" == "1" ]] && cm_component_available "$repo" "$id"; then
            CM_COMP_ON[$repo|$id]=1
            CM_COMP_UNINSTALL[$repo|$id]=0
          fi
        done
        ;;
      ALL)
        for id in "${ids[@]}"; do
          if cm_component_available "$repo" "$id"; then
            CM_COMP_ON[$repo|$id]=1
            CM_COMP_UNINSTALL[$repo|$id]=0
          fi
        done
        cm_reconcile_dependencies "$repo"
        cm_run_post_toggle_callback
        ;;
      NONE)
        # Locked components stay on even when the user clears all selections.
        for id in "${ids[@]}"; do
          cm_component_locked "$repo" "$id" && continue
          CM_COMP_ON[$repo|$id]=0
        done
        cm_run_post_toggle_callback
        ;;
      LEFT)
        [[ "$mode" == "embedded" ]] && return 0
        ;;
      ENTER) return 0 ;;
      ESC|QUIT)
        [[ "$mode" == "standalone" ]] && return 1
        return 0
        ;;
    esac
  done
}

# Public: run a standalone single-repo component submenu.
#
# Arguments:
#   $1 - repo id
#
# Returns:
#   0 when the user accepted (install), 1 when cancelled.
cm_single_submenu() {
  local repo="$1"
  isc_log_debug "opening standalone submenu for repo '$repo'"
  cm_hide_cursor
  trap 'cm_show_cursor' RETURN
  cm_submenu_loop "$repo" standalone
  local rc=$?
  cm_show_cursor
  cm_clear
  trap - RETURN
  isc_log_debug "standalone submenu for repo '$repo' closed with rc=$rc"
  return $rc
}

###############################################################################
# Aggregate menu (repos as rows with submenu drill-down)
###############################################################################

# Render the top-level repo menu.
#
# Arguments:
#   $1 - currently selected row index
cm_render_aggregate() {
  local sel="$1"
  local i repo mark box label on total status term_rows chrome_rows footer_rows
  local visible_rows offset end indicators
  if (( sel < 0 )); then sel=0; fi
  if (( sel >= ${#CM_REPOS[@]} )); then sel=$(( ${#CM_REPOS[@]} - 1 )); fi
  term_rows="${LINES:-}"
  [[ "$term_rows" =~ ^[0-9]+$ ]] || term_rows="$(tput lines 2>/dev/null || printf '24')"
  chrome_rows=3
  footer_rows=2
  visible_rows=$((term_rows - chrome_rows - footer_rows))
  (( visible_rows < 1 )) && visible_rows=1
  offset=0
  if (( sel >= visible_rows )); then
    offset=$((sel - visible_rows + 1))
  fi
  end=$((offset + visible_rows))
  (( end > ${#CM_REPOS[@]} )) && end=${#CM_REPOS[@]}
  indicators=0
  (( offset > 0 )) && indicators=$((indicators + 1))
  (( end < ${#CM_REPOS[@]} )) && indicators=$((indicators + 1))
  if (( indicators > 0 )); then
    visible_rows=$((term_rows - chrome_rows - footer_rows - indicators))
    (( visible_rows < 1 )) && visible_rows=1
    offset=0
    if (( sel >= visible_rows )); then
      offset=$((sel - visible_rows + 1))
    fi
    end=$((offset + visible_rows))
    (( end > ${#CM_REPOS[@]} )) && end=${#CM_REPOS[@]}
  fi
  cm_clear
  printf '  \033[1mInstallation Components\033[0m\n'
  printf '  \033[2mSelect what to install. Disabled repositories are skipped entirely.\033[0m\n\n'
  if (( offset > 0 )); then
    printf '     \033[2m... %s more above ...\033[0m\n' "$offset"
  fi
  for ((i = offset; i < end; i++)); do
    repo="${CM_REPOS[$i]}"
    if [[ "$i" == "$sel" ]]; then mark='\033[36m›\033[0m'; else mark=' '; fi
    if [[ "${CM_REPO_ENABLED[$repo]:-0}" == "1" ]]; then box='[\033[32mx\033[0m]'; else box='[ ]'; fi
    label="${CM_REPO_LABEL[$repo]:-$repo}"
    total="$(cm_repo_total_count "$repo")"
    if [[ "${CM_REPO_ENABLED[$repo]:-0}" == "1" ]]; then
      on="$(cm_repo_on_count "$repo")"
      if (( total > 0 )); then
        local inst
        inst="$(cm_repo_installed_count "$repo")"
        if (( inst > 0 )); then
          status="$(printf '(%s/%s, \033[32m%s installed\033[0m) \033[36m›\033[0m' "$on" "$total" "$inst")"
        else
          status="$(printf '(%s/%s) \033[36m›\033[0m' "$on" "$total")"
        fi
      else
        status='(no options)'
      fi
    else
      status='\033[2mdisabled\033[0m'
    fi
    printf '   %b %b %-44s %b\n' "$mark" "$box" "$label" "$status"
  done
  if (( end < ${#CM_REPOS[@]} )); then
    printf '     \033[2m... %s more below ...\033[0m\n' "$((${#CM_REPOS[@]} - end))"
  fi
  # Print the caller-supplied notice (e.g. tmux auto-install) between the repo
  # list and the footer help line.
  if [[ -n "${CM_NOTICE:-}" ]]; then
    printf '\n  %s\n' "$CM_NOTICE"
  fi
  if [[ "${ISC_MENU_DEBUG:-0}" == "1" ]]; then
    printf '\n  \033[2m[↑/↓] move   [space] enable/disable   [→] configure (incl. reconfigure/uninstall)   [l] log state   [enter] apply   [q] cancel\033[0m\n'
  else
    printf '\n  \033[2m[↑/↓] move   [space] enable/disable   [→] configure (incl. reconfigure/uninstall)   [enter] apply   [q] cancel\033[0m\n'
  fi
}

# Public: run the two-level aggregate menu.
#
# Returns:
#   0 when the user accepted the selection (ENTER); 1 when cancelled (q/Esc).
cm_aggregate_menu() {
  local sel=0 key repo
  isc_log_debug "opening aggregate menu with ${#CM_REPOS[@]} repo row(s)"
  cm_hide_cursor
  while true; do
    (( sel < 0 )) && sel=0
    (( sel >= ${#CM_REPOS[@]} )) && sel=$(( ${#CM_REPOS[@]} - 1 ))
    cm_render_aggregate "$sel"
    key="$(cm_read_key)"
    repo="${CM_REPOS[$sel]:-}"
    case "$key" in
      UP)    sel=$((sel - 1)) ;;
      DOWN)  sel=$((sel + 1)) ;;
      SPACE)
        [[ -z "$repo" ]] && continue
        # A repository that has any locked component (e.g. tmux locked because a
        # sibling-repo component depends on it) cannot be disabled from the
        # aggregate menu — the locked dependency must stay selected.
        if [[ "${CM_REPO_ENABLED[$repo]:-0}" == "1" ]] && cm_repo_has_locked "$repo"; then
          continue
        fi
        if [[ "${CM_REPO_ENABLED[$repo]:-0}" == "1" ]]; then
          CM_REPO_ENABLED[$repo]=0
        else
          CM_REPO_ENABLED[$repo]=1
        fi
        cm_run_post_toggle_callback
        ;;
      RIGHT)
        [[ -z "$repo" ]] && continue
        [[ "${CM_REPO_ENABLED[$repo]:-0}" != "1" ]] && continue
        [[ "$(cm_repo_total_count "$repo")" == "0" ]] && continue
        cm_submenu_loop "$repo" embedded
        cm_hide_cursor
        # Re-evaluate cross-repo locks after returning from a submenu: the user
        # may have toggled a component that adds or removes a tmux dependency.
        cm_run_post_toggle_callback
        ;;
      LOG)
        [[ "${ISC_MENU_DEBUG:-0}" == "1" ]] || continue
        cm_log_component_state_snapshot
        ;;
      ENTER)
        isc_log_info "aggregate menu accepted"
        cm_show_cursor; cm_clear
        return 0
        ;;
      ESC|QUIT)
        isc_log_info "aggregate menu cancelled"
        cm_show_cursor; cm_clear
        return 1
        ;;
    esac
  done
}
