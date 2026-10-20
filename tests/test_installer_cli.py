"""Exercise the public installer with isolated desktop and framework boundaries."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def installer_environment(tmp_path):
    """Prepare a clean checkout and fake desktop commands without host effects.

    Parameters: tmp_path - pytest's isolated temporary directory.
    Returns: the checkout, target home, effects log and subprocess environment.
    """
    print(f"tmp_path={tmp_path}")
    checkout = tmp_path / "checkout"
    shutil.copytree(ROOT, checkout, ignore=shutil.ignore_patterns(
        ".git", "tmp", "target", "dist", ".log", ".pytest_cache", "__pycache__",
    ))
    home = tmp_path / "desktop"
    home.mkdir()
    commands = tmp_path / "bin"
    commands.mkdir()
    effects = tmp_path / "effects"
    effects.touch()
    scripts = {
        "id": "#!/bin/bash\nprintf '1000\\n'\n",
        "getent": '#!/bin/bash\nprintf "%s:x:1000:1000::%s:/bin/bash\\n" "$2" "$AWT_TEST_HOME"\n',
        "gsettings": r'''#!/bin/bash
printf '%s\t' "$@" >> "$AWT_TEST_EFFECTS"
printf '\n' >> "$AWT_TEST_EFFECTS"
if [[ -n "${AWT_TEST_FAIL_KEY:-}" && "$*" == *"$AWT_TEST_FAIL_KEY"* ]]; then exit 1; fi
case "$*" in
  *'get org.gnome.shell enabled-extensions') printf "['existing@local']\n" ;;
esac
''',
        "glib-compile-schemas": '#!/bin/bash\nprintf "compile\\n" >> "$AWT_TEST_EFFECTS"\n',
        "gnome-extensions": "#!/bin/bash\nexit 0\n",
        "awt-test-helper": '#!/bin/bash\nprintf "[\x27existing@local\x27, \x27automatic-window-tiling@local\x27]\\n"\n',
    }
    for name, script in scripts.items():
        path = commands / name
        path.write_text(script)
        path.chmod(0o755)
    build = checkout / "scripts/build_awt_tools.sh"
    build.write_text('''#!/bin/bash
if [[ "${AWT_TEST_FAIL_BUILD:-0}" == 1 ]]; then exit 1; fi
printf '%s\n' "$AWT_TEST_HELPER"
''')
    build.chmod(0o755)
    framework = tmp_path / "framework"
    framework.mkdir()
    (framework / "component_loader.sh").write_text(r'''
# Supply the external framework's core-before-install-only contract.
# Parameters: none. Returns: zero.
isc_load_helpers() {
  printf 'isc_load_helpers parameters=none\n' >&2
  printf 'isc_load_helpers return=0\n' >&2
}
# Activate the framework test double.
# Parameters: none. Returns: zero.
isc_activate_components() {
  printf 'isc_activate_components parameters=none\n' >&2
  printf 'isc_activate_components return=0\n' >&2
}
# Route supported framework modes, preserving the ISC_CORE callback contract.
# Parameters: $@ - framework arguments. Returns: command exit status.
component_main() {
  printf 'component_main parameters=%s\n' "$*" >&2
  local mode=install selected=keybinding result
  while (($#)); do
    case "$1" in
      --help|-h) printf 'Framework usage\n'; printf 'component_main return=0\n' >&2; return 0 ;;
      --list-components) printf 'keybinding\tTiling accelerators\ton\nper_app_widths\tWidths\ton\nportrait_stacking\tPortrait\ton\n'; printf 'component_main return=0\n' >&2; return 0 ;;
      --list-configurable-components|--list-select-configure-components|--list-component-config-values|--detect|--export-selection)
        printf 'query\n'; printf 'component_main return=0\n' >&2; return 0 ;;
      --config|--select|--reconfigure|--uninstall|--configure-component)
        (($# >= 2)) || { printf 'component_main return=2\n' >&2; return 2; }
        case "$1" in
          --uninstall) mode=uninstall ;;
          --select|--reconfigure) selected="$2" ;;
        esac
        shift 2; continue ;;
      --config=*|--select=*|--reconfigure=*|--uninstall=*|--configure-component=*)
        case "$1" in --uninstall=*) mode=uninstall;; esac ;;
      --default|--all|--auth) ;;
      *) printf 'component_main return=2\n' >&2; return 2 ;;
    esac
    shift
  done
  if [[ "$mode" == uninstall ]]; then
    uninstall_awt_keybinding
  else
    if [[ -n "${ISC_CORE:-}" ]]; then
      "$ISC_CORE" || { result=$?; printf 'component_main return=%s\n' "$result" >&2; return "$result"; }
    fi
    if [[ "$selected" == keybinding ]]; then
      awt_configure_keybinding || { result=$?; printf 'component_main return=%s\n' "$result" >&2; return "$result"; }
    fi
  fi
  printf 'component_main return=0\n' >&2
}
''')
    environment = {"PATH": os.environ["PATH"], "LANG": "C.UTF-8"}
    environment.update({
        "PATH": f"{commands}:{environment['PATH']}", "HOME": str(home),
        "USER": "desktop", "TARGET_USER": "desktop", "ISC_FUNCTIONS_DIR": str(framework),
        "XDG_STATE_HOME": str(home / ".local/state"),
        "AWT_TEST_HOME": str(home), "AWT_TEST_EFFECTS": str(effects),
        "AWT_TEST_HELPER": str(commands / "awt-test-helper"),
    })
    result = (checkout, home, effects, environment)
    print(result)
    return result


def run_installer(sandbox, arguments):
    """Invoke the actual public installer in its isolated environment.

    Parameters: sandbox - checkout/home/log/environment tuple; arguments - raw CLI arguments.
    Returns: the completed Bash process.
    """
    print(f"sandbox={sandbox}, arguments={arguments}")
    checkout, _, _, environment = sandbox
    result = subprocess.run(["bash", str(checkout / "install.sh"), *arguments],
                            env=environment, text=True, capture_output=True, timeout=15)
    print(result)
    return result


@pytest.mark.parametrize("arguments", [
    ["--help"], ["--binding", "<Super>y", "--help"],
    ["--all-binding", "<Super><Shift>y", "--list-components"],
    ["--config", "empty.json", "--list-components"],
    ["--config=empty.json", "--detect"],
    ["--binding", "<Super>y", "--export-selection"],
    ["--list-configurable-components"],
])
def test_queries_do_not_deploy_or_change_settings(installer_environment, arguments):
    """Keep every query free of extension deployment and desktop writes.

    Parameters: installer_environment - isolated installer fixture; arguments - public query form.
    Returns: None.
    """
    print(f"installer_environment={installer_environment}, arguments={arguments}")
    _, home, effects, _ = installer_environment
    result = run_installer(installer_environment, arguments)
    assert result.returncode == 0, (arguments, result.stderr)
    assert effects.read_text() == "", (arguments, effects.read_text())
    assert not (home / ".local/share/gnome-shell/extensions").exists(), arguments
    assert "Installed automatic-window-tiling" not in result.stdout, result.stdout
    print(None)


@pytest.mark.parametrize("arguments", [["--unknown"], ["--select"], ["--config"], ["--reconfigure"], ["--uninstall"]])
def test_invalid_commands_fail_before_desktop_changes(installer_environment, arguments):
    """Reject unknown or missing operands without partially installing anything.

    Parameters: installer_environment - isolated installer fixture; arguments - invalid CLI form.
    Returns: None.
    """
    print(f"installer_environment={installer_environment}, arguments={arguments}")
    _, home, effects, _ = installer_environment
    result = run_installer(installer_environment, arguments)
    assert result.returncode == 2, (arguments, result.stdout, result.stderr)
    assert effects.read_text() == "", (arguments, effects.read_text())
    assert not (home / ".local/share/gnome-shell/extensions").exists(), arguments
    print(None)


def test_uninstall_after_binding_options_never_installs_core(installer_environment):
    """Route uninstall operands unchanged and reset only the requested settings.

    Parameters: installer_environment - isolated installer fixture.
    Returns: None.
    """
    print(f"installer_environment={installer_environment}")
    _, home, effects, _ = installer_environment
    result = run_installer(installer_environment, ["--binding", "<Super>y", "--uninstall", "keybinding"])
    assert result.returncode == 0, result.stderr
    lines = effects.read_text().splitlines()
    assert len(lines) == 2 and all("reset" in line for line in lines), lines
    assert not (home / ".local/share/gnome-shell/extensions").exists()
    print(None)


def test_build_failure_preserves_the_existing_installation(installer_environment):
    """Leave installed files and settings untouched when the helper cannot build.

    Parameters: installer_environment - isolated installer fixture.
    Returns: None.
    """
    print(f"installer_environment={installer_environment}")
    _, home, effects, environment = installer_environment
    target = home / ".local/share/gnome-shell/extensions/automatic-window-tiling@local"
    target.mkdir(parents=True)
    original = target / "extension.js"
    original.write_text("original user installation")
    environment["AWT_TEST_FAIL_BUILD"] = "1"
    result = run_installer(installer_environment, ["--default"])
    assert result.returncode != 0, result.stdout
    assert original.read_text() == "original user installation"
    assert effects.read_text() == "", effects.read_text()
    print(None)


def test_clean_install_and_reinstall_deploy_complete_runtime(installer_environment):
    """Install twice in a clean home with both explicit accelerator choices.

    Parameters: installer_environment - isolated installer fixture.
    Returns: None.
    """
    print(f"installer_environment={installer_environment}")
    checkout, home, effects, _ = installer_environment
    for attempt in range(2):
        result = run_installer(installer_environment, [
            "--binding", "<Super>y", "--all-binding", "<Super><Shift>y", "--default",
        ])
        assert result.returncode == 0, (attempt, result.stderr)
        target = home / ".local/share/gnome-shell/extensions/automatic-window-tiling@local"
        for source in checkout.glob("*.js"):
            assert (target / source.name).read_bytes() == source.read_bytes(), source.name
    calls = effects.read_text()
    assert "tile-focused-application-windows\t['<Super>y']" in calls, calls
    assert "tile-all-windows\t['<Super><Shift>y']" in calls, calls
    print(None)


@pytest.mark.parametrize("arguments", [
    ["--standalone"],
    ["--standalone", "--binding", "<Super>y", "--all-binding", "<Super><Shift>y"],
    ["--standalone", "--default", "<Super>y", "--all-binding=<Super><Shift>y"],
])
def test_standalone_install_needs_no_framework_or_git_access(installer_environment, arguments):
    """Install and reapply the complete extension without fetching private dependencies.

    Parameters: installer_environment - isolated installer fixture; arguments - public standalone form.
    Returns: None.
    """
    print(f"installer_environment={installer_environment}, arguments={arguments}")
    checkout, home, effects, environment = installer_environment
    framework = Path(environment["ISC_FUNCTIONS_DIR"])
    shutil.rmtree(framework)
    git = home.parent / "bin/git"
    git.write_text('#!/bin/bash\nprintf "network-attempt\\n" >> "$AWT_TEST_EFFECTS"\nexit 1\n')
    git.chmod(0o755)
    for attempt in range(2):
        result = run_installer(installer_environment, arguments)
        assert result.returncode == 0, (attempt, result.stdout, result.stderr)
    target = home / ".local/share/gnome-shell/extensions/automatic-window-tiling@local"
    for source in checkout.glob("*.js"):
        assert (target / source.name).read_bytes() == source.read_bytes(), source.name
    calls = effects.read_text()
    assert "network-attempt" not in calls, calls
    assert "application-preferred-widths" in calls and "portrait-minimum-tile-height" in calls
    binding = "<Super>y" if len(arguments) > 1 else "<Super>t"
    assert f"tile-focused-application-windows\t['{binding}']" in calls, calls
    assert "Installed automatic-window-tiling@local." in result.stdout
    print(None)


@pytest.mark.parametrize("arguments,returncode", [
    (["--standalone", "--help"], 0),
    (["--standalone", "--select", "keybinding"], 2),
    (["--standalone", "--unknown"], 2),
    (["--standalone", "--binding"], 2),
])
def test_standalone_queries_and_errors_do_not_load_framework_or_mutate(installer_environment, arguments, returncode):
    """Keep standalone help and invalid commands independent of the framework.

    Parameters: installer_environment - isolated installer fixture; arguments - standalone CLI form; returncode - required exit status.
    Returns: None.
    """
    print(f"installer_environment={installer_environment}, arguments={arguments}, returncode={returncode}")
    _, home, effects, environment = installer_environment
    shutil.rmtree(Path(environment["ISC_FUNCTIONS_DIR"]))
    result = run_installer(installer_environment, arguments)
    assert result.returncode == returncode, (arguments, result.stdout, result.stderr)
    assert effects.read_text() == "", effects.read_text()
    assert not (home / ".local/share/gnome-shell/extensions").exists()
    print(None)


@pytest.mark.parametrize("standalone", [False, True])
def test_first_binding_write_failure_is_reported_and_stops_later_writes(installer_environment, standalone):
    """Propagate a failed first shortcut write through both installation paths.

    Parameters: installer_environment - isolated installer fixture; standalone - select the independent installer path.
    Returns: None.
    """
    print(f"installer_environment={installer_environment}, standalone={standalone}")
    _, _, effects, environment = installer_environment
    environment["AWT_TEST_FAIL_KEY"] = "tile-focused-application-windows"
    arguments = ["--standalone"] if standalone else ["--default"]
    result = run_installer(installer_environment, arguments)
    assert result.returncode != 0, result.stdout
    assert "tile-focused-application-windows" in effects.read_text()
    assert "tile-all-windows" not in effects.read_text(), effects.read_text()
    assert "Installed automatic-window-tiling" not in result.stdout
    print(None)
