"""Public installer checks for configurable tiling accelerators."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _run_installer_parser(
    arguments: list[str],
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run the parser copied from the install entrypoint with test arguments.

    Parameters: arguments - installer arguments passed to parse_binding;
    environment - optional environment overrides for the parser process.
    Returns: the Bash process result containing the parsed installer state.
    """
    print(f"arguments={arguments}, environment={environment}")
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")
    match = re.search(r"(?ms)^parse_binding\(\) \{\n.*?^\}", installer)
    assert match, "parse_binding must remain available in install.sh"
    script = (
        match.group(0)
        + "\nusage() { :; }\n"
        + 'parse_binding "$@" || exit $?\n'
        + "printf 'binding=%s\\n' \"${AWT_BINDING:-}\"\n"
        + "printf 'all_binding=%s\\n' \"${AWT_ALL_BINDING:-}\"\n"
        + "printf 'binding_explicit=%s\\n' \"${AWT_BINDING_EXPLICIT:-0}\"\n"
        + "printf 'all_binding_explicit=%s\\n' \"${AWT_ALL_BINDING_EXPLICIT:-0}\"\n"
        + "printf 'framework_args='; if ((${#FRAMEWORK_ARGS[@]})); then printf '%s|' \"${FRAMEWORK_ARGS[@]}\"; fi; printf '\\n'\n"
    )
    process_environment = os.environ.copy()
    for name in (
        "AWT_BINDING",
        "AWT_ALL_BINDING",
        "AWT_BINDING_EXPLICIT",
        "AWT_ALL_BINDING_EXPLICIT",
    ):
        process_environment.pop(name, None)
    if environment is not None:
        process_environment.update(environment)
    result = subprocess.run(
        ["bash", "-c", script, "test-installer-parser", *arguments],
        capture_output=True,
        text=True,
        check=False,
        env=process_environment,
    )
    print(result)
    return result


def _run_keybinding_operation(
    binding: str,
    all_binding: str,
    explicit: bool = False,
    explicit_all: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run the real keybinding operation with captured GSettings writes.

    Parameters: binding - captured focused-app accelerator; all_binding - captured
    monitor-wide accelerator; explicit - whether the focused value bypasses
    capture; explicit_all - whether the monitor-wide value bypasses capture.
    Returns: the Bash process result containing captured calls and writes.
    """
    print(
        f"binding={binding}, all_binding={all_binding}, explicit={explicit}, "
        f"explicit_all={explicit_all}"
    )
    script = r'''set -euo pipefail
ROOT="$1"
isc_capture_hotkey() {
  printf 'capture:%s\n' "$1" >&2
  case "$1" in
    TILING_HOTKEY) printf '%s\n' "$CAPTURE_BINDING" ;;
    TILING_ALL_HOTKEY) printf '%s\n' "$CAPTURE_ALL_BINDING" ;;
    *) return 2 ;;
  esac
}
source "$ROOT/lib/tiling_setup.sh"
installer_log() { :; }
awt_set_strv() { printf '%s=%s\n' "$1" "$2"; }
awt_configure_keybinding
'''
    environment = os.environ.copy()
    environment.update(
        {
            "CAPTURE_BINDING": binding,
            "CAPTURE_ALL_BINDING": all_binding,
            "ISC_HOTKEY_INTERACTIVE": "1",
        }
    )
    if explicit:
        environment.update(
            {
                "AWT_BINDING": binding,
                "AWT_BINDING_EXPLICIT": "1",
            }
        )
    else:
        environment.pop("AWT_BINDING", None)
        environment.pop("AWT_BINDING_EXPLICIT", None)
    if explicit_all:
        environment.update(
            {
                "AWT_ALL_BINDING": all_binding,
                "AWT_ALL_BINDING_EXPLICIT": "1",
            }
        )
    else:
        environment.pop("AWT_ALL_BINDING", None)
        environment.pop("AWT_ALL_BINDING_EXPLICIT", None)
    result = subprocess.run(
        ["bash", "-c", script, "test-keybinding-operation", str(ROOT)],
        capture_output=True,
        text=True,
        check=False,
        env=environment,
    )
    print(result)
    return result


def test_parser_accepts_both_explicit_accelerators() -> None:
    """Parse Super+T and Super+Shift+T without forwarding them as menu flags.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = _run_installer_parser(
        [
            "--binding",
            "<Super>t",
            "--all-binding",
            "<Super><Shift>t",
            "--default",
        ]
    )
    assert result.returncode == 0, result.stderr
    assert "binding=<Super>t\n" in result.stdout
    assert "all_binding=<Super><Shift>t\n" in result.stdout
    assert "binding_explicit=1\n" in result.stdout
    assert "all_binding_explicit=1\n" in result.stdout
    assert "framework_args=--default|\n" in result.stdout
    print(None)


def test_parser_keeps_legacy_positional_binding() -> None:
    """Keep the existing single positional binding interface working.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = _run_installer_parser(["<Super>t", "--default"])
    assert result.returncode == 0, result.stderr
    assert "binding=<Super>t\n" in result.stdout
    assert "framework_args=--default|\n" in result.stdout
    print(None)


def test_parser_accepts_equals_binding_options() -> None:
    """Parse both accelerator overrides using their equals forms.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = _run_installer_parser(
        ["--binding=<Super>t", "--all-binding=<Super><Shift>t"]
    )
    assert result.returncode == 0, result.stderr
    assert "binding=<Super>t\n" in result.stdout
    assert "all_binding=<Super><Shift>t\n" in result.stdout
    print(None)


def test_parser_rejects_missing_accelerator_values() -> None:
    """Reject either binding option when its accelerator is missing.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    for arguments in (
        ["--binding"],
        ["--binding", "--default"],
        ["--binding="],
        ["--all-binding"],
        ["--all-binding", "--default"],
        ["--all-binding="],
    ):
        result = _run_installer_parser(arguments)
        assert result.returncode == 2, (arguments, result.stdout, result.stderr)
    print(None)


def test_environment_binding_is_explicit_for_bundle_and_scripted_installs() -> None:
    """Keep environment-selected accelerators when interactive capture is enabled.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = _run_installer_parser(
        [],
        {
            "AWT_BINDING": "<Super>t",
            "AWT_ALL_BINDING": "<Super><Shift>t",
        },
    )
    assert result.returncode == 0, result.stderr
    assert "binding=<Super>t\n" in result.stdout
    assert "all_binding=<Super><Shift>t\n" in result.stdout
    assert "binding_explicit=1\n" in result.stdout
    assert "all_binding_explicit=1\n" in result.stdout
    assert "framework_args=\n" in result.stdout
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")
    assert '"${AWT_BINDING_EXPLICIT:-}${AWT_ALL_BINDING_EXPLICIT:-}"' in installer
    print(None)


def test_one_scripted_accelerator_leaves_the_other_capture_available() -> None:
    """Keep a scripted monitor-wide key while capturing the focused-app key.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = _run_keybinding_operation(
        "<Super>t", "<Super><Shift>t", explicit_all=True
    )
    assert result.returncode == 0, result.stderr
    assert "capture:TILING_HOTKEY\n" in result.stderr
    assert "capture:TILING_ALL_HOTKEY\n" not in result.stderr
    assert "tile-focused-application-windows=<Super>t\n" in result.stdout
    assert "tile-all-windows=<Super><Shift>t\n" in result.stdout
    print(None)


def test_operation_captures_and_applies_both_accelerators() -> None:
    """Use the shared capture helper for both tiling actions.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = _run_keybinding_operation("<Super>t", "<Super><Shift>t")
    assert result.returncode == 0, result.stderr
    assert "capture:TILING_HOTKEY\n" in result.stderr
    assert "capture:TILING_ALL_HOTKEY\n" in result.stderr
    assert "tile-focused-application-windows=<Super>t\n" in result.stdout
    assert "tile-all-windows=<Super><Shift>t\n" in result.stdout
    print(None)


def test_explicit_environment_values_bypass_interactive_capture() -> None:
    """Apply scripted accelerators directly without opening hotkey capture.

    Parameters: none.
    Returns: None.
    """
    print("parameters=none")
    result = _run_keybinding_operation(
        "<Super>t", "<Super><Shift>t", explicit=True, explicit_all=True
    )
    assert result.returncode == 0, result.stderr
    assert "capture:" not in result.stderr
    assert "tile-focused-application-windows=<Super>t\n" in result.stdout
    assert "tile-all-windows=<Super><Shift>t\n" in result.stdout
    print(None)
