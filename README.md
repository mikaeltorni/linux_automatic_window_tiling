# Linux Automatic Window Tiling

> Part of [installation_scripts](https://github.com/mikaeltorni/installation_scripts) — the master installer that orchestrates a productivity-focused Ubuntu 24.04 desktop setup (workspaces, hotkeys, window tiling, programming tools, and more). Tested on Ubuntu 24.04.4 LTS.

GNOME Shell extension that tiles windows on the focused window's current
workspace and monitor. Super+T keeps the existing same-application behavior;
Ctrl+Shift+T tiles every eligible application window together on that monitor.
Desktop launchers can call the session D-Bus method
`org.gnome.shell.extensions.AutomaticWindowTiling.TileWindowGroup` with an X11
window ID. It applies the Super+T application grid on that window's workspace
and monitor without selecting the workspace, raising a window, or cycling an
already tiled grid. This lets a batch of background terminals be placed first
and tiled once per workspace/monitor. `TileWindowGroups` accepts an array of
X11 window IDs and groups them by their actual workspace, monitor, and
application tile group; it covers existing windows moved by hand to another
monitor.

The installer accepts the desired same-application GNOME accelerator and exposes
an environment override for the monitor-wide accelerator, so both actions can
be configured without editing the extension source.

## Repository dependencies

This repository installs and runs **standalone**. Its installer uses the shared
component framework owned by `linux_installation_scripts_functions`, resolving it
from a sibling checkout when present and otherwise downloading it on demand, so a
clean standalone install needs no other repository checked out. It is *consumed
by* `linux_hotkey_setup` and `linux_workspaces_setup`, which call this installer
(passing the desired accelerator) when it sits beside them; that is a one-way
relationship and does not create a dependency in this direction.

See the full cross-repository map in
[installation_scripts/DEPENDENCIES.md](https://github.com/mikaeltorni/installation_scripts/blob/master/DEPENDENCIES.md).

## Behavior

- Only normal, taskbar-visible windows are tiled.
- Windows must match the focused application's tile group: exact identity for
  most apps, with plain `kitty` and per-provider `kitty-agent-*` model-icon
  terminals co-tiling as one family (icons stay distinct via real WM_CLASS).
- Windows must already be on the focused window's workspace and monitor.
- Maximized matching windows remain eligible: Super+T restores them before
  placing them in the grid, including when the focused window is maximized.
  Windows outside the selected application, workspace, or monitor keep their state.
- Ctrl+Shift+T includes every eligible application on the focused window's
  workspace and monitor, using one balanced grid for the mixed window set.
- One window fills the monitor work area.
- Two windows tile left/right.
- Four windows use a 2x2 grid.
- On a portrait (taller-than-wide) monitor, windows stack top-to-bottom in a single full-width column (two windows are top and bottom, a third continues below and is never cut in half); a configurable minimum tile height keeps a window usable before the next one wraps into a column to the right.
- Other counts use a balanced calculated grid.
- Kitty uses a 1300px preferred width to choose grid density on wide monitors,
  but tiled windows always expand to fill their complete grid cells.
- GNOME's work area is used, excluding panels and docks.
- Pressing the accelerator again while the windows already fill the grid rotates
  them by one cell instead of re-tiling them into the same places, so tapping
  the combination repeatedly cycles through the possible arrangements.

## Installation

The installer always deploys and enables the extension core, so the tiling
action works regardless of which optional pieces you keep. Each customizable
behavior is then a selectable component, matching the component model used
across `installation_scripts`.

The quickest install passes a GNOME accelerator as the first argument and
installs every default-on component:

```bash
bash install.sh '<Super>t'
```

Long-form binding syntax is also supported:

```bash
bash install.sh --binding '<Control><Alt>t'
```

Component-framework flags select exactly what to configure:

```bash
bash install.sh                      # interactive component menu on a TTY
bash install.sh --default            # all default-on components, no prompts
bash install.sh --all                # every component, no prompts
bash install.sh --select keybinding  # only the listed component ids
bash install.sh --list-components    # id<TAB>label<TAB>default, for tooling
```

### Components

All components are default-on, so a plain install reproduces the extension's
built-in behavior. Each writes a single gsettings key, so behavior stays fully
customizable without editing the extension source:

| Component | gsettings key | Env override | Default |
| --- | --- | --- | --- |
| `keybinding` | `tile-focused-application-windows`, `tile-all-windows` | `AWT_BINDING`, `AWT_ALL_BINDING` | `<Super>t`, `<Control><Shift>t` |
| `per_app_widths` | `application-preferred-widths` | `AWT_APP_WIDTHS` | `kitty:1300` |
| `portrait_stacking` | `portrait-minimum-tile-height` | `AWT_PORTRAIT_MIN_HEIGHT` | `0` |

`AWT_ALL_BINDING` changes the monitor-wide all-window accelerator while keeping
Ctrl+Shift+T as the default. `AWT_APP_WIDTHS` is a comma- or space-separated list
of `name:width` entries.
A `portrait-minimum-tile-height` of `0` (the default) keeps portrait monitors in a
single, full-height column (pure vertical stacking, top to bottom). Set a positive
value (for example `1080`) to wrap windows into side-by-side columns once a column
would fall below that height, keeping many windows usable on a tall monitor. On a TTY the `keybinding`
component prompts for the same-application accelerator, defaulting to `<Super>t`;
the all-window accelerator defaults to `<Control><Shift>t`.

The installer can run directly as the desktop user or through `sudo`. When run
through `sudo`, it uses `SUDO_USER` to install into that user's local GNOME
Shell extension directory and apply settings through the user's session bus. It
resolves the shared component framework from a sibling
`linux_installation_scripts_functions` checkout, falling back to an on-demand
download so a standalone clean install needs no extra setup.

Log out and back in after installation when GNOME Shell cannot reload the
extension in the current session. On X11, restarting GNOME Shell also loads the
new version.

## Development

Runtime modules:

- `extension.js` owns tiling orchestration, logging, and extension lifecycle.
- `layout.js` owns pure grid selection and tile geometry calculations.
- `windows.js` owns GNOME window selection, identity, and state management.

Run tests and syntax checks:

```bash
cargo test
python3 -m pytest tests -q
bash -n install.sh
```

Validate the schema:

```bash
glib-compile-schemas --strict schemas
```

The compiled `schemas/gschemas.compiled` file is generated and ignored.

## Integration

`linux_hotkey_setup` detects this repository as a sibling checkout and invokes:

```bash
bash ../linux_automatic_window_tiling/install.sh '<Super>t'
```

The master `installation_scripts` repository clones this project before
`linux_hotkey_setup`, while installation is delegated to the hotkey setup so
the binding remains explicitly owned there.

## Detect, reconfigure, and uninstall

This installer tracks what it has installed and can re-apply or remove it, so you
can refresh configuration after a repo update or cleanly back a feature out.

```bash
bash install.sh --detect            # show each component as installed|absent
bash install.sh --reconfigure a,b   # re-apply (idempotent) these component ids
bash install.sh --uninstall a,b     # uninstall these component ids
```

In the interactive menu (run `bash install.sh` on a terminal, or via the master
installer), already-installed components show a green `✓`. Select one with
**space** to **reconfigure** it (`~`), press **`u`** to mark it for **uninstall**
(`✗`), or press **`r`** to reconfigure every installed component at once. Detection
uses a live check where deterministic and otherwise an install receipt under
`${XDG_STATE_HOME:-~/.local/state}/isc/receipts/`; a component without a reversal
step simply clears that receipt on uninstall.

## Disclaimer

This software is provided under the MIT License on an **“as is”** basis, without warranties of any kind. To the maximum extent permitted by applicable law, the authors and copyright holders shall not be liable for any claims, damages, losses, or other liability arising from the use of this software.

You are solely responsible for determining whether this software is suitable, safe, lawful, and appropriate for your intended use. Unless explicitly stated otherwise, this project is general-purpose software and is not designed, tested, certified, or approved for safety-critical, medical, automotive, aviation, industrial-control, life-support, cybersecurity-critical, financial-critical, or other high-risk use cases.

The authors and copyright holders make no guarantees regarding security, reliability, availability, correctness, compliance, non-infringement, or fitness for any particular purpose.

This notice is intended to clarify the nature of the project and does not impose additional restrictions beyond the MIT License.
