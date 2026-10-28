"""验证真实路由、ready 失败关闭、探针调用与启动日志。"""

import asyncio
import logging

import pytest
from fastapi.testclient import TestClient

from app.factory import create_app
from app.settings import Settings
from common.readiness import DatabaseStatus


class FakeProbe:
    def __init__(self, status: DatabaseStatus = "ok", error: Exception | None = None) -> None:
        self.status = status
        self.error = error
        self.calls = 0
        self.closed = False

    async def check(self) -> DatabaseStatus:
        self.calls += 1
        if self.error is not None:
            raise self.error
        return self.status

    async def close(self) -> None:
        self.closed = True


def test_live_and_openapi_do_not_query_database(settings: Settings) -> None:
    probe = FakeProbe(error=RuntimeError("database down"))
    with TestClient(create_app(settings, probe)) as client:
        assert client.get("/health/live").json() == {"status": "alive"}
        assert client.get("/health/live").status_code == 200
        specification = client.get("/openapi.json")
        assert specification.status_code == 200
        assert {"/health/live", "/health/ready"} <= specification.json()["paths"].keys()
        assert probe.calls == 0
    assert probe.closed


@pytest.mark.parametrize("path", ["/health/ready", "/healthz", "/api/v1/health/ready"])
def test_unconfigured_database_is_503(settings: Settings, path: str) -> None:
    with TestClient(create_app(settings)) as client:
        response = client.get(path)
        assert response.status_code == 503
        assert response.json() == {"status": "not_ready", "checks": {"database": "not_configured"}}


@pytest.mark.parametrize("status", ["ok", "unavailable", "timeout", "not_configured"])
def test_ready_uses_probe_result(settings: Settings, status: DatabaseStatus) -> None:
    probe = FakeProbe(status)
    with TestClient(create_app(settings, probe)) as client:
        response = client.get("/health/ready")
        assert response.status_code == (200 if status == "ok" else 503)
        assert response.json()["checks"]["database"] == status
        assert probe.calls == 1
        # 再次请求仍执行检查；不能把启动成功缓存成永久 ready。
        probe.status = "unavailable"
        assert client.get("/health/ready").status_code == 503
        assert probe.calls == 2


def test_probe_error_does_not_leak_secret(
    settings: Settings, caplog: pytest.LogCaptureFixture
) -> None:
    secret = "FAKE_DATABASE_PASSWORD_123"
    probe = FakeProbe(error=RuntimeError(f"mysql://user:{secret}@db/private"))
    with caplog.at_level(logging.INFO), TestClient(create_app(settings, probe)) as client:
        response = client.get("/health/ready")
        assert response.status_code == 503
        assert secret not in response.text
    assert secret not in caplog.text


def test_probe_timeout_returns_503(settings: Settings) -> None:
    class SlowProbe(FakeProbe):
        async def check(self) -> DatabaseStatus:
            await asyncio.sleep(0.1)
            return "ok"

    settings.readiness_timeout_s = 0.01
    with TestClient(create_app(settings, SlowProbe())) as client:
        response = client.get("/health/ready")
        assert response.status_code == 503
        assert response.json()["checks"]["database"] == "timeout"


def test_startup_never_logs_secrets(caplog: pytest.LogCaptureFixture) -> None:
    secret_jwt = "FAKE_JWT_" + "x" * 40
    secret_glm = "FAKE_GLM_" + "y" * 40
    config = Settings(_env_file=None, jwt_signing_key=secret_jwt, glm_api_key=secret_glm)
    with caplog.at_level(logging.INFO), TestClient(create_app(config)) as client:
        assert client.get("/health/live").status_code == 200
    assert "最小后端启动" in caplog.text
    assert secret_jwt not in caplog.text
    assert secret_glm not in caplog.text
