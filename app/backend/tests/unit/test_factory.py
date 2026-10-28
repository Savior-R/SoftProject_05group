"""坏的本机配置不能阻止测试收集；真实应用创建仍须严格校验。"""

import os
import subprocess
import sys
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.factory import create_app

BACKEND = Path(__file__).resolve().parents[2]


def test_invalid_local_configuration_does_not_break_collection(tmp_path: Path) -> None:
    (tmp_path / ".env").write_text("ENV=invalid-local-value\n", encoding="utf-8")
    environment = os.environ.copy()
    environment.update(ENV="prod", JWT_SIGNING_KEY="short", DEBUG="false")
    # 从中立目录使用真实 pytest 收集；不是只验证一次普通 import。
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "import sys; sys.path.insert(0, sys.argv[1]); import pytest; "
            "raise SystemExit(pytest.main(['--collect-only', sys.argv[2], '-q', "
            "'-p', 'no:cacheprovider']))",
            str(BACKEND),
            str(BACKEND / "tests/unit/test_health.py"),
        ],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0
    assert b"test_live_and_openapi_do_not_query_database" in result.stdout
    assert b"ERROR collecting" not in result.stdout + result.stderr


def test_default_application_still_rejects_invalid_production(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("ENV", "prod")
    monkeypatch.setenv("JWT_SIGNING_KEY", "short")
    with pytest.raises(ValidationError, match="至少 32 字符"):
        create_app()
