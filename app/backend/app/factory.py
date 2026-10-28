"""无配置加载副作用的应用工厂；创建应用时才读取并校验运行配置。"""

import logging
from asyncio import to_thread
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.platform.health import router as health_router
from app.settings import Settings
from common.db import DatabaseProvider
from common.readiness import DatabaseReadinessProbe, ReadinessProbe

logger = logging.getLogger("uvicorn.error")


def create_app(settings: Settings | None = None, probe: ReadinessProbe | None = None) -> FastAPI:
    config = settings if settings is not None else Settings()
    readiness_probe = (
        probe
        if probe is not None
        else DatabaseReadinessProbe(config.database_url, config.readiness_timeout_s)
    )
    database_provider = DatabaseProvider(config.database_url, config.db_schema_prefix)

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        # 固定消息；不输出配置对象、DSN、令牌或供应商密钥。
        logger.info("最小后端启动；数据库就绪状态由请求时探针判定。")
        try:
            yield
        finally:
            try:
                await readiness_probe.close()
            finally:
                await to_thread(database_provider.close)

    application = FastAPI(
        title="AI Teach 最小后端",
        version="0.1.0",
        debug=config.debug,
        lifespan=lifespan,
    )
    application.state.readiness_probe = readiness_probe
    application.state.database_provider = database_provider
    application.state.readiness_timeout_s = config.readiness_timeout_s
    application.include_router(health_router)
    return application
