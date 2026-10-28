"""从已安装的包启动真实 Uvicorn，验证 HTTP 和启动日志，不读取实际 secret。"""

import argparse
import importlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

from sqlalchemy.engine import make_url


def get_json(url: str) -> tuple[int, dict[str, object]]:
    try:
        with urlopen(url, timeout=2) as response:
            return response.status, json.load(response)
    except HTTPError as error:
        return error.code, json.load(error)


def stop_server(process: subprocess.Popen[bytes]) -> None:
    """只停止本工具创建的服务；Windows venv 启动器可能还有真正的 Python 子进程。"""
    if process.poll() is None:
        if os.name == "nt":
            stopped = subprocess.run(
                ["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                capture_output=True,
                check=False,
            )
            if stopped.returncode != 0 and process.poll() is None:
                raise RuntimeError("本次 HTTP 测试进程树清理失败。")
        else:
            process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def run_smoke(database_url: str | None = None) -> dict[str, object]:
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError("T05/T06 必须在 Python 3.12 运行。")
    modules: dict[str, str] = {}
    for name in ("app", "common", "tools"):
        module = importlib.import_module(name)
        path = Path(module.__file__).resolve()
        if not path.is_relative_to(Path(sys.prefix).resolve()):
            raise RuntimeError(f"{name} 来自源码而非新 venv 的已安装包。")
        modules[name] = str(path)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    environment = os.environ.copy()
    for key in ("PYTHONPATH", "PYTHONHOME"):
        environment.pop(key, None)
    secret_values = ["SMOKE_FAKE_JWT_" + "x" * 40, "SMOKE_FAKE_GLM_" + "y" * 40]
    if database_url is not None:
        secret_values.append(database_url)
        password = make_url(database_url).password
        if password:
            secret_values.append(password)
    environment.update(
        ENV="dev",
        DEBUG="false",
        DATABASE_URL=database_url or "",
        READINESS_TIMEOUT_S="5" if database_url else "0.2",
        JWT_SIGNING_KEY=secret_values[0],
        GLM_API_KEY=secret_values[1],
    )
    with tempfile.TemporaryDirectory(prefix="ai-teach-http-") as directory:
        workdir = Path(directory)
        log_path = workdir / "server.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-I",
                    "-m",
                    "uvicorn",
                    "app.main:app",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port),
                    "--workers",
                    "1",
                ],
                cwd=workdir,
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                base = f"http://127.0.0.1:{port}"
                deadline = time.monotonic() + 25
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(
                            "真实 HTTP 服务启动失败；未输出可能含 secret 的日志原文。"
                        )
                    try:
                        live_code, _ = get_json(base + "/health/live")
                        break
                    except (OSError, URLError):
                        if time.monotonic() >= deadline:
                            raise RuntimeError("真实 HTTP 服务启动超时。") from None
                        time.sleep(0.1)
                ready_code, ready = get_json(base + "/health/ready")
                openapi_code, specification = get_json(base + "/openapi.json")
                alias_code, _ = get_json(base + "/healthz")
                expected_code = 200 if database_url else 503
                if (live_code, ready_code, openapi_code, alias_code) != (
                    200,
                    expected_code,
                    200,
                    expected_code,
                ):
                    raise RuntimeError("真实 HTTP 存活/就绪/OpenAPI/兼容路径状态码不符合要求。")
                expected_ready = {
                    "status": "ready" if database_url else "not_ready",
                    "checks": {"database": "ok" if database_url else "not_configured"},
                }
                if ready != expected_ready:
                    raise RuntimeError("数据库 readiness 响应不符合要求。")
                for path in ("/api/v1/health/live", "/api/v1/health/ready"):
                    code, _ = get_json(base + path)
                    if code != (200 if path.endswith("live") else expected_code):
                        raise RuntimeError("版本前缀兼容路径状态码不符合要求。")
                if not {"/health/live", "/health/ready"} <= set(specification["paths"]):
                    raise RuntimeError("OpenAPI 缺少健康检查主路径。")
            finally:
                stop_server(process)
        startup_log = log_path.read_text(encoding="utf-8", errors="replace")
        if any(secret in startup_log for secret in secret_values):
            raise RuntimeError("启动日志泄漏测试用 secret。")
        if "Application startup complete" not in startup_log:
            raise RuntimeError("缺少真实服务启动完成日志。")
    return {
        "status": "passed",
        "python": sys.version.split()[0],
        "packages": modules,
        "http": {
            "live": live_code,
            "ready_with_database" if database_url else "ready_without_database": ready_code,
            "openapi": openapi_code,
            "legacy_healthz": alias_code,
        },
        "startup_secret_leak": False,
        "executed_from_source": False,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    result = run_smoke()
    content = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(content + "\n", encoding="utf-8")
    print(content)


if __name__ == "__main__":
    main()
