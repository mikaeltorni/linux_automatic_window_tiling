#!/usr/bin/env bash
# components.sh - Component manifest for linux_automatic_window_tiling.
#
# install.sh deploys the extension core (awt_install_core) unconditionally so
# tiling always works, then routes execution through component_main from the
# shared component runtime. Each component below writes one gsettings key, so
# every customizable behavior is selectable and fully editable without touching
# the extension source. All components are default-on: a plain install reproduces
# the extension's built-in behavior.
#
# Entry format: "id|label|default(on/off)|function[|detect_fn[|uninstall_fn]]".
# The functions are defined in lib/tiling_setup.sh, sourced by install.sh before
# this manifest. detect_* reports whether the extension schema is present (so the
# key applies); uninstall_* resets that key to the schema default.

ISC_REPO_NAME="linux_automatic_window_tiling"
ISC_REPO_LABEL="Automatic same-application window tiling"

ISC_COMPONENTS=(
  "keybinding|Tiling accelerator (default <Super>t)|on|awt_configure_keybinding|detect_awt_keybinding|uninstall_awt_keybinding"
  "per_app_widths|Per-application preferred tile widths (kitty:1300)|on|awt_configure_app_widths|detect_awt_app_widths|uninstall_awt_app_widths"
  "portrait_stacking|Portrait monitor vertical stacking minimum width|on|awt_configure_portrait_stacking|detect_awt_portrait_stacking|uninstall_awt_portrait_stacking"
)
