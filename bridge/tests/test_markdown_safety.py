"""Model text in a public comment can't link, embed, reference other issues or hide characters."""

from __future__ import annotations

import pytest

from bridge import pii
from bridge.pipeline import plain


@pytest.mark.parametrize(
    "text",
    [
        "see [the fix](https://evil.test/x)",
        "![](https://tracker.test/px.gif)",
        "<https://evil.test>",
        "`code` and ``more``",
    ],
)
def test_plain_escapes_link_and_image_syntax(text: str) -> None:
    out = plain(text)
    for ch in "[]()!<>`":
        # every control character that was there is now escaped
        assert out.count(ch) == out.count("\\" + ch)


@pytest.mark.parametrize("text", ["fixes #123", "other-org/other-repo#9", "GH-1 and #1"])
def test_plain_breaks_issue_references(text: str) -> None:
    out = plain(text)
    assert "#​" in out
    import re

    assert not re.search(r"#\d", out)


def test_plain_strips_format_characters() -> None:
    assert plain("ops​@exam⁠ple.com‮") == "ops@example.com"


def test_plain_keeps_ordinary_text() -> None:
    text = "PR-242 cut UPSTREAM_TIMEOUT_MS to 200 without bumping config-version."
    assert plain(text) == text


def test_plain_still_breaks_mentions() -> None:
    assert plain("ping @team") == "ping @​team"


def test_pii_scan_sees_through_format_and_fullwidth_characters() -> None:
    assert [h.kind for h in pii.scan(pii.normalize("ops​@example.com"))] == ["email"]
    assert [h.kind for h in pii.scan(pii.normalize("ops＠example.com"))] == ["email"]
