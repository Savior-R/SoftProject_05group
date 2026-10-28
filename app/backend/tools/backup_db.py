"""G1新基线测试数据备份；结构由已冻结迁移重建，不备份账号／媒体。"""

import argparse
import base64
import hashlib
import json
import re
from datetime import UTC, date, datetime, time, timedelta
from decimal import Decimal
from pathlib import Path

from sqlalchemy import text

from app.settings import Settings
from common.model_registry import load_models
from tools.db_guard import configured_database, inspect_group, write_result
from tools.db_manifest import reflect_manifest
from tools.freeze_baseline import load_snapshot
from tools.verify_db import verify_schema


def pack(value):
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, (bytes, bytearray, memoryview)):
        return {"type": "bytes", "value": base64.b64encode(value).decode("ascii")}
    if isinstance(value, Decimal):
        return {"type": "decimal", "value": str(value)}
    if isinstance(value, (datetime, date, time)):
        return {"type": type(value).__name__, "value": value.isoformat()}
    if isinstance(value, timedelta):
        return {"type": "timedelta", "value": value // timedelta(microseconds=1)}
    raise ValueError("测试数据包含不支持的类型，拒绝有损备份。")


def unpack(value):
    if not isinstance(value, dict):
        return value
    converters = {
        "bytes": lambda x: base64.b64decode(x, validate=True),
        "decimal": Decimal,
        "datetime": datetime.fromisoformat,
        "date": date.fromisoformat,
        "time": time.fromisoformat,
        "timedelta": lambda x: timedelta(microseconds=x),
    }
    if set(value) != {"type", "value"} or value["type"] not in converters:
        raise ValueError("备份数据类型无效。")
    return converters[value["type"]](value["value"])


def canonical(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    )


def digest(value):
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def identifier(value):
    # 列名来自实库反射；仍不能将未校验的备份内容拼成SQL。
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", value):
        raise ValueError("数据库标识符不在白名单内。")
    return f"`{value}`"


def table_name(schemas, key):
    domain, name = key.split(".")
    return f"{identifier(schemas.mapping[domain])}.{identifier(name)}"


def read_rows(connection, schemas, key, spec):
    columns = [c["name"] for c in spec["columns"]]
    query = f"SELECT {','.join(identifier(c) for c in columns)} FROM {table_name(schemas, key)}"
    return sorted(
        ([pack(value) for value in row] for row in connection.exec_driver_sql(query)),
        key=canonical,
    )


def read_revision(connection, schemas):
    return (
        connection.exec_driver_sql(
            f"SELECT version_num FROM `{schemas.version_schema}`.alembic_version"
        )
        .scalars()
        .all()
    )


def capture(connection, schemas):
    """调用方已暂停DDL并开启RR一致性快照；只读，不假定生产模型已齐。"""
    identity = inspect_group(connection, schemas)
    manifest = reflect_manifest(connection, schemas)
    if not manifest:
        raise ValueError("没有可备份的测试表。")
    version_key = f"{schemas.version_schema}.alembic_version"
    revisions = read_revision(connection, schemas) if version_key in identity["tables"] else []
    return {
        "format": "g1-test-data-v1",
        "created_at": datetime.now(UTC).isoformat(),
        "source": {"server_uuid": identity["server_uuid"], "prefix": schemas.prefix},
        "revisions": revisions,
        "manifest": manifest,
        "rows": {key: read_rows(connection, schemas, key, spec) for key, spec in manifest.items()},
    }


def save_backup(payload, output):
    if not output.name.endswith(".g1-backup.json"):
        raise ValueError("备份必须使用被Git忽略的.g1-backup.json后缀。")
    envelope = {"payload": payload, "sha256": digest(payload)}
    output.parent.mkdir(parents=True, exist_ok=True)
    # 独占创建，不覆盖既有备份；输出内容不可当作公开证据提交。
    with output.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(canonical(envelope) + "\n")
    return {
        "sha256": envelope["sha256"],
        "tables": len(payload["rows"]),
        "rows": sum(len(rows) for rows in payload["rows"].values()),
    }


def load_backup(path):
    envelope = json.loads(path.read_text("utf-8"))
    payload = envelope["payload"]
    if envelope.get("sha256") != digest(payload) or payload.get("format") != "g1-test-data-v1":
        raise ValueError("备份校验失败；摘要只检测损坏，不认证文件来源。")
    if not payload["manifest"] or set(payload["manifest"]) != set(payload["rows"]):
        raise ValueError("备份表清单不完整。")
    for key, spec in payload["manifest"].items():
        for row in payload["rows"][key]:
            if len(row) != len(spec["columns"]):
                raise ValueError("备份字段数量不一致。")
            for value in row:
                unpack(value)
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--purpose", choices=["dev", "test"], default="test")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    database = None
    try:
        # 生产CLI必须是真实61表及冻结快照；低层函数仅供夹具验证协议。
        load_models()
        load_snapshot()
        database = configured_database(Settings(), args.purpose)
        with database.engine.connect().execution_options(isolation_level="REPEATABLE READ") as conn:
            if conn.scalar(text("SELECT GET_LOCK('ai_teach_baseline_320', 5)")) != 1:
                raise ValueError("迁移锁被占用。")
            conn.commit()
            try:
                conn.exec_driver_sql("START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY")
                if verify_schema(conn, database.schemas)["status"] != "passed":
                    raise ValueError("完整基线结构未通过。")
                payload = capture(conn, database.schemas)
                conn.rollback()
                result = {
                    "status": "passed",
                    "scope": "仅G1测试数据备份，尚未证明恢复",
                    **save_backup(payload, args.output),
                }
            finally:
                conn.rollback()
                conn.execute(text("SELECT RELEASE_LOCK('ai_teach_baseline_320')"))
                conn.commit()
    except Exception:
        result = {
            "status": "blocked",
            "reason": "模型／冻结／结构／连接或备份输出预检失败；未覆盖备份。",
        }
    finally:
        if database:
            database.close()
    write_result(result)
    if result["status"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
