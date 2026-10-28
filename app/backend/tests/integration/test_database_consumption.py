"""消费示例为测试路由，不作为步骤4登录或业务接口交付。"""

from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.testclient import TestClient
from sqlalchemy import text

from app.factory import create_app
from app.settings import Settings
from common.db import Database, get_database


def test_sync_consumer_and_async_misuse(isolated_mysql):
    database = isolated_mysql["database"]
    settings = Settings(
        _env_file=None,
        database_url=database.engine.url.render_as_string(hide_password=False),
        db_schema_prefix=database.schemas.prefix,
    )
    app = create_app(settings)
    router = APIRouter()

    @router.get("/test/sync")
    def good(db: Annotated[Database, Depends(get_database)]):
        return {"value": db.run(lambda session: session.scalar(text("SELECT 1")))}

    @router.get("/test/async")
    async def wrong(db: Annotated[Database, Depends(get_database)]):
        return {"value": db.run(lambda session: session.scalar(text("SELECT 1")))}

    app.include_router(router)
    with TestClient(app, raise_server_exceptions=False) as client:
        assert client.get("/test/sync").json() == {"value": 1}
        assert client.get("/test/async").status_code == 500
        assert client.get("/health/ready").status_code == 200
        assert client.get("/health/live").status_code == 200
