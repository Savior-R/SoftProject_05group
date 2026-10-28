"""构建及空环境复验必须按显式参数、环境变量、默认值选择索引。"""

import sys
from pathlib import Path
from unittest.mock import patch

import pytest

from tools import build_release, verify_install


class InstallationIntercepted(Exception):
    """在真正联网或构建之前捕获命令。"""


@pytest.mark.parametrize("module", [build_release, verify_install])
@pytest.mark.parametrize(
    ("environment_index", "arguments", "expected"),
    [
        (None, [], "https://pypi.org/simple"),
        ("https://environment.invalid/simple", [], "https://environment.invalid/simple"),
        (
            "https://environment.invalid/simple",
            ["--index-url", "https://explicit.invalid/simple"],
            "https://explicit.invalid/simple",
        ),
    ],
)
def test_package_index_precedence(
    module,
    environment_index: str | None,
    arguments: list[str],
    expected: str,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    if environment_index is None:
        monkeypatch.delenv("PIP_INDEX_URL", raising=False)
    else:
        monkeypatch.setenv("PIP_INDEX_URL", environment_index)
    monkeypatch.setattr(sys, "argv", [module.__name__, *arguments])
    if module is verify_install:
        # 不安装、不创建真实venv、不读取受保护wheel；只核验实际构造的安装命令。
        monkeypatch.setattr(module, "inspect_lock", lambda root: {"status": "passed"})
        monkeypatch.setattr(module.tempfile, "mkdtemp", lambda **kwargs: str(tmp_path))
        monkeypatch.setattr(module.venv.EnvBuilder, "create", lambda self, path: None)
    with patch.object(module.subprocess, "run", side_effect=InstallationIntercepted) as execute:
        with pytest.raises(InstallationIntercepted):
            module.main()
    command = execute.call_args.args[0]
    assert command[command.index("--index-url") + 1] == expected
