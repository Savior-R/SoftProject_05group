# 实施状态表（IMPLEMENTATION_STATUS）

| 项目 | 内容 |
|---|---|
| 设计基线 | 3.2.0 |
| 维护人 | A（每次集成后更新，其他人只提变更请求） |
| 状态取值 | 仅四种：**未开始 / 进行中 / 通过 / 阻塞** |
| 规则 | 部分完成写在"证据/阻塞"列，**不把部分测试通过写成整个步骤通过** |

## 步骤状态

| 步骤 | 目标 | 主责 | 状态 | 日期/commit | 证据 | 阻塞与下一步 |
|---|---|---|---|---|---|---|
| 0 | 环境/基线/Git | A + 全员 | 进行中 | 2026-10-28 | `artifacts/M0/bootstrap/` | A 机 Python/Node/FFmpeg/MySQL 已就绪；本地 main 已初始化，远端待配置；**SQL Server 缺机器**，其余五人环境表待填 |
| 1 | 工程/测试/health | A | 进行中 | 2026-10-28；基线待提交 | `artifacts/M0/bootstrap/t07-step1.json`、`t05-clean-venv.json`、`ds-cold-auth-regression.json` | 既有技术证据通过：58 项测试、Ruff、pip check，新空 venv 仅 lock 安装，无库 503/有库 200、真实 RSA 冷认证与负例；只证明骨架和 SQL 连通性，非全系统或 G1 通过；当前交付修复待重新锁包、复验与基线提交，不能复用旧证据直接放行 |
| 2 | 目标 DB/双方言 G1 | A + 各域 | 未开始 | — | `artifacts/G1/mysql/`、`artifacts/G1/sqlserver/` | MySQL 容器已可用；SQL Server 阻塞 |
| 3 | DTO/前端/契约 | A + 全员 | 未开始 | — | `artifacts/M0/contracts/` | 依赖步骤 2 的 DB 可连 |
| 4 | 身份组织/授权 | B | 未开始 | — | `artifacts/M0/identity/` | 依赖步骤 2/3 |
| 5 | 标准/内容/任务 | C | 未开始 | — | `artifacts/M0/tasks/` | 依赖步骤 4 |
| 6 | 课堂/WS/RTC 信令 | D | 未开始 | — | `artifacts/G4/classroom/` | 依赖步骤 4/5 |
| 7 | 媒体/上传/回放 | E | 未开始 | — | `artifacts/G2/media/` | 依赖步骤 6 + 真实设备预检 |
| 8 | submit/评测/报告 | F + A | 未开始 | — | `artifacts/G2/evaluation/` | 依赖步骤 7 + 模型账号 |
| 9 | 主批/统计/导出 | F + A | 未开始 | — | `artifacts/G4/score/` | 依赖步骤 8 |
| 10 | M1/全部 P0 | 全员 | 未开始 | — | `artifacts/M1/` | 依赖上面全部 |
| 11 | 全部 P1 | 全员 | 未开始 | — | `artifacts/M2/` | 依赖步骤 10 |
| 12 | A2/运维/恢复 | A + D/E/F | 未开始 | — | `artifacts/G6/` | 依赖步骤 11 或与 10 并行准备 |
| 13 | G5/G6/UAT/发布 | 全员 + 业务 | 未开始 | — | `artifacts/M2/` | 依赖全部 |

## 当前阻塞项

### 历史记录：T05–T07 独立任务验收（2026-10-27）

| 任务 | 状态 | 独立验证结果 |
|---|---|---|
| T05 | 通过 | 三包 wheel；lock 无本机绝对路径；全新 venv 仅安装 lock；pip check；中立目录真实 HTTP |
| T06 | 通过 | live 200、未配置 DB 的 ready 503、OpenAPI 200；48 项测试、Ruff、日志标记无泄漏 |
| T07 | 通过 | 完整 Step 1 退出 0；Step 0/2–13 退出 2；越界及缺解释器非零；UTF-8 BOM |

2026-10-27 当次未运行真实数据库连通成功、迁移、业务或 GLM 验收。48 项测试中包含 T07 脚本负例，
不是 48 项业务测试。pytest 有 1 条上游 Starlette/httpx 弃用提醒，无失败、无跳过。

### 历史技术证据：2026-10-28 增强门禁复验

- 当前 Step 1 真实退出 0；58 passed、0 skipped，Ruff lint/format 与 pip check 通过。
- 新空 venv 只安装新主 lock，三个包来自 site-packages；中立目录真实 HTTP：
  live=200、无库 ready=503、有独立测试库 ready=200、OpenAPI=200。
- 同一个新建账户在旧版缺 RSA 环境返回 503，新版成功；另一个全新账户观察到真实 RSA
  加密调用且返回 200。两个临时账户均已删除；未重启容器、未 FLUSH PRIVILEGES。
- 缺测试库、不可达测试库均退出 1；Step 0/2–13 保持退出 2，脚本 BOM 为 EF BB BF。
- 首次复验因 Windows venv 子进程清理失败而未通过；修复本工具的精确进程树清理后，
  重建 wheel/lock 并重新创建空 venv，以上为最终交付版本的完整成功结果，失败记录保留在 history。
- 仍有 1 条既有上游测试客户端弃用提醒；未屏蔽。迁移、SQL Server、业务和 GLM 不在本次范围。

### 后续业务与团队阻塞

| 编号 | 阻塞内容 | 影响 | 责任人 | 计划到位 |
|---|---|---|---|---|
| BLK-01 | SQL Server 未安装（第二方言） | G1 只能记"部分完成"，不能整体通过 | A 安排 | 待定 |
| BLK-02 | 真实模型账号与配额未验证 | 步骤 8 只能先跑规则降级 | F | 待定 |
| BLK-03 | 教师样本 / 双盲评分人未预约 | G5（≥50 份）无法开始 | A 负责预约 | 待定 |
| BLK-04 | 五名成员环境表未填 | 不能声称"全组环境通过" | 各成员 | 首次会议后 |

## 环境实测记录（2026-10-27，A 机）

| 项 | 结果 |
|---|---|
| Python 3.12.10 | 已装，`py -3.12 --version` 正常；自检报告 `python.ok = true` |
| Node v24.19.0 / npm 11.17.0 | 可用（未纳入自检脚本，靠 `node --version` 人工确认） |
| Git 2.55.0 | 可用；本地初始化无需远端地址，远端发布与六人 clone 另行配置 |
| Docker 29.8.0（Desktop 4.91.0） | 引擎可用；必须先启动 Docker Desktop |
| MySQL 8.0.46 容器 | 七域 + 七测试库齐全，日常账户可连，重启后数据保持 |
| FFmpeg / FFprobe 6.1.1 | 可用；已实测生成 vp8+vorbis webm 并用 FFprobe 探出 3.003 秒 |
| SQL Server | 未安装（BLK-01） |

证据：`artifacts/M0/bootstrap/env-check.json`（由 `app/tools/check-env.py` 生成）

本次 T05–T07 会话补充：当前终端 `py` 不可用、裸 `python` 指向 3.14；已使用
`D:\soft\DevEnv\Python312\python.exe`（3.12.10）创建后端 `.venv`。
历史环境记录不代表每个新终端的 PATH/Launcher 配置均相同。

## 更新方式

1. 每次集成后由 A 更新，写明日期与 commit；
2. 状态只能从"未开始"→"进行中"→"通过"，或标"阻塞"并写清责任人与下一步；
3. 证据必须是可复验的路径或命令输出，不接受"群里说已修"。
