"""Short lines for the stage terminal: `▸ <step>: <detail>`, no timestamp, no padding.

The bridge's normal log keeps timestamps; these lines go to the `bridge.stage`
logger and are picked out by `make bridge-log` (it greps for the `▸`).
"""

from __future__ import annotations

import logging
import os
import sys

MARK = "▸"
ELLIPSIS = "…"
DEFAULT_COLS = 30

_stage_logger = logging.getLogger("bridge.stage")


def _default_cols() -> int:
    try:
        return max(8, int(os.environ.get("STAGE_COLS", DEFAULT_COLS)))
    except ValueError:
        return DEFAULT_COLS


def line(step: str, detail: str, cols: int | None = None) -> str:
    width = _default_cols() if cols is None else cols
    text = f"{MARK} {' '.join(step.split())}: {' '.join(str(detail).split())}"
    if len(text) > width:
        text = text[: width - 1] + ELLIPSIS
    return text


def emit(step: str, detail: str, cols: int | None = None) -> str:
    """Write one stage line and return it."""
    text = line(step, detail, cols)
    _stage_logger.info(text)
    return text


def configure(stream=None) -> None:
    """Send stage lines to stdout bare (no timestamp), once."""
    if any(getattr(h, "_bridge_stage", False) for h in _stage_logger.handlers):
        return
    handler = logging.StreamHandler(stream or sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    handler._bridge_stage = True  # type: ignore[attr-defined]
    _stage_logger.addHandler(handler)
    _stage_logger.setLevel(logging.INFO)
    _stage_logger.propagate = False
