"""构建项目 wheel，编译带 hash 的第三方锁，组合出唯一安装入口。"""

import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--index-url", default=os.environ.get("PIP_INDEX_URL") or "https://pypi.org/simple"
    )
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if sys.version_info[:2] != (3, 12):
        raise SystemExit("必须使用 Python 3.12 生成并验证锁。")
    environment = dict(os.environ, CUSTOM_COMPILE_COMMAND="python -m tools.build_release")
    subprocess.run(
        [
            sys.executable,
            "-m",
            "piptools",
            "compile",
            "pyproject.toml",
            "--extra",
            "dev",
            "--generate-hashes",
            "--allow-unsafe",
            "--strip-extras",
            "--no-header",
            "--no-emit-index-url",
            "--no-emit-trusted-host",
            "--output-file",
            "requirements.dependencies.lock",
            "--index-url",
            arguments.index_url,
        ],
        cwd=root,
        env=environment,
        check=True,
    )
    subprocess.run(
        [sys.executable, "-m", "build", "--wheel", "--no-isolation", "--outdir", "wheels"],
        cwd=root,
        check=True,
    )
    wheel = root / "wheels" / "ai_teach_backend-0.1.0-py3-none-any.whl"
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    dependencies = (root / "requirements.dependencies.lock").read_text(encoding="utf-8")
    content = (
        "# 生成入口：python -m tools.build_release\n"
        "# 目标：Windows x64 / CPython 3.12；从本目录安装并同时交付 wheels/。\n"
        "# 包含第三方依赖与本项目 wheel；空 venv 只需安装此 lock。\n\n"
        + dependencies.rstrip()
        + f"\n\n./wheels/{wheel.name} --hash=sha256:{digest}\n"
    )
    (root / "requirements.lock").write_text(content, encoding="utf-8", newline="\n")
    print("已生成 requirements.lock 与相对路径 wheel；仍须独立空 venv 验收。")


if __name__ == "__main__":
    main()
