//! Report display monitors in GNOME Settings order.

use repeatable_fields::monitor;
use serde_json::Value;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    match run(&args) {
        Ok(text) => {
            if !text.is_empty() {
                println!("{text}");
            }
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("[monitor_layout] {message}");
            ExitCode::from(if message.starts_with("unknown command") { 2 } else { 1 })
        }
    }
}

fn run(args: &[String]) -> Result<String, String> {
    let command = args.first().map(String::as_str).unwrap_or("list");
    let rows = match command {
        "list" | "count" => load_rows(args)?,
        other => return Err(format!("unknown command: {other}")),
    };
    if rows.is_empty() {
        return Err("DisplayConfig returned no monitors".into());
    }
    if command == "count" {
        Ok(rows.len().to_string())
    } else {
        Ok(monitor::format_rows(&rows))
    }
}

fn load_rows(args: &[String]) -> Result<Vec<monitor::Row>, String> {
    if let Some(path) = flag(args, "--state") {
        let text = fs::read_to_string(path).map_err(|error| error.to_string())?;
        let document: Value = serde_json::from_str(&text).map_err(|error| error.to_string())?;
        return monitor::rows_from_simplified(&document);
    }
    if let Some(path) = flag(args, "--busctl") {
        let text = fs::read_to_string(path).map_err(|error| error.to_string())?;
        let document: Value = serde_json::from_str(&text).map_err(|error| error.to_string())?;
        return monitor::rows_from_busctl(&document);
    }
    monitor::query_busctl()
}

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|arg| arg == name).and_then(|index| args.get(index + 1)).map(String::as_str)
}

#[allow(dead_code)]
fn _keep_stdout() {
    let _ = io::stdout().flush();
}
