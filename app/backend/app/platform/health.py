"""存活和数据库连通性就绪接口。"""

import asyncio
from typing import Literal, cast

from fastapi import APIRouter, Request, Response
from pydantic import BaseModel

from common.readiness import DatabaseStatus, ReadinessProbe

router = APIRouter(tags=["health"])


class LiveResponse(BaseModel):
    status: Literal["alive"] = "alive"


class ReadyResponse(BaseModel):
    status: Literal["ready", "not_ready"]
    checks: dict[str, DatabaseStatus]


@router.get("/health/live", response_model=LiveResponse)
@router.get("/api/v1/health/live", response_model=LiveResponse, include_in_schema=False)
async def live() -> LiveResponse:
    """进程可响应即可存活，不查询外部依赖。"""
    return LiveResponse()


@router.get(
    "/health/ready",
    response_model=ReadyResponse,
    responses={503: {"model": ReadyResponse, "description": "数据库未就绪"}},
)
@router.get("/healthz", response_model=ReadyResponse, include_in_schema=False)
@router.get("/api/v1/health/ready", response_model=ReadyResponse, include_in_schema=False)
async def ready(request: Request, response: Response) -> ReadyResponse:
    probe = cast(ReadinessProbe, request.app.state.readiness_probe)
    try:
        async with asyncio.timeout(request.app.state.readiness_timeout_s):
            status = await probe.check()
    except TimeoutError:
        status = "timeout"
    except Exception:
        # 可插拔探针同样失败关闭，避免其异常被作为含 secret 的 HTTP 500 输出。
        status = "unavailable"
    is_ready = status == "ok"
    response.status_code = 200 if is_ready else 503
    return ReadyResponse(status="ready" if is_ready else "not_ready", checks={"database": status})
