//! Convert, display, and store installer hotkey fields.

use repeatable_fields::hotkey;
use std::env;
use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    match run(&args) {
        Ok(code) => ExitCode::from(code),
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(2)
        }
    }
}

fn run(args: &[String]) -> Result<u8, String> {
    let command = args.first().map(String::as_str).unwrap_or("");
    match command {
        "accel" => {
            let spec = required(args, 1)?;
            println!("{}", hotkey::to_gnome_accelerator(spec).map_err(|error| format!("Invalid hotkey: {error}"))?);
            Ok(0)
        }
        "display" => {
            let spec = required(args, 1)?;
            println!("{}", hotkey::display_accelerator(spec).map_err(|error| format!("Invalid hotkey: {error}"))?);
            Ok(0)
        }
        "modifier" => {
            let spec = required(args, 1)?;
            println!("{}", hotkey::normalize_modifier(spec).map_err(|error| format!("Invalid modifier: {error}"))?);
            Ok(0)
        }
        "add-modifier" => {
            let accelerator = required(args, 1)?;
            let modifier = required(args, 2)?;
            println!("{}", hotkey::add_modifier(accelerator, modifier).map_err(|error| format!("Invalid move modifier: {error}"))?);
            Ok(0)
        }
        "config-get" => {
            let path = required(args, 1)?;
            let key = required(args, 2)?;
            let default_value = args.get(3).map(String::as_str).unwrap_or("");
            println!("{}", hotkey::config_get(Path::new(path), key, default_value));
            Ok(0)
        }
        "config-set" => {
            let path = required(args, 1)?;
            let key = required(args, 2)?;
            let value = required(args, 3)?;
            hotkey::config_set(Path::new(path), key, value).map_err(|error| format!("Could not save field: {error}"))?;
            Ok(0)
        }
        _ => Err("usage: hotkey-capture accel|display|modifier|add-modifier|config-get|config-set".into()),
    }
}

fn required(args: &[String], index: usize) -> Result<&str, String> {
    args.get(index).map(String::as_str).ok_or_else(|| "missing argument".to_string())
}
