# =============================================================
# 初始化 A1 开发数据库（Docker 容器形态）
# 用法：在项目根目录执行  .\app\tools\init-dev-db.ps1
# 幂等：容器已存在则只启动；库已存在则跳过；用户已存在则改口令
# 维护人：A
# =============================================================
[CmdletBinding()]
param(
    [string]$ContainerName = 'ai-teach-mysql',
    [string]$Image = 'mysql:8.0'
)

# 原生命令的 stderr（如 MySQL 的口令警告）不应终止脚本，统一按退出码判断
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$envFile = Join-Path $root 'runtime\local-db.env'
$sqlFile = Join-Path $PSScriptRoot 'sql\init-dev-databases.sql'
$dataDir = Join-Path $root 'runtime\mysql-data'

if (-not (Test-Path -LiteralPath $envFile)) { throw "缺少凭据文件：$envFile" }
if (-not (Test-Path -LiteralPath $sqlFile)) { throw "缺少建库脚本：$sqlFile" }

$conf = @{}
Get-Content -LiteralPath $envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $conf[$Matches[1]] = $Matches[2].Trim() }
}
foreach ($k in @('DB_DEV_USER','DB_DEV_PASSWORD','DB_ROOT_PASSWORD','DB_DEV_PORT')) {
    if (-not $conf.ContainsKey($k)) { throw "凭据文件缺少键：$k" }
}

$port = $conf['DB_DEV_PORT']
$rootPw = $conf['DB_ROOT_PASSWORD']

# 1) 引擎是否可用
docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker 引擎未就绪，请先启动 Docker Desktop' }

# 2) 容器：不存在则创建，存在则启动
$exists = docker ps -a --filter "name=^/$ContainerName$" --format '{{.Names}}'
if (-not $exists) {
    Write-Output "创建容器 $ContainerName（端口 $port，数据目录 runtime\mysql-data）"
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
    docker run -d --name $ContainerName --restart unless-stopped `
        -p "${port}:3306" `
        -e "MYSQL_ROOT_PASSWORD=$rootPw" `
        -e 'MYSQL_ROOT_HOST=%' `
        -v "${dataDir}:/var/lib/mysql" `
        $Image | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '容器创建失败，检查端口是否被占用' }
    Write-Output '首次启动需要初始化数据目录，请耐心等待'
} else {
    $running = docker ps --filter "name=^/$ContainerName$" --format '{{.Names}}'
    if (-not $running) { docker start $ContainerName | Out-Null; Write-Output '已启动已有容器' }
    else { Write-Output '容器已在运行' }
}

# 3) 等 MySQL 真正可用
Write-Output '等待 MySQL 就绪...'
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    docker exec $ContainerName mysqladmin ping -uroot "-p$rootPw" --silent 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 3
}
if (-not $ready) { throw 'MySQL 未在预期时间内就绪，查看日志：docker logs ' + $ContainerName }

# 4) 建库：拷进容器后由容器内 shell 重定向执行，避免 PowerShell 重定向差异
docker cp $sqlFile "${ContainerName}:/tmp/init-dev-databases.sql" | Out-Null
docker exec $ContainerName sh -c "mysql -uroot -p'$rootPw' < /tmp/init-dev-databases.sql"
if ($LASTEXITCODE -ne 0) { throw '建库失败，请查看上面的 mysql 输出' }

# 5) 建/改日常账户并授权
$devUser = $conf['DB_DEV_USER']
$devPw = $conf['DB_DEV_PASSWORD']
$grantSql = @"
CREATE USER IF NOT EXISTS '$devUser'@'%' IDENTIFIED BY '$devPw';
ALTER USER '$devUser'@'%' IDENTIFIED BY '$devPw';
GRANT ALL PRIVILEGES ON ``identity_org``.* TO '$devUser'@'%';
GRANT ALL PRIVILEGES ON ``task_content``.* TO '$devUser'@'%';
GRANT ALL PRIVILEGES ON ``classroom``.* TO '$devUser'@'%';
GRANT ALL PRIVILEGES ON ``media``.* TO '$devUser'@'%';
GRANT ALL PRIVILEGES ON ``evaluation``.* TO '$devUser'@'%';
GRANT ALL PRIVILEGES ON ``growth_cert``.* TO '$devUser'@'%';
GRANT ALL PRIVILEGES ON ``platform``.* TO '$devUser'@'%';
GRANT ALL PRIVILEGES ON ``test\_%``.* TO '$devUser'@'%';
FLUSH PRIVILEGES;
"@
$grantFile = Join-Path $root 'runtime\tmp\grant-dev.sql'
# 纯 ASCII 内容，避免 BOM 让 mysql 客户端报语法错误
Set-Content -LiteralPath $grantFile -Value $grantSql -Encoding ASCII
docker cp $grantFile "${ContainerName}:/tmp/grant-dev.sql" | Out-Null
docker exec $ContainerName sh -c "mysql -uroot -p'$rootPw' < /tmp/grant-dev.sql"
if ($LASTEXITCODE -ne 0) { throw '账户授权失败，请查看上面的 mysql 输出' }

# 6) 用日常账户回连验证
Write-Output '--- 用日常账户验证七库 ---'
docker exec $ContainerName sh -c "mysql -u$devUser -p'$devPw' -e 'SHOW DATABASES;'"

Write-Output ''
Write-Output '完成。连接信息见 runtime\local-db.env（该文件不入库）'
