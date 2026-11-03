"""Task 3.4: short stage-terminal lines."""

from __future__ import annotations

import pytest

from bridge import stagelog


def test_stagelog_format() -> None:
    assert stagelog.line("holmes", "prometheus query", cols=80) == "▸ holmes: prometheus query"


def test_stagelog_truncates_to_stage_cols(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("STAGE_COLS", raising=False)
    out = stagelog.line("holmes", "a very long description of a tool call that will not fit")
    assert len(out) == 30
    assert out.endswith("…")
    assert out.startswith("▸ holmes: ")


def test_stagelog_respects_explicit_cols() -> None:
    out = stagelog.line("webhook", "checkout@" + "a" * 40, cols=20)
    assert len(out) == 20
    assert out.endswith("…")


def test_stagelog_reads_stage_cols_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("STAGE_COLS", "24")
    assert len(stagelog.line("autonomy", "suggest (read from file in git)")) == 24


def test_stagelog_short_line_not_padded() -> None:
    assert stagelog.line("webhook", "ok", cols=30) == "▸ webhook: ok"


def test_stagelog_collapses_newlines_and_spaces() -> None:
    assert stagelog.line("holmes", "two\nlines   here", cols=80) == "▸ holmes: two lines here"


def test_stagelog_has_no_timestamp() -> None:
    out = stagelog.line("webhook", "x", cols=80)
    assert out == "▸ webhook: x"
