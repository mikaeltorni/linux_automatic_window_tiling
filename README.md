# Linux Automatic Window Tiling

> Part of [installation_scripts](https://github.com/mikaeltorni/installation_scripts) — the master installer that orchestrates a productivity-focused Ubuntu 24.04 desktop setup (workspaces, hotkeys, window tiling, programming tools, and more). Tested on Ubuntu 24.04.4 LTS.

GNOME Shell extension that tiles windows matching the focused application on
the focused window's current workspace and monitor.

The installer accepts the desired GNOME accelerator, so the tiling action can
be bound without editing the extension source.

## Repository dependencies

This repository installs and runs **standalone** — it has **no** dependency on
any other setup repository. It is *consumed by* `linux_hotkey_setup` and
`linux_workspaces_setup`, which call this installer (passing the desired
accelerator) when it sits beside them; that is a one-way relationship and does
not create a dependency in this direction.

See the full cross-repository map in
[installation_scripts/DEPENDENCIES.md](https://github.com/mikaeltorni/installation_scripts/blob/master/DEPENDENCIES.md).

## Behavior

- Only normal, taskbar-visible windows are tiled.
- Windows must match the focused application's concrete identity.
- Windows must already be on the focused window's workspace and monitor.
- One window fills the monitor work area.
- Two windows tile left/right.
- Four windows use a 2x2 grid.
- Other counts use a balanced calculated grid.
- Kitty uses a 1300px preferred width to choose grid density on wide monitors,
  but tiled windows always expand to fill their complete grid cells.
- GNOME's work area is used, excluding panels and docks.

## Installation

Pass a GNOME accelerator as the first argument:

```bash
bash install.sh '<Super>t'
```

Long-form syntax is also supported:

```bash
bash install.sh --binding '<Control><Alt>t'
```

The installer can run directly as the desktop user or through `sudo`. When run
through `sudo`, it uses `SUDO_USER` to install into that user's local GNOME
Shell extension directory and apply the binding through the user's session
bus.

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

## Disclaimer

This software is provided under the MIT License on an **“as is”** basis, without warranties of any kind. To the maximum extent permitted by applicable law, the authors and copyright holders shall not be liable for any claims, damages, losses, or other liability arising from the use of this software.

You are solely responsible for determining whether this software is suitable, safe, lawful, and appropriate for your intended use. Unless explicitly stated otherwise, this project is general-purpose software and is not designed, tested, certified, or approved for safety-critical, medical, automotive, aviation, industrial-control, life-support, cybersecurity-critical, financial-critical, or other high-risk use cases.

The authors and copyright holders make no guarantees regarding security, reliability, availability, correctness, compliance, non-infringement, or fitness for any particular purpose.

This notice is intended to clarify the nature of the project and does not impose additional restrictions beyond the MIT License.
