"""Check actual X11 window placement and cycling through a configured hotkey."""

import argparse
import itertools
import re
import subprocess
import time


def command(*arguments):
    """Read the output from one X11 utility.

    Parameters: arguments - executable and command arguments.
    Returns: stripped command output.
    """
    print(f"arguments={arguments}")
    result = subprocess.run(arguments, check=True, capture_output=True, text=True)
    output = result.stdout.strip()
    print(output)
    return output


def read_work_area():
    """Read the current X11 desktop's usable rectangle.

    Parameters: none.
    Returns: an x, y, width, height dictionary.
    """
    print("parameters=none")
    desktop = int(command("xprop", "-root", "_NET_CURRENT_DESKTOP").split("=", 1)[1])
    values = [int(value) for value in re.findall(
        r"-?\d+", command("xprop", "-root", "_NET_WORKAREA").split("=", 1)[1]
    )]
    result = dict(zip(("x", "y", "width", "height"), values[desktop * 4:desktop * 4 + 4]))
    print(result)
    return result


def read_frame(window_id):
    """Read an X11 client frame, excluding GTK's invisible shadow margins.

    Parameters: window_id - numeric X11 window identifier.
    Returns: an x, y, width, height dictionary.
    """
    print(f"window_id={window_id}")
    info = command("xwininfo", "-id", str(window_id))
    fields = [int(re.search(pattern, info).group(1)) for pattern in (
        r"Absolute upper-left X:\s*(-?\d+)",
        r"Absolute upper-left Y:\s*(-?\d+)",
        r"Width:\s*(\d+)", r"Height:\s*(\d+)",
    )]
    hints = command("xprop", "-id", str(window_id), "_GTK_FRAME_EXTENTS")
    extents = [int(value) for value in re.findall(r"\d+", hints.split("=", 1)[1])] if "=" in hints else [0, 0, 0, 0]
    left, right, top, bottom = extents
    result = {"x": fields[0] + left, "y": fields[1] + top,
              "width": fields[2] - left - right, "height": fields[3] - top - bottom}
    print(result)
    return result


def require_windows(window_ids):
    """Require multiple distinct windows for a meaningful tiling check.

    Parameters: window_ids - converted X11 identifiers.
    Returns: None.
    """
    print(f"window_ids={window_ids}")
    assert len(set(window_ids)) == len(window_ids) >= 2, window_ids
    print(None)


def require_tiled_layout(frames, area):
    """Require visible frames to fit the work area without overlapping.

    Parameters: frames - window identifier to frame mapping; area - usable rectangle.
    Returns: None.
    """
    print(f"frames={frames}, area={area}")
    for window_id, frame in frames.items():
        assert frame["x"] >= area["x"] - 1, (window_id, frame, area)
        assert frame["y"] >= area["y"] - 1, (window_id, frame, area)
        assert frame["x"] + frame["width"] <= area["x"] + area["width"] + 1, (window_id, frame, area)
        assert frame["y"] + frame["height"] <= area["y"] + area["height"] + 1, (window_id, frame, area)
    for (left_id, left), (right_id, right) in itertools.combinations(frames.items(), 2):
        overlap_x = min(left["x"] + left["width"], right["x"] + right["width"]) - max(left["x"], right["x"])
        overlap_y = min(left["y"] + left["height"], right["y"] + right["height"]) - max(left["y"], right["y"])
        assert overlap_x <= 1 or overlap_y <= 1, (left_id, right_id, left, right)
    print(None)


def require_cycle(first, second):
    """Require every window to rotate to the previous validated grid position.

    Parameters: first - independently validated initial frames; second - frames after another keypress.
    Returns: None.
    """
    print(f"first={first}, second={second}")
    order = sorted(first, key=lambda window_id: (first[window_id]["y"], first[window_id]["x"]))
    for index, window_id in enumerate(order):
        target = first[order[(index - 1) % len(order)]]
        actual = second[window_id]
        assert abs(actual["x"] - target["x"]) <= 2 and abs(actual["y"] - target["y"]) <= 2, (window_id, actual, target)
    print(None)


def check_hotkey(key, window_ids):
    """Exercise a real GNOME hotkey twice and verify placement and cycling.

    Parameters: key - xdotool accelerator; window_ids - eligible windows in the current workspace.
    Returns: None.
    """
    print(f"key={key}, window_ids={window_ids}")
    require_windows(window_ids)
    area = read_work_area()
    command("xdotool", "windowactivate", "--sync", str(window_ids[0]))
    command("xdotool", "key", "--clearmodifiers", key)
    time.sleep(0.8)
    first = {window_id: read_frame(window_id) for window_id in window_ids}
    require_tiled_layout(first, area)
    command("xdotool", "key", "--clearmodifiers", key)
    time.sleep(0.8)
    second = {window_id: read_frame(window_id) for window_id in window_ids}
    require_tiled_layout(second, area)
    require_cycle(first, second)
    print(None)


def parse_arguments():
    """Parse the configured shortcut and the numeric X11 test windows.

    Parameters: none.
    Returns: the parsed command arguments.
    """
    print("parameters=none")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", required=True)
    parser.add_argument("--windows", type=int, nargs="+", required=True)
    result = parser.parse_args()
    print(result)
    return result


def main():
    """Dispatch the VM regression through the configured public hotkey.

    Parameters: none.
    Returns: zero after all live geometry assertions pass.
    """
    print("parameters=none")
    arguments = parse_arguments()
    check_hotkey(arguments.key, arguments.windows)
    print(0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
