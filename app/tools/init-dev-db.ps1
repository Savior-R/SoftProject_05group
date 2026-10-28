# 旧宽权限数据库初始化入口已停用。维护人：A。
# 不修改现有库/账号，不执行GRANT ALL、ALTER USER或删库。
[CmdletBinding()]
param(
    [string]$ContainerName = 'ai-teach-mysql',
    [string]$Image = 'mysql:8.0'
)
[Console]::Error.WriteLine('[已停用] 旧初始化会破坏业务/迁移最小权限边界，不再执行。')
[Console]::Error.WriteLine('日常容器启动请执行 docker start ai-teach-mysql；不会重新授权。')
[Console]::Error.WriteLine('新建隔离七库请从app/backend运行 python -m tools.bootstrap_db 先预览。')
[Console]::Error.WriteLine('完整说明：app/docs/步骤2-A公共数据库基础与交接.md。已有库/账号须人工交接，禁止覆盖。')
exit 2
