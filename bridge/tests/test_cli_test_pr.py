"""e2e harness: `open-test-pr` opens an App-authored policy-negative test PR (Task 5.6 Step 2),
and `test-pr-try-merge` tries to merge one with the App token."""

from __future__ import annotations

import base64
import json

import httpx
import pytest

from bridge.cli import (
    TEST_LABEL,
    TEST_PR_BODY,
    NegativePrError,
    negative_branch_name,
    run_open_test_pr,
    run_test_pr_try_merge,
    scenario_edits,
)

API = "https://api.github.test"
REPO = "example-org/example-repo"
R = f"{API}/repos/{REPO}"
BASE = "build/demo"
HEAD = "a" * 40
CAUSE = "c" * 40

CONFIG = (
    "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: checkout-config\ndata:\n"
    '  UPSTREAM_TIMEOUT_MS: "2000"\n  PRICING_URL: http://pricing.demo.svc:8080\n'
)
ROLLOUT = (
    "kind: Rollout\nspec:\n  template:\n    metadata:\n      annotations:\n"
    '        example.dev/config-version: "7"\n'
)
KUSTOMIZATION = "images:\n  - name: checkout\n    newTag: v1.4.1\n"
PRICING = (
    "kind: Deployment\nmetadata:\n  name: pricing\n  labels:\n    app: pricing\n"
    "    example.dev/owner: payments-team\n    example.dev/tier: \"1\"\nspec:\n  template:\n"
    "    metadata:\n      labels:\n        example.dev/owner: payments-team\n"
)
AUTONOMY = "kind: Autonomy\nlevel: suggest\nsince: \"2026-11-02\"\n"
WORKFLOW = "name: policy\non:\n  pull_request:\n"
REGO = "package autofix\n\nimport rego.v1\n\ndeny contains msg if { false; msg := \"x\" }\n"
GP_REGO = "package goldenpath\n\nimport rego.v1\n\ndeny contains msg if { false; msg := \"x\" }\n"

FILES = {
    "apps/checkout/config/checkout-config.yaml": CONFIG,
    "apps/checkout/deploy/rollout.yaml": ROLLOUT,
    "apps/checkout/kustomization.yaml": KUSTOMIZATION,
    "apps/pricing/deploy/deployment.yaml": PRICING,
    "aiops/autonomy.yaml": AUTONOMY,
    ".github/workflows/policy.yml": WORKFLOW,
    "policy/autofix.rego": REGO,
    "policy/golden_path.rego": GP_REGO,
}


class Tokens:
    async def token(self) -> str:
        return "installation-token-not-a-secret"


def _changed_lines(old: str, new: str) -> int:
    a, b = old.splitlines(), new.splitlines()
    return sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))


# ------------------------------------------------------------------ pure parts


def test_branch_name_is_agent_test() -> None:
    assert negative_branch_name("image-change", "T1") == "agent/test-image-change-T1"


def test_unknown_scenario_refused() -> None:
    with pytest.raises(NegativePrError, match="scenario"):
        scenario_edits("rm-rf", FILES)


def test_image_change_is_a_fix_shape_plus_a_tag_bump() -> None:
    e = scenario_edits("image-change", FILES)
    assert set(e) == {
        "apps/checkout/config/checkout-config.yaml",
        "apps/checkout/deploy/rollout.yaml",
        "apps/checkout/kustomization.yaml",
    }
    assert 'UPSTREAM_TIMEOUT_MS: "200"' in e["apps/checkout/config/checkout-config.yaml"]
    assert 'example.dev/config-version: "8"' in e["apps/checkout/deploy/rollout.yaml"]
    assert "newTag: v1.4.2" in e["apps/checkout/kustomization.yaml"]
    for path, text in e.items():
        assert _changed_lines(FILES[path], text) == 1, path


def test_image_change_from_armed_goes_back_to_healthy() -> None:
    armed = dict(FILES)
    armed["apps/checkout/config/checkout-config.yaml"] = CONFIG.replace('"2000"', '"200"')
    e = scenario_edits("image-change", armed)
    assert 'UPSTREAM_TIMEOUT_MS: "2000"' in e["apps/checkout/config/checkout-config.yaml"]


def test_tamper_autofix_adds_an_allow_everything_rego() -> None:
    e = scenario_edits("tamper-autofix", FILES)
    assert "newTag: v1.4.2" in e["apps/checkout/kustomization.yaml"]
    assert "deny := set()" in e["policy/autofix.rego"]
    assert e["policy/autofix.rego"].startswith("package autofix")


def test_tamper_goldenpath_drops_the_owner_label_and_loosens_the_rego() -> None:
    e = scenario_edits("tamper-goldenpath", FILES)
    dep = e["apps/pricing/deploy/deployment.yaml"]
    # Only the workload's own label goes; the pod template keeps its copy.
    assert dep.count("example.dev/owner") == 1
    assert _changed_lines(PRICING, dep) >= 1
    assert "deny := set()" in e["policy/golden_path.rego"]
    assert set(e) == {"apps/pricing/deploy/deployment.yaml", "policy/golden_path.rego"}


def test_tamper_workflow_touches_only_the_workflow() -> None:
    e = scenario_edits("tamper-workflow", FILES)
    assert set(e) == {".github/workflows/policy.yml"}
    assert e[".github/workflows/policy.yml"] != WORKFLOW


def test_tamper_autonomy_sets_act() -> None:
    e = scenario_edits("tamper-autonomy", FILES)
    assert set(e) == {"aiops/autonomy.yaml"}
    assert "level: act" in e["aiops/autonomy.yaml"]


def test_tamper_autonomy_refuses_when_already_act() -> None:
    f = dict(FILES)
    f["aiops/autonomy.yaml"] = AUTONOMY.replace("suggest", "act")
    with pytest.raises(NegativePrError, match="already"):
        scenario_edits("tamper-autonomy", f)


def test_missing_anchor_line_refused() -> None:
    f = dict(FILES)
    f["apps/checkout/kustomization.yaml"] = "images: []\n"
    with pytest.raises(NegativePrError, match="newTag"):
        scenario_edits("image-change", f)


# ------------------------------------------------------------------ HTTP


def _mock_repo(r, *, ref_status=201, ref_json=None, label_status=200):
    r.get(f"{R}/git/ref/heads/{BASE}").mock(return_value=httpx.Response(200, json={"object": {"sha": HEAD}}))
    r.get(f"{R}/git/commits/{HEAD}").mock(return_value=httpx.Response(200, json={"tree": {"sha": "t" * 40}}))

    def contents(req):
        path = req.url.path.split("/contents/", 1)[1]
        assert req.url.params["ref"] == HEAD
        return httpx.Response(200, json={"content": base64.b64encode(FILES[path].encode()).decode()})

    r.get(url__startswith=f"{R}/contents/").mock(side_effect=contents)
    r.get(f"{R}/commits").mock(return_value=httpx.Response(200, json=[{"sha": CAUSE}]))
    tree = r.post(f"{R}/git/trees").mock(return_value=httpx.Response(201, json={"sha": "e" * 40}))
    commit = r.post(f"{R}/git/commits").mock(return_value=httpx.Response(201, json={"sha": "f" * 40}))
    ref = r.post(f"{R}/git/refs").mock(return_value=httpx.Response(ref_status, json=ref_json or {}))
    pulls = r.post(f"{R}/pulls").mock(
        return_value=httpx.Response(201, json={"number": 9, "html_url": "https://gh/pr/9", "node_id": "N"})
    )
    label = r.post(f"{R}/issues/9/labels").mock(return_value=httpx.Response(label_status, json=[]))
    return tree, commit, ref, pulls, label


async def _open(scenario: str, **kw):
    async with httpx.AsyncClient() as http:
        return await run_open_test_pr(http, Tokens(), repo=REPO, base=BASE, scenario=scenario,
                                      api_url=API, stamp="T1", **kw)


async def test_open_image_change_pr(_no_unmocked_http) -> None:
    import respx

    with respx.mock(assert_all_called=False) as r:
        tree, commit, ref, pulls, label = _mock_repo(r)
        res = await _open("image-change")
    assert res.number == 9 and res.branch == "agent/test-image-change-T1" and res.head == "f" * 40
    entries = json.loads(tree.calls[0].request.content)
    assert entries["base_tree"] == "t" * 40
    assert {x["path"] for x in entries["tree"]} == {
        "apps/checkout/config/checkout-config.yaml",
        "apps/checkout/deploy/rollout.yaml",
        "apps/checkout/kustomization.yaml",
    }
    assert json.loads(commit.calls[0].request.content)["parents"] == [HEAD]
    assert json.loads(ref.calls[0].request.content) == {"ref": "refs/heads/agent/test-image-change-T1", "sha": "f" * 40}
    pr = json.loads(pulls.calls[0].request.content)
    assert pr["title"].startswith("[policy negative test]")
    assert pr["base"] == BASE and pr["head"] == "agent/test-image-change-T1"
    assert TEST_PR_BODY in pr["body"]
    assert f"\nCause: {CAUSE}\n" in f"\n{pr['body']}\n"
    assert json.loads(label.calls[0].request.content) == {"labels": [TEST_LABEL]}


async def test_label_failure_closes_the_pr_and_deletes_the_branch(_no_unmocked_http) -> None:
    import respx

    with respx.mock(assert_all_called=False) as r:
        _mock_repo(r, label_status=403)
        close = r.patch(f"{R}/pulls/9").mock(return_value=httpx.Response(200, json={}))
        delete = r.delete(f"{R}/git/refs/heads/agent/test-image-change-T1").mock(return_value=httpx.Response(204))
        with pytest.raises(NegativePrError, match="label"):
            await _open("image-change")
    assert json.loads(close.calls[0].request.content) == {"state": "closed"}
    assert delete.called


async def test_tamper_workflow_refused_opens_no_pr(_no_unmocked_http) -> None:
    import respx

    msg = "refusing to allow a GitHub App to create or update workflow `.github/workflows/policy.yml` without `workflows` permission"
    with respx.mock(assert_all_called=False) as r:
        _, _, _, pulls, _ = _mock_repo(r, ref_status=422, ref_json={"message": msg})
        r.get(f"{R}/git/ref/heads/agent/test-tamper-workflow-T1").mock(return_value=httpx.Response(404, json={}))
        res = await _open("tamper-workflow")
    assert res.number is None
    assert res.refused_status == 422 and "workflows" in res.refused_message
    assert not pulls.called


async def test_tamper_workflow_accepted_is_undone_and_reported(_no_unmocked_http) -> None:
    import respx

    with respx.mock(assert_all_called=False) as r:
        _, _, _, pulls, _ = _mock_repo(r, ref_status=201)
        delete = r.delete(f"{R}/git/refs/heads/agent/test-tamper-workflow-T1").mock(return_value=httpx.Response(204))
        res = await _open("tamper-workflow")
    assert res.number is None and res.refused_status is None
    assert delete.called and not pulls.called


async def test_open_refuses_a_non_test_branch_before_any_http(_no_unmocked_http) -> None:
    with pytest.raises(NegativePrError, match="agent/test-"):
        await _open("image-change", branch="agent/checkout-123")
    assert not _no_unmocked_http.calls


async def test_open_refuses_an_unknown_scenario_before_any_http(_no_unmocked_http) -> None:
    with pytest.raises(NegativePrError, match="scenario"):
        await _open("nope")
    assert not _no_unmocked_http.calls


# ------------------------------------------------------------------ try-merge


def _pr(ref="agent/test-image-change-T1", labels=(TEST_LABEL,)):
    return {"number": 9, "node_id": "N", "head": {"ref": ref, "sha": "f" * 40},
            "labels": [{"name": n} for n in labels]}


async def _try(**kw):
    async with httpx.AsyncClient() as http:
        return await run_test_pr_try_merge(http, Tokens(), repo=REPO, number=9, api_url=API, **kw)


@pytest.mark.parametrize("pr", [_pr(ref="agent/checkout-1"), _pr(labels=()), _pr(labels=("demo-reset",))])
async def test_try_merge_refuses_anything_but_a_labelled_test_pr(_no_unmocked_http, pr) -> None:
    import respx

    with respx.mock(assert_all_called=False) as r:
        r.get(f"{R}/pulls/9").mock(return_value=httpx.Response(200, json=pr))
        gql = r.post(f"{API}/graphql")
        put = r.put(f"{R}/pulls/9/merge")
        with pytest.raises(NegativePrError):
            await _try(rest=True)
    assert not gql.called and not put.called


async def test_try_merge_reports_both_refusals(_no_unmocked_http) -> None:
    import respx

    with respx.mock(assert_all_called=False) as r:
        r.get(f"{R}/pulls/9").mock(return_value=httpx.Response(200, json=_pr()))
        r.post(f"{API}/graphql").mock(return_value=httpx.Response(200, json={
            "data": {"enablePullRequestAutoMerge": {"pullRequest": {"autoMergeRequest": {"enabledAt": "t"}}}}}))
        put = r.put(f"{R}/pulls/9/merge").mock(
            return_value=httpx.Response(405, json={"message": "Repository rule violations found"}))
        res = await _try(rest=True)
    assert res.auto_merge_enabled is True
    assert res.rest_status == 405 and "rule" in res.rest_message
    assert json.loads(put.calls[0].request.content)["sha"] == "f" * 40


async def test_try_merge_without_rest_never_puts(_no_unmocked_http) -> None:
    import respx

    with respx.mock(assert_all_called=False) as r:
        r.get(f"{R}/pulls/9").mock(return_value=httpx.Response(200, json=_pr()))
        r.post(f"{API}/graphql").mock(return_value=httpx.Response(200, json={
            "errors": [{"message": "Pull request is in clean status"}]}))
        put = r.put(f"{R}/pulls/9/merge")
        res = await _try(rest=False)
    assert res.auto_merge_enabled is False and "clean status" in res.auto_merge_error
    assert res.rest_status is None and not put.called
