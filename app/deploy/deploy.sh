#!/usr/bin/env bash
# 3.2.0 A1；只检查或启动既有发布包，不执行旧DDL、迁移或数据删除。
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:---check}"
if [ "$#" -gt 1 ] || { [ "$mode" != "--check" ] && [ "$mode" != "--start" ]; }; then
  printf '%s\n' '用法：bash deploy.sh [--check|--start]' >&2
  exit 2
fi
require_file() {
  if [ ! -s "$1" ]; then
    printf '缺少前置交付：%s；参见 app/deploy/README.md\n' "$1" >&2
    exit 1
  fi
}
require_file .env
require_file backend-release/requirements.lock
require_file backend-release/wheels/ai_teach_backend-0.1.0-py3-none-any.whl
require_file ../frontend/package-lock.json
require_file ../frontend/dist/index.html
command -v docker >/dev/null 2>&1 || { printf '%s\n' '缺少 Docker Compose v2。' >&2; exit 1; }
# 不 source .env，不将配置或DSN输出到终端。
docker compose -f compose.cloud.yml config --quiet
printf '%s\n' '文件与编排静态检查通过；未验证Linux锁包、SQL、G1或业务门禁。'
if [ "$mode" = "--check" ]; then
  exit 0
fi
docker info >/dev/null
docker compose -f compose.cloud.yml up -d --build --wait
printf '%s\n' 'A1入口已启动：http://127.0.0.1:8080；健康不等于业务验收。'
