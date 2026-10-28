# 最小后端：T05 / T06 / T07

解释器基线为 Python 3.12；默认 `python` 不一定符合要求。
本工程提供三个可安装包：`app`、`common`、`tools`。

完整设计核对、命令、验收证据与已知边界见 `../docs/T05-T07-实现与独立验收.md`。

## 安装及启动

在 PowerShell 中执行：

```powershell
Set-Location -LiteralPath 'D:\soft\HomeWork\SoftProject\app\backend'
# 只在 .venv 不存在时创建；其他机器改为本机 Python 3.12 的实际路径。
& 'D:\soft\DevEnv\Python312\python.exe' -m venv .venv
.\.venv\Scripts\python.exe -m pip install --require-hashes --only-binary=:all: -r requirements.lock
.\.venv\Scripts\python.exe -m pip check
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 1
```

`requirements.lock` 同时包含第三方精确版本、hash 和本项目的相对路径 wheel。
必须将 `wheels/` 与 lock 一起交付，并在本目录执行安装。首次使用 lock 不再额外运行
`pip install -e .`，以便检验真正的打包结果。开发修改源码后重新生成 wheel/lock 再验收。

## 健康检查

- `GET /health/live`：进程存活返回 200，不依赖数据库。
- `GET /health/ready`：未配置数据库、连接失败或超时返回 503；真实 `SELECT 1` 成功才返回 200。
- `GET /openapi.json`：返回 200。
- `/healthz` 与 `/api/v1/health/ready` 是 readiness 兼容路径；`/api/v1/health/live` 为 liveness 兼容路径。

数据库探针只验证连通性。T05–T07 不验证 61 表、迁移、Redis、模型或业务就绪。
生产配置必须提供至少 32 字符的 JWT_SIGNING_KEY，且不得开启 DEBUG。

## 独立验收

```powershell
Set-Location -LiteralPath 'D:\soft\HomeWork\SoftProject\app\backend'
# T05：扫描 lock/校验 wheel，并在全新 venv 安装、离开源码目录后真正启动 HTTP 服务。
.\.venv\Scripts\python.exe -m tools.verify_lock
.\.venv\Scripts\python.exe -m tools.verify_install
# T06
.\.venv\Scripts\python.exe -m pytest tests/unit -q
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m ruff format --check .
# T07：Step 1 执行以上全部；其他未实现阶段明确非零。
..\tools\verify-step.ps1 -Step 1
..\tools\verify-step.ps1 -Step 2
```

## 2026-10-28 复核修正

MySQL 驱动使用 `aiomysql[rsa]`，确保冷认证所需的 cryptography 进入 lock。
`ENV=demo` 可启动；`.env.example` 包含团队 18 键及 DEBUG/探针超时两个附加键。
未来业务字段目前仅登记，不能据此宣称登录、队列、存储或模型业务已经实现。

增强 Step 1 必须有独立测试库：在不提交的 `.env` 中填写 `TEST_DATABASE_URL`，
或在当前 PowerShell 会话中设置该环境变量。只允许 `test_` 加七个逻辑域名的白名单。
验证仅执行 SELECT 1，不写数据；不要填写共享开发库。缺少配置或连接失败返回非零。

```powershell
# backend 目录：独立真实数据库验证；输出不包含 DSN/口令。
.\.venv\Scripts\python.exe -I -m tools.verify_database
# T05 可单独验证无库安装，结果会明确记录数据库未执行。
.\.venv\Scripts\python.exe -m tools.verify_install
# 强化验收：新空 venv 仅 lock 安装后，同时验证无库 503 与有库 200。
.\.venv\Scripts\python.exe -m tools.verify_install --require-database
```

业务同步 Session 与异步运维探针的边界、路由例外见 `../docs/adr/ADR-012-MySQL冷认证与最小后端复核修正.md`。

## 修改源码后的交付流程

仅A维护发布锁。已从当前lock安装好构建依赖的Python3.12环境执行：

```powershell
.\.venv\Scripts\python.exe -m tools.build_release
.\.venv\Scripts\python.exe -m tools.verify_lock
..\tools\verify-step.ps1 -Step 1
```

不直接用pip-compile覆盖主lock，不额外editable安装掩盖wheel缺漏。`build_release`生成第三方锁、项目wheel及带wheel hash的主锁；复测成功后共同提交。若只改源码而未重建，`verify_lock`必须拒绝。

索引优先级为显式`--index-url`或`-PackageIndexUrl`、环境变量`PIP_INDEX_URL`、默认PyPI；使用团队已确认可达的源，不在提交中保存带凭据地址。

单测只从`app.factory`导入`create_app`，在fixture中显式注入`Settings(_env_file=None)`；`app.main:app`保留真实运行入口，启动时仍校验生产配置。同步Session与公共业务错误契约继续按步骤2–3交付。

