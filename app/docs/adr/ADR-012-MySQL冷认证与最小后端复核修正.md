# ADR-012：MySQL 冷认证与最小后端复核修正

日期：2026-10-28。状态：按用户授权实施复核中可行的修正。

## 决策与边界

1. MySQL 驱动改为 `aiomysql[rsa]`，通过驱动官方 extra 声明 PyMySQL RSA 认证所需
   cryptography，不自行维护一个可能与驱动安全要求冲突的 cryptography 范围。
   非 TLS、认证缓存未命中时需要 RSA；不能概括为所有 MySQL 8 连接都失败。
2. T05 仍可独立验证无库安装。增强后的 Step 1 必须同时具备独立测试库的真实成功证据；
   缺少 TEST_DATABASE_URL 返回非零，不能跳过后将 Step 1 标为通过。
   真库检查在仅安装 lock 的新 venv 中执行，执行真实 HTTP 和 SELECT 1，先校验 RSA
   依赖可导入，避免暖缓存掩盖缺依赖。该检查不证明表结构、迁移或业务已完成。
3. 业务事务继续采用 ADR-010 的同步 SQLAlchemy Session，后续 MySQL/PyODBC 驱动、
   Alembic 和事务测试在步骤 2 实施。现有异步 engine 只用于独立运维探针，不提供业务
   Session，不共享业务事务。ADR-011 不再被解释为全项目已选择异步业务访问。
   不能从一个异步 SELECT 1 推导出禁止同步 Session；SQL Server 的驱动路线也不能省略。
4. 保留本次明确 T06 契约：/health/live、/health/ready 在 OpenAPI 中公开；
   /api/v1/health/* 为隐藏兼容别名，/healthz 为旧 readiness 别名。
   业务 API 使用 /api/v1；运维探针为明确例外。团队指南据此统一。
5. ENV 增加 demo；.env.example 包含团队要求的全部 18 键，另保留 DEBUG 和探针超时。
   完整列出键名不代表未来队列、存储、JWT 或模型业务已经实现。
6. 忽略 build/；共享 fixture 放到 tests/conftest.py；删除尚未纳入门禁的 mypy strict
   配置，保留类型注解。将来增加 mypy 时同时增加依赖、实际类型修正和门禁。
7. Git 可在本地初始化，不需要远端；不自动提交、关联远端或推送。

## 验收

- 重新构建 wheel 和两个 lock；pip check、pytest、Ruff 和源码/wheel 一致性通过。
- 从全新空 venv 仅安装主 lock，在中立目录验证 live=200、无库 ready=503、OpenAPI=200，
  再验证独立测试库 ready=200；记录当前 hash、时间和测试数据库验证范围。
- 用新建的 caching_sha2_password 临时账户验证冷认证，避免重启共享容器或清空全局认证缓存。
- 缺少测试库配置、RSA 依赖缺失、数据库不可达均必须明确失败，不输出 DSN 或真实口令。
- 未实现 Step 0/2–13 仍非零，verify-step.ps1 保持 UTF-8 BOM。
