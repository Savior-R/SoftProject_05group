# 师范专业 AI 试讲台系统 — 应用工程入口

| 项目 | 内容 |
|---|---|
| 设计基线 | 设计文档 3.2.0（`../设计文档3.x/`） |
| 工程状态 | 步骤1已通过；步骤2 A公共基础与4张platform模型已实现，完整61表及G1待各域交接 |
| 集成负责人 | A（平台/集成/迁移/部署） |
| 上次更新 | 2026-10-28 |

> 本文件是本工程的唯一启动入口说明。**不写任何密码**，密钥只放在本机 `.env`。
> 与设计冲突时以 `01/05/06/11` 为准，登记问题并提交 ADR。

## 1 目录约定

| 路径 | 用途 | 维护人 |
|---|---|---|
| `app/backend/` | FastAPI 最小后端、app/common/tools 三包及独立验收工具 | 按域分，公共部分 A |
| `app/frontend/` | Vue 3 + TypeScript 工程版前端（步骤 3 创建） | 按页面分 |
| `app/contracts/` | OpenAPI 快照与追踪表（步骤 3 创建） | A |
| `app/docs/adr/` | 架构决策记录 | A |
| `app/docs/team/` | 团队协作模板（环境表等） | A |
| `app/deploy/` | 3.2.0统一部署入口；Python3.12、Linux发布包、frontend/dist；前置交付与G门禁仍待验证 | A |
| `app/tools/` | 分步校验与运维脚本 | A |
| `runtime/` | 私有运行数据（媒体、日志、临时），不进 Git | 各自 |
| `artifacts/` | 脱敏验收证据，不进 Git | 各自 |

## 2 环境基线（已实测冻结）

| 组件 | 版本 | 位置 | 备注 |
|---|---|---|---|
| Python | 3.12.10 | `D:\soft\DevEnv\Python312` | 全组统一用 `py -3.12`，不要依赖裸 `python` |
| Node | v24.19.0（LTS） | `D:\soft\DevEnv\Node` | npm 11.17.0 |
| Git | 2.55.0 | `D:\soft\DevEnv\Git` | |
| MySQL | 8.0.46（容器 `ai-teach-mysql`） | Docker，**主机端口 3307** → 容器内 3306 | 唯一目标数据库；3306 已被本机既有服务 `mysqlzt` 占用 |
| 数据库范围 | 仅MySQL 8.0 | — | 全新61表；取消第二方言和旧52表升级，G1仍待完整验收 |
| FFmpeg / FFprobe | 6.1.1-essentials | `D:\soft\DevEnv\ffmpeg\bin` | 已在用户 PATH |

版本冻结理由与取舍见 `app/docs/adr/ADR-010-工程实现基线.md`。

## 3 启动顺序（A1 单机形态）

```text
1) 数据库   → 启动容器 / 确认七库可连
2) 迁移     → alembic upgrade head（步骤 2 起）
3) 后端     → uvicorn，端口 8000
4) 前端     → vite，端口 5173，通过同源代理访问 /api/v1 与 /ws
```

开发端口约定：API 8000，Vite 5173。数据库端口从 `.env` 读取，不假设固定值。

## 4 常用命令

### 数据库（容器形态）

旧`init-dev-db.ps1`宽权限初始化已停用，不再修改既有账号或授予业务DDL。新建七库/独立迁移与业务账号，使用`backend`目录的`python -m tools.bootstrap_db`先预览，人工确认隔离目标后再显式`--apply`；建表后单独交接platform权限。完整环境变量、命令顺序及当前4/61边界见[步骤2 A交接说明](docs/步骤2-A公共数据库基础与交接.md)。当前缺57表及冻结DDL，不能直接将现有共享库当作G1目标。

日常只需启动容器（Docker Desktop 必须先运行）：

```powershell
docker start ai-teach-mysql
docker exec -it ai-teach-mysql mysql -uroot -p -e "SHOW DATABASES;"
```

连接信息（含口令）在 `runtime/local-db.env`，该文件已被 `.gitignore` 排除，**不要提交、不要发群**。
端口说明：主机侧是 **3307**，容器内是 3306；写 DSN 时用主机端口。

### 后端（T05–T07）

```powershell
Set-Location -LiteralPath 'D:\soft\HomeWork\SoftProject\app\backend'
# 本会话 py 不可用，裸 python 为 3.14；显式选用已定位的 Python 3.12。
if (-not (Test-Path -LiteralPath '.venv\Scripts\python.exe')) {
    & 'D:\soft\DevEnv\Python312\python.exe' -m venv .venv
}
.\.venv\Scripts\python.exe -m pip install --require-hashes --only-binary=:all: -r requirements.lock
.\.venv\Scripts\python.exe -m pip check
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 1
```

从 backend 目录安装，并同时交付 `requirements.lock` 与 `wheels/`。设计差异、
每项任务独立命令、空 venv 复验及常见问题见
[`docs/T05-T07-实现与独立验收.md`](docs/T05-T07-实现与独立验收.md)。

健康检查：

```powershell
curl.exe -sS -o NUL -w "%{http_code}\n" http://127.0.0.1:8000/health/live
curl.exe -sS -o NUL -w "%{http_code}\n" http://127.0.0.1:8000/health/ready
curl.exe -sS -o NUL -w "%{http_code}\n" http://127.0.0.1:8000/openapi.json
```

未配置数据库时依次预期 200、503、200。ready 每次执行数据库连通性检查，
不能因为服务启动成功或 DSN 非空就返回 200；不代表后续数据库结构/业务已验收。

### 前端（步骤 3 完成后）

```powershell
Set-Location -LiteralPath 'D:\soft\HomeWork\SoftProject\app\frontend'
npm ci
npm run dev -- --host 127.0.0.1 --port 5173
```

### 分步校验

```powershell
Set-Location -LiteralPath 'D:\soft\HomeWork\SoftProject'
.\app\tools\verify-step.ps1 -Step 1
```

## 5 角色与演示范围

四种角色（管理、教师、学生、观摩）的具体权限以 `01-需求规格说明书` 为准。
当前版本目标：**先跑 M0 → M1（全部 P0）**，P1 在步骤 11 追加。

## 6 六人分工与证据目录

| 代号 | 主责 | 首轮证据目录 |
|---|---|---|
| A | 平台/集成/迁移/部署 | `artifacts/M0/bootstrap/`、`artifacts/G1/`、`artifacts/M0/contracts/` |
| B | 身份组织/权限 | `artifacts/M0/identity/` |
| C | 内容任务 | `artifacts/M0/tasks/` |
| D | 课堂/WS/实时 | `artifacts/G4/classroom/` |
| E | 媒体/采集/回放 | `artifacts/G2/media/` |
| F | 评测/报告/主批 | `artifacts/G2/evaluation/`、`artifacts/G4/score/` |

任务卡与联调清单见 `../设计文档3.x/团队开发文档/14-六人成员任务卡与联调清单.md`。

## 7 不要做的事

- 不删库重来掩盖迁移问题；
- 不把密码、token、真实媒体、预签名链接提交进仓库或贴到群里；
- 不用假数据、桩、缓存冒充门禁通过；
- 部署只维护 `app/deploy/` 的现行入口；A2/B另交付对应编排，不恢复旧壳或自动导入旧DDL。

## 8 协作与首次交付

唯一策略为main加`codex/<任务简述>`短分支，不使用develop；依据见[ADR-010 §2.7](docs/adr/ADR-010-工程实现基线.md)。main通过PR集成，远端保护设置须单独实际确认。

```powershell
git fetch origin
git switch main
git pull --ff-only origin main
git switch -c codex/identity-auth
# 修改后运行对应阶段检查；只暂存本任务明确文件
git status --short
# git add <明确路径>
git diff --cached --stat
git commit -m "feat(identity): implement revocable sessions"
git push -u origin codex/identity-auth
```

PR必须说明改动、依赖commit、数据库／契约影响、验证结果、证据位置及未完成事项，并由非作者复核。首次交付须有真实基线提交，状态表随后引用该commit，不能只记录日期。

`artifacts/`、`runtime/`、`.venv/`、`build/`及本地工具目录不入库；clone后没有完整本机证据是预期行为。仓库保留[本次交付摘要](docs/当前阶段交付记录-2026-10-28.md)及复跑入口，完整脱敏证据按团队受控方式共享；不得为共享而提交密钥或私有数据。

源码变化后先按[后端README](backend/README.md)重新构建项目wheel与主锁，再执行`verify-step -Step 1`。默认索引读取`PIP_INDEX_URL`，也可显式覆盖：

```powershell
# 示例地址需换成实际可访问的索引；不在文档或提交中填写含凭据地址。
.\app\tools\verify-step.ps1 -Step 1 -PackageIndexUrl 'https://pypi.org/simple'
```

后续阶段、依赖及关闭条件见[问题跟踪文档](docs/当前开发阻塞与修复阶段记录-2026-10-28.md)。
