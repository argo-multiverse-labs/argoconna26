"""A deliberately simple PII scan over everything the bridge posts that carries model text.

It flags email addresses, well-known token formats, private-key headers and IP
addresses. It does not flag bare hex: commit SHAs, pod-template hashes and
ReplicaSet names are everywhere in an RCA and are not personal data. Loopback
addresses (127.0.0.1 and ::1) are allowed, because the demo links to local UIs.
"""

from __future__ import annotations

import ipaddress
import re
import unicodedata
from dataclasses import dataclass
from typing import Literal

Kind = Literal["email", "token", "private_key", "ipv4", "ipv6"]

# Token patterns must not start in the middle of a word: "risk-assessment-..." is not a key.
_NOT_AFTER_WORD = r"(?<![A-Za-z0-9_-])"

_PATTERNS: list[tuple[Kind, re.Pattern[str]]] = [
    ("private_key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("token", re.compile(_NOT_AFTER_WORD + r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("token", re.compile(_NOT_AFTER_WORD + r"github_pat_\w{20,}")),
    ("token", re.compile(_NOT_AFTER_WORD + r"sk-(?:ant-)?[A-Za-z0-9_-]{20,}")),
    ("token", re.compile(_NOT_AFTER_WORD + r"AKIA[0-9A-Z]{16}")),
    ("token", re.compile(_NOT_AFTER_WORD + r"eyJ[\w-]+\.[\w-]+\.[\w-]+")),
    ("token", re.compile(_NOT_AFTER_WORD + r"xox[abpr]-[\w-]+")),
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
]

_OCTET = r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"
# Not part of a longer dotted or word token (so v1.4.2.1 and 1.10.1 never match).
_IPV4 = re.compile(rf"(?<![\w.]){_OCTET}(?:\.{_OCTET}){{3}}(?![\w]|\.\d)")
_IPV6 = re.compile(r"(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])")

_LOOPBACK = {ipaddress.ip_address("127.0.0.1"), ipaddress.ip_address("::1")}


@dataclass(frozen=True)
class PiiHit:
    kind: Kind
    span: tuple[int, int]


def _ip_hits(text: str) -> list[PiiHit]:
    hits: list[PiiHit] = []
    for kind, pattern in (("ipv4", _IPV4), ("ipv6", _IPV6)):
        for m in pattern.finditer(text):
            try:
                addr = ipaddress.ip_address(m.group(0))
            except ValueError:
                continue
            if addr in _LOOPBACK or (kind == "ipv6" and addr.version != 6):
                continue
            hits.append(PiiHit(kind, m.span()))  # type: ignore[arg-type]
    return hits


def strip_format(text: str) -> str:
    """Drop Unicode format characters (category Cf: zero-width spaces and joiners,
    bidi controls). They render as nothing, so they can hide an address from a regex."""
    return "".join(ch for ch in text if unicodedata.category(ch) != "Cf")


def normalize(text: str) -> str:
    """What the scan should see: format characters dropped and compatibility forms
    (fullwidth @, ligatures) folded to their plain equivalents."""
    return unicodedata.normalize("NFKC", strip_format(text))


def scan(text: str) -> list[PiiHit]:
    """All hits in `text`, ordered by position, with nested duplicates removed."""
    hits = [PiiHit(kind, m.span()) for kind, pattern in _PATTERNS for m in pattern.finditer(text)]
    hits.extend(_ip_hits(text))
    hits.sort(key=lambda h: (h.span[0], -h.span[1]))
    result: list[PiiHit] = []
    for hit in hits:
        if result and hit.span[1] <= result[-1].span[1]:
            continue  # inside an earlier, longer hit
        result.append(hit)
    return result
