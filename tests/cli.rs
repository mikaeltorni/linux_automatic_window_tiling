//! CLI contract formerly covered by tests/test_gsettings_strv.py.

use std::env;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_awt-tools"))
}

#[test]
fn cli_formats_updated_array_from_current_environment() {
    let output = bin()
        .arg("two")
        .env("CURRENT", "@as ['one']")
        .output()
        .expect("run awt-tools");
    assert!(
        output.status.success(),
        "stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "['one', 'two']"
    );
}

#[test]
fn cli_rejects_wrong_argument_count() {
    let none = bin().output().expect("run awt-tools");
    assert_eq!(none.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&none.stderr).contains("Usage: awt-tools <value>"));

    let extra = bin().args(["one", "two"]).output().expect("run awt-tools");
    assert_eq!(extra.status.code(), Some(2));
}

#[test]
fn cli_writes_log_under_configured_dir() {
    let dir = tempfile_dir();
    let output = bin()
        .arg("automatic-window-tiling@local")
        .env("CURRENT", "[]")
        .env("AUTOMATIC_WINDOW_TILING_LOG_DIR", &dir)
        .output()
        .expect("run awt-tools");
    assert!(output.status.success());
    let log = std::fs::read_to_string(std::path::Path::new(&dir).join("gsettings_strv.log"))
        .expect("log file");
    assert!(log.contains("Ensuring extension UUID is present in enabled-extensions"));
}

fn tempfile_dir() -> String {
    let path = env::temp_dir().join(format!("awt-tools-cli-{}", std::process::id()));
    std::fs::create_dir_all(&path).expect("temp log dir");
    path.to_string_lossy().into_owned()
}
