#!/usr/bin/env bash
# Generated-support entry point, maintained by linux_installation_scripts_functions.
# A consumer sources .installer-support/bootstrap.sh before loading its helpers.
# Explicit framework overrides remain supported; ordinary first use is offline.
_isc_support_directory="${ISC_COMPONENT_LIB_DIR:-${ISC_FUNCTIONS_DIR:-}}"
if [[ -z "$_isc_support_directory" ]]; then
  _isc_support_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [[ ! -f "$_isc_support_directory/component_loader.sh" \
   || ! -f "$_isc_support_directory/component_runtime.sh" \
   || ! -f "$_isc_support_directory/component_menu.sh" ]]; then
  printf 'ERROR: incomplete installer support: %s\n' "$_isc_support_directory" >&2
  return 2
fi
export ISC_COMPONENT_LIB_DIR="$_isc_support_directory"
source "$_isc_support_directory/component_loader.sh"
unset _isc_support_directory
