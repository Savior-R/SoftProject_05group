"""七域身份／权限／隔离检查；失败只打印固定说明，不输出DSN或驱动异常。"""

import argparse
import json
import re
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import bindparam, text

from app.settings import Settings
from common.database_config import SchemaGroup, mysql_url, same_database_group
from common.db import Database


def configured_database(settings: Settings, purpose: str, *, migration: bool = False) -> Database:
    if settings.env not in {"dev", "demo"}:
        raise ValueError("数据库开发／验收工具只允许ENV=dev或demo。")
    secret = settings.test_database_url if purpose == "test" else settings.database_url
    group = SchemaGroup(
        settings.test_db_schema_prefix if purpose == "test" else settings.db_schema_prefix
    )
    if purpose == "test" and not group.prefix.startswith("test_"):
        raise ValueError("测试必须使用独立test_库组。")
    url = mysql_url(secret)
    group.validate_url(url)
    if purpose == "test" and settings.database_url:
        business = mysql_url(settings.database_url)
        development = SchemaGroup(settings.db_schema_prefix)
        if same_database_group(url, business) and set(group.mapping.values()) & set(
            development.mapping.values()
        ):
            raise ValueError("测试与开发七域库组有交集，拒绝执行。")
    if migration:
        privileged = mysql_url(settings.migration_database_url)
        if (
            privileged.host != url.host
            or (privileged.port or 3306) != (url.port or 3306)
            or privileged.database != url.database
            or privileged.username == url.username
        ):
            raise ValueError("迁移必须使用同目标、不同于日常业务账号的专用凭据。")
        url = privileged
    return Database(url.render_as_string(hide_password=False), schema_prefix=group.prefix)


def inspect_group(connection, schemas: SchemaGroup) -> dict:
    row = connection.execute(
        text("SELECT VERSION(), @@server_uuid, @@port, @@session.time_zone")
    ).one()
    version = tuple(int(x) for x in re.match(r"(\d+)\.(\d+)\.(\d+)", row[0]).groups())
    if "mariadb" in row[0].lower() or version < (8, 0, 16) or version >= (9,):
        raise ValueError("需要实际执行CHECK约束的MySQL8，最低8.0.16。")
    if row[3] != "+00:00":
        raise ValueError("数据库会话没有固定UTC。")
    query = text(
        "SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME "
        "FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN :names"
    ).bindparams(bindparam("names", expanding=True))
    found = connection.execute(query, {"names": list(schemas.mapping.values())}).all()
    if len(found) != 7 or any(x[1:] != ("utf8mb4", "utf8mb4_0900_ai_ci") for x in found):
        raise ValueError("七域库不存在、无访问权限或字符集／排序规则不一致。")
    query = text(
        "SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE FROM information_schema.TABLES "
        "WHERE TABLE_SCHEMA IN :names AND TABLE_TYPE='BASE TABLE'"
    ).bindparams(bindparam("names", expanding=True))
    tables = connection.execute(query, {"names": list(schemas.mapping.values())}).all()
    if any(t[2] != "InnoDB" for t in tables):
        raise ValueError("发现非InnoDB表，拒绝继续。")
    return {
        "mysql_version": row[0],
        "server_uuid": row[1],
        "port": row[2],
        "time_zone": row[3],
        "schemas": sorted(schemas.mapping.values()),
        "tables": sorted(f"{x[0]}.{x[1]}" for x in tables),
    }


def require_empty_baseline(connection, schemas: SchemaGroup) -> dict:
    result = inspect_group(connection, schemas)
    if result["tables"]:
        raise ValueError("初始迁移只接受七域全部为空；拒绝未受管非空库或部分初始化。")
    return result


def schema_name_filter(schemas: SchemaGroup, default_schema: str):
    """Alembic把连接默认库表示为None；仍须保留该库参与结构比较。"""

    def include_name(name, type_, parent):
        if type_ != "schema":
            return True
        return (default_schema if name is None else name) in schemas.mapping.values()

    return include_name


def inspect_permissions(connection, schemas: SchemaGroup, *, migration: bool = False) -> dict:
    """检查当前账号直接授权；角色／全局权限或其他库授权无法证明隔离时拒绝。"""
    grants = connection.exec_driver_sql("SHOW GRANTS FOR CURRENT_USER").scalars().all()
    seen = {}
    dml = {"SELECT", "INSERT", "UPDATE", "DELETE"}
    allowed = dml | ({"CREATE", "ALTER", "DROP", "INDEX", "REFERENCES"} if migration else set())
    for grant in grants:
        match = re.match(r"GRANT (.+?) ON (.+?) TO ", grant)
        if not match or "WITH GRANT OPTION" in grant:
            raise ValueError("不允许角色继承、转授权或无法识别的权限。")
        privileges = set(match[1].split(", "))
        if privileges == {"USAGE"} and match[2] == "*.*":
            continue
        scope = match[2].replace("`", "").replace("\\_", "_")
        if not privileges.issubset(allowed) or "." not in scope:
            raise ValueError("账号存在超出用途的权限。")
        schema, table = scope.split(".", 1)
        if schema not in schemas.mapping.values():
            raise ValueError("账号可访问本次白名单以外的数据库。")
        if not migration and schema == schemas.version_schema:
            permitted = (
                {"SELECT"}
                if table == "*"
                else ({"SELECT", "INSERT"} if table == "audit_log" else dml)
            )
            if table not in {"*", "audit_log", "export_task", "outbox_event", "consumer_receipt"}:
                raise ValueError("业务账号含未知platform表授权。")
            if not privileges.issubset(permitted):
                raise ValueError("业务账号可以篡改审计记录。")
        seen.setdefault(scope, set()).update(privileges)
    for schema in schemas.mapping.values():
        required = allowed if migration else dml
        if not migration and schema == schemas.version_schema:
            if "SELECT" not in seen.get(f"{schema}.*", set()):
                raise ValueError("缺少platform读取权限。")
            existing = (
                connection.execute(
                    text(
                        "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=:name"
                    ),
                    {"name": schema},
                )
                .scalars()
                .all()
            )
            for table in ("export_task", "outbox_event", "consumer_receipt", "audit_log"):
                required_table = {"SELECT", "INSERT"} if table == "audit_log" else dml
                actual = seen.get(f"{schema}.*", set()) | seen.get(f"{schema}.{table}", set())
                if table in existing and not required_table.issubset(actual):
                    raise ValueError("platform建表后缺少业务分表权限，请完成授权交接。")
            continue
        if not required.issubset(seen.get(f"{schema}.*", set())):
            raise ValueError("缺少七域必要权限。")
    return {
        "scope": "migration" if migration else "business",
        "isolated_grants": True,
        "audit_append_only": not migration,
    }


def write_result(result: dict, output: Path | None = None) -> None:
    content = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(content, encoding="utf-8", newline="\n")
    print(content, end="")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--purpose", choices=["dev", "test"], default="dev")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    database = None
    try:
        database = configured_database(Settings(), args.purpose)
        with database.engine.connect() as connection:
            details = inspect_group(connection, database.schemas)
            permissions = inspect_permissions(connection, database.schemas)
        result = {
            "status": "passed",
            "read_only": True,
            "identity": details,
            "permissions": permissions,
        }
    except Exception:
        result = {"status": "failed", "reason": "数据库身份／版本／七域权限检查失败，请核对配置。"}
    finally:
        if database:
            database.close()
    result["verified_at"] = datetime.now(UTC).isoformat()
    write_result(result, args.output)
    if result["status"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
