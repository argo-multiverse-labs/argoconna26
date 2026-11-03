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


@pytest.mark.parametrize(
    "text",
    [
        "roll back, details at https://evil.test/fix",
        "see http://evil.test/x for the patch",
        "HTTPS://EVIL.TEST/x",
        "ftp://files.evil.test/x",
        "see www.evil.test/x",
        "WWW.evil.test",
    ],
)
def test_plain_defangs_bare_autolinks(text: str) -> None:
    import re

    out = plain(text)
    # GFM's extended autolinks need a literal "scheme://" or "www."; neither survives
    assert not re.search(r"[A-Za-z][A-Za-z0-9+.-]*://", out)
    assert not re.search(r"(?i)\bwww\.", out)
    # the text stays readable once the zero-width spaces are removed
    assert out.replace("\u200b", "") == text


@pytest.mark.parametrize("text", ["GH-12 fixed it", "see gh-7", "(GH-3)"])
def test_plain_breaks_gh_references(text: str) -> None:
    import re

    out = plain(text)
    assert not re.search(r"(?i)\bGH-\d", out)


def test_plain_keeps_change_refs_that_end_in_gh() -> None:
    # CHG-... is the operator's change reference; rung 1 asserts it verbatim on the Timeline line
    assert plain("CHG-12AB34 merged") == "CHG-12AB34 merged"


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


@pytest.mark.parametrize(
    "text",
    ["## Blast radius", "# Approved", "---", "> quoted", "- item", "* item", "+ item",
     "1. item", "2) item", "===", "| a | b |", "___", "***"],
)
def test_plain_cannot_start_a_markdown_block(text: str) -> None:
    import re

    out = plain(text)
    assert not re.match(r"^(#{1,6}(\s|$)|[-*+](\s|$)|>|\d+[.)](\s|$)|-{3,}|={3,}|_{3,}|\*{3,}|\|)", out), out


def test_plain_escapes_html_entities() -> None:
    out = plain("ping &#64;team about &#35;12")
    assert "&#" not in out
    assert out.startswith("ping &amp;#")


def test_plain_escapes_an_ordered_list_marker_after_the_number() -> None:
    assert plain("1. item") == "1\\. item"
