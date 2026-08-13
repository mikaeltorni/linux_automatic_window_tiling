//! Centralized file logging for `awt-tools`.
//!
//! Writes best-effort records under the repository `.log/` directory (or
//! `AUTOMATIC_WINDOW_TILING_LOG_DIR`) so helper stdout stays reserved for the
//! installer contract. Logging never aborts the program.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;

static LOG_FILE: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Resolve the repository root (parent of `src/` / `Cargo.toml` / `install.sh`).
fn repo_root() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    if manifest.join("install.sh").is_file() || manifest.join("Cargo.toml").is_file() {
        return manifest;
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Configure the file sink under `.log/gsettings_strv.log` (idempotent).
pub fn init() {
    let mut guard = LOG_FILE.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_some() {
        return;
    }
    let dir = std::env::var("AUTOMATIC_WINDOW_TILING_LOG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root().join(".log"));
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    *guard = Some(dir.join("gsettings_strv.log"));
}

fn write_line(level: &str, message: &str) {
    init();
    let path = {
        let guard = LOG_FILE.lock().unwrap_or_else(|e| e.into_inner());
        guard.clone()
    };
    let Some(path) = path else {
        return;
    };
    let ts = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!("{ts} {level} [gsettings_strv] {message}\n");
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(line.as_bytes());
    }
}

/// Log an informational action-path message.
pub fn info(message: impl AsRef<str>) {
    write_line("INFO", message.as_ref());
}

/// Log a warning that does not abort the caller.
pub fn warn(message: impl AsRef<str>) {
    write_line("WARN", message.as_ref());
}

/// Log an error condition (caller still decides the process exit code).
pub fn error(message: impl AsRef<str>) {
    write_line("ERROR", message.as_ref());
}

/// Log a debug/trace detail for diagnostics.
pub fn debug(message: impl AsRef<str>) {
    write_line("DEBUG", message.as_ref());
}
