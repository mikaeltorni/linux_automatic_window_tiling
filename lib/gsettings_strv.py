"""gsettings_strv.py - helpers for GNOME gsettings string-array values.

Components:
  - parse_strv: Parse gsettings array output into a list of strings.
  - append_strv: Return a de-duplicated array with a value appended.
  - format_strv: Serialize values back to the gsettings string-array format.
"""

from __future__ import annotations

import ast
import os
import sys


def parse_strv(raw: str | None) -> list[str]:
    """Parse gsettings string-array output into normalized string values."""
    value = (raw or "").strip()
    if value.startswith("@as "):
        value = value[4:].strip()

    try:
        parsed = ast.literal_eval(value) if value else []
    except (SyntaxError, ValueError):
        return []

    if not isinstance(parsed, list):
        return []

    return [str(item) for item in parsed]


def append_strv(raw: str | None, value: str) -> list[str]:
    """Return normalized values with ``value`` appended if it is not present."""
    current = list(dict.fromkeys(parse_strv(raw)))
    if value and value not in current:
        current.append(value)
    return current


def format_strv(values: list[str]) -> str:
    """Serialize values for ``gsettings set``."""
    return "[" + ", ".join(repr(str(item)) for item in values) + "]"


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint used by ``install.sh``."""
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        print("Usage: gsettings_strv.py <value>", file=sys.stderr)
        return 2

    current = os.environ.get("CURRENT", "")
    print(format_strv(append_strv(current, args[0])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
