"""Task 3.8: the PII scanner flags emails, real token formats, private keys and IPs,
and never Git or Kubernetes identifiers.

Every token-shaped test value is built at runtime, so no literal that looks like a
credential is committed (gitleaks would block it, rightly).
"""

from __future__ import annotations

import pytest

from bridge.pii import PiiHit, scan


def kinds(text: str) -> list[str]:
    return [h.kind for h in scan(text)]


def test_email_flagged() -> None:
    text = "Ping jane.doe+oncall@example.com about it."
    hits = scan(text)
    assert [h.kind for h in hits] == ["email"]
    start, end = hits[0].span
    assert text[start:end] == "jane.doe+oncall@example.com"


@pytest.mark.parametrize("prefix", ["ghp", "gho", "ghu", "ghs", "ghr"])
def test_github_token_flagged(prefix: str) -> None:
    token = prefix + "_" + "Ab3" * 12
    assert kinds(f"token {token} leaked") == ["token"]


def test_github_fine_grained_pat_flagged() -> None:
    token = "github" + "_pat_" + "11ABCDEFG0" * 3
    assert kinds(token) == ["token"]


@pytest.mark.parametrize("prefix", ["sk-" + "ant-", "sk-"])
def test_anthropic_key_flagged(prefix: str) -> None:
    key = prefix + "api03-" + "x9Y8z7W6v5" * 3
    assert kinds(f"key={key}") == ["token"]


def test_aws_key_flagged() -> None:
    assert kinds("AKIA" + "ABCDEFGH" + "IJKLMNOP") == ["token"]


def test_slack_token_flagged() -> None:
    assert kinds("xox" + "b-1234-5678-abcdef") == ["token"]


def test_jwt_flagged() -> None:
    jwt = "eyJ" + "hbGciOiJSUzI1NiJ9" + "." + "eyJ" + "pc3MiOiIxIn0" + "." + "c2lnbmF0dXJl"
    assert kinds(f"Authorization: Bearer {jwt}") == ["token"]


def test_pem_private_key_flagged() -> None:
    for label in ("RSA PRIVATE", "PRIVATE", "EC PRIVATE", "OPENSSH PRIVATE"):
        header = "-----BEGIN " + label + " KEY-----"
        assert kinds(f"here:\n{header}\nMIIB...") == ["private_key"]


def test_private_ipv4_flagged() -> None:
    assert kinds("pod IP 10.244.1.7 refused") == ["ipv4"]
    assert kinds("from 192.168.0.12.") == ["ipv4"]


def test_public_ipv4_flagged() -> None:
    assert kinds("egress to 8.8.8.8") == ["ipv4"]


def test_ipv6_flagged() -> None:
    assert kinds("pod fd00:10:244::7 restarted") == ["ipv6"]
    assert kinds("addr 2001:db8:85a3::8a2e:370:7334") == ["ipv6"]


def test_loopback_allowed() -> None:
    assert scan("Argo UI: http://127.0.0.1:30080/applications/argocd/checkout") == []
    assert scan("listening on [::1]:8080") == []


def test_commit_sha_not_flagged() -> None:
    assert scan("Cause: 3a7c1e9b5d2f4a6c8e0b1d3f5a7c9e2b4d6f8a0c (raise timeout)") == []
    assert scan("short sha 3a7c1e9 and upper 3A7C1E9B5D2F4A6C8E0B1D3F5A7C9E2B4D6F8A0C") == []


def test_pod_template_hash_not_flagged() -> None:
    assert scan("checkout-6d4f9c7b8-x2k9p crashed; ReplicaSet checkout-6d4f9c7b8") == []
    assert scan("rollouts-pod-template-hash=6d4f9c7b8") == []


def test_version_string_not_flagged() -> None:
    assert scan("checkout v1.4.2 on Rollouts 1.10.1 and Prometheus 3.15.1; image v1.4.2.1") == []


def test_timestamps_and_durations_not_flagged() -> None:
    assert scan("aborted at 2026-11-09T17:42:05Z after 00:01:30; window 17:32:05-17:43:05") == []


def test_words_containing_token_prefixes_not_flagged() -> None:
    assert scan("risk-assessment-for-checkout-payments-team and task-runner-checkout-canary-1") == []
    assert scan("disk-pressure-on-worker-node-argoconna26") == []


def test_bot_login_not_flagged() -> None:
    assert scan("opened by argoconna26-agent[bot]") == []


def test_hit_is_dataclass_with_span() -> None:
    hit = scan("a@b.io")[0]
    assert hit == PiiHit(kind="email", span=(0, 6))


def test_multiple_hits_in_order() -> None:
    text = "mail a@example.com from 10.0.0.1"
    assert kinds(text) == ["email", "ipv4"]


def test_realistic_rca_clean() -> None:
    rca = """\
## Root cause
The canary pods of checkout ran with UPSTREAM_TIMEOUT_MS=200 instead of 2000, so calls to
pricing timed out and returned 502.

- Prometheus: checkout_config_upstream_timeout_ms{pod="checkout-6d4f9c7b8-x2k9p"} = 200;
  stable pod checkout-7b9c5d4f6-q8w2z reports 2000.
- AnalysisRun checkout-6d4f9c7b8-12: success rate 71.4% < 99% (slo.example.dev/success-rate).
- Timeline: CHG-ab12cd merged commit 3a7c1e9 three days before the abort (2026-11-06T17:40:00Z);
  config-version stayed at "7".

Cause: 3a7c1e9b5d2f4a6c8e0b1d3f5a7c9e2b4d6f8a0c (pricing: lower upstream timeout)

**What a human should do:** apps/checkout/config/checkout-config.yaml UPSTREAM_TIMEOUT_MS 200 → 2000,
and bump config-version.

[Argo history](http://127.0.0.1:30080/applications/argocd/checkout?view=tree&resource=)
Image checkout:v1.4.2 replaced v1.4.1; owner example.dev/owner=payments-team, tier "1".
"""
    assert scan(rca) == []
