//! Apply one-based repeatable-row commands and print the resulting state.

mod rows;

use std::io::{self, Read};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut raw = String::new();
    if io::stdin().read_to_string(&mut raw).is_err() {
        eprintln!("invalid command script");
        return ExitCode::from(1);
    }
    match rows::apply_script(&raw) {
        Ok(report) => {
            println!("{}", rows::python_json(&report));
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(1)
        }
    }
}
