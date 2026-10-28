"""集中配置；不输出配置对象、环境变量原文或连接异常原文。"""

from typing import Literal

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """最小后端配置；生产缺少必需密钥时明确拒绝启动。"""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        hide_input_in_errors=True,
    )

    env: Literal["dev", "demo", "staging", "prod"] = "dev"
    debug: bool = False
    database_url: SecretStr | None = Field(default=None, repr=False)
    test_database_url: SecretStr | None = Field(default=None, repr=False)
    jwt_signing_key: SecretStr | None = Field(default=None, repr=False)
    glm_api_key: SecretStr | None = Field(default=None, repr=False)
    readiness_timeout_s: float = Field(default=2.0, gt=0, le=30)

    @field_validator(
        "database_url", "test_database_url", "jwt_signing_key", "glm_api_key", mode="before"
    )
    @classmethod
    def empty_secret_is_unconfigured(cls, value: object) -> object:
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @model_validator(mode="after")
    def validate_production(self) -> "Settings":
        if self.env in {"staging", "prod"}:
            if self.jwt_signing_key is None or len(self.jwt_signing_key.get_secret_value()) < 32:
                raise ValueError("staging/prod 必须配置至少 32 字符的 JWT_SIGNING_KEY")
            if self.debug:
                raise ValueError("staging/prod 不允许开启 DEBUG")
        return self
