//! `awt-tools` — installer-facing helpers for automatic-window-tiling.
//!
//! Usage (matches the former `lib/gsettings_strv.py` contract):
//!
//! ```text
//! CURRENT="@as ['one']" awt-tools two
//! # -> ['one', 'two']
//! ```

mod gsettings_strv;
mod logging;

fn main() {
    std::process::exit(gsettings_strv::run_cli());
}
