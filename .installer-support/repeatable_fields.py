#!/usr/bin/env python3
"""Reusable state for installer screens with repeatable editable rows.

Repositories own their field semantics and rendering.  This helper only owns
the consistent one-based add/edit/toggle/group mutations used by those screens.
"""

from __future__ import annotations


class RepeatableRows:
    """Maintain ordered dictionaries addressed by user-facing 1-based indices."""

    def __init__(self, items: list[dict] | None = None):
        self.items = [dict(item) for item in (items or [])]

    def _row(self, index: int) -> dict | None:
        return self.items[index - 1] if 1 <= index <= len(self.items) else None

    def add(self, values: dict) -> int:
        """Append ``values`` and return its one-based row number."""
        self.items.append(dict(values))
        return len(self.items)

    def set_value(self, index: int, field: str, value) -> bool:
        """Set one field, returning false when ``index`` does not exist."""
        row = self._row(index)
        if row is None:
            return False
        row[field] = value
        return True

    def toggle(self, index: int, field: str) -> bool:
        """Toggle a boolean field, returning false for a missing row."""
        row = self._row(index)
        if row is None:
            return False
        row[field] = not bool(row.get(field))
        return True

    def set_group(self, index: int, group: int) -> bool:
        """Set a non-negative exclusivity group number (zero means ungrouped)."""
        if group < 0:
            raise ValueError("group must be zero or greater")
        return self.set_value(index, "group", group)
