"""T05：创建全新空 venv，只安装 requirements.lock，再做独立启动验证。"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import venv
from datetime import UTC, datetime
from pathlib import Path

from tools.verify_lock import inspect_lock


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument(
        "--index-url", default=os.environ.get("PIP_INDEX_URL") or "https://pypi.org/simple"
    )
    parser.add_argument("--require-database", action="store_true")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    project = root.parents[1]
    evidence = arguments.evidence or project / "artifacts/M0/bootstrap/t05-clean-venv.json"
    if sys.version_info[:2] != (3, 12):
        raise SystemExit("T05 复验必须使用 Python 3.12。")
    lock_result = inspect_lock(root)
    runtime = project / "runtime/backend-verification"
    runtime.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="t05-", dir=runtime))
    target = run_dir / "venv"
    neutral = run_dir / "neutral-cwd"
    neutral.mkdir()
    venv.EnvBuilder(with_pip=True, clear=False).create(target)
    python = target / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    environment = os.environ.copy()
    for key in ("PYTHONPATH", "PYTHONHOME"):
        environment.pop(key, None)
    cache = project / "runtime/pip-cache"
    install_log = run_dir / "install.log"
    print("已创建新的空 venv；开始仅通过 requirements.lock 安装。", flush=True)
    with install_log.open("w", encoding="utf-8") as log:
        installation = subprocess.run(
            [
                str(python),
                "-I",
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "--index-url",
                arguments.index_url,
                "--cache-dir",
                str(cache),
                "--require-hashes",
                "--only-binary=:all:",
                "-r",
                "requirements.lock",
            ],
            cwd=root,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if installation.returncode != 0:
        raise SystemExit(f"T05 空 venv 安装失败，查看脱敏后本地日志：{install_log}")
    checked = subprocess.run(
        [str(python), "-I", "-m", "pip", "check"],
        cwd=neutral,
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )
    smoke_path = run_dir / "http-smoke.json"
    subprocess.run(
        [str(python), "-I", "-m", "tools.smoke", "--output", str(smoke_path)],
        cwd=neutral,
        env=environment,
        check=True,
    )
    database_result = {"status": "not_run", "reason": "仅 T05 无库安装验证；未声明数据库通过。"}
    if arguments.require_database:
        database_path = run_dir / "database-smoke.json"
        # 从调用方 .env 加载，但仅将测试库 DSN 传给子进程，不传共享库或其他密钥。
        from app.settings import Settings

        settings = Settings()
        if settings.test_database_url:
            environment["TEST_DATABASE_URL"] = settings.test_database_url.get_secret_value()
        subprocess.run(
            [str(python), "-I", "-m", "tools.verify_database", "--output", str(database_path)],
            cwd=neutral,
            env=environment,
            check=True,
        )
        database_result = json.loads(database_path.read_text(encoding="utf-8"))
    result = {
        "task": "T05",
        "status": "passed",
        "created_at": datetime.now(UTC).isoformat(),
        "fresh_venv": str(target),
        "neutral_cwd": str(neutral),
        "only_install_command": (
            "python -m pip install --require-hashes --only-binary=:all: -r requirements.lock"
        ),
        "pip_check": checked.stdout.strip(),
        "lock": lock_result,
        "smoke": json.loads(smoke_path.read_text(encoding="utf-8")),
        "install_log": str(install_log),
        "database": database_result,
    }
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"T05 通过：空 venv、pip check、三个已安装包和真实 HTTP；证据：{evidence}")


if __name__ == "__main__":
    main()
