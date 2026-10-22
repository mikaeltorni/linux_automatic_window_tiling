#!/usr/bin/env python3
"""Centralized Python logging for repository maintenance scripts.

Every Python module in this repository that needs diagnostics should import
``get_logger`` and ``log_call`` from here. Logging is best-effort, writes under
the repository ``.log/`` directory by default, and never raises into callers.
"""

from __future__ import annotations

import functools
import inspect
import logging
from pathlib import Path
from typing import Any, Callable, TypeVar

LOG_FORMAT = "%(asctime)s %(levelname)s [%(name)s] %(message)s"
F = TypeVar("F", bound=Callable[..., Any])


def _repo_root() -> Path:
    """Return the repository root relative to this module."""
    return Path(__file__).resolve().parent


def get_logger(name: str, log_file: str) -> logging.Logger:
    """Return an idempotent logger writing to ``.log/log_file``.

    Args:
        name: Logger name included in every record.
        log_file: File name inside the repository ``.log/`` directory.

    Returns:
        A configured logger. If the file sink cannot be created, the logger uses
        a ``NullHandler`` so logging never aborts the caller.
    """
    logger = logging.getLogger(name)
    logger.setLevel(logging.DEBUG)
    logger.propagate = False
    if logger.handlers:
        return logger
    try:
        log_dir = _repo_root() / ".log"
        log_dir.mkdir(parents=True, exist_ok=True)
        handler: logging.Handler = logging.FileHandler(
            log_dir / log_file, encoding="utf-8"
        )
        handler.setFormatter(logging.Formatter(LOG_FORMAT))
    except OSError:
        handler = logging.NullHandler()
    logger.addHandler(handler)
    return logger


def log_call(logger: logging.Logger, level: int = logging.DEBUG) -> Callable[[F], F]:
    """Trace a function by logging bound arguments on entry and return on exit.

    Args:
        logger: Centralized logger obtained from ``get_logger``.
        level: Logging level used for both trace records.

    Returns:
        A decorator that wraps a callable without changing its return value.
    """

    def decorator(func: F) -> F:
        location = f"{Path(func.__code__.co_filename).name}:{func.__qualname__}"
        signature = inspect.signature(func)

        @functools.wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            bound = signature.bind(*args, **kwargs)
            bound.apply_defaults()
            rendered = ", ".join(
                f"{name}={value!r}" for name, value in bound.arguments.items()
            )
            logger.log(level, "ENTER %s(%s)", location, rendered)
            result = func(*args, **kwargs)
            logger.log(level, "EXIT %s -> %r", location, result)
            return result

        return wrapper  # type: ignore[return-value]

    return decorator
