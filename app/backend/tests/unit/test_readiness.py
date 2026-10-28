"""验证异步数据库探针真正查询、超时/异常处理与池清理。"""

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from pydantic import SecretStr

from common.readiness import DatabaseReadinessProbe


async def test_no_url_does_not_create_engine() -> None:
    with patch("common.readiness.create_async_engine") as factory:
        probe = DatabaseReadinessProbe(None, 1)
        assert await probe.check() == "not_configured"
        factory.assert_not_called()
        await probe.close()


async def test_success_requires_select_one_and_disposes_pool() -> None:
    result = MagicMock()
    result.scalar_one.return_value = 1
    connection = AsyncMock()
    connection.execute.return_value = result
    manager = AsyncMock()
    manager.__aenter__.return_value = connection
    engine = MagicMock()
    engine.connect.return_value = manager
    engine.dispose = AsyncMock()
    probe = DatabaseReadinessProbe(SecretStr("mysql+aiomysql://user:FAKE@db/test"), 1)
    with patch("common.readiness.create_async_engine", return_value=engine) as factory:
        assert await probe.check() == "ok"
        assert str(connection.execute.call_args.args[0]) == "SELECT 1"
        assert factory.call_args.kwargs["echo"] is False
        assert factory.call_args.kwargs["hide_parameters"] is True
        await probe.close()
        engine.dispose.assert_awaited_once()


async def test_invalid_url_is_not_ready(caplog: pytest.LogCaptureFixture) -> None:
    secret = "FAKE_PASSWORD_FOR_TEST"
    probe = DatabaseReadinessProbe(SecretStr(f"unsupported://user:{secret}@db/test"), 1)
    assert await probe.check() == "unavailable"
    assert secret not in caplog.text


async def test_configured_database_failure_is_not_ready(
    caplog: pytest.LogCaptureFixture,
) -> None:
    secret = "FAKE_CONNECTION_PASSWORD"
    manager = AsyncMock()
    manager.__aenter__.side_effect = ConnectionError(f"authentication failed: {secret}")
    engine = MagicMock()
    engine.connect.return_value = manager
    with patch("common.readiness.create_async_engine", return_value=engine):
        probe = DatabaseReadinessProbe(SecretStr(f"mysql+aiomysql://user:{secret}@db/test"), 1)
        assert await probe.check() == "unavailable"
    assert secret not in caplog.text


async def test_unexpected_database_result_is_not_ready() -> None:
    result = MagicMock()
    result.scalar_one.return_value = 0
    connection = AsyncMock()
    connection.execute.return_value = result
    manager = AsyncMock()
    manager.__aenter__.return_value = connection
    engine = MagicMock()
    engine.connect.return_value = manager
    with patch("common.readiness.create_async_engine", return_value=engine):
        probe = DatabaseReadinessProbe(SecretStr("mysql+aiomysql://user:FAKE@db/test"), 1)
        assert await probe.check() == "unavailable"


async def test_database_timeout() -> None:
    async def wait_for_connection() -> None:
        await asyncio.sleep(0.2)

    manager = AsyncMock()
    manager.__aenter__.side_effect = wait_for_connection
    engine = MagicMock()
    engine.connect.return_value = manager
    with patch("common.readiness.create_async_engine", return_value=engine):
        probe = DatabaseReadinessProbe(SecretStr("mysql+aiomysql://user:FAKE@db/test"), 0.01)
        assert await probe.check() == "timeout"
