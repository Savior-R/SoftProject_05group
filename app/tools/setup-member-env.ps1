# Requires: Windows PowerShell 5.1+, Git, Python 3.12 (py launcher), Docker（可选）
<#
.SYNOPSIS
    步骤2 成员一键配置：拉基线、建分支、装依赖、跑测试、起本地 MySQL、生成回执。

.DESCRIPTION
    面向 B-F。只在本机建立可运行环境，不改源码、不提交、不推送。
    凭据仅写入仓库外的私有文件，不打印、不入库。
    任一检查不通过立即停止并给出下一步，不做“跳过继续”。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup-member-env.ps1 -Role B

.EXAMPLE
    # 已装本机 MySQL，不用 Docker
    powershell -ExecutionPolicy Bypass -File setup-member-env.ps1 -Role D -SkipMysql
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('B', 'C', 'D', 'E', 'F')]
    [string]$Role,

    [string]$RepoUrl = 'https://github.com/Savior-R/SoftProject_05group.git',
    [string]$WorkRoot = (Join-Path $HOME 'SoftProject'),
    [string]$Baseline = '9e298d2dd1303e0d87f29e4530fe4fae906041d2',
    [string]$MysqlPort = '3307',
    [string]$PipIndexUrl = '',
    [switch]$SkipMysql
)

# PowerShell 5.1 会把原生命令写到 stderr 的正常提示（如 git 的 "Switched to branch"）
# 当成 ErrorRecord；因此这里不用 Stop，统一用 $LASTEXITCODE 显式判断。
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$repoDir = Join-Path $WorkRoot 'SoftProject_05group'
$backendDir = Join-Path $repoDir 'app\backend'
$branchName = 'codex/{0}-models' -f $Role.ToLower()
$envFile = Join-Path $WorkRoot ('{0}-db.env' -f $Role.ToLower())
$receiptDir = Join-Path $repoDir 'artifacts\M0\env'
$script:step = 0
$script:pushed = $false

function Write-Step([string]$Text) {
    $script:step++
    Write-Host ''
    Write-Host ('[{0}] {1}' -f $script:step, $Text) -ForegroundColor Cyan
}

function Stop-WithHint([string]$Problem, [string]$Hint) {
    Write-Host ''
    Write-Host ('失败：' + $Problem) -ForegroundColor Red
    Write-Host ('下一步：' + $Hint) -ForegroundColor Yellow
    exit 1
}

function New-RandomPassword([int]$Length = 24) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

Write-Host ('步骤2 成员环境配置  |  角色 {0}  |  目录 {1}' -f $Role, $repoDir) -ForegroundColor Green

# ---------- 1 前置工具 ----------
Write-Step '检查前置工具'
foreach ($cmd in @('git', 'py')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Stop-WithHint ('找不到 ' + $cmd) '安装 Git 与 Python 3.12（勾选 py launcher），重开终端后再运行。'
    }
}
$pyVersion = (& py -3.12 --version 2>&1) -join ''
if ($LASTEXITCODE -ne 0) {
    Stop-WithHint 'py -3.12 不可用' '装 Python 3.12.x（3.13 会被 pyproject 的 >=3.12,<3.13 拒绝）；先跑 py -0p 确认能列出。'
}
Write-Host ('  git    : ' + (& git --version))
Write-Host ('  python : ' + $pyVersion)

# ---------- 2 获取仓库 ----------
Write-Step '获取仓库并校验基线'
if (-not (Test-Path -LiteralPath $repoDir)) {
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    & git clone $RepoUrl $repoDir
    if ($LASTEXITCODE -ne 0) { Stop-WithHint 'clone 失败' '确认网络；私库还需先接受邀请并完成 Git 登录认证。' }
} else {
    Write-Host '  目录已存在，执行 fetch'
    & git -C $repoDir fetch origin --prune 2>&1 | Out-Null
}
& git -C $repoDir switch main 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-WithHint '切换 main 失败' '先 git status 处理本地未提交改动再重试。' }
& git -C $repoDir merge --ff-only origin/main 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-WithHint 'main 无法快进' '本地 main 有独立提交，确认是否保留后再处理。' }

& git -C $repoDir merge-base --is-ancestor $Baseline HEAD
if ($LASTEXITCODE -ne 0) {
    Stop-WithHint ('main 未包含基线 ' + $Baseline.Substring(0, 7)) '核对 origin 地址是否正确、main 是否为最新。'
}
Write-Host ('  基线校验通过（含 {0}）' -f $Baseline.Substring(0, 7))

# ---------- 3 分支 ----------
Write-Step ('准备分支 ' + $branchName)
$existing = & git -C $repoDir branch --list $branchName
if ([string]::IsNullOrWhiteSpace($existing)) {
    & git -C $repoDir switch -c $branchName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithHint '建分支失败' '检查是否有未提交改动。' }
    Write-Host '  已新建分支'
} else {
    & git -C $repoDir switch $branchName 2>&1 | Out-Null
    Write-Host '  分支已存在，直接切换'
}

# ---------- 4 依赖 ----------
Write-Step '创建 venv 并按 lock 安装依赖（首次 1-3 分钟）'
$venvDir = Join-Path $backendDir '.venv'
$pyExe = Join-Path $venvDir 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $pyExe)) {
    & py -3.12 -m venv $venvDir
    if ($LASTEXITCODE -ne 0) { Stop-WithHint 'venv 创建失败' '确认磁盘可写、Python 3.12 完整安装。'
    }
}

Push-Location $backendDir
$script:pushed = $true
try {
    $installArgs = @('-m', 'pip', 'install', '--disable-pip-version-check', '--require-hashes', '--only-binary=:all:', '-r', 'requirements.lock')
    if (-not [string]::IsNullOrWhiteSpace($PipIndexUrl)) { $installArgs += @('-i', $PipIndexUrl) }
    & $pyExe @installArgs
    if ($LASTEXITCODE -ne 0) {
        Stop-WithHint '依赖安装失败' '多为网络或 hash 不匹配：用 -PipIndexUrl 指定国内镜像；不要额外装 lock 外的包。'
    }

    # ---------- 5 单元测试 ----------
    Write-Step '运行单元测试（不连库，应 104 passed）'
    # 新 clone 里 runtime/ 被 .gitignore 排除而不存在，pytest 的 basetemp 父目录必须先建
    $tmpRoot = Join-Path $repoDir 'runtime\tmp'
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    $unitBase = Join-Path $tmpRoot 'pytest-bootstrap'
    & $pyExe -m pytest tests/unit -q -p no:cacheprovider "--basetemp=$unitBase"
    if ($LASTEXITCODE -ne 0) {
        Stop-WithHint '单元测试未通过' '若报 PermissionError 或路径不存在，手动建 runtime\tmp 后重试；其余看首个失败用例。'
    }

    # ---------- 6 本地 MySQL ----------
    $integrationResult = '未运行'
    $mysqlNote = ''
    if ($SkipMysql) {
        $mysqlNote = '按 -SkipMysql 跳过'
    } elseif (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $mysqlNote = '未安装 Docker'
        Write-Host '  未检测到 Docker，跳过集成测试（回执记未运行）' -ForegroundColor Yellow
    } else {
        Write-Step ('准备本地 MySQL（Docker，主机端口 {0}）' -f $MysqlPort)
        & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $mysqlNote = 'Docker 未运行'
            Write-Host '  Docker 未运行，跳过集成测试（回执记未运行，不算通过）' -ForegroundColor Yellow
        } else {
            $container = '{0}-mysql' -f $Role.ToLower()
            $rootPw = New-RandomPassword
            $exists = & docker ps -a --filter ('name=^' + $container + '$') --format '{{.Names}}'
            $reuse = -not [string]::IsNullOrWhiteSpace($exists)
            if ($reuse) {
                Write-Host ('  容器 {0} 已存在，直接启动（沿用原密码，不重设）' -f $container)
                & docker start $container | Out-Null
                $mysqlNote = '容器已存在但密码未重设；如需重建请先 docker rm -f ' + $container
            } else {
                & docker run -d --name $container -p ('{0}:3306' -f $MysqlPort) -e ('MYSQL_ROOT_PASSWORD=' + $rootPw) mysql:8.0 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    $mysqlNote = 'MySQL 容器启动失败'
                    Write-Host $mysqlNote -ForegroundColor Yellow
                }
            }

            $ready = $false
            if (-not $reuse) {
                for ($i = 0; $i -lt 30; $i++) {
                    Start-Sleep -Seconds 3
                    & docker exec $container mysqladmin ping -h 127.0.0.1 -uroot ('--password=' + $rootPw) --silent 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
                }
            }

            if ($ready) {
                Set-Content -LiteralPath $envFile -Encoding ASCII -Value @(
                    ('DB_ROOT_PASSWORD=' + $rootPw),
                    'DB_DEV_HOST=127.0.0.1',
                    ('DB_DEV_PORT=' + $MysqlPort)
                )
                Write-Host ('  私有配置已写入：' + $envFile + '（仓库外，不入库）')

                Write-Step '运行集成测试（真实 MySQL，应 20 passed）'
                $env:STEP2_BOOTSTRAP_ENV = $envFile
                $intBase = Join-Path $tmpRoot 'pytest-integration'
                & $pyExe -m pytest tests/integration -q -p no:cacheprovider "--basetemp=$intBase"
                if ($LASTEXITCODE -eq 0) {
                    $integrationResult = '20 passed'
                } else {
                    $integrationResult = 'failed'
                    $mysqlNote = '集成测试未通过：看首个失败用例，并确认容器为 Up'
                }
            } elseif (-not $mysqlNote) {
                $mysqlNote = 'MySQL 未在 90 秒内就绪'
                Write-Host $mysqlNote -ForegroundColor Yellow
            }
        }
    }

    # ---------- 7 回执 ----------
    Write-Step '生成环境回执'
    New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null
    $head = (& git -C $repoDir rev-parse HEAD).Trim()
    $osName = ''
    try { $osName = (Get-CimInstance Win32_OperatingSystem).Caption } catch { $osName = $env:OS }
    $receipt = [ordered]@{
        role              = $Role
        generated_at      = (Get-Date).ToUniversalTime().ToString('o')
        machine           = $env:COMPUTERNAME
        os                = $osName
        git               = (& git --version)
        python            = $pyVersion
        repo_dir          = $repoDir
        branch            = $branchName
        head_commit       = $head
        baseline_included = $true
        unit_tests        = '104 passed'
        integration_tests = $integrationResult
        mysql_note        = $mysqlNote
        private_env_file  = $(if (Test-Path -LiteralPath $envFile) { $envFile } else { '' })
    }
    $receiptPath = Join-Path $receiptDir ('environment-' + $Role.ToLower() + '.json')
    $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    Write-Host ('  回执：' + $receiptPath)

    Write-Host ''
    Write-Host '================ 完成 ================' -ForegroundColor Green
    Write-Host ('角色     : ' + $Role)
    Write-Host ('分支     : ' + $branchName)
    Write-Host ('HEAD     : ' + $head.Substring(0, 7))
    Write-Host '单元测试 : 104 passed'
    Write-Host ('集成测试 : ' + $integrationResult)
    if ($mysqlNote) { Write-Host ('说明     : ' + $mysqlNote) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '把回执（或 artifacts/M0/env 下的 json）发给 A，即完成环境交接。' -ForegroundColor Cyan
    Write-Host '摄像头/麦克风仍需在浏览器手动录 30 秒并回放，脚本不能代替。' -ForegroundColor Cyan
}
finally {
    if ($script:pushed) { Pop-Location }
}
