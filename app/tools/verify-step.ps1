[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 13)]
    [int]$Step,
    [string]$PythonExe,
    [string]$PackageIndexUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PackageIndexUrl)) {
    $PackageIndexUrl = $env:PIP_INDEX_URL
}
if ([string]::IsNullOrWhiteSpace($PackageIndexUrl)) {
    $PackageIndexUrl = 'https://pypi.org/simple'
}
$backendRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\backend'))
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

$unimplemented = @{
    0 = '全组机器预检、Git/远端与基线认领尚未实现为可复验门禁；不能只凭本机可用判定通过。'
    2 = '双方言迁移、目标结构、约束负例与 G1 验收尚未实现。'
    3 = '公共业务 DTO、前端骨架与契约一致性检查尚未实现。'
    4 = '身份组织、登录/授权/撤权及权限测试尚未实现。'
    5 = '标准、内容与任务发布的真实链路尚未实现。'
    6 = '课堂状态机、活动时钟、WebSocket 与 RTC 信令尚未实现。'
    7 = '真实媒体采集、分片、封存、续传与私有回放尚未实现。'
    8 = 'submit、持久评测任务、真实 provider 与报告尚未实现。'
    9 = '教师主批、分数版本、统计及导出尚未实现。'
    10 = '真实十分钟链路与全部 P0 联调尚未实现或验收。'
    11 = '训练、模拟考核、成长及证书的完整 P1 尚未实现。'
    12 = 'A2 队列、多人部署、故障恢复和运维演练尚未实现。'
    13 = 'G5/G6、效果、安全、容量、四角色 UAT 与发布验收尚未完成。'
}

if ($unimplemented.ContainsKey($Step)) {
    [Console]::Error.WriteLine(("[未实现] Step {0}：{1}" -f $Step, $unimplemented[$Step]))
    exit 2
}

if ([string]::IsNullOrWhiteSpace($PythonExe)) {
    $PythonExe = Join-Path $backendRoot '.venv\Scripts\python.exe'
}
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
    [Console]::Error.WriteLine('[失败] 缺少后端 Python 3.12 虚拟环境；请先按 backend/README.md 创建并安装 lock。')
    exit 1
}
$PythonExe = (Resolve-Path -LiteralPath $PythonExe).Path

function Invoke-Checked {
    param([string]$Label, [string[]]$Arguments)
    Write-Output ("[执行] {0}" -f $Label)
    & $PythonExe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} 失败，退出码 {1}。" -f $Label, $LASTEXITCODE)
    }
}

$evidenceRoot = Join-Path $projectRoot 'artifacts\M0\bootstrap'
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$runRoot = Join-Path $projectRoot ('runtime\backend-verification\step1-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
Push-Location -LiteralPath $backendRoot
try {
    Invoke-Checked -Label 'Python 3.12 基线' -Arguments @(
        '-c', 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else 1)'
    )
    Invoke-Checked -Label 'T05 lock/项目 wheel 与源码一致' -Arguments @('-m', 'tools.verify_lock')
    Invoke-Checked -Label 'pip check' -Arguments @('-m', 'pip', 'check')
    Invoke-Checked -Label 'T06/T07 单元和脚本负例' -Arguments @(
        '-m', 'pytest', 'tests/unit', '-q',
        '--basetemp', (Join-Path $runRoot 'pytest-tmp'),
        '-o', ('cache_dir=' + (Join-Path $runRoot 'pytest-cache')),
        ('--junitxml=' + (Join-Path $evidenceRoot 't06-t07-pytest.xml'))
    )
    Invoke-Checked -Label 'Ruff lint' -Arguments @(
        '-m', 'ruff', 'check', '.', '--cache-dir', (Join-Path $runRoot 'ruff-cache')
    )
    Invoke-Checked -Label 'Ruff format' -Arguments @(
        '-m', 'ruff', 'format', '--check', '.', '--cache-dir', (Join-Path $runRoot 'ruff-cache')
    )
    Invoke-Checked -Label 'T05 全新空 venv 仅 lock 安装及真实 HTTP' -Arguments @(
        '-m', 'tools.verify_install', '--evidence', (Join-Path $evidenceRoot 't05-clean-venv.json'),
        '--index-url', $PackageIndexUrl, '--require-database'
    )
    $result = [ordered]@{
        step = 1
        status = 'passed'
        verified_at = [DateTime]::UtcNow.ToString('o')
        tasks = @('T05', 'T06', 'T07')
        evidence = @('t05-clean-venv.json', 't06-t07-pytest.xml')
        limitation = '包含独立测试库真实 readiness；仅工程骨架/探针/阶段校验，不代表数据库结构或业务 P0 已完成。'
    }
    $json = $result | ConvertTo-Json -Depth 4
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText((Join-Path $evidenceRoot 't07-step1.json'), $json, $utf8Bom)
    Write-Output '[通过] Step 1：T05/T06/T07 全部检查通过；Step 0 和 Step 2-13 仍未实现。'
}
catch {
    $failure = [ordered]@{
        step = 1
        status = 'failed'
        verified_at = [DateTime]::UtcNow.ToString('o')
        reason = '本轮至少一项检查失败；不得复用旧成功证据宣称本轮通过。'
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText((Join-Path $evidenceRoot 't07-step1.json'), ($failure | ConvertTo-Json), $utf8Bom)
    [Console]::Error.WriteLine('[失败] Step 1：' + $_.Exception.Message)
    exit 1
}
finally {
    Pop-Location
}
exit 0

