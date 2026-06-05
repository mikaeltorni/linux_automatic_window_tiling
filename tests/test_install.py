from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def test_extension_filters_by_application_workspace_and_monitor():
    source = (ROOT / "extension.js").read_text(encoding="utf-8")

    assert "getWindowApplicationId" in source
    assert "global.workspace_manager.get_active_workspace()" in source
    assert "win.get_monitor() !== monitorIndex" in source
    assert "workspace.get_work_area_for_monitor(monitorIndex)" in source
    assert "win.move_resize_frame(true, x1, y1, x2 - x1, y2 - y1)" in source
    assert "workArea.width >= workArea.height" in source


def test_schema_has_no_hard_coded_binding():
    schema = (
        ROOT
        / "schemas"
        / "org.gnome.shell.extensions.automatic-window-tiling.gschema.xml"
    ).read_text(encoding="utf-8")

    assert '<key name="tile-focused-application-windows"' in schema
    assert "<default>[]</default>" in schema
    assert "&lt;Super&gt;t" not in schema


def test_installer_requires_and_applies_binding_argument():
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")

    assert 'parse_binding "$@"' in installer
    assert '"--binding"' in installer
    assert "gsettings_array" in installer
    assert '"$SCHEMA_ID" "$BINDING_KEY"' in installer
    assert 'TARGET_USER="${SUDO_USER:-${TARGET_USER:-$USER}}"' in installer
    assert 'if [[ "$(id -u)" -eq "$TARGET_UID" ]]' in installer
