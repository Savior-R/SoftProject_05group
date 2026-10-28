"""ASGI 入口；示例启动：python -m uvicorn app.main:app。"""

from app.factory import create_app

app = create_app()
