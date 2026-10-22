#!/usr/bin/env python3
"""monitor_layout.py - report the display monitors in GNOME's own numbering.

Single source of truth for "which monitor is monitor 1" across the setup chain.
The numbering matches the GNOME Settings -> Displays panel because both read the
same list: the `monitors` array returned by
org.gnome.Mutter.DisplayConfig.GetCurrentState, whose order is also the order
Mutter assigns monitor indexes to (so user-facing number N is Mutter index N-1).

Commands:
    list    Print one TSV row per monitor:
            number<TAB>connector<TAB>display-name<TAB>primary<TAB>x<TAB>y<TAB>width<TAB>height
    count   Print the number of connected monitors.

Both commands need a reachable GNOME session bus; without one they print
nothing and exit 1 so callers can degrade gracefully (the installer then hides
the per-application monitor action instead of guessing a layout).

Usage:
    python3 monitor_layout.py list
    python3 monitor_layout.py count
"""

import sys

# GetCurrentState signature: u a((ssss)a(siiddada{sv})a{sv}) a(iiduba(ssss)a{sv}) a{sv}
DISPLAY_CONFIG_BUS = "org.gnome.Mutter.DisplayConfig"
DISPLAY_CONFIG_PATH = "/org/gnome/Mutter/DisplayConfig"
DISPLAY_CONFIG_IFACE = "org.gnome.Mutter.DisplayConfig"
CALL_TIMEOUT_MS = 5000
# Mutter transform ids that turn the panel 90 or 270 degrees (plain + flipped).
ROTATED_TRANSFORMS = (1, 3, 5, 7)


def _log(message):
    """Print a diagnostic line to stderr (installer logs capture it).

    Args:
        message: Human-readable diagnostic text.
    """
    print(f"[monitor_layout] {message}", file=sys.stderr)


def query_state():
    """Return the unpacked GetCurrentState tuple from Mutter's DisplayConfig.

    Returns:
        tuple: (serial, monitors, logical_monitors, properties).

    Raises:
        RuntimeError: When PyGObject or the GNOME session bus is unavailable.
    """
    try:
        import gi  # noqa: F401  (import guarded on purpose: optional dependency)
        from gi.repository import Gio
    except Exception as exc:  # pragma: no cover - depends on host packages
        raise RuntimeError(f"PyGObject/Gio unavailable: {exc}") from exc

    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        reply = bus.call_sync(
            DISPLAY_CONFIG_BUS,
            DISPLAY_CONFIG_PATH,
            DISPLAY_CONFIG_IFACE,
            "GetCurrentState",
            None,
            None,
            Gio.DBusCallFlags.NONE,
            CALL_TIMEOUT_MS,
            None,
        )
    except Exception as exc:
        raise RuntimeError(f"DisplayConfig call failed: {exc}") from exc
    return reply.unpack()


def monitors_from_state(state):
    """Convert a GetCurrentState payload into ordered monitor rows.

    Args:
        state: The tuple returned by query_state().

    Returns:
        list[dict]: One entry per connected monitor, in GNOME's own order, with
            keys number, connector, name, primary, x, y, width, height. Geometry
            is the logical-monitor geometry (already scaled), which is what
            Meta.Display.get_monitor_geometry() reports inside GNOME Shell; it is
            zeroed when a monitor has no logical monitor (disabled output).
    """
    _serial, monitors, logical_monitors, _props = state
    geometry = {}
    primary = set()
    for logical in logical_monitors:
        x, y, scale, transform, is_primary, assigned, _lprops = logical[:7]
        width = height = 0
        for entry in assigned:
            connector = entry[0]
            if is_primary:
                primary.add(connector)
            # Logical size is the current mode size divided by the scale, with
            # width/height swapped for the 90/270 degree (and flipped) rotations
            # so a portrait monitor reports its on-screen extent.
            for monitor in monitors:
                if monitor[0][0] != connector:
                    continue
                for mode in monitor[1]:
                    if mode[6].get("is-current"):
                        width = int(round(mode[1] / (scale or 1)))
                        height = int(round(mode[2] / (scale or 1)))
                        if transform in ROTATED_TRANSFORMS:
                            width, height = height, width
                        break
            geometry[connector] = (int(x), int(y), width, height)

    rows = []
    for index, monitor in enumerate(monitors):
        connector = monitor[0][0]
        name = monitor[2].get("display-name") or connector
        x, y, width, height = geometry.get(connector, (0, 0, 0, 0))
        rows.append(
            {
                "number": index + 1,
                "connector": connector,
                "name": str(name),
                "primary": 1 if connector in primary else 0,
                "x": x,
                "y": y,
                "width": width,
                "height": height,
            }
        )
    return rows


def list_monitors():
    """Print one TSV row per monitor. Returns 0 on success, 1 when unavailable."""
    try:
        rows = monitors_from_state(query_state())
    except RuntimeError as exc:
        _log(str(exc))
        return 1
    if not rows:
        _log("DisplayConfig returned no monitors")
        return 1
    for row in rows:
        print(
            "\t".join(
                str(row[key])
                for key in ("number", "connector", "name", "primary", "x", "y", "width", "height")
            )
        )
    return 0


def count_monitors():
    """Print the monitor count. Returns 0 on success, 1 when unavailable."""
    try:
        rows = monitors_from_state(query_state())
    except RuntimeError as exc:
        _log(str(exc))
        return 1
    print(len(rows))
    return 0 if rows else 1


def main(argv):
    """Dispatch the requested sub-command.

    Args:
        argv: Argument vector without the program name.

    Returns:
        int: Process exit status.
    """
    command = argv[0] if argv else "list"
    if command == "list":
        return list_monitors()
    if command == "count":
        return count_monitors()
    _log(f"unknown command: {command}")
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
