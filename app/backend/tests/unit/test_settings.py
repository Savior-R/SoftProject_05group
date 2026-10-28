"""验证配置来源、secret 隐藏及生产校验。"""

import pytest
from pydantic import ValidationError

from app.core.config import Settings as LegacySettings
from app.settings import Settings


def test_legacy_config_is_the_same_class() -> None:
    assert LegacySettings is Settings


def test_empty_database_is_unconfigured(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", " ")
    assert Settings(_env_file=None).database_url is None


def test_demo_configuration_is_supported(tmp_path) -> None:
    path = tmp_path / ".env"
    path.write_text("ENV=demo\nDATABASE_URL=\nTEST_DATABASE_URL=\n", encoding="utf-8")
    config = Settings(_env_file=path)
    assert config.env == "demo"
    assert config.database_url is None
    assert config.test_database_url is None


def test_environment_overrides_dotenv(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    path = tmp_path / ".env"
    path.write_text("READINESS_TIMEOUT_S=3\n", encoding="utf-8")
    monkeypatch.setenv("READINESS_TIMEOUT_S", "0.5")
    assert Settings(_env_file=path).readiness_timeout_s == 0.5


def test_secret_not_in_repr_or_json() -> None:
    secret = "FAKE_SECRET_" + "x" * 40
    settings = Settings(_env_file=None, jwt_signing_key=secret, glm_api_key=secret)
    assert secret not in repr(settings)
    assert secret not in settings.model_dump_json()


@pytest.mark.parametrize("env", ["staging", "prod"])
def test_production_requires_key(env: str) -> None:
    with pytest.raises(ValidationError, match="至少 32 字符"):
        Settings(_env_file=None, env=env)


def test_production_rejects_debug() -> None:
    with pytest.raises(ValidationError, match="不允许开启 DEBUG"):
        Settings(_env_file=None, env="prod", jwt_signing_key="x" * 40, debug=True)


def test_validation_error_hides_input_secret() -> None:
    secret = "FAKE_INVALID_ENV_SECRET"
    with pytest.raises(ValidationError) as error:
        Settings(_env_file=None, env=secret)
    assert secret not in str(error.value)
