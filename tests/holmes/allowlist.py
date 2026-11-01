"""Checks the cdevents-timeline allow-list with HolmesGPT's own URL matcher.

Run inside the pinned HolmesGPT image (see tests/bats/holmes_allowlist.bats). Reads the
toolset's `config` as JSON on stdin and prints one line per case; exits 1 if any case
is wrong. The matcher is the one the toolset calls before every request (match_endpoint).
"""
import json
import sys

from holmes.plugins.toolsets.http.http_toolset import HttpToolset, HttpToolsetConfig

BASE = "http://cdevents-sim.aiops.svc:8080"
LONG = "http://cdevents-sim.aiops.svc.cluster.local:8080"

ALLOWED = [
    f"{BASE}/timeline",
    f"{BASE}/timeline?app=checkout&since=-72h",
    f"{BASE}/incidents",
    f"{BASE}/incidents?app=checkout",
    f"{LONG}/timeline?app=checkout",
]
REFUSED = [
    f"{BASE}/events",
    f"{BASE}/events?app=checkout",
    f"{BASE}/timeline/../events",
    f"{BASE}/timeline/..%2fevents",
    f"{BASE}/timeline/%2e%2e/events",
    f"{BASE}/timeline-x/../events",
    f"{BASE}/timeline/",
    f"{BASE}/timelinefoo",
    f"{BASE}/incidents/../events",
    f"{BASE}//events",
    f"{BASE}/annotations",
    f"{BASE}/metrics",
    "http://cdevents-sim.aiops.svc:9999/timeline",
    "http://other.aiops.svc:8080/timeline",
    "https://cdevents-sim.aiops.svc:8080/timeline",
]


def main() -> int:
    cfg = json.load(sys.stdin)
    toolset = HttpToolset(name="cdevents-timeline", config=cfg, enabled=True)
    toolset._http_config = HttpToolsetConfig(**cfg)
    bad = 0
    for url in ALLOWED:
        ep, _ = toolset.match_endpoint(url)
        ok = ep is not None and toolset.is_method_allowed("GET", ep)
        print(("ok   " if ok else "FAIL ") + "allowed  " + url)
        bad += not ok
    for url in REFUSED:
        ep, _ = toolset.match_endpoint(url)
        ok = ep is None
        print(("ok   " if ok else "FAIL ") + "refused  " + url)
        bad += not ok
    ep, _ = toolset.match_endpoint(f"{BASE}/timeline")
    ok = ep is not None and not toolset.is_method_allowed("POST", ep)
    print(("ok   " if ok else "FAIL ") + "refused  POST " + BASE + "/timeline")
    bad += not ok
    return 1 if bad else 0


sys.exit(main())
