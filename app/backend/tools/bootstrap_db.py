"""仅向全新七库授予独立迁移／DML权限；不修改既有库或既有账号。"""

import argparse
import re

from sqlalchemy import create_engine, text

from common.database_config import SchemaGroup, mysql_url
from tools.db_guard import write_result


def bootstrap(
    connection,
    schemas,
    migration_user,
    migration_password,
    business_user,
    business_password,
    *,
    created_objects=None,
):
    created_objects = [] if created_objects is None else created_objects
    for name in (migration_user, business_user):
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,30}", name):
            raise ValueError("账号名称不在白名单内。")
    if migration_user == business_user or migration_password == business_password:
        raise ValueError("迁移与业务凭据必须独立。")
    if min(len(migration_password), len(business_password)) < 20:
        raise ValueError("口令至少20字符。")
    # 所有检查先完成；不依赖IF NOT EXISTS悄悄接管已有对象。
    for name in schemas.mapping.values():
        if connection.execute(
            text("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=:name"),
            {"name": name},
        ).scalar():
            raise ValueError("目标库已存在；本工具只允许创建全新库组。")
    for name in (migration_user, business_user):
        if connection.execute(
            text("SELECT COUNT(*) FROM mysql.user WHERE User=:name"), {"name": name}
        ).scalar():
            raise ValueError("账号已存在；拒绝变更已有账号。")
    # MySQL DDL会隐式提交；失败时不自动清理已创建对象，须人工核对。
    for name in schemas.mapping.values():
        connection.exec_driver_sql(
            f"CREATE DATABASE `{name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
        )
        created_objects.append(("database", name))
    for user, password in (
        (migration_user, migration_password),
        (business_user, business_password),
    ):
        connection.exec_driver_sql(f"CREATE USER '{user}'@'%%' IDENTIFIED BY %s", (password,))
        created_objects.append(("user", user))
    for name in schemas.mapping.values():
        # database层授权中的下划线必须转义，避免匹配其他测试库。
        escaped = name.replace("_", "\\_")
        connection.exec_driver_sql(
            f"GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES "
            f"ON `{escaped}`.* TO '{migration_user}'@'%%'"
        )
        if name != schemas.version_schema:
            connection.exec_driver_sql(
                f"GRANT SELECT, INSERT, UPDATE, DELETE ON `{escaped}`.* TO '{business_user}'@'%%'"
            )
    platform = schemas.version_schema.replace("_", "\\_")
    connection.exec_driver_sql(f"GRANT SELECT ON `{platform}`.* TO '{business_user}'@'%%'")
    connection.commit()


def grant_platform(connection, schemas, business_user):
    """必须在建表后执行；MySQL不能向尚不存在的表授予这些DML权限。"""
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,30}", business_user):
        raise ValueError("账号名称不在白名单内。")
    tables = ("export_task", "outbox_event", "consumer_receipt", "audit_log")
    for table in tables:
        if (
            connection.execute(
                text(
                    "SELECT COUNT(*) FROM information_schema.TABLES "
                    "WHERE TABLE_SCHEMA=:schema AND TABLE_NAME=:table"
                ),
                {"schema": schemas.version_schema, "table": table},
            ).scalar()
            != 1
        ):
            raise ValueError("platform四表未齐全，不能交接业务权限。")
    for table in tables:
        privileges = "SELECT, INSERT" if table == "audit_log" else "SELECT, INSERT, UPDATE, DELETE"
        connection.exec_driver_sql(
            f"GRANT {privileges} ON `{schemas.version_schema}`.`{table}` TO '{business_user}'@'%%'"
        )
    connection.commit()


def main():
    import os

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default="")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--grant-platform", action="store_true")
    args = parser.parse_args()
    engine = None
    try:
        schemas = SchemaGroup(args.prefix)
        if not args.apply:
            write_result(
                {
                    "status": "planned",
                    "schemas": list(schemas.mapping.values()),
                    "note": "未连接数据库；执行需--apply及五项BOOTSTRAP环境变量。",
                }
            )
            return
        url = mysql_url(os.environ["BOOTSTRAP_DATABASE_URL"])
        engine = create_engine(url, hide_parameters=True, connect_args={"connect_timeout": 5})
        with engine.connect() as connection:
            if args.grant_platform:
                grant_platform(connection, schemas, os.environ["BOOTSTRAP_BUSINESS_USER"])
            else:
                bootstrap(
                    connection,
                    schemas,
                    os.environ["BOOTSTRAP_MIGRATION_USER"],
                    os.environ["BOOTSTRAP_MIGRATION_PASSWORD"],
                    os.environ["BOOTSTRAP_BUSINESS_USER"],
                    os.environ["BOOTSTRAP_BUSINESS_PASSWORD"],
                )

        write_result(
            {
                "status": "passed",
                "schemas": list(schemas.mapping.values()),
                "scope": "仅新库和独立账号；没有执行61表迁移",
            }
        )
    except Exception:
        write_result(
            {
                "status": "failed",
                "reason": "新库／账号预检或创建失败；可能部分创建，请人工核对，禁止重复覆盖。",
            }
        )
        raise SystemExit(1) from None
    finally:
        if engine:
            engine.dispose()


if __name__ == "__main__":
    main()
