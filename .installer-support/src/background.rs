//! Preserve background console output and bound its tmux history.

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const HISTORY_LIMIT: i64 = 2000;

#[derive(Debug)]
pub struct StartRequest {
    pub target: String,
    pub session: String,
    pub window: String,
    pub archive_dir: PathBuf,
    pub cwd: Option<PathBuf>,
    pub command: Vec<String>,
}

/// Parse public commands before invoking an operation.
/// Parameters: args - raw command-line arguments.
/// Returns: parsed command or a grammar error.
pub fn parse(args: &[String]) -> Result<Parsed, String> {
    eprintln!("args={args:?}");
    let operation = args.first().map(String::as_str).unwrap_or("");
    let result = match operation {
        "record" => {
            if args.len() != 3 || args.get(1).map(String::as_str) != Some("--file") {
                return Err("usage: tmux-background-output record --file FILE".into());
            }
            Ok(Parsed::Record { file: PathBuf::from(&args[2]) })
        }
        "prune" => {
            if args.len() != 3 || args.get(1).map(String::as_str) != Some("--archive-dir") {
                return Err("usage: tmux-background-output prune --archive-dir DIR".into());
            }
            Ok(Parsed::Prune { directory: PathBuf::from(&args[2]) })
        }
        "start" => parse_start(args),
        "" => Err("usage: tmux-background-output record|start|prune".into()),
        other => Err(format!("unknown command: {other}")),
    };
    eprintln!("{result:?}");
    result
}

#[derive(Debug)]
pub enum Parsed {
    Record { file: PathBuf },
    Start(StartRequest),
    Prune { directory: PathBuf },
}

fn parse_start(args: &[String]) -> Result<Parsed, String> {
    let mut target = None;
    let mut archive = None;
    let mut cwd = None;
    let mut command = Vec::new();
    let mut index = 1;
    while index < args.len() {
        let arg = &args[index];
        if arg == "--" {
            command.extend(args[index + 1..].iter().cloned());
            break;
        }
        let value = args.get(index + 1).ok_or_else(|| format!("missing value for {arg}"))?;
        match arg.as_str() {
            "--target" => target = Some(value.clone()),
            "--archive-dir" => archive = Some(PathBuf::from(value)),
            "--cwd" => cwd = Some(PathBuf::from(value)),
            other => return Err(format!("unknown argument: {other}")),
        }
        index += 2;
    }
    let target = target.ok_or_else(|| "start requires --target".to_string())?;
    let archive_dir = archive.ok_or_else(|| "start requires --archive-dir".to_string())?;
    if command.is_empty() {
        return Err("start requires a command after --".into());
    }
    let (session, window) = match target.split_once(':') {
        Some((session, window)) if !session.is_empty() && !window.is_empty() => (session.to_string(), window.to_string()),
        _ => return Err("target must be SESSION:WINDOW".into()),
    };
    Ok(Parsed::Start(StartRequest { target, session, window, archive_dir, cwd, command }))
}

/// Record using the embedded shared compressor and retention implementation.
/// Parameters: file - initial archive path; stream - raw console byte stream.
/// Returns: success or recording failure.
pub fn record(file: &Path, mut stream: impl Read) -> Result<(), String> {
    eprintln!("file={file:?} stream={:p}", &stream);
    let result = run_recorder("record", "--file", file, Some(&mut stream));
    eprintln!("{result:?}");
    result
}

/// Retain bounded recent recorder archives without changing tmux panes.
/// Parameters: directory - archive directory.
/// Returns: success or retention failure.
pub fn prune(directory: &Path) -> Result<(), String> {
    eprintln!("directory={directory:?}");
    let result = run_recorder("prune", "--archive-dir", directory, None);
    eprintln!("{result:?}");
    result
}

/// Invoke the embedded canonical recorder without one gzip subprocess per chunk.
/// Parameters: operation - validated operation; flag - path selector; path - destination; stream - optional raw input.
/// Returns: success or child process failure.
fn run_recorder(operation: &str, flag: &str, path: &Path, stream: Option<&mut dyn Read>) -> Result<(), String> {
    eprintln!("operation={operation} flag={flag} path={path:?} stream={:?}", stream.as_ref().map(|input| *input as *const dyn Read));
    let mut child = Command::new("python3")
        .args(["-c", include_str!("../tmux_background_output.py"), operation, flag])
        .arg(path).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::inherit())
        .spawn().map_err(|error| error.to_string())?;
    let mut input = child.stdin.take().ok_or("recorder stdin unavailable")?;
    let copied = match stream {
        Some(source) => std::io::copy(source, &mut input).map(|_| ()).map_err(|error| error.to_string()),
        None => Ok(()),
    };
    drop(input);
    let status = child.wait().map_err(|error| error.to_string())?;
    copied?;
    if !status.success() {
        return Err(format!("recorder failed: {status}"));
    }
    eprintln!("Ok(())");
    Ok(())
}

/// Start one recorded background window while preserving unrelated history.
/// Parameters: request - validated window, directory, working directory and command.
/// Returns: success or launch failure.
pub fn start(request: &StartRequest) -> Result<(), String> {
    eprintln!("request={request:?}");
    if let Some(cwd) = &request.cwd {
        if !cwd.is_dir() {
            return Err(format!("Working directory does not exist: {}", cwd.display()));
        }
    }
    fs::create_dir_all(&request.archive_dir).map_err(|error| error.to_string())?;
    let windows = tmux(&["list-windows", "-t", &request.session, "-F", "#{window_name}"])?;
    if !windows.lines().any(|name| name == request.window) {
        tmux(&["new-window", "-d", "-t", &request.session, "-n", &request.window, "sleep infinity"])?;
    }
    let panes = tmux(&["list-panes", "-t", &request.target, "-F", "#{pane_id} #{history_limit}"])?;
    let pane_lines: Vec<&str> = panes.lines().filter(|line| !line.is_empty()).collect();
    if pane_lines.len() != 1 {
        return Err("Refusing to replace a window with multiple panes".into());
    }
    let mut fields = pane_lines[0].split_whitespace();
    let old_pane = fields.next().unwrap_or("").to_string();
    let old_limit: i64 = fields.next().unwrap_or("0").parse().unwrap_or(0);
    prune(&request.archive_dir)?;
    connect_recorder(&old_pane, &request.archive_dir)?;
    snapshot_history(&old_pane, &request.archive_dir)?;
    tmux(&["set-window-option", "-t", &request.target, "history-limit", &HISTORY_LIMIT.to_string()])?;
    let mut pane = old_pane.clone();
    let launch = (|| {
        if old_limit > HISTORY_LIMIT {
            pane = tmux(&["split-window", "-d", "-l", "1", "-P", "-F", "#{pane_id}", "-t", &old_pane, "sleep infinity"])?;
            connect_recorder(&pane, &request.archive_dir)?;
        }
        let mut arguments = vec!["respawn-pane".to_string(), "-k".into(), "-t".into(), pane.clone()];
        if let Some(cwd) = &request.cwd {
            arguments.push("-c".into());
            arguments.push(cwd.display().to_string());
        }
        arguments.push(shell_join(&request.command));
        let refs: Vec<&str> = arguments.iter().map(String::as_str).collect();
        tmux(&refs)
    })();
    if launch.is_err() {
        if pane != old_pane {
            let _ = tmux(&["kill-pane", "-t", &pane]);
        }
        return Err(launch.unwrap_err());
    }
    if pane != old_pane {
        tmux(&["kill-pane", "-t", &old_pane])?;
    }
    eprintln!("Ok(())");
    Ok(())
}

fn connect_recorder(pane: &str, directory: &Path) -> Result<(), String> {
    let path = archive_path(directory, "output")?;
    let command = format!("{} >/dev/null", shell_join(&[current_exe(), "record".into(), "--file".into(), path.display().to_string()]));
    tmux(&["pipe-pane", "-O", "-t", pane, &command])?;
    Ok(())
}

fn snapshot_history(pane: &str, directory: &Path) -> Result<(), String> {
    let path = archive_path(directory, "snapshot")?;
    let mut process = Command::new("tmux").args(["capture-pane", "-p", "-e", "-S", "-", "-t", pane]).stdout(Stdio::piped()).spawn().map_err(|error| error.to_string())?;
    let stdout = process.stdout.take().ok_or_else(|| "capture-pane produced no output".to_string())?;
    record(&path, stdout)?;
    let status = process.wait().map_err(|error| error.to_string())?;
    if !status.success() {
        return Err("Cannot preserve existing pane history; pane left running".into());
    }
    Ok(())
}

fn archive_path(directory: &Path, suffix: &str) -> Result<PathBuf, String> {
    fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|error| error.to_string())?.as_nanos();
    let stamp = format_stamp(nanos);
    let path = directory.join(format!("{stamp}-{suffix}.gz"));
    let mut output = OpenOptions::new().create_new(true).write(true).mode(0o600).open(&path).map_err(|error| error.to_string())?;
    output.write_all(&gzip_member(b"")?).map_err(|error| error.to_string())?;
    Ok(path)
}

fn format_stamp(nanos: u128) -> String {
    let seconds = (nanos / 1_000_000_000) as i64;
    let micros = ((nanos % 1_000_000_000) / 1_000) as u32;
    let days = seconds.div_euclid(86400);
    let time = seconds.rem_euclid(86400);
    let (year, month, day) = civil_from_days(days);
    let hour = time / 3600;
    let minute = (time % 3600) / 60;
    let second = time % 60;
    format!("{year:04}{month:02}{day:02}T{hour:02}{minute:02}{second:02}.{micros:06}Z")
}

fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };
    (year as i32, month as u32, day as u32)
}

fn gzip_member(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut child = Command::new("gzip").args(["-1", "-n", "-c"]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|error| error.to_string())?;
    child.stdin.take().ok_or_else(|| "gzip stdin unavailable".to_string())?.write_all(data).map_err(|error| error.to_string())?;
    let output = child.wait_with_output().map_err(|error| error.to_string())?;
    if !output.status.success() {
        return Err("gzip failed".into());
    }
    Ok(output.stdout)
}

fn tmux(arguments: &[&str]) -> Result<String, String> {
    let output = Command::new("tmux").args(arguments).output().map_err(|error| error.to_string())?;
    if !output.status.success() {
        return Err(format!("tmux {} failed: {}", arguments.join(" "), String::from_utf8_lossy(&output.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn shell_join(args: &[String]) -> String {
    args.iter().map(|arg| {
        if arg.chars().all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | '+' | '=' | ':' | ',')) {
            arg.clone()
        } else {
            format!("'{}'", arg.replace('\'', "'\\''"))
        }
    }).collect::<Vec<_>>().join(" ")
}

fn current_exe() -> String {
    env::current_exe().map(|path| path.display().to_string()).unwrap_or_else(|_| "tmux-background-output".into())
}
