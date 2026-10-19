# Linux Automatic Window Tiling

> Part of [installation_scripts](https://github.com/mikaeltorni/installation_scripts) — the master installer that orchestrates a productivity-focused Ubuntu 24.04 desktop setup (workspaces, hotkeys, window tiling, programming tools, and more). Tested on Ubuntu 24.04.4 LTS.

GNOME Shell extension that tiles windows on the focused window's current
workspace and monitor. Super+T is the default for same-application tiling;
Ctrl+Shift+T is the default for tiling every eligible application window on
that monitor. Both accelerators can be selected independently during install.
Desktop launchers can call the session D-Bus method
`org.gnome.shell.extensions.AutomaticWindowTiling.TileWindowGroup` with an X11
window ID. It applies the Super+T application grid on that window's workspace
and monitor without selecting the workspace, raising a window, or cycling an
already tiled grid. This lets a batch of background terminals be placed first
and tiled once per workspace/monitor. `TileWindowGroups` accepts an array of
X11 window IDs and groups them by their actual workspace, monitor, and
application tile group; it covers existing windows moved by hand to another
monitor.

The installer accepts both GNOME accelerators as command-line options or
environment overrides, so both actions can be configured without editing the
extension source.

## Repository dependencies

This repository can be installed **standalone** or through the
`installation_scripts` bundle. The master bundle clones and runs this installer
directly as its own selectable repository; `linux_hotkey_setup` does not install
or configure this extension. The installer uses the shared component framework
owned by `linux_installation_scripts_functions`, resolving a sibling checkout
when present and otherwise cloning it with the current Git credentials. A
standalone first install therefore needs Git access to that framework when no
sibling checkout exists.

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

Set both requested shortcuts independently. This example keeps Super+T for the
focused application and selects Super+Shift+T for monitor-wide tiling:

```bash
bash install.sh --binding '<Super>t' --all-binding '<Super><Shift>t'
```

The equivalent `--binding=<accelerator>` and
`--all-binding=<accelerator>` forms are also accepted. The legacy positional
accelerator remains an alias for `--binding`.

The same choices work in scripted standalone or bundle installs through
environment overrides:

```bash
AWT_BINDING='<Super>t' AWT_ALL_BINDING='<Super><Shift>t' bash install.sh --default
```

For press-to-capture on a terminal, enable the shared capture UI for this
standalone component install:

```bash
ISC_HOTKEY_INTERACTIVE=1 bash install.sh --select keybinding
```

Plain and master-bundle installs stay non-interactive and use the defaults or
the `AWT_BINDING` / `AWT_ALL_BINDING` overrides. The master bundle passes those
environment values to this repository's installer.

Component-framework flags select exactly what to configure:

```bash
bash install.sh                      # interactive component menu on a TTY
bash install.sh --default            # all default-on components, no prompts
bash install.sh --all                # every component, no prompts
bash install.sh --select keybinding  # only the listed component ids
bash install.sh --list-components    # id<TAB>label<TAB>default, for tooling
bash install.sh --export-selection   # export current component selection
bash install.sh --help              # print installer help
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
component uses the shared press-to-capture engine for both keys when
`ISC_HOTKEY_INTERACTIVE=1`; otherwise it uses the configured values or defaults.

The installer can run directly as the desktop user or through `sudo`. When run
through `sudo`, it uses `SUDO_USER` to install into that user's local GNOME
Shell extension directory and apply settings through the user's session bus. It
requires `glib-compile-schemas` (Ubuntu package `libglib2.0-bin`) and builds the
`awt-tools` Rust helper during installation. Provide Cargo, or Docker/Podman for
the container build fallback. When the shared framework is not checked out as a
sibling, Git credentials must permit cloning
`linux_installation_scripts_functions`.

GSettings accelerator changes apply live. If edited extension JavaScript needs
a Shell reload, use GNOME's in-place run-dialog reload on X11:

```bash
xdotool key --clearmodifiers alt+F2
sleep 0.5
xdotool type 'r'
xdotool key Return
```

On Wayland, deploy the files and log out and back in to load edited extension
code.

## Development

Runtime modules:

- `extension.js` owns tiling orchestration, logging, and extension lifecycle.
- `layout.js` owns pure grid selection and tile geometry calculations.
- `windows.js` owns GNOME window selection, identity, and state management.

Run the complete local test and build checks:

```bash
./tests/run_tests.sh
```

The runner checks Rust tests and builds, Python tests, Bash syntax, and the
GSettings schema. It requires Cargo, Python with pytest, Node.js, and
`glib-compile-schemas`.

The individual checks can also be run separately:

```bash
cargo test
python3 -m pytest tests -q
bash -n install.sh
glib-compile-schemas --strict schemas
```

The compiled `schemas/gschemas.compiled` file is generated and ignored.

## Integration

The `installation_scripts` master installer clones this repository and runs it
directly before `linux_hotkey_setup`. It exposes this installer's
`keybinding` component in the repository selection menu. Configure both hotkeys
for the bundle with:

```bash
sudo env AWT_BINDING='<Super>t' AWT_ALL_BINDING='<Super><Shift>t' bash install.sh
```

The same installer and accelerator options are available from this repository
when run standalone.

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
