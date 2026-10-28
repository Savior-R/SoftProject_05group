# syntax=docker/dockerfile:1
# Python3.12；只安装已经在 Linux 验证的锁文件与项目 wheel。
# 前端由 Caddy 从 frontend/dist 提供，不复制不存在的 web/。
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    TZ=Asia/Shanghai

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg curl tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app/release
COPY deploy/backend-release/requirements.lock ./requirements.lock
COPY deploy/backend-release/wheels/ ./wheels/
RUN python -m pip install --require-hashes --only-binary=:all: -r requirements.lock

EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=4s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8000/health/ready || exit 1

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
