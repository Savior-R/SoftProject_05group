"""MySQL唯一驱动适配与七域物理库映射；不输出凭据。"""

import re
from dataclasses import dataclass

from pydantic import SecretStr
from sqlalchemy.engine import URL, make_url

DOMAINS = (
    "identity_org",
    "task_content",
    "classroom",
    "media",
    "evaluation",
    "growth_cert",
    "platform",
)


def mysql_url(value: SecretStr | str | None, *, asynchronous: bool = False) -> URL:
    """兼容步骤一aiomysql配置，结构化派生唯一业务／探针驱动。"""
    try:
        raw = value.get_secret_value() if isinstance(value, SecretStr) else value
        if not raw:
            raise ValueError
        url = make_url(raw)
        if url.drivername not in {"mysql+pymysql", "mysql+aiomysql"}:
            raise ValueError
        if not url.host or not url.username or not url.database:
            raise ValueError
        # 配置查询参数不能改选其他database或执行隐式初始化SQL。
        if set(url.query) - {"charset", "ssl_ca", "ssl_cert", "ssl_key", "ssl_check_hostname"}:
            raise ValueError
        if url.query.get("charset", "utf8mb4") != "utf8mb4":
            raise ValueError
        return url.set(drivername="mysql+aiomysql" if asynchronous else "mysql+pymysql")
    except Exception:
        raise ValueError("数据库配置无效；仅支持带库名的MySQL pymysql／aiomysql配置。") from None


@dataclass(frozen=True)
class SchemaGroup:
    prefix: str = ""

    def __post_init__(self) -> None:
        if self.prefix not in {"", "test_"} and not re.fullmatch(
            r"test_[a-z0-9]{1,20}_", self.prefix
        ):
            raise ValueError("库前缀只能为空、test_或test_加受控小写标识及下划线。")

    @property
    def mapping(self) -> dict[str, str]:
        return {domain: self.prefix + domain for domain in DOMAINS}

    @property
    def version_schema(self) -> str:
        return self.mapping["platform"]

    def validate_url(self, url: URL) -> None:
        if url.database not in self.mapping.values():
            raise ValueError("DSN默认库不在本次七域白名单内。")


def same_database_group(left: URL, right: URL) -> bool:
    """账号和驱动不同不构成隔离；同服务器上的不同域也可能是同一组。"""
    hosts = {"localhost": "loopback", "127.0.0.1": "loopback", "::1": "loopback"}
    a = hosts.get(left.host, left.host)
    b = hosts.get(right.host, right.host)
    return a == b and (left.port or 3306) == (right.port or 3306)
