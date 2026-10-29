#Requires -Version 5.1
<#
.SYNOPSIS
    一键配置开发环境（幂等）：已有的跳过，缺的自动装，最后给状态表。

.DESCRIPTION
    面向 Windows x64 团队成员。按顺序处理：Git → Python 3.12 → 仓库 → 分支 → venv → 依赖 → 单元测试 → MySQL → 集成测试 → 回执。
    任一步已满足则明确打印“已存在，跳过”，不重复安装、不重复创建、不覆盖数据。

    自动安装依赖 winget（Win10 1809+ / Win11 自带）。没有 winget 时只报告缺什么，不猜测下载地址。
    Docker Desktop 不默认安装：需要管理员权限、WSL2、通常要重启；用 -WithDocker 显式开启尝试。

    不做的事：不给 GitHub 权限，不填摄像头/麦克风实测，不提交任何代码，不打印口令。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup-member-env.ps1 -Role B

.EXAMPLE
    # 只想检查，不安装任何东西
    powershell -ExecutionPolicy Bypass -File setup-member-env.ps1 -Role C -NoInstall

.EXAMPLE
    # 允许尝试安装 Docker Desktop（需管理员，可能要重启）
    powershell -ExecutionPolicy Bypass -File setup-member-env.ps1 -Role D -WithDocker
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
    [switch]$NoInstall,
    [switch]$WithDocker,
    [switch]$SkipMysql
)

# PS 5.1 会把原生命令写到 stderr 的正常提示（如 git 的 "Switched to branch"）当成 ErrorRecord，
# 因此不用 Stop，统一用 $LASTEXITCODE 判断。
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$repoDir = Join-Path $WorkRoot 'SoftProject_05group'
$backendDir = Join-Path $repoDir 'app\backend'
$branchName = 'codex/{0}-models' -f $Role.ToLower()
$envFile = Join-Path $WorkRoot ('{0}-db.env' -f $Role.ToLower())
$receiptDir = Join-Path $repoDir 'artifacts\M0\env'
$script:step = 0
$script:pushed = $false
$script:status = New-Object System.Collections.ArrayList

function Write-Step([string]$Text) {
    $script:step++
    Write-Host ''
    Write-Host ('[{0}] {1}' -f $script:step, $Text) -ForegroundColor Cyan
}

function Stop-WithHint([string]$Problem, [string]$Hint) {
    Write-Host ''
    Write-Host ('失败：' + $Problem) -ForegroundColor Red
    Write-Host ('下一步：' + $Hint) -ForegroundColor Yellow
    Show-Summary
    exit 1
}

function Add-Status([string]$Item, [string]$State, [string]$Detail) {
    [void]$script:status.Add([pscustomobject]@{ Item = $Item; State = $State; Detail = $Detail })
    $color = switch ($State) {
        '已有' { 'DarkGray' }
        '已安装' { 'Green' }
        '已完成' { 'Green' }
        '通过' { 'Green' }
        '跳过' { 'Yellow' }
        default { 'White' }
    }
    Write-Host ('  -> {0}：{1}' -f $State, $Detail) -ForegroundColor $color
}

function Show-Summary {
    if ($script:status.Count -eq 0) { return }
    Write-Host ''
    Write-Host '================ 环境状态 ================' -ForegroundColor Cyan
    $script:status |
        Select-Object @{ n = '组件'; e = { $_.Item } }, @{ n = '状态'; e = { $_.State } }, @{ n = '详情'; e = { $_.Detail } } |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Get-Python312Version {
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) { return $null }
    $out = (& py -3.12 --version 2>&1) -join ''
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out.Trim()
}

function Install-WithWinget([string]$PackageId, [string]$Label) {
    if ($NoInstall) {
        Write-Host ('  缺 {0}；当前为 -NoInstall，不自动安装' -f $Label) -ForegroundColor Yellow
        return $false
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host '  未检测到 winget，无法自动安装（Win10 1809 以下或精简系统常见）' -ForegroundColor Yellow
        return $false
    }
    Write-Host ('  正在用 winget 安装 {0}（可能需要几分钟）...' -f $Label) -ForegroundColor Yellow
    & winget install --exact --id $PackageId --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  默认安装未成功，尝试逐用户范围重试...' -ForegroundColor Yellow
        & winget install --exact --id $PackageId --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    }
    Update-SessionPath
    return $true
}

function New-RandomPassword([int]$Length = 24) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

Write-Host ('一键环境配置  |  角色 {0}  |  目录 {1}' -f $Role, $repoDir) -ForegroundColor Green
if ($NoInstall) { Write-Host '模式：只检查，不安装（-NoInstall）' -ForegroundColor Yellow }

# ---------- 1 Git ----------
Write-Step 'Git'
if (Get-Command git -ErrorAction SilentlyContinue) {
    Add-Status 'Git' '已有' ((& git --version) -replace '^git version ', '')
} else {
    Install-WithWinget 'Git.Git' 'Git' | Out-Null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Add-Status 'Git' '已安装' ((& git --version) -replace '^git version ', '')
    } else {
        Stop-WithHint 'Git 不可用' '手动装 Git for Windows（https://git-scm.com/download/win），装完重开终端再跑。'
    }
}

# ---------- 2 Python 3.12 ----------
Write-Step 'Python 3.12'
$pyVersion = Get-Python312Version
if ($pyVersion) {
    Add-Status 'Python 3.12' '已有' $pyVersion
} else {
    Install-WithWinget 'Python.Python.3.12' 'Python 3.12' | Out-Null
    $pyVersion = Get-Python312Version
    if ($pyVersion) {
        Add-Status 'Python 3.12' '已安装' $pyVersion
    } else {
        Stop-WithHint 'py -3.12 不可用' '装 Python 3.12.x（3.13 会被 pyproject 的 >=3.12,<3.13 拒绝），勾选 py launcher；装完重开终端。'
    }
}

# ---------- 3 仓库 ----------
Write-Step '仓库'
if (-not (Test-Path -LiteralPath $repoDir)) {
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    & git clone $RepoUrl $repoDir
    if ($LASTEXITCODE -ne 0) { Stop-WithHint 'clone 失败' '确认网络；私库还需先接受邀请并完成 Git 登录认证。' }
    Add-Status '仓库' '已完成' ('已克隆到 ' + $repoDir)
} else {
    & git -C $repoDir fetch origin --prune 2>&1 | Out-Null
    Add-Status '仓库' '已有' ('复用 ' + $repoDir)
}

& git -C $repoDir switch main 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-WithHint '切换 main 失败' '先 git status 处理本地未提交改动再重试。' }
& git -C $repoDir merge --ff-only origin/main 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-WithHint 'main 无法快进' '本地 main 有独立提交，确认是否保留后再处理。' }

& git -C $repoDir merge-base --is-ancestor $Baseline HEAD
if ($LASTEXITCODE -ne 0) {
    Stop-WithHint ('main 未包含基线 ' + $Baseline.Substring(0, 7)) '核对 origin 地址与 main 最新提交，可能不是预期仓库。'
}
Add-Status '基线校验' '通过' ('含 ' + $Baseline.Substring(0, 7))

# ---------- 4 分支 ----------
Write-Step ('分支 ' + $branchName)
$existingBranch = & git -C $repoDir branch --list $branchName
if ([string]::IsNullOrWhiteSpace($existingBranch)) {
    & git -C $repoDir switch -c $branchName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithHint '建分支失败' '检查是否有未提交改动。' }
    Add-Status '分支' '已完成' ('新建 ' + $branchName)
} else {
    & git -C $repoDir switch $branchName 2>&1 | Out-Null
    Add-Status '分支' '已有' ('切换到 ' + $branchName)
}

# ---------- 5 venv ----------
Write-Step '虚拟环境'
$venvDir = Join-Path $backendDir '.venv'
$pyExe = Join-Path $venvDir 'Scripts\python.exe'
if (Test-Path -LiteralPath $pyExe) {
    Add-Status 'venv' '已有' $venvDir
} else {
    & py -3.12 -m venv $venvDir
    if ($LASTEXITCODE -ne 0) { Stop-WithHint 'venv 创建失败' '确认磁盘可写、Python 3.12 完整安装。' }
    Add-Status 'venv' '已完成' $venvDir
}

Push-Location $backendDir
$script:pushed = $true
try {
    # ---------- 6 依赖 ----------
    Write-Step '依赖（按 lock 安装）'
    $installArgs = @('-m', 'pip', 'install', '--disable-pip-version-check', '--require-hashes', '--only-binary=:all:', '-r', 'requirements.lock')
    if (-not [string]::IsNullOrWhiteSpace($PipIndexUrl)) { $installArgs += @('-i', $PipIndexUrl) }
    $pipOut = (& $pyExe @installArgs 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Host $pipOut
        Stop-WithHint '依赖安装失败' '多为网络或 hash 不匹配：用 -PipIndexUrl 指定国内镜像；不要安装 lock 外的包。'
    }
    if ($pipOut -match 'Requirement already satisfied' -and $pipOut -notmatch 'Successfully installed') {
        Add-Status '依赖' '已有' 'lock 内全部已满足'
    } else {
        Add-Status '依赖' '已完成' '按 requirements.lock 安装'
    }

    # ---------- 7 单元测试 ----------
    Write-Step '单元测试'
    $tmpRoot = Join-Path $repoDir 'runtime\tmp'
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    $unitBase = Join-Path $tmpRoot 'pytest-bootstrap'
    $unitOut = (& $pyExe -m pytest tests/unit -q -p no:cacheprovider "--basetemp=$unitBase" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Host $unitOut
        Stop-WithHint '单元测试未通过' '看首个失败用例；若报路径/权限错误，手动建 runtime\tmp 后重试。'
    }
    $unitLine = ($unitOut -split "`n" | Where-Object { $_ -match 'passed' } | Select-Object -Last 1)
    Add-Status '单元测试' '通过' $unitLine.Trim()

    # ---------- 8 MySQL ----------
    $integrationState = '跳过'
    $integrationDetail = ''
    $mysqlNote = ''
    if ($SkipMysql) {
        $integrationDetail = '按 -SkipMysql 跳过'
        Add-Status '集成测试' '跳过' $integrationDetail
    } elseif (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        if ($WithDocker) {
            Install-WithWinget 'Docker.DockerDesktop' 'Docker Desktop' | Out-Null
            Write-Host '  Docker Desktop 安装后通常需要重启并启用 WSL2；本次不继续等待。' -ForegroundColor Yellow
        }
        $integrationDetail = '未安装 Docker'
        $mysqlNote = '未安装 Docker；集成测试未运行'
        Add-Status 'Docker' '跳过' '未安装（加 -WithDocker 可尝试安装，需管理员并可能重启）'
        Add-Status '集成测试' '跳过' $integrationDetail
    } else {
        Write-Step ('MySQL（Docker，主机端口 {0}）' -f $MysqlPort)
        & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Add-Status 'Docker' '跳过' '引擎未启动，请打开 Docker Desktop 后重跑'
            Add-Status '集成测试' '跳过' 'Docker 未运行'
            $mysqlNote = 'Docker 未运行；集成测试未运行'
        } else {
            $container = '{0}-mysql' -f $Role.ToLower()
            $exists = & docker ps -a --filter ('name=^' + $container + '$') --format '{{.Names}}'
            $reuse = -not [string]::IsNullOrWhiteSpace($exists)
            $rootPw = New-RandomPassword
            $ready = $false
            if ($reuse) {
                & docker start $container 2>&1 | Out-Null
                if (Test-Path -LiteralPath $envFile) {
                    $ready = $true
                    Add-Status 'MySQL 容器' '已有' ($container + '（复用原密码配置）')
                } else {
                    Add-Status 'MySQL 容器' '已有' ($container + '（密码未知，需 docker rm -f ' + $container + ' 后重跑）')
                    $mysqlNote = '容器已存在但私有配置缺失；集成测试未运行'
                }
            } else {
                & docker run -d --name $container -p ('{0}:3306' -f $MysqlPort) -e ('MYSQL_ROOT_PASSWORD=' + $rootPw) mysql:8.0 | Out-Null
                for ($i = 0; $i -lt 30; $i++) {
                    Start-Sleep -Seconds 3
                    & docker exec $container mysqladmin ping -h 127.0.0.1 -uroot ('--password=' + $rootPw) --silent 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
                }
                if ($ready) {
                    Set-Content -LiteralPath $envFile -Encoding ASCII -Value @(
                        ('DB_ROOT_PASSWORD=' + $rootPw),
                        'DB_DEV_HOST=127.0.0.1',
                        ('DB_DEV_PORT=' + $MysqlPort)
                    )
                    Add-Status 'MySQL 容器' '已完成' ($container + '，端口 ' + $MysqlPort)
                } else {
                    Add-Status 'MySQL 容器' '跳过' '90 秒内未就绪'
                    $mysqlNote = 'MySQL 未就绪；集成测试未运行'
                }
            }

            if ($ready -and (Test-Path -LiteralPath $envFile)) {
                Write-Step '集成测试'
                $env:STEP2_BOOTSTRAP_ENV = $envFile
                $intBase = Join-Path $tmpRoot 'pytest-integration'
                $intOut = (& $pyExe -m pytest tests/integration -q -p no:cacheprovider "--basetemp=$intBase" 2>&1) -join "`n"
                if ($LASTEXITCODE -eq 0) {
                    $intLine = ($intOut -split "`n" | Where-Object { $_ -match 'passed' } | Select-Object -Last 1)
                    Add-Status '集成测试' '通过' $intLine.Trim()
                    $integrationState = '通过'
                } else {
                    Write-Host (($intOut -split "`n" | Select-Object -Last 12) -join "`n")
                    Add-Status '集成测试' '跳过' '未通过，见上方输出'
                    $mysqlNote = '集成测试未通过'
                }
            } else {
                Add-Status '集成测试' '跳过' '缺少可用的 MySQL 私有配置'
            }
        }
    }

    # ---------- 9 回执 ----------
    Write-Step '回执'
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
        unit_tests        = $(if ($unitLine) { $unitLine.Trim() } else { 'unknown' })
        integration_tests = $integrationState
        mysql_note        = $mysqlNote
        private_env_file  = $(if (Test-Path -LiteralPath $envFile) { $envFile } else { '' })
        steps             = $script:status
    }
    $receiptPath = Join-Path $receiptDir ('environment-' + $Role.ToLower() + '.json')
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    Add-Status '回执' '已完成' $receiptPath

    Show-Summary
    Write-Host ''
    if ($integrationState -eq '通过') {
        Write-Host '环境已完整就绪：可以写模型并运行约束负例测试。' -ForegroundColor Green
    } else {
        Write-Host '环境只到“能写模型、能跑单测”这一层；要交约束负例测试，需让集成测试通过。' -ForegroundColor Yellow
    }
    Write-Host '仍需人工完成：GitHub Write 权限、摄像头/麦克风实测 30 秒并回放。' -ForegroundColor Cyan
    Write-Host '把回执（artifacts/M0/env 下的 json）发给 A，即完成环境交接。' -ForegroundColor Cyan
}
finally {
    if ($script:pushed) { Pop-Location }
}
