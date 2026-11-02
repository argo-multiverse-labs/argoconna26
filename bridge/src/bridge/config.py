"""Bridge settings, read from the environment: the Deployment's env, Secret `bridge-secrets`, and
the optional Secret `bridge-env` (test hooks only, Task 4.6; not managed by Argo CD).

`bridge-env` is loaded with envFrom, which loses to any `env` entry of the same name. The
Deployment pins every setting under the first name listed here, so the Secret can only
reach the two test hooks, whose first name starts with TEST_ (TEST_HOOKS). A test checks
that against the manifest. /status and preflight show when a hook is active."""

from __future__ import annotations

from pydantic import AliasChoices, Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


def _env(*names: str) -> AliasChoices:
    return AliasChoices(*names)


DEFAULT_CONFIDENCE_THRESHOLD = 0.7
DEFAULT_HOLMES_TIMEOUT_S = 115.0
# Settings fields a TEST_* variable can override (Task 4.6 failure paths).
TEST_HOOKS = ("confidence_threshold", "holmes_timeout_s")


class Settings(BaseSettings):
    """Every value has a safe default so the app can start for `/healthz` alone.

    An empty `webhook_token` makes the webhook reject every request, so a missing
    Secret fails closed.
    """

    model_config = SettingsConfigDict(extra="ignore", populate_by_name=True)

    webhook_token: SecretStr = Field(
        default=SecretStr(""), validation_alias=_env("BRIDGE_WEBHOOK_TOKEN", "WEBHOOK_TOKEN")
    )
    github_repo: str = Field(default="", validation_alias=_env("REPO_SLUG", "GITHUB_REPO"))
    github_api_url: str = Field(default="https://api.github.com", validation_alias=_env("GITHUB_API_URL"))
    tracked_branch: str = Field(default="build/demo", validation_alias=_env("TRACKED_BRANCH"))
    github_app_id: str = Field(default="", validation_alias=_env("GITHUB_APP_ID"))
    github_installation_id: str = Field(default="", validation_alias=_env("GITHUB_INSTALLATION_ID"))
    github_app_key_path: str = Field(default="", validation_alias=_env("GITHUB_APP_KEY_PATH"))
    holmes_url: str = Field(default="", validation_alias=_env("HOLMES_URL"))
    holmes_api_key: SecretStr = Field(default=SecretStr(""), validation_alias=_env("HOLMES_API_KEY"))
    holmes_model: str = Field(default="rca", validation_alias=_env("HOLMES_MODEL"))
    # TEST_HOLMES_TIMEOUT_S comes first: it is the Task 4.6 timeout hook, set in the optional
    # Secret bridge-env, and a Deployment `env` entry (HOLMES_TIMEOUT_S) beats `envFrom`.
    holmes_timeout_s: float = Field(
        default=DEFAULT_HOLMES_TIMEOUT_S, gt=0, validation_alias=_env("TEST_HOLMES_TIMEOUT_S", "HOLMES_TIMEOUT_S")
    )
    stage_cols: int = Field(default=30, ge=8, validation_alias=_env("STAGE_COLS"))
    cdevents_url: str = Field(default="", validation_alias=_env("CDEVENTS_URL"))
    # The CloudEvents source on every bridge event; cdevents-sim keeps these off /timeline (P16).
    # Empty means no event is sent (an unmarked bridge event would reach HolmesGPT).
    bridge_event_source: str = Field(default="", validation_alias=_env("BRIDGE_EVENT_SOURCE"))
    # The optional ConfigMap `dryrun-summary`, mounted by the Deployment (Task 3.10).
    dryrun_summary_path: str = Field(
        default="/etc/bridge/dryrun/summary.json", validation_alias=_env("DRYRUN_SUMMARY_PATH")
    )
    # No upper bound: a value above 1 refuses every answer (the Task 4.6 forced-refusal hook,
    # TEST_CONFIDENCE_THRESHOLD; the Deployment pins CONFIDENCE_THRESHOLD to the default).
    confidence_threshold: float = Field(
        default=DEFAULT_CONFIDENCE_THRESHOLD, ge=0,
        validation_alias=_env("TEST_CONFIDENCE_THRESHOLD", "CONFIDENCE_THRESHOLD"),
    )
    config_allowlist: list[str] = Field(
        default_factory=lambda: ["apps/*/config/*.yaml"], validation_alias=_env("CONFIG_ALLOWLIST")
    )
    config_version_annotation: str = Field(
        default="example.dev/config-version", validation_alias=_env("CONFIG_VERSION_ANNOTATION")
    )
    argo_ui_url: str = Field(default="", validation_alias=_env("ARGO_UI_URL"))
    # The fix PR (Task 4.3): the file whose config-version annotation rolls the pods, the
    # file that pins the image (named in the PR's blast radius), and the first image tag
    # with the security fix. Defaults match demo.env.
    rollout_file: str = Field(default="apps/checkout/deploy/rollout.yaml", validation_alias=_env("ROLLOUT_FILE"))
    kustomization_file: str = Field(
        default="apps/checkout/kustomization.yaml", validation_alias=_env("KUSTOMIZATION_FILE")
    )
    cve_fix_tag: str = Field(default="", validation_alias=_env("CHECKOUT_CVE_TAG"))
    # The App's login; open agent PRs by anyone else are ignored (D6).
    bot_login: str = Field(default="argoconna26-agent[bot]", validation_alias=_env("BOT_LOGIN"))
    dry_forge: bool = Field(default=False, validation_alias=_env("DRY_FORGE"))
    # How often /status probes (GitHub token, HolmesGPT readiness) and the touchpoints
    # gauge (aiops/autonomy.yaml) are refreshed. The first refresh runs at startup.
    status_refresh_s: float = Field(default=60, gt=0, validation_alias=_env("STATUS_REFRESH_S"))
    # The fix-PR outcome reconciler (Task 4.3a) polls agent/<app>-* PRs this often.
    reconcile_app: str = Field(default="checkout", validation_alias=_env("RECONCILE_APP"))
    reconcile_interval_s: float = Field(default=30, gt=0, validation_alias=_env("RECONCILE_INTERVAL_S"))
    # Act (Task 5.4): the required check (demo.env), and how the clean_status fallback waits for it.
    policy_check_context: str = Field(default="policy-check", validation_alias=_env("POLICY_CHECK_CONTEXT"))
    policy_check_integration_id: int = Field(default=15368, validation_alias=_env("POLICY_CHECK_INTEGRATION_ID"))
    act_check_poll_s: float = Field(default=5, gt=0, validation_alias=_env("ACT_CHECK_POLL_S"))
    act_check_timeout_s: float = Field(default=600, gt=0, validation_alias=_env("ACT_CHECK_TIMEOUT_S"))

    @property
    def test_hooks_active(self) -> bool:
        """True when a test hook moved the threshold or the HolmesGPT timeout off its default."""
        return (
            self.confidence_threshold != DEFAULT_CONFIDENCE_THRESHOLD
            or self.holmes_timeout_s != DEFAULT_HOLMES_TIMEOUT_S
        )
