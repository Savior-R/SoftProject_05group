# 师范专业 AI 试讲台系统

## 唯一设计基准

自 2026-10-28 起，项目唯一采用 [设计文档3.x/00-README.md](设计文档3.x/00-README.md) 的 **3.2.0** 设计包。旧设计、提交快照、模板和已被替代的审查建议不再保留为开发依据。

- 业务需求、数据库、API 与验收：设计文档3.x/01–12。
- 六人分工和实施顺序：设计文档3.x/团队开发文档/13、14。
- 工程选择：app/docs/adr/ADR-010、ADR-011、ADR-012，在各自范围内细化基准。
- 当前实施进度：[app/IMPLEMENTATION_STATUS.md](app/IMPLEMENTATION_STATUS.md)。文档统一不代表业务或 G1–G6 已通过。

## 已冻结的实施选择

1. 先完成 A1 模块化单体：单 API、同进程调度，SQL 持久待办；A2/B 按门禁另行验证。
2. Python 3.12；后端依赖和本项目 wheel 以 app/backend/requirements.lock 锁定。
3. 唯一正式前端为 app/frontend/（Vue 3 + TypeScript + Vite），构建产物为 dist/。
4. ENV 取值为 dev/demo/staging/prod；正式生产统一使用 prod。
5. 数据库目标为 61 表，先完成MySQL G1；仅支持全新空库初始化，取消旧52表升级及历史数据导入；历史SQL、模型和生成器不再是开发输入。

## 开发与部署入口

- [应用工程](app/README.md)
- [部署说明](app/deploy/README.md)
- [设计验收门禁](设计文档3.x/12-修订追踪与验收门禁.md)
- [基准统一与清理记录](基准统一与清理记录.md)

当前最小后端只提供骨架与健康检查。前端、目标迁移、媒体和评测等业务按实施状态逐项交付，不能用健康检查代替完整业务验收。
