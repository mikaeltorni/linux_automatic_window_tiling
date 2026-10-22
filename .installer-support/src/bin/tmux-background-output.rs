//! Preserve background console output on disk and bound its tmux history.

use repeatable_fields::background::{self, Parsed};
use std::env;
use std::io;
use std::process::ExitCode;

fn main() -> ExitCode {
    match run(&env::args().skip(1).collect::<Vec<_>>()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(if message.starts_with("usage:") || message.starts_with("unknown") || message.starts_with("start requires") || message.starts_with("target must") || message.starts_with("missing ") { 2 } else { 1 })
        }
    }
}

/// Dispatch validated commands to the shared operation owner.
/// Parameters: args - raw command-line arguments.
/// Returns: success or command failure.
fn run(args: &[String]) -> Result<(), String> {
    eprintln!("args={args:?}");
    let result = match background::parse(args)? {
        Parsed::Record { file } => background::record(&file, io::stdin()),
        Parsed::Start(request) => background::start(&request),
        Parsed::Prune { directory } => background::prune(&directory),
    };
    eprintln!("{result:?}");
    result
}
