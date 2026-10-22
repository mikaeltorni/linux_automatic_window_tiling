#!/usr/bin/env bash
# components.sh - Component manifest for linux_installation_scripts_functions.
#
# This repository is the shared installer component framework itself, so its
# install.sh deploys these files to a stable location every consuming installer
# can resolve. The CORE (the bootstrap loader and the logging helpers) is always
# installed by install.sh through isc_install_core, independent of this manifest,
# so the framework's core works no matter which optional modules the user picks.
#
# This manifest lists only the OPTIONAL, user-customizable modules. They are all
# default-on, so a plain `bash install.sh --default` reproduces the complete
# framework, while a user may deselect any of them. Deselecting one only means
# that file is not deployed locally; a consuming installer still fetches it on
# demand through component_loader.sh, so nothing breaks.
#
# Entry format: "id|label|default(on/off)|function". The functions are defined
# in lib/framework_install.sh, sourced by install.sh before this manifest.

ISC_REPO_NAME="linux_installation_scripts_functions"
ISC_REPO_LABEL="Shared installer component framework"

ISC_COMPONENTS=(
  "menu|Interactive selection menu engine (component_menu.sh)|on|isc_install_menu"
  "runtime|Per-repository installer runtime contract (component_runtime.sh)|on|isc_install_runtime"
  "installer_helpers|Shared install-time helpers + hotkey-capture engine|on|isc_install_helpers"
)
