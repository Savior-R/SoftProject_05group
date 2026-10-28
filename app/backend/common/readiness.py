"""异步数据库连通性探针；配置存在不代表连接或检查成功。"""

import asyncio
import logging
from typing import Literal, Protocol

from pydantic import SecretStr
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from common.database_config import mysql_url

DatabaseStatus = Literal["ok", "not_configured", "unavailable", "timeout"]
logger = logging.getLogger(__name__)


class ReadinessProbe(Protocol):
    async def check(self) -> DatabaseStatus: ...

    async def close(self) -> None: ...


class DatabaseReadinessProbe:
    """每个请求检查 SELECT 1；在 lifespan 退出时释放连接池。"""

    def __init__(self, database_url: SecretStr | None, timeout_s: float) -> None:
        self._database_url = database_url
        self._timeout_s = timeout_s
        self._engine: AsyncEngine | None = None

    async def check(self) -> DatabaseStatus:
        if self._database_url is None:
            return "not_configured"
        try:
            async with asyncio.timeout(self._timeout_s):
                if self._engine is None:
                    self._engine = create_async_engine(
                        mysql_url(self._database_url, asynchronous=True),
                        echo=False,
                        hide_parameters=True,
                        pool_pre_ping=True,
                    )
                async with self._engine.connect() as connection:
                    result = await connection.execute(text("SELECT 1"))
                    return "ok" if result.scalar_one() == 1 else "unavailable"
        except TimeoutError:
            logger.warning("数据库就绪检查超时。")
            return "timeout"
        except Exception:
            # 驱动/DSN/认证错误可能包含口令；禁止记录 exc_info 或异常原文。
            logger.warning("数据库就绪检查失败。")
            return "unavailable"

    async def close(self) -> None:
        if self._engine is not None:
            await self._engine.dispose()
            self._engine = None
