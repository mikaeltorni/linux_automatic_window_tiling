"""gsettings_strv.py - helpers for GNOME gsettings string-array values.

Parses, de-duplicates, and re-serializes the GVariant string-array (``as``)
values that ``install.sh`` reads from and writes back to gsettings (for
example ``org.gnome.shell enabled-extensions``). Keeping this logic in a
tested Python module avoids fragile inline shell/Python heredocs in the
installer.

Components:
  - parse_strv: Parse gsettings array output into a list of strings.
  - append_strv: Return a de-duplicated array with a value appended.
  - format_strv: Serialize values back to the gsettings string-array format.
  - main: CLI entrypoint used by ``install.sh``.

Usage:
  CURRENT="$(gsettings get org.gnome.shell enabled-extensions)" \\
      python3 lib/gsettings_strv.py 'automatic-window-tiling@local'

  The updated array literal is printed to stdout (kept clean for command
  substitution); diagnostics go to ``.log/gsettings_strv.log``.
"""

from __future__ import annotations

import ast
import os
import sys

from logging_utils import get_logger, log_call

LOGGER = get_logger("gsettings_strv", "gsettings_strv.log")


@log_call(LOGGER)
def parse_strv(raw: str | None) -> list[str]:
    """Parse gsettings string-array output into normalized string values.

    Accepts both the bare ``['a', 'b']`` literal and the GVariant-annotated
    ``@as ['a', 'b']`` form that ``gsettings get`` may emit. Malformed input is
    treated as an empty array rather than raising, so the installer degrades
    gracefully on unexpected gsettings output.

    Args:
        raw: The raw ``gsettings get`` value, or None. Leading ``@as`` GVariant
            annotation and surrounding whitespace are tolerated.

    Returns:
        list[str]: The parsed values as strings, or an empty list when ``raw``
        is empty, not a list literal, or cannot be parsed.
    """
    value = (raw or "").strip()
    if value.startswith("@as "):
        value = value[4:].strip()

    try:
        parsed = ast.literal_eval(value) if value else []
    except (SyntaxError, ValueError):
        LOGGER.warning("could not parse gsettings array: %r", raw)
        return []

    if not isinstance(parsed, list):
        LOGGER.warning("gsettings value is not an array: %r", raw)
        return []

    values = [str(item) for item in parsed]
    return values


@log_call(LOGGER)
def append_strv(raw: str | None, value: str) -> list[str]:
    """Return normalized values with ``value`` appended if it is not present.

    Existing duplicates in ``raw`` are collapsed so the result is order-stable
    and contains each entry exactly once. An empty ``value`` is never appended.

    Args:
        raw: The current gsettings array value (see :func:`parse_strv`), or None.
        value: The entry to ensure is present, for example an extension UUID.

    Returns:
        list[str]: The de-duplicated values, with ``value`` appended when it was
        non-empty and not already present.
    """
    current = list(dict.fromkeys(parse_strv(raw)))
    if value and value not in current:
        current.append(value)
        LOGGER.info("appended %r; array now has %d value(s)", value, len(current))
    else:
        LOGGER.debug("%r already present or empty; array unchanged", value)
    return current


@log_call(LOGGER)
def format_strv(values: list[str]) -> str:
    """Serialize values for ``gsettings set``.

    Args:
        values: The string values to serialize.

    Returns:
        str: A gsettings array literal such as ``['one', 'two']`` with each
        element rendered via :func:`repr` so embedded quotes are escaped.
    """
    formatted = "[" + ", ".join(repr(str(item)) for item in values) + "]"
    return formatted


@log_call(LOGGER)
def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint used by ``install.sh``.

    Reads the current array from the ``CURRENT`` environment variable, appends
    the single positional argument, and prints the updated array literal to
    stdout for capture via command substitution.

    Args:
        argv: Argument vector excluding the program name. Defaults to
            ``sys.argv[1:]`` when None. Exactly one argument (the value to
            append) is required.

    Returns:
        int: ``0`` on success, or ``2`` when the argument count is wrong.
    """
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        LOGGER.error("expected exactly one argument, got %d", len(args))
        print("Usage: gsettings_strv.py <value>", file=sys.stderr)
        return 2

    current = os.environ.get("CURRENT", "")
    LOGGER.info("appending %r to CURRENT array", args[0])
    print(format_strv(append_strv(current, args[0])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
