"""A1 环境连通性自检（只读，不建表）。

用法（在项目根目录）：
    py -3.12 -m pip install --target runtime/tmp/pylibs pymysql
    set PYTHONPATH=runtime/tmp/pylibs
    py -3.12 app/tools/check-env.py

输出：控制台摘要 + artifacts/M0/bootstrap/env-check.json
"""

from __future__ import annotations

import json
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV_FILE = ROOT / "runtime" / "local-db.env"
OUT_DIR = ROOT / "artifacts" / "M0" / "bootstrap"

EXPECTED_DB = [
    "identity_org", "task_content", "classroom", "media",
    "evaluation", "growth_cert", "platform",
]


def read_env(path: Path) -> dict[str, str]:
    conf: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        conf[key.strip()] = value.strip()
    return conf


def check_python() -> dict:
    return {
        "version": sys.version.split()[0],
        "executable": sys.executable,
        "ok": sys.version_info[:2] == (3, 12),
        "machine": platform.machine(),
        "os": platform.platform(),
    }


def check_db(conf: dict[str, str]) -> dict:
    import pymysql

    result: dict = {"ok": False}
    try:
        conn = pymysql.connect(
            host=conf.get("DB_DEV_HOST", "127.0.0.1"),
            port=int(conf.get("DB_DEV_PORT", "3306")),
            user=conf["DB_DEV_USER"],
            password=conf["DB_DEV_PASSWORD"],
            connect_timeout=10,
            charset="utf8mb4",
        )
    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"
        return result

    try:
        with conn.cursor() as cur:
            cur.execute("SELECT VERSION(), @@port, @@character_set_server;")
            version, port, charset = cur.fetchone()
            cur.execute("SHOW DATABASES;")
            databases = sorted(row[0] for row in cur.fetchall())
        missing = [name for name in EXPECTED_DB if name not in databases]
        missing_test = [f"test_{n}" for n in EXPECTED_DB if f"test_{n}" not in databases]
        result.update({
            "ok": not missing and not missing_test,
            "server_version": version,
            "server_port_internal": port,
            "host_port": conf.get("DB_DEV_PORT", "3306"),
            "server_charset": charset,
            "databases": databases,
            "missing_dev": missing,
            "missing_test": missing_test,
        })
    finally:
        conn.close()
    return result


def check_ffmpeg() -> dict:
    info: dict = {}
    for exe in ("ffmpeg", "ffprobe"):
        try:
            out = subprocess.run(
                [exe, "-version"], capture_output=True, text=True, timeout=20, check=False
            )
            first = (out.stdout or out.stderr).splitlines()[0] if (out.stdout or out.stderr) else ""
            info[exe] = {"ok": out.returncode == 0, "version_line": first}
        except FileNotFoundError:
            info[exe] = {"ok": False, "error": "not found on PATH"}
        except subprocess.SubprocessError as exc:
            info[exe] = {"ok": False, "error": str(exc)}
    return info


def main() -> int:
    if not ENV_FILE.exists():
        print(f"缺少凭据文件：{ENV_FILE}")
        return 2
    conf = read_env(ENV_FILE)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "python": check_python(),
        "database": check_db(conf),
        "media": check_ffmpeg(),
    }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_file = OUT_DIR / "env-check.json"
    out_file.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    py, db, media = report["python"], report["database"], report["media"]
    print(f"Python : {py['version']}  ({'OK' if py['ok'] else '版本不符，需要 3.12.x'})")
    if db.get("ok"):
        print(f"MySQL  : {db['server_version']}  主机端口 {db['host_port']}（容器内 {db['server_port_internal']}）七库齐全 OK")
    else:
        print(f"MySQL  : 失败 -> {db.get('error') or db.get('missing_dev') or db.get('missing_test')}")
    for name, info in media.items():
        print(f"{name:7}: {'OK' if info['ok'] else 'FAIL'}  {info.get('version_line', info.get('error', ''))[:70]}")
    print(f"证据   : {out_file}")

    return 0 if (py["ok"] and db.get("ok") and all(v["ok"] for v in media.values())) else 1


if __name__ == "__main__":
    raise SystemExit(main())
