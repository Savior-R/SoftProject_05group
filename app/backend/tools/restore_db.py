"""G1测试数据恢复到独立已迁移空库；默认预览，不执行DDL或删除数据。"""

import argparse
from pathlib import Path

from sqlalchemy import text

from app.settings import Settings
from common.model_registry import load_models
from tools.backup_db import (
    identifier,
    load_backup,
    read_revision,
    read_rows,
    table_name,
    unpack,
)
from tools.db_guard import configured_database, inspect_group, inspect_permissions, write_result
from tools.db_manifest import reflect_manifest
from tools.freeze_baseline import load_snapshot
from tools.verify_db import verify_schema


def validate_target(connection, schemas, payload):
    if not schemas.prefix.startswith("test_") or schemas.prefix == payload["source"]["prefix"]:
        raise ValueError("仅恢复到不同前缀的隔离test_库组。")
    inspect_group(connection, schemas)
    manifest = reflect_manifest(connection, schemas)
    if manifest != payload["manifest"]:
        raise ValueError("恢复目标结构与备份不一致；先用冻结迁移创建空库。")
    for key in manifest:
        if connection.exec_driver_sql(f"SELECT 1 FROM {table_name(schemas, key)} LIMIT 1").first():
            raise ValueError("目标含业务数据，拒绝覆盖。")
    if payload["revisions"]:
        if read_revision(connection, schemas) != payload["revisions"]:
            raise ValueError("恢复目标迁移版本不匹配。")
    elif (
        f"{schemas.version_schema}.alembic_version" in inspect_group(connection, schemas)["tables"]
    ):
        raise ValueError("无版本备份不能导入受管库。")


def verify_foreign_keys(connection, schemas, manifest):
    # 重启FOREIGN_KEY_CHECKS不会补查既有数据，必须在提交前逐条检查完整外键。
    for key, spec in manifest.items():
        for fk in spec["foreign_keys"]:
            local = fk["constrained_columns"]
            remote = fk["referred_columns"]
            parent = f"{fk['referred_schema']}.{fk['referred_table']}"
            if parent not in manifest or len(local) != len(remote):
                raise ValueError("发现备份范围外或无效外键。")
            present = " AND ".join(f"c.{identifier(c)} IS NOT NULL" for c in local)
            joined = " AND ".join(
                f"p.{identifier(r)}=c.{identifier(c)}" for c, r in zip(local, remote, strict=True)
            )
            sql = (
                f"SELECT 1 FROM {table_name(schemas, key)} c WHERE {present} AND NOT EXISTS "
                f"(SELECT 1 FROM {table_name(schemas, parent)} p WHERE {joined}) LIMIT 1"
            )
            if connection.exec_driver_sql(sql).first():
                raise ValueError("恢复数据违反外键，拒绝提交。")


def restore_rows(connection, schemas, payload):
    """所有写入及核对置于调用方的单个事务；调用方保证目标没有其他写入者。"""
    validate_target(connection, schemas, payload)
    if connection.exec_driver_sql("SELECT @@session.foreign_key_checks").scalar() != 1:
        raise ValueError("恢复前外键检查必须开启。")
    # 允许合法循环FK；CHECK和唯一键仍由数据库执行；全量FK在提交前独立复核。
    connection.exec_driver_sql("SET SESSION FOREIGN_KEY_CHECKS=0")
    try:
        for key, spec in payload["manifest"].items():
            writable = [
                (i, c["name"]) for i, c in enumerate(spec["columns"]) if not c.get("computed")
            ]
            columns = ",".join(identifier(name) for _, name in writable)
            placeholders = ",".join(["%s"] * len(writable))
            sql = f"INSERT INTO {table_name(schemas, key)} ({columns}) VALUES ({placeholders})"
            values = [tuple(unpack(row[i]) for i, _ in writable) for row in payload["rows"][key]]
            for offset in range(0, len(values), 200):
                connection.exec_driver_sql(sql, values[offset : offset + 200])
        verify_foreign_keys(connection, schemas, payload["manifest"])
        for key, spec in payload["manifest"].items():
            if read_rows(connection, schemas, key, spec) != payload["rows"][key]:
                raise ValueError("恢复后的行数／数据摘要不一致，拒绝提交。")
    finally:
        connection.exec_driver_sql("SET SESSION FOREIGN_KEY_CHECKS=1")
    return {
        "status": "passed",
        "tables": len(payload["rows"]),
        "rows": sum(len(rows) for rows in payload["rows"].values()),
        "structure_equal": True,
        "data_equal": True,
        "foreign_keys_valid": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    database = None
    try:
        payload = load_backup(args.input)
        if not args.apply:
            result = {
                "status": "planned",
                "read_only": True,
                "tables": len(payload["rows"]),
                "next": "暂停目标全部写入，配置独立test_七库及迁移账号，再显式--apply。",
            }
        else:
            load_models()
            load_snapshot()
            database = configured_database(Settings(), "test", migration=True)
            with database.engine.connect() as conn:
                if conn.scalar(text("SELECT GET_LOCK('ai_teach_baseline_320', 5)")) != 1:
                    raise ValueError("迁移锁被占用。")
                conn.commit()
                try:
                    with conn.begin():
                        inspect_permissions(conn, database.schemas, migration=True)
                        if verify_schema(conn, database.schemas)["status"] != "passed":
                            raise ValueError("完整目标基线结构未通过。")
                        result = restore_rows(conn, database.schemas, payload)
                finally:
                    conn.rollback()
                    conn.execute(text("SELECT RELEASE_LOCK('ai_teach_baseline_320')"))
                    conn.commit()
    except Exception:
        result = {
            "status": "blocked",
            "reason": "备份／隔离／空库／结构／版本／数据验证失败；本次恢复事务未提交。",
        }
    finally:
        if database:
            database.close()
    write_result(result, args.output)
    if result["status"] not in {"passed", "planned"}:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
