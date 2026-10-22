//! installation-config export, apply, diff, and roundtrip.

use repeatable_fields::config;
use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    match run(&args) {
        Ok(code) => ExitCode::from(code),
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(1)
        }
    }
}

fn run(args: &[String]) -> Result<u8, String> {
    match args.first().map(String::as_str).unwrap_or("") {
        "export" => {
            let state = required(args, "--state-file")?;
            let document = config::export_state(Path::new(&state))?;
            let text = config::dumps(&document);
            if let Some(output) = optional(args, "--output") {
                if let Some(parent) = Path::new(&output).parent() {
                    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
                }
                fs::write(output, &text).map_err(|error| error.to_string())?;
            } else {
                print!("{text}");
            }
            Ok(0)
        }
        "apply" => {
            let config_path = required(args, "--config")?;
            let state = required(args, "--state-file")?;
            let document = config::load_document(Path::new(&config_path))?;
            config::apply_document(&document, Path::new(&state))?;
            Ok(0)
        }
        "diff" => {
            let baseline = config::load_document(Path::new(&required(args, "--baseline")?))?;
            let current = config::load_document(Path::new(&required(args, "--current")?))?;
            for line in config::diff_documents(&baseline, &current) {
                println!("{line}");
            }
            Ok(0)
        }
        "is-empty" => {
            let document = config::load_document(Path::new(&required(args, "--config")?))?;
            Ok(if config::is_explicit_empty(&document) { 0 } else { 1 })
        }
        "scope" => {
            let document = config::load_document(Path::new(&required(args, "--config")?))?;
            println!("{}", config::scope_name(&document));
            Ok(0)
        }
        "repo-enabled" => {
            let document = config::load_document(Path::new(&required(args, "--config")?))?;
            println!("{}", config::repo_enabled(&document, &required(args, "--repo")?));
            Ok(0)
        }
        "component-ids" => {
            let document = config::load_document(Path::new(&required(args, "--config")?))?;
            let repo = optional(args, "--repo");
            println!("{}", config::component_ids(&document, repo.as_deref()).join(" "));
            Ok(0)
        }
        "roundtrip" => {
            let state = required(args, "--state-file")?;
            let path = Path::new(&state);
            let document = config::export_state(path)?;
            let applied = path.with_extension("applied");
            config::apply_document(&document, &applied)?;
            let roundtrip = config::export_state(&applied)?;
            if document != roundtrip { Ok(1) } else { Ok(0) }
        }
        _ => Err("usage: installation-config export|apply|diff|roundtrip|is-empty|scope|repo-enabled|component-ids".into()),
    }
}

fn required(args: &[String], name: &str) -> Result<String, String> {
    optional(args, name).ok_or_else(|| format!("missing {name}"))
}

fn optional(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|arg| arg == name).and_then(|index| args.get(index + 1)).cloned()
}
