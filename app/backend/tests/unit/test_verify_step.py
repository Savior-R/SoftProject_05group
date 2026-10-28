"""真实启动 PowerShell 验证未实现步骤不会返回成功；核验 UTF-8 BOM。"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[3] / "tools/verify-step.ps1"


def powershell() -> str:
    executable = shutil.which("powershell.exe") or shutil.which("pwsh")
    if executable is None:
        pytest.fail("T07 必须有 PowerShell 实测，不能跳过后视为通过。")
    return executable


def run_step(step: int, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [
            powershell(),
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SCRIPT),
            "-Step",
            str(step),
            *arguments,
        ],
        capture_output=True,
        timeout=30,
        check=False,
    )


def test_script_uses_utf8_bom() -> None:
    content = SCRIPT.read_bytes()
    assert content.startswith(b"\xef\xbb\xbf")
    assert "未实现" in content.decode("utf-8-sig")


@pytest.mark.parametrize("step", [0, *range(2, 14)])
def test_unimplemented_step_is_nonzero_with_reason(step: int) -> None:
    result = run_step(step)
    assert result.returncode == 2
    assert len(result.stderr.strip()) > 20
    assert str(step).encode() in result.stderr
    assert b"[PASS]" not in result.stdout


@pytest.mark.parametrize("step", [-1, 14])
def test_invalid_step_is_nonzero(step: int) -> None:
    assert run_step(step).returncode != 0


def test_missing_python_cannot_pass(tmp_path: Path) -> None:
    result = run_step(1, "-PythonExe", str(tmp_path / "missing-python.exe"))
    assert result.returncode == 1
    assert result.stderr.strip()


@pytest.mark.parametrize(
    ("environment_index", "explicit_index", "expected"),
    [
        (None, None, "https://pypi.org/simple"),
        ("https://environment.invalid/simple", None, "https://environment.invalid/simple"),
        (
            "https://environment.invalid/simple",
            "https://explicit.invalid/simple",
            "https://explicit.invalid/simple",
        ),
    ],
)
def test_script_index_precedence(
    environment_index: str | None, explicit_index: str | None, expected: str
) -> None:
    # 实际运行参数解析与默认值处理；不运行之后的安装、数据库或网络检查。
    header = SCRIPT.read_text(encoding="utf-8-sig").split("$backendRoot =", 1)[0]
    environment = os.environ.copy()
    environment.pop("PIP_INDEX_URL", None)
    if environment_index:
        environment["PIP_INDEX_URL"] = environment_index
    command = "& { " + header + "\nWrite-Output $PackageIndexUrl\n} -Step 1"
    if explicit_index:
        command += " -PackageIndexUrl '" + explicit_index + "'"
    result = subprocess.run(
        [powershell(), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
        env=environment,
        capture_output=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0
    assert result.stdout.strip() == expected.encode()
