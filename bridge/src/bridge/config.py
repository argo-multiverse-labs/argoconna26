"""Bridge settings, read from the environment (Secret `bridge-env` in the cluster)."""

from __future__ import annotations

from pydantic import AliasChoices, Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


def _env(*names: str) -> AliasChoices:
    return AliasChoices(*names)


class Settings(BaseSettings):
    """Every value has a safe default so the app can start for `/healthz` alone.

    An empty `webhook_token` makes the webhook reject every request, so a missing
    Secret fails closed.
    """

    model_config = SettingsConfigDict(extra="ignore", populate_by_name=True)

    webhook_token: SecretStr = Field(
        default=SecretStr(""), validation_alias=_env("BRIDGE_WEBHOOK_TOKEN", "WEBHOOK_TOKEN")
    )
    github_repo: str = Field(default="", validation_alias=_env("GITHUB_REPO", "REPO_SLUG"))
    github_api_url: str = Field(default="https://api.github.com", validation_alias=_env("GITHUB_API_URL"))
    tracked_branch: str = Field(default="build/demo", validation_alias=_env("TRACKED_BRANCH"))
    github_app_id: str = Field(default="", validation_alias=_env("GITHUB_APP_ID"))
    github_installation_id: str = Field(default="", validation_alias=_env("GITHUB_INSTALLATION_ID"))
    github_app_key_path: str = Field(default="", validation_alias=_env("GITHUB_APP_KEY_PATH"))
    holmes_url: str = Field(default="", validation_alias=_env("HOLMES_URL"))
    holmes_api_key: SecretStr = Field(default=SecretStr(""), validation_alias=_env("HOLMES_API_KEY"))
    holmes_model: str = Field(default="rca", validation_alias=_env("HOLMES_MODEL"))
    holmes_timeout_s: float = Field(default=115, gt=0, validation_alias=_env("HOLMES_TIMEOUT_S"))
    stage_cols: int = Field(default=30, ge=8, validation_alias=_env("STAGE_COLS"))
    cdevents_url: str = Field(default="", validation_alias=_env("CDEVENTS_URL"))
    confidence_threshold: float = Field(default=0.7, ge=0, le=1, validation_alias=_env("CONFIDENCE_THRESHOLD"))
    config_allowlist: list[str] = Field(
        default_factory=lambda: ["apps/*/config/*.yaml"], validation_alias=_env("CONFIG_ALLOWLIST")
    )
    config_version_annotation: str = Field(
        default="example.dev/config-version", validation_alias=_env("CONFIG_VERSION_ANNOTATION")
    )
    argo_ui_url: str = Field(default="", validation_alias=_env("ARGO_UI_URL"))
    dry_forge: bool = Field(default=False, validation_alias=_env("DRY_FORGE"))
