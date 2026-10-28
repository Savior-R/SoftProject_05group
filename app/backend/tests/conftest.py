"""所有测试共享的配置与本机 .env/secret 隔离。"""

import pytest

from app.settings import Settings


@pytest.fixture(autouse=True)
def isolate_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in Settings.model_fields:
        monkeypatch.delenv(name.upper(), raising=False)


@pytest.fixture
def settings() -> Settings:
    return Settings(_env_file=None)
