"""只读验证独立 MySQL 测试库；无配置明确非零，不执行迁移或写数据。"""

import argparse
import importlib
import json
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy.engine import make_url

from app.settings import Settings
from tools.smoke import run_smoke

TEST_DATABASES = frozenset(
    f"test_{domain}"
    for domain in (
        "identity_org",
        "task_content",
        "classroom",
        "media",
        "evaluation",
        "growth_cert",
        "platform",
    )
)


def require_rsa_support() -> None:
    """即便服务端缓存已暖，也不能让缺少完整认证依赖的环境通过。"""
    try:
        importlib.import_module("cryptography.hazmat.primitives.asymmetric.rsa")
        auth = importlib.import_module("pymysql._auth")
        if not auth._have_cryptography:
            raise ImportError
    except ImportError:
        raise RuntimeError(
            "缺少 MySQL RSA 认证依赖；请重建并安装含 aiomysql[rsa] 的 lock。"
        ) from None


def validate_test_database_url(value: str | None) -> str:
    if not value or not value.strip():
        raise ValueError("未配置 TEST_DATABASE_URL；真实数据库验证未执行，不能判为通过。")
    try:
        url = make_url(value)
        valid = (
            url.drivername == "mysql+aiomysql"
            and url.host is not None
            and url.database in TEST_DATABASES
        )
    except Exception:
        valid = False
    if not valid:
        raise ValueError(
            "TEST_DATABASE_URL 必须为 mysql+aiomysql DSN，且库名属于 test_ 加七个逻辑域名白名单。"
        ) from None
    return value


def verify_database() -> dict[str, object]:
    settings = Settings()
    secret = settings.test_database_url
    database_url = validate_test_database_url(secret.get_secret_value() if secret else None)
    require_rsa_support()
    result = run_smoke(database_url)
    return {
        "status": "passed",
        "verified_at": datetime.now(UTC).isoformat(),
        "scope": "独立测试库真实 HTTP readiness 和 SELECT 1；不证明迁移、业务或冷缓存。",
        "rsa_dependency_available": True,
        "read_only": True,
        "smoke": result,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        result = verify_database()
    except Exception:
        # 第三方异常可能含 DSN；故意只给固定提示，不输出 traceback 或异常原文。
        result = {
            "status": "failed",
            "verified_at": datetime.now(UTC).isoformat(),
            "reason": "真实数据库验证失败：检查 TEST_DATABASE_URL、RSA 依赖、网络与权限。",
        }
    content = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(content + "\n", encoding="utf-8")
    print(content)
    if result["status"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
