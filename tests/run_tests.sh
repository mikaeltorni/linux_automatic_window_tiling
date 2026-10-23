#!/usr/bin/env bash
# Run the repository's Rust, Python, Bash, and GSettings schema checks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

for command_name in cargo python3 node glib-compile-schemas; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing test dependency: %s\n' "$command_name" >&2
    exit 1
  fi
done

if ! python3 -m pytest --version >/dev/null 2>&1; then
  printf 'Missing test dependency: python3 -m pytest\n' >&2
  exit 1
fi

printf '%s\n' 'Running Rust tests'
cargo test

printf '%s\n' 'Building the installer helper'
bash scripts/build_awt_tools.sh --print >/dev/null

printf '%s\n' 'Running Python tests'
python3 -m pytest tests -q

python3 tests/check_invalid_selection.py

printf '%s\n' 'Checking installer shell syntax'
bash -n install.sh lib/*.sh installer/*.sh scripts/*.sh tests/run_tests.sh

printf '%s\n' 'Validating GSettings schemas'
glib-compile-schemas --strict schemas

printf '%s\n' 'All repository checks passed'
