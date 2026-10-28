# 3.2.0 A1 部署入口

日期：2026-10-28。唯一设计见 [09部署运维](../../设计文档3.x/09-部署运维方案.md)，工程选择见 [ADR-010](../docs/adr/ADR-010-工程实现基线.md)。

当前只有最小后端已完成；正式前端、目标迁移和媒体/评测等业务未完成。此目录统一了部署约定，尚未经过 Docker 构建或 G2/G6，不能当作已验收发布包。

## 固定选择

- Python 3.12，单 API 进程，入口 app.main:app；A1不启动Redis/arq多进程。
- 唯一前端 app/frontend，npm ci 后 npm run build，静态产物 dist 由Caddy提供。
- ENV=dev/demo/staging/prod；正式生产统一prod，staging/prod强制长密钥和禁DEBUG。
- SQL复用已按目标61表及G1准备的实例，不自动导入旧52表DDL，不自动升级存量库。
- 私有媒体只挂载到API的runtime/media，不进入静态根。

## 先交付这些文件

1. frontend/package-lock.json及frontend/dist/index.html，必须由已冻结前端工程实际构建。
2. 在Linux x64/Python3.12环境生成并验证的完整后端发布包，放在deploy/backend-release/requirements.lock及其相对路径wheels/。本项目wheel须与源码一致；锁带hash，在全新Linux环境仅安装该lock并从中立目录启动验证。不能直接把Windows锁标成Linux已通过，参见ADR-010的平台约束。
3. deploy/.env：从本目录样例复制并填写DATABASE_URL。容器不能用127.0.0.1访问宿主SQL；样例说明了host.docker.internal。使用既有库，不运行清库命令。
4. 目标迁移、G1证据及对应业务交付。当前是否就绪以 [实施状态](../IMPLEMENTATION_STATUS.md) 为准。

缺少上述文件时预检必须失败，不创建假前端、假锁或空迁移绕过检查。

## 检查和启动

在本目录的Bash中执行：

```bash
bash deploy.sh --check
# 前置交付及相应门禁确认后，启动既有发布包：
bash deploy.sh --start
```

--check只检查文件存在和Compose配置，不连接数据库或运行迁移。--start构建API镜像并等待readiness，然后启动静态代理；服务只绑定宿主回环端口8000/8080。本脚本不开放公网、不购买资源、不调用模型，也不改变G门禁状态。

## 后续A2/B

A2/B按09另交付Redis+arq、SQL恢复/outbox、私有对象存储、可信HTTPS和TURN，并通过对应故障/容量验证。旧隧道、STATE_BACKEND、DB_URL及旧模型键名已停用。本入口不提供未完成的A2/B发布选项；prod只是环境取值，不代表此A1编排满足生产验收。
