"""hotkey_capture.py - shared interactive press-to-capture hotkey engine.

This is the single source of truth for the configurable-hotkey experience every
setup repository consumes (it is not hard-coded to any one repo). A user picks a
component to install and then *presses* the keys they want: modifier keys (Ctrl,
Alt, Super, Shift — including left and right physical keys) toggle on repeat
press and may be pressed one at a time; a single non-modifier press becomes the
key. Simultaneous chord reports replace held modifiers via
:meth:`HotkeyBinding.set_modifiers_from_chord`. The capture overlay shows
separate **Modifiers** and **Key** fields that update live. The Backspace key
removes the most recent input. When the binding is confirmed it is converted to
the canonical GTK accelerator (``<Super><Shift>s``) that ``gsettings`` expects.

Two capture flavours are supported:

* keyboard accelerators (the default) — the key is a normal keyboard key and the
  result is a GTK accelerator string;
* pointer/mouse triggers (``mouse_mode``) — used by the window-placement tiling
  service, where the "key" is a mouse Back/Forward button. Because a terminal
  installer may not be able to receive the physical side buttons, the keyboard
  ``F`` and ``B`` keys stand in for Forward and Back respectively.

The pure state machine (:class:`HotkeyBinding`), the accelerator conversion and
the conflict detection are all import-safe and unit-tested. The evdev capture
driver is a thin best-effort I/O layer that degrades to the caller's default
when no input device can be read (for example a non-interactive install).

Components:
  - MODIFIER_ALIASES / MODIFIER_ORDER: canonical modifier vocabulary.
  - EVDEV_MODIFIERS / EVDEV_MOUSE_BUTTONS: evdev key-name to token maps.
  - HotkeyBinding: the press/back/format/accelerator state machine.
  - to_gnome_accelerator / normalize_accelerator: friendly<->GTK conversion.
  - find_conflicts / describe_conflicts: GNOME default collision reporting.
  - capture_binding: evdev press-to-capture driver (best effort).
  - main: CLI entrypoint used by hotkey_capture.sh.

Usage:
  python3 hotkey_capture.py accel super+shift+s        # -> <Shift><Super>s
  python3 hotkey_capture.py capture --label screenshot --default '<Shift><Super>s' --single-key
"""

from __future__ import annotations

import argparse
import contextlib
import os
import re
import sys
import tempfile
import termios
import tty
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable, Iterator, TextIO

from logging_utils import get_logger, log_call

LOGGER = get_logger("hotkey_capture", "hotkey_capture.log")

# Accepted spellings for each modifier mapped to the canonical GTK keyword that
# appears inside angle brackets. Comparison is case-insensitive.
MODIFIER_ALIASES = {
    "ctrl": "Control",
    "control": "Control",
    "alt": "Alt",
    "meta": "Alt",
    "super": "Super",
    "win": "Super",
    "windows": "Super",
    "cmd": "Super",
    "shift": "Shift",
}

# Emit modifiers in a stable canonical order regardless of press order so the
# resulting accelerator is deterministic and matches GNOME's own conventions.
MODIFIER_ORDER = ["Control", "Alt", "Super", "Shift"]

# Short display names shown in the "+"-joined live preview.
MODIFIER_DISPLAY = {
    "Control": "Ctrl",
    "Alt": "Alt",
    "Super": "Super",
    "Shift": "Shift",
}

# evdev key names (ecodes.KEY[...] / BTN[...]) mapped to a canonical modifier.
EVDEV_MODIFIERS = {
    "KEY_LEFTCTRL": "Control",
    "KEY_RIGHTCTRL": "Control",
    "KEY_LEFTALT": "Alt",
    "KEY_RIGHTALT": "Alt",
    "KEY_LEFTMETA": "Super",
    "KEY_RIGHTMETA": "Super",
    "KEY_LEFTSHIFT": "Shift",
    "KEY_RIGHTSHIFT": "Shift",
}

# evdev button/key names mapped to the mouse trigger tokens used by mouse_mode.
EVDEV_MOUSE_BUTTONS = {
    "BTN_BACK": "MouseBack",
    "BTN_SIDE": "MouseBack",
    "BTN_FORWARD": "MouseForward",
    "BTN_EXTRA": "MouseForward",
    # Keyboard stand-ins for machines/terminals without side buttons.
    "KEY_B": "MouseBack",
    "KEY_F": "MouseForward",
}

# Mouse trigger token -> the evdev button name the tiler service watches for.
MOUSE_TRIGGER_EVENT = {
    "MouseBack": "BTN_BACK",
    "MouseForward": "BTN_FORWARD",
}

# Named (non-alphanumeric) keyboard keys mapped from evdev names to the GTK
# accelerator key spelling. Anything not listed falls back to the letter/number.
EVDEV_NAMED_KEYS = {
    "KEY_SPACE": "space",
    "KEY_ENTER": "Return",
    "KEY_TAB": "Tab",
    "KEY_ESC": "Escape",
    "KEY_SYSRQ": "Print",
    "KEY_PRINT": "Print",
    "KEY_HOME": "Home",
    "KEY_END": "End",
    "KEY_PAGEUP": "Page_Up",
    "KEY_PAGEDOWN": "Page_Down",
    "KEY_LEFT": "Left",
    "KEY_RIGHT": "Right",
    "KEY_UP": "Up",
    "KEY_DOWN": "Down",
    "KEY_DELETE": "Delete",
    "KEY_INSERT": "Insert",
}

# evdev names that confirm the current binding (accept it as final).
EVDEV_CONFIRM_KEYS = {"KEY_ENTER", "KEY_KPENTER"}
# evdev names that remove the most recent input (the "Back" key from the goal).
EVDEV_BACK_KEYS = {"KEY_BACKSPACE"}
# evdev names that cancel capture and keep the default.
EVDEV_CANCEL_KEYS = {"KEY_ESC"}

# Kitty keyboard-protocol modifier key codes (pressed alone).
KITTY_MODIFIER_KEY_CODES = {
    57417: "Shift",
    57418: "Shift",
    57419: "Alt",
    57420: "Alt",
    57421: "Control",
    57422: "Control",
    57423: "Super",
    57424: "Super",
}

# Kitty ``CSI … ; modifiers u`` bit flags (OR-combined).
KITTY_MOD_SHIFT = 1
KITTY_MOD_ALT = 2
KITTY_MOD_CTRL = 4
KITTY_MOD_SUPER = 8

# CSI final-byte range for an escape sequence.
_CSI_FINAL_BYTE = tuple(range(0x40, 0x80))


class HotkeyBinding:
    """Accumulate modifiers and a single key from discrete key presses.

    The binding records an *ordered* history of presses so that
    :meth:`back` can undo exactly the most recent one. Modifier keys toggle on
    repeat press (left and right physical keys map to the same canonical name);
    only one non-modifier key is ever held (pressing a second key replaces the
    first, honoring the "many modifiers but only one key" rule).
    """

    def __init__(self, mouse_mode: bool = False) -> None:
        self.mouse_mode = mouse_mode
        # Ordered press history of (kind, name) where kind is "mod" or "key".
        self._events: list[tuple[str, str]] = []

    @property
    def modifiers(self) -> list[str]:
        """Return the accumulated modifiers in canonical emit order."""
        held = {name for kind, name in self._events if kind == "mod"}
        return [name for name in MODIFIER_ORDER if name in held]

    @property
    def key(self) -> str | None:
        """Return the current non-modifier key, or ``None`` when unset."""
        keys = [name for kind, name in self._events if kind == "key"]
        return keys[-1] if keys else None

    def is_empty(self) -> bool:
        """Return True when nothing has been captured yet."""
        return not self._events

    def is_complete(self) -> bool:
        """Return True when a key has been captured (a bindable hotkey)."""
        return self.key is not None

    def toggle_modifier(self, name: str) -> str:
        """Toggle a modifier on or off when its physical key is pressed again.

        Args:
            name: A canonical modifier name (``Control``/``Alt``/``Super``/``Shift``).

        Returns:
            ``"added"`` when newly held, ``"removed"`` when toggled off.
        """
        if name not in MODIFIER_ORDER:
            raise ValueError(f"unknown modifier {name!r}")
        if any(kind == "mod" and held == name for kind, held in self._events):
            for index in range(len(self._events) - 1, -1, -1):
                kind, held = self._events[index]
                if kind == "mod" and held == name:
                    del self._events[index]
                    return "removed"
        self._events.append(("mod", name))
        return "added"

    def ensure_modifier(self, name: str) -> str:
        """Add a modifier when bundled with a key chord without toggling off.

        Args:
            name: A canonical modifier name.

        Returns:
            ``"added"`` when newly recorded, ``"duplicate"`` when already held.
        """
        if name not in MODIFIER_ORDER:
            raise ValueError(f"unknown modifier {name!r}")
        if any(kind == "mod" and held == name for kind, held in self._events):
            return "duplicate"
        self._events.append(("mod", name))
        return "added"

    def set_modifiers_from_chord(self, names: list[str]) -> None:
        """Replace toggled modifiers with those held during a simultaneous chord.

        Stale modifiers tapped earlier are cleared so a chord report reflects
        only the modifiers physically held with that key press.
        """
        held = {name for name in names if name in MODIFIER_ORDER}
        self._events = [event for event in self._events if event[0] != "mod"]
        for name in MODIFIER_ORDER:
            if name in held:
                self._events.append(("mod", name))

    def add_modifier(self, name: str) -> str:
        """Backward-compatible alias for :meth:`toggle_modifier`."""
        return self.toggle_modifier(name)

    def set_key(self, name: str) -> str:
        """Set the single key, replacing any previous key.

        Args:
            name: The key spelling (a letter, named key, or mouse trigger token).

        Returns:
            ``"added"`` when no key was held before, otherwise ``"replaced"``.
        """
        had_key = self.key is not None
        self._events = [event for event in self._events if event[0] != "key"]
        self._events.append(("key", name))
        return "replaced" if had_key else "added"

    def toggle_key(self, name: str) -> str:
        """Toggle the single key off when the same key is pressed again.

        Args:
            name: The key spelling (a letter, named key, or mouse trigger token).

        Returns:
            ``"added"``, ``"replaced"``, or ``"removed"`` when toggled off.
        """
        if self.key == name:
            self._events = [event for event in self._events if event[0] != "key"]
            return "removed"
        return self.set_key(name)

    def back(self) -> tuple[str, str] | None:
        """Remove and return the most recent press, or ``None`` when empty."""
        if not self._events:
            return None
        return self._events.pop()

    def clear(self) -> None:
        """Discard all captured input."""
        self._events = []

    def display_modifiers_field(self) -> str:
        """Render active modifiers for the capture overlay (``Ctrl+Shift``)."""
        parts = [MODIFIER_DISPLAY[name] for name in self.modifiers]
        return "+".join(parts) if parts else "(none)"

    def display_key_field(self) -> str:
        """Render the captured non-modifier key for the capture overlay."""
        if self.key is None:
            return "(none)"
        key = self.key
        return key.upper() if len(key) == 1 else key

    def display(self) -> str:
        """Render the live ``Ctrl+Super+S`` style preview.

        Modifiers are shown in canonical order using their short names and the
        key (if any) is upper-cased for single letters. An empty binding renders
        as ``(none)``.
        """
        parts = [MODIFIER_DISPLAY[name] for name in self.modifiers]
        if self.key is not None:
            parts.append(self.display_key_field())
        return "+".join(parts) if parts else "(none)"

    def to_accelerator(self) -> str:
        """Return the canonical GTK accelerator (``<Super><Shift>s``).

        Raises:
            ValueError: When no key is set, or in ``mouse_mode`` where the key is
                a pointer button that has no GTK accelerator representation.
        """
        if self.key is None:
            raise ValueError("no key captured")
        if self.key in MOUSE_TRIGGER_EVENT:
            raise ValueError(f"mouse trigger {self.key!r} has no GTK accelerator")
        prefix = "".join(f"<{name}>" for name in self.modifiers)
        return f"{prefix}{self.key}"

    def to_trigger(self) -> tuple[list[str], str]:
        """Return ``(modifiers, event_name)`` for a pointer-driven trigger.

        Used by the window-placement tiling service, whose "hotkey" is a set of
        held modifiers plus a mouse Back/Forward button rather than a GTK
        accelerator.

        Raises:
            ValueError: When the captured key is not a mouse trigger token.
        """
        if self.key not in MOUSE_TRIGGER_EVENT:
            raise ValueError(f"{self.key!r} is not a mouse trigger")
        return self.modifiers, MOUSE_TRIGGER_EVENT[self.key]


def token_for_evdev_key(name: str, mouse_mode: bool = False) -> tuple[str, str] | None:
    """Map an evdev key/button name to a ``(kind, value)`` binding token.

    Args:
        name: An evdev name such as ``KEY_LEFTCTRL``, ``KEY_S`` or ``BTN_BACK``.
        mouse_mode: When True, side buttons and the ``F``/``B`` stand-ins map to
            mouse trigger tokens; otherwise ``F``/``B`` are ordinary letters.

    Returns:
        ``("mod", canonical)`` for a modifier, ``("key", spelling)`` for a key or
        mouse trigger, or ``None`` when the name is not bindable.
    """
    if name in EVDEV_MODIFIERS:
        return ("mod", EVDEV_MODIFIERS[name])
    if mouse_mode and name in EVDEV_MOUSE_BUTTONS:
        return ("key", EVDEV_MOUSE_BUTTONS[name])
    if not mouse_mode and name in EVDEV_NAMED_KEYS:
        return ("key", EVDEV_NAMED_KEYS[name])
    if name in EVDEV_NAMED_KEYS:
        return ("key", EVDEV_NAMED_KEYS[name])
    if name.startswith("KEY_"):
        raw = name[len("KEY_"):]
        if len(raw) == 1 and raw.isalnum():
            return ("key", raw.lower())
    return None


@log_call(LOGGER)
def to_gnome_accelerator(spec: str) -> str:
    """Convert a friendly ``modifier+key`` spec to a GTK accelerator string.

    The final ``+``-separated token is the key; every preceding token must be a
    recognized modifier. Modifiers are de-duplicated and emitted in canonical
    order; the key token is preserved verbatim.

    Raises:
        ValueError: When the spec is empty, malformed, or names an unknown
            modifier.
    """
    raw = (spec or "").strip()
    if not raw:
        raise ValueError("empty hotkey specification")
    tokens = [part.strip() for part in raw.split("+")]
    if any(not token for token in tokens):
        raise ValueError(f"malformed hotkey {spec!r}: empty modifier or key")
    *modifier_tokens, key = tokens
    if not key:
        raise ValueError(f"hotkey {spec!r} has no key")
    seen: set[str] = set()
    for token in modifier_tokens:
        canonical = MODIFIER_ALIASES.get(token.lower())
        if canonical is None:
            raise ValueError(f"unknown modifier {token!r} in hotkey {spec!r}")
        seen.add(canonical)
    prefix = "".join(f"<{name}>" for name in MODIFIER_ORDER if name in seen)
    return f"{prefix}{key}"


_GTK_MODIFIER_RE = re.compile(r"<([^>]+)>")


def normalize_accelerator(text: str) -> tuple[frozenset[str], str]:
    """Reduce a friendly or GTK accelerator to a comparable (modifiers, key).

    Makes ``<Super><Alt>e`` and ``alt+super+E`` compare equal so conflict
    detection is order- and case-insensitive.

    Raises:
        ValueError: When the spec is empty, has no key, or names an unknown
            modifier.
    """
    value = (text or "").strip()
    if not value:
        raise ValueError("empty accelerator")
    modifiers: set[str] = set()
    if "<" in value:
        for token in _GTK_MODIFIER_RE.findall(value):
            canonical = MODIFIER_ALIASES.get(token.lower())
            if canonical is None:
                raise ValueError(f"unknown modifier {token!r} in accelerator {text!r}")
            modifiers.add(canonical)
        key = _GTK_MODIFIER_RE.sub("", value)
    else:
        parts = [part.strip() for part in value.split("+") if part.strip()]
        if not parts:
            raise ValueError(f"accelerator {text!r} has no key")
        *modifier_tokens, key = parts
        for token in modifier_tokens:
            canonical = MODIFIER_ALIASES.get(token.lower())
            if canonical is None:
                raise ValueError(f"unknown modifier {token!r} in accelerator {text!r}")
            modifiers.add(canonical)
    if not key:
        raise ValueError(f"accelerator {text!r} has no key")
    return frozenset(modifiers), key.lower()


def display_accelerator(text: str) -> str:
    """Render a friendly ``Ctrl+Super+W`` value from GTK or typed syntax."""
    modifiers, key = normalize_accelerator(text)
    parts = [MODIFIER_DISPLAY[name] for name in MODIFIER_ORDER if name in modifiers]
    parts.append(key.upper() if len(key) == 1 else key)
    return "+".join(parts)


def normalize_modifier(text: str) -> str:
    """Return one canonical modifier, rejecting chords and non-modifier keys."""
    raw = (text or "").strip()
    if not raw or "+" in raw or "<" in raw or ">" in raw:
        raise ValueError("enter exactly one modifier: Shift, Ctrl, Alt, or Super")
    modifier = MODIFIER_ALIASES.get(raw.lower())
    if modifier is None:
        raise ValueError(f"unknown modifier {text!r}")
    return modifier


def add_modifier_to_accelerator(accelerator: str, modifier: str) -> str:
    """Add one modifier to an accelerator without allowing a no-op collision."""
    modifiers, key = normalize_accelerator(accelerator)
    canonical = normalize_modifier(modifier)
    if canonical in modifiers:
        raise ValueError(
            f"{MODIFIER_DISPLAY[canonical]} is already part of {display_accelerator(accelerator)}"
        )
    combined = set(modifiers)
    combined.add(canonical)
    prefix = "".join(f"<{name}>" for name in MODIFIER_ORDER if name in combined)
    return f"{prefix}{key}"


def _read_config_value(path: Path, key: str, default: str = "") -> str:
    """Read one known key from a simple installer-owned ``KEY=value`` file."""
    if not path.is_file():
        return default
    for line in path.read_text(encoding="utf-8").splitlines():
        name, separator, value = line.partition("=")
        if separator and name == key:
            return value
    return default


def _set_config_value(path: Path, key: str, value: str) -> None:
    """Atomically update one validated value without evaluating shell syntax."""
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
        raise ValueError(f"invalid config key {key!r}")
    if "\n" in value or "\r" in value:
        raise ValueError("config values cannot contain newlines")
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = path.read_text(encoding="utf-8").splitlines() if path.is_file() else []
    updated: list[str] = []
    replaced = False
    for line in lines:
        name, separator, _old = line.partition("=")
        if separator and name == key:
            updated.append(f"{key}={value}")
            replaced = True
        else:
            updated.append(line)
    if not replaced:
        updated.append(f"{key}={value}")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write("\n".join(updated) + "\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def find_conflicts(
    accelerator: str, candidates: Iterable[tuple[str, str]]
) -> list[tuple[str, str]]:
    """Return the ``(identifier, stored)`` candidates that shadow ``accelerator``.

    Args:
        accelerator: A friendly or GTK accelerator the user is assigning.
        candidates: Iterable of ``(identifier, stored_accelerator)`` pairs, e.g.
            ``("org.gnome.shell.keybindings show-screenshot-ui", "<Shift><Super>s")``.

    Returns:
        The candidate pairs whose stored accelerator matches, unparsable stored
        values skipped.
    """
    try:
        target = normalize_accelerator(accelerator)
    except ValueError:
        return []
    matches: list[tuple[str, str]] = []
    for identifier, stored in candidates:
        try:
            if normalize_accelerator(stored) == target:
                matches.append((identifier, stored))
        except ValueError:
            continue
    return matches


def describe_conflicts(conflicts: list[tuple[str, str]]) -> list[str]:
    """Render human-readable "will be unbound" lines for a conflict list."""
    return [
        f"{identifier}  (currently {stored}) will be unbound"
        for identifier, stored in conflicts
    ]


def _read_conflict_candidates(stream) -> list[tuple[str, str]]:
    """Parse ``identifier<TAB>accelerator`` lines into candidate pairs."""
    candidates: list[tuple[str, str]] = []
    for line in stream:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        identifier, tab, accel = line.partition("\t")
        if not tab:
            continue
        candidates.append((identifier.strip(), accel.strip()))
    return candidates


# ---------------------------------------------------------------------------
# TTY press-to-capture (used by component-menu rebind fields)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class TtyAction:
    """One decoded terminal input action for the capture state machine."""

    kind: str  # mod | sync_mods | key | confirm | cancel | back
    value: str | None = None
    # ``toggle`` for lone modifier presses (``mod`` actions only).
    mod_mode: str = "toggle"
    # ``toggle`` for lone key presses; ``set`` for chord-reported keys.
    key_mode: str = "toggle"
    # Kitty event type: 1=press, 2=repeat, 3=release.
    event_type: int = 1


# Kitty progressive-enhancement flags pushed during TTY capture.
_KITTY_KB_FLAG_DISAMBIGUATE = 1
_KITTY_KB_FLAG_REPORT_ALL_KEYS = 8
_KITTY_KEYBOARD_PUSH = b"\x1b[>9u"
_KITTY_KEYBOARD_POP = b"\x1b[<1u"


def kitty_modifier_bits(bits: int) -> list[str]:
    """Expand Kitty ``CSI u`` modifier bits into canonical modifier names."""
    held: set[str] = set()
    if bits & KITTY_MOD_SHIFT:
        held.add("Shift")
    if bits & KITTY_MOD_ALT:
        held.add("Alt")
    if bits & KITTY_MOD_CTRL:
        held.add("Control")
    if bits & KITTY_MOD_SUPER:
        held.add("Super")
    return [name for name in MODIFIER_ORDER if name in held]


def kitty_key_token(codepoint: int, modifier_bits: int = 0) -> tuple[str, str] | None:
    """Map a Kitty key code and held modifiers to a binding token.

    Returns:
        ``("mod", canonical)`` for a lone modifier press, ``("key", spelling)``
        for a non-modifier key, or ``None`` when the code is not bindable.
    """
    if codepoint in KITTY_MODIFIER_KEY_CODES:
        return ("mod", KITTY_MODIFIER_KEY_CODES[codepoint])
    if 32 <= codepoint <= 126:
        key = chr(codepoint)
        if modifier_bits & KITTY_MOD_SHIFT and len(key) == 1 and key.isalpha():
            key = key.lower()
        return ("key", key.lower() if len(key) == 1 and key.isalpha() else key)
    named = {
        13: "Return",
        27: "Escape",
        9: "Tab",
        32: "space",
        127: "Delete",
    }
    if codepoint in named:
        return ("key", named[codepoint])
    return None


def _parse_kitty_u_params(params: str) -> tuple[int, int, int] | None:
    """Parse Kitty ``CSI … u`` parameters into codepoint, modifier bits, event type."""
    if not params:
        return None
    parts = params.split(";")
    key_field = parts[0]
    key_chunks = key_field.split(":")
    try:
        codepoint = int(key_chunks[0])
    except ValueError:
        return None
    event_type = 1
    if len(key_chunks) > 1 and key_chunks[1] in {"1", "2", "3"}:
        event_type = int(key_chunks[1])
    modifier_bits = 0
    if len(parts) > 1 and parts[1]:
        mod_field = parts[1]
        mod_chunks = mod_field.split(":")
        try:
            modifier_bits = int(mod_chunks[0])
        except ValueError:
            return None
        if len(mod_chunks) > 1 and mod_chunks[1] in {"1", "2", "3"}:
            event_type = int(mod_chunks[1])
    return codepoint, modifier_bits, event_type


def parse_csi_sequence(params: str, final: str) -> list[TtyAction]:
    """Decode one completed CSI sequence into zero or more capture actions."""
    if final == "u":
        parsed = _parse_kitty_u_params(params)
        if parsed is None:
            return []
        codepoint, modifier_bits, event_type = parsed
        if event_type == 3:
            return []
        actions: list[TtyAction] = []
        token = kitty_key_token(codepoint, modifier_bits)
        if token is None:
            return actions
        kind, value = token
        if kind == "mod":
            if event_type == 2:
                return []
            actions.append(
                TtyAction("mod", value, mod_mode="toggle", event_type=event_type)
            )
            return actions
        key_mode = "toggle"
        if modifier_bits:
            mods = kitty_modifier_bits(modifier_bits)
            actions.append(TtyAction("sync_mods", ",".join(mods)))
            key_mode = "set"
        actions.append(TtyAction("key", value, key_mode=key_mode, event_type=event_type))
        return actions
    if final == "~" and params in {"3", "127"}:
        return [TtyAction("back")]
    return []


def parse_tty_byte(chunk: bytes) -> list[TtyAction]:
    """Decode a single raw byte or UTF-8 fragment into capture actions.

    Handles Ctrl/Alt chords, Backspace, Enter, Esc, and Kitty ``CSI u`` reports.
    Multi-byte sequences are accumulated by :class:`TtyInputParser`.
    """
    if not chunk:
        return []
    if chunk in {b"\r", b"\n"}:
        return [TtyAction("confirm")]
    if chunk in {b"\x7f", b"\x08"}:
        return [TtyAction("back")]
    if len(chunk) == 1:
        byte = chunk[0]
        if byte == 0x1B:
            return []
        if 1 <= byte <= 26:
            letter = chr(ord("a") + byte - 1)
            return [
                TtyAction("sync_mods", "Control"),
                TtyAction("key", letter, key_mode="set"),
            ]
        if 32 <= byte <= 126:
            char = chr(byte)
            if char.isupper():
                return [
                    TtyAction("sync_mods", "Shift"),
                    TtyAction("key", char.lower(), key_mode="set"),
                ]
            return [TtyAction("key", char.lower() if char.isalpha() else char)]
    return []


class TtyInputParser:
    """Incremental parser that turns a raw TTY byte stream into :class:`TtyAction`s."""

    def __init__(self) -> None:
        self._buffer = b""
        self._escaping = False

    def feed(self, data: bytes) -> list[TtyAction]:
        """Consume ``data`` and return any fully decoded actions."""
        actions: list[TtyAction] = []
        for byte in data:
            if self._escaping:
                if byte == 0x1B and self._buffer != b"\x1b":
                    actions.extend(self._flush_escape(cancel=False))
                    self._escaping = True
                    self._buffer = b"\x1b"
                    continue
                if self._buffer == b"\x1b":
                    if byte == ord("["):
                        self._buffer = b"\x1b["
                        continue
                    if byte == ord("O"):
                        self._buffer = b"\x1bO"
                        continue
                    actions.extend(self._flush_escape(cancel=True))
                    if 32 <= byte <= 126:
                        actions.append(TtyAction("sync_mods", "Alt"))
                        actions.append(
                            TtyAction(
                                "key",
                                chr(byte).lower() if chr(byte).isalpha() else chr(byte),
                                key_mode="set",
                            )
                        )
                    continue
                self._buffer += bytes((byte,))
                if self._buffer.startswith(b"\x1b[") and len(self._buffer) > 2:
                    if byte in _CSI_FINAL_BYTE:
                        actions.extend(self._flush_csi(final=chr(byte)))
                    continue
                if self._buffer.startswith(b"\x1bO") and len(self._buffer) == 3:
                    actions.extend(self._flush_csi(final=chr(byte)))
                    continue
                continue

            if byte == 0x1B:
                self._escaping = True
                self._buffer = b"\x1b"
                continue

            actions.extend(parse_tty_byte(bytes((byte,))))
        return actions

    def _flush_escape(self, *, cancel: bool) -> list[TtyAction]:
        pending = self._buffer
        self._buffer = b""
        self._escaping = False
        if cancel and pending == b"\x1b":
            return [TtyAction("cancel")]
        return []

    def _flush_csi(self, *, final: str) -> list[TtyAction]:
        raw = self._buffer
        self._buffer = b""
        self._escaping = False
        if raw.startswith(b"\x1b["):
            params = raw[2:-1].decode("ascii", errors="ignore")
            return parse_csi_sequence(params, final)
        if raw.startswith(b"\x1bO") and len(raw) == 3:
            letter = chr(raw[2])
            return [
                TtyAction("key", letter.lower() if letter.isalpha() else letter)
            ]
        return []


def apply_tty_action(
    binding: HotkeyBinding,
    action: TtyAction,
    *,
    single_key: bool = False,
    modifier_only: bool = False,
) -> str | None:
    """Apply one decoded action to ``binding``.

    Returns:
        ``"confirm"`` when Enter should finalize, ``"cancel"`` on Esc,
        ``"back"`` after undo, or ``None`` for ordinary input.
    """
    if action.kind == "confirm":
        return "confirm"
    if action.kind == "cancel":
        return "cancel"
    if action.kind == "back":
        binding.back()
        return "back"
    if action.kind == "sync_mods":
        raw = action.value or ""
        names = [part for part in raw.split(",") if part]
        binding.set_modifiers_from_chord(names)
        return None
    if action.kind == "mod":
        if action.event_type in {2, 3}:
            return None
        if modifier_only:
            binding.clear()
            binding.toggle_modifier(action.value or "")
            return None
        if not single_key:
            binding.toggle_modifier(action.value or "")
        return None
    if action.kind == "key":
        if modifier_only:
            return None
        if action.event_type in {2, 3}:
            return None
        if single_key:
            binding.clear()
        key_name = action.value or ""
        if action.key_mode == "set":
            binding.set_key(key_name)
        else:
            binding.toggle_key(key_name)
        return None
    return None


@contextlib.contextmanager
def raw_tty(stream: BinaryIO) -> Iterator[None]:
    """Put ``stream`` into raw mode for the duration of the context."""
    if not stream.isatty():
        yield
        return
    fd = stream.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


@contextlib.contextmanager
def kitty_keyboard_protocol(out: TextIO) -> Iterator[None]:
    """Enable Kitty keyboard protocol so lone modifier presses are reported."""
    pushed = False
    try:
        if out.isatty():
            out.write(_KITTY_KEYBOARD_PUSH.decode("ascii"))
            out.flush()
            pushed = True
        yield
    finally:
        if pushed:
            out.write(_KITTY_KEYBOARD_POP.decode("ascii"))
            out.flush()


_CAPTURE_OVERLAY_LINES = 3
_REBIND_BOX_LINES = 5


class CaptureOverlay:
    """Fixed-size rebind UI that updates in place and erases itself on exit."""

    def __init__(self, out: TextIO, *, box_lines: int = 0) -> None:
        self.out = out
        self.box_lines = box_lines
        self._overlay_drawn = False

    def draw_box(self, label: str, current_display: str, *, modifier: bool = False) -> None:
        """Render the bordered rebind header once (five lines)."""
        title = "Rebind modifier" if modifier else "Rebind hotkey"
        print("", file=self.out, flush=True)
        print("  ┌─ " + title + " " + "─" * (44 - len(title)) + "┐", file=self.out, flush=True)
        print(f"  │ {label:<44} │", file=self.out, flush=True)
        print(f"  │ Current: {current_display:<35} │", file=self.out, flush=True)
        print("  └──────────────────────────────────────────────┘", file=self.out, flush=True)
        self.box_lines = _REBIND_BOX_LINES

    def update(self, binding: HotkeyBinding, hint: str | None = None) -> None:
        """Draw or refresh the Modifiers / Key overlay without scrolling."""
        line1 = f"  Modifiers: {binding.display_modifiers_field()}"
        line2 = f"  Key: {binding.display_key_field()}"
        line3 = hint or (
            "  Press modifiers to toggle, then one key. "
            "Backspace = undo, Enter = confirm, Esc = keep."
        )
        _transcript_line(
            "overlay "
            f"modifiers={binding.display_modifiers_field()!r} "
            f"key={binding.display_key_field()!r}"
        )
        if not self._overlay_drawn:
            print(line1, file=self.out, flush=True)
            print(line2, file=self.out, flush=True)
            print(line3, file=self.out, flush=True)
            self._overlay_drawn = True
            return
        print(
            f"\033[{_CAPTURE_OVERLAY_LINES}A\r\033[K{line1}\n\r\033[K{line2}\n\r\033[K{line3}",
            file=self.out,
            flush=True,
        )

    def clear(self) -> None:
        """Mark the overlay finished; the menu caller redraws with ``cm_clear``."""
        self._overlay_drawn = False
        self.box_lines = 0


def _transcript_line(line: str) -> None:
    """Append one capture transcript line when ISC_CAPTURE_TRANSCRIPT is set."""
    path = os.environ.get("ISC_CAPTURE_TRANSCRIPT")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as stream:
            stream.write(line + "\n")
    except OSError as error:
        LOGGER.debug("could not write capture transcript: %s", error)


def _read_tty_byte(stream: BinaryIO, parser: TtyInputParser) -> bytes:
    """Read one byte, flushing a lone Esc when no follow-up arrives."""
    from select import select

    if not stream.isatty():
        return stream.read(1)
    if parser._escaping and parser._buffer == b"\x1b":
        ready, _, _ = select([stream], [], [], 0.05)
        if not ready:
            return b""
    return stream.read(1)


def capture_binding_tty(
    label: str,
    current: str,
    *,
    single_key: bool = False,
    modifier_only: bool = False,
    show_box: bool = False,
    stream: BinaryIO | None = None,
    out: TextIO = sys.stderr,
) -> str | None:
    """Capture one hotkey from raw terminal key presses.

    Modifier keys toggle on repeat press; simultaneous chord reports replace held
    modifiers via :meth:`HotkeyBinding.set_modifiers_from_chord`. Exactly one
    non-modifier key completes the binding (except ``modifier_only``). Returns
    the GTK accelerator (or canonical modifier name) on confirm, ``None`` when
    the user keeps the current value, and re-prompts when incomplete.
    """
    stream = stream or sys.stdin.buffer
    binding = HotkeyBinding()
    parser = TtyInputParser()
    overlay = CaptureOverlay(out)
    try:
        current_display = display_accelerator(current) if not modifier_only else (
            "Ctrl" if current == "Control" else current
        )
    except ValueError:
        current_display = current
    if show_box:
        overlay.draw_box(label, current_display, modifier=modifier_only)

    def finish(value: str | None) -> str | None:
        overlay.clear()
        return value

    def handle_actions(actions: list[TtyAction]) -> str | None | bool:
        redraw = False
        for action in actions:
            result = apply_tty_action(
                binding,
                action,
                single_key=single_key,
                modifier_only=modifier_only,
            )
            if result == "cancel":
                return finish(None)
            if result == "confirm":
                if binding.is_empty():
                    return finish(None)
                if modifier_only:
                    modifiers = binding.modifiers
                    if not modifiers:
                        overlay.update(
                            binding,
                            hint="  ! Press one modifier, then Enter to confirm.",
                        )
                        return False
                    return finish(modifiers[-1])
                if not binding.is_complete():
                    overlay.update(
                        binding,
                        hint="  ! Press one key, then Enter to confirm.",
                    )
                    return False
                return finish(binding.to_accelerator())
            if result == "back":
                redraw = True
            if action.kind in {"mod", "sync_mods", "key"}:
                redraw = True
        return redraw

    overlay.update(binding)

    with kitty_keyboard_protocol(out), raw_tty(stream):
        while True:
            chunk = _read_tty_byte(stream, parser)
            if not chunk:
                if parser._escaping and parser._buffer == b"\x1b":
                    for action in parser._flush_escape(cancel=True):
                        outcome = handle_actions([action])
                        if outcome is None or isinstance(outcome, str):
                            return outcome
                        if outcome is True:
                            overlay.update(binding)
                if not stream.isatty():
                    return finish(None)
                continue
            for action in parser.feed(chunk):
                outcome = handle_actions([action])
                if outcome is None or isinstance(outcome, str):
                    return outcome
                if outcome is True:
                    overlay.update(binding)


# ---------------------------------------------------------------------------
# evdev capture driver (best effort; not exercised by unit tests)
# ---------------------------------------------------------------------------


def _open_input_devices():
    """Yield readable evdev InputDevices that emit keys or buttons.

    Returns an empty list when evdev is unavailable or nothing can be opened, so
    the caller falls back to the default without raising.
    """
    try:
        from evdev import InputDevice, ecodes, list_devices
    except Exception as error:  # pragma: no cover - environment dependent
        LOGGER.warning("evdev unavailable: %s", error)
        return []
    devices = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
        except OSError:
            continue
        caps = dev.capabilities(absinfo=False)
        if ecodes.EV_KEY in caps:
            devices.append(dev)
        else:
            dev.close()
    return devices


def capture_binding(
    label: str,
    default: str,
    *,
    single_key: bool = False,
    mouse_mode: bool = False,
    conflicts: list[tuple[str, str]] | None = None,
    out=sys.stderr,
) -> str | None:
    """Interactively capture one hotkey by reading key presses from evdev.

    Prints a live ``+``-joined preview and real-time conflict warnings to
    ``out``. Returns the chosen GTK accelerator (or ``modifiers|EVENT`` for a
    mouse trigger) on confirm, the ``default`` on cancel, or ``None`` when no
    input device is readable (the caller then keeps its default).

    Args:
        label: Human description shown in the prompt.
        default: The accelerator kept when the user cancels or capture is
            unavailable.
        single_key: When True, only one key and no modifiers are captured
            (used for the single-key screenshot binding).
        mouse_mode: Capture a pointer Back/Forward trigger instead of a key.
        conflicts: ``(identifier, stored)`` candidates to warn about live.
        out: Stream for the interactive prompt (defaults to stderr).
    """
    try:
        from evdev import categorize, ecodes
    except Exception as error:  # pragma: no cover
        LOGGER.warning("evdev unavailable, keeping default: %s", error)
        return None

    devices = _open_input_devices()
    if not devices:
        print("  (no readable input device — keeping default)", file=out)
        return None

    from select import select

    conflicts = conflicts or []
    binding = HotkeyBinding(mouse_mode=mouse_mode)

    def render() -> None:
        preview = binding.display()
        print(f"\r\033[K  {label}: {preview}", end="", file=out, flush=True)
        if binding.is_complete() and not mouse_mode:
            try:
                accel = binding.to_accelerator()
                hits = find_conflicts(accel, conflicts)
                for line in describe_conflicts(hits):
                    print(f"\n    ! {line}", end="", file=out, flush=True)
            except ValueError:
                pass

    print(
        f"\nPress keys for '{label}'. Modifiers accumulate; "
        f"{'one key' if single_key else 'one key + any modifiers'}.",
        file=out,
    )
    if mouse_mode:
        print(
            "  Mouse Back/Forward = the trigger button. No side buttons? "
            "Press keyboard B (=Back) or F (=Forward).",
            file=out,
        )
    print(
        f"  Backspace = remove last, Enter = confirm, Esc = keep default [{default}].",
        file=out,
    )
    render()

    for dev in devices:
        try:
            dev.grab()
        except OSError:
            LOGGER.debug("could not grab %s", getattr(dev, "path", "?"))

    import time

    result: str | None = default
    idle_timeout = 120.0  # never block the installer forever; keep default if idle
    last_activity = time.monotonic()
    try:
        active = True
        while active:
            ready, _, _ = select(devices, [], [], 1.0)
            if not ready:
                if time.monotonic() - last_activity > idle_timeout:
                    print("\n  (no input — keeping default)", file=out)
                    result = default
                    break
                continue
            last_activity = time.monotonic()
            for dev in ready:
                try:
                    events = list(dev.read())
                except OSError:
                    continue
                for event in events:
                    if event.type != ecodes.EV_KEY or event.value != 1:
                        continue  # key-down only
                    keyname = _event_keyname(categorize(event))
                    if keyname in EVDEV_CONFIRM_KEYS:
                        if binding.is_complete():
                            result = _finalize(binding, mouse_mode)
                            active = False
                            break
                        continue
                    if keyname in EVDEV_CANCEL_KEYS:
                        result = default
                        active = False
                        break
                    if keyname in EVDEV_BACK_KEYS:
                        binding.back()
                        render()
                        continue
                    token = token_for_evdev_key(keyname, mouse_mode=mouse_mode)
                    if token is None:
                        continue
                    kind, value = token
                    if single_key:
                        if kind == "key":
                            binding.clear()
                            binding.set_key(value)
                    elif kind == "mod":
                        binding.toggle_modifier(value)
                    else:
                        binding.toggle_key(value)
                    render()
                if not active:
                    break
    finally:
        for dev in devices:
            try:
                dev.ungrab()
            except OSError:
                pass
            dev.close()
        print("", file=out)
    return result


def _event_keyname(categorized) -> str:
    """Return a single evdev key name from a categorized key event."""
    keycode = getattr(categorized, "keycode", "")
    if isinstance(keycode, (list, tuple)):
        return keycode[0] if keycode else ""
    return keycode


def _finalize(binding: HotkeyBinding, mouse_mode: bool) -> str:
    """Serialize a completed binding to the string the shell consumes."""
    if mouse_mode:
        modifiers, event = binding.to_trigger()
        return f"{'+'.join(modifiers)}|{event}"
    return binding.to_accelerator()


@log_call(LOGGER)
def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint used by hotkey_capture.sh."""
    parser = argparse.ArgumentParser(description="Interactive hotkey capture")
    sub = parser.add_subparsers(dest="command", required=True)

    accel = sub.add_parser("accel", help="Convert friendly spec to GTK accelerator")
    accel.add_argument("spec")

    display = sub.add_parser("display", help="Render a friendly accelerator value")
    display.add_argument("spec")

    modifier = sub.add_parser("modifier", help="Validate exactly one modifier")
    modifier.add_argument("spec")

    add_modifier = sub.add_parser("add-modifier", help="Add a modifier to an accelerator")
    add_modifier.add_argument("accelerator")
    add_modifier.add_argument("modifier")

    config_get = sub.add_parser("config-get", help="Read one persisted field")
    config_get.add_argument("path")
    config_get.add_argument("key")
    config_get.add_argument("default", nargs="?", default="")

    config_set = sub.add_parser("config-set", help="Persist one validated field")
    config_set.add_argument("path")
    config_set.add_argument("key")
    config_set.add_argument("value")

    cap = sub.add_parser("capture", help="Interactively capture a hotkey")
    cap.add_argument("--label", required=True)
    cap.add_argument("--default", required=True)
    cap.add_argument("--single-key", action="store_true")
    cap.add_argument("--mouse", action="store_true")

    prompt = sub.add_parser(
        "prompt-capture",
        help="Press-to-capture one field value for component-menu rebind",
    )
    prompt.add_argument("--label", required=True)
    prompt.add_argument("--current", required=True)
    prompt.add_argument("--single-key", action="store_true")
    prompt.add_argument("--modifier-only", action="store_true")
    prompt.add_argument(
        "--show-box",
        action="store_true",
        help="Draw the bordered rebind header and erase it on exit",
    )

    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    if args.command == "accel":
        try:
            print(to_gnome_accelerator(args.spec))
        except ValueError as error:
            print(f"Invalid hotkey: {error}", file=sys.stderr)
            return 2
        return 0

    if args.command == "display":
        try:
            print(display_accelerator(args.spec))
        except ValueError as error:
            print(f"Invalid hotkey: {error}", file=sys.stderr)
            return 2
        return 0

    if args.command == "modifier":
        try:
            print(normalize_modifier(args.spec))
        except ValueError as error:
            print(f"Invalid modifier: {error}", file=sys.stderr)
            return 2
        return 0

    if args.command == "add-modifier":
        try:
            print(add_modifier_to_accelerator(args.accelerator, args.modifier))
        except ValueError as error:
            print(f"Invalid move modifier: {error}", file=sys.stderr)
            return 2
        return 0

    if args.command == "config-get":
        print(_read_config_value(Path(args.path), args.key, args.default))
        return 0

    if args.command == "config-set":
        try:
            _set_config_value(Path(args.path), args.key, args.value)
        except (OSError, ValueError) as error:
            print(f"Could not save field: {error}", file=sys.stderr)
            return 2
        return 0

    if args.command == "capture":
        conflicts = []
        if not sys.stdin.isatty():
            conflicts = _read_conflict_candidates(sys.stdin)
        chosen = capture_binding(
            args.label,
            args.default,
            single_key=args.single_key,
            mouse_mode=args.mouse,
            conflicts=conflicts,
        )
        if chosen is None:
            chosen = args.default
        print(chosen)
        return 0

    if args.command == "prompt-capture":
        chosen = capture_binding_tty(
            args.label,
            args.current,
            single_key=args.single_key,
            modifier_only=args.modifier_only,
            show_box=args.show_box,
        )
        if chosen is not None:
            print(chosen)
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
