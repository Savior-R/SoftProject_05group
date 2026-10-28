"""真实MySQL验证四表夹具恢复／失败回滚；不等于61表G1恢复。"""

from copy import deepcopy
from datetime import UTC, datetime
from uuid import uuid4

import pytest
from sqlalchemy import insert, text

from app.platform.models import AuditLog, OutboxEvent
from tools.backup_db import capture, load_backup, save_backup, table_name
from tools.restore_db import restore_rows


def populate(source):
    database = source["database"]
    identifier = str(uuid4())
    schema = database.schemas.mapping["identity_org"]
    with database.engine.begin() as conn:
        conn.execute(text(f"INSERT INTO `{schema}`.user VALUES (:id)"), {"id": identifier})
        conn.execute(
            insert(AuditLog).values(
                user_id=identifier,
                action="login",
                target_type="user",
                target_id=identifier,
                details={"原样保留": source["schemas"].prefix, "引号": "'\\\n"},
            )
        )
        conn.execute(
            insert(OutboxEvent).values(
                aggregate_type="report",
                aggregate_id=identifier,
                aggregate_version=1,
                topic="score.changed",
                payload={"version": 1},
                status="pending",
                next_attempt_at=datetime.now(UTC),
                created_at=datetime.now(UTC),
            )
        )
    with (
        source["migration"]
        .engine.connect()
        .execution_options(isolation_level="REPEATABLE READ") as conn
    ):
        conn.exec_driver_sql("START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY")
        return capture(conn, source["schemas"])


def assert_no_data(target, payload):
    with target["migration"].engine.connect() as conn:
        for key in payload["manifest"]:
            assert (
                conn.exec_driver_sql(
                    f"SELECT COUNT(*) FROM {table_name(target['schemas'], key)}"
                ).scalar()
                == 0
            )


def test_real_mysql_backup_restore_roundtrip_and_nonempty_refusal(backup_pair, tmp_path):
    source, target = backup_pair
    payload = populate(source)
    path = tmp_path / "fixture.g1-backup.json"
    summary = save_backup(payload, path)
    assert summary["rows"] == 3
    payload = load_backup(path)
    with target["migration"].engine.begin() as conn:
        result = restore_rows(conn, target["schemas"], payload)
        assert result["data_equal"] and result["foreign_keys_valid"]
    with target["migration"].engine.connect() as conn:
        restored = capture(conn, target["schemas"])
        assert restored["rows"] == payload["rows"]
        assert restored["manifest"] == payload["manifest"]
        assert restored["revisions"] == payload["revisions"]
    with pytest.raises(ValueError, match="业务数据"):
        with target["migration"].engine.begin() as conn:
            restore_rows(conn, target["schemas"], payload)


def test_real_mysql_restore_bad_fk_rolls_back_every_schema(backup_pair):
    source, target = backup_pair
    payload = populate(source)
    invalid = deepcopy(payload)
    # 模拟外键孤儿；FOREIGN_KEY_CHECKS恢复开启本身不会补查，必须独立拒绝。
    invalid["rows"]["identity_org.user"] = []
    with pytest.raises(ValueError, match="外键"):
        with target["migration"].engine.begin() as conn:
            restore_rows(conn, target["schemas"], invalid)
    assert_no_data(target, payload)
    with target["migration"].engine.connect() as conn:
        assert conn.exec_driver_sql("SELECT @@session.foreign_key_checks").scalar() == 1


def test_real_mysql_restore_rejects_structure_drift_before_insert(backup_pair):
    source, target = backup_pair
    payload = populate(source)
    schema = target["schemas"].mapping["identity_org"]
    with target["migration"].engine.begin() as conn:
        conn.exec_driver_sql(f"ALTER TABLE `{schema}`.user ADD COLUMN unexpected INT")
    with pytest.raises(ValueError, match="结构"):
        with target["migration"].engine.begin() as conn:
            restore_rows(conn, target["schemas"], payload)
    assert_no_data(target, payload)


def test_generated_columns_exact_values_and_cycle_fk_survive_restore(backup_pair):
    source, target = backup_pair
    # 专用协议夹具，绝不注册生产Base或代替F域真实生成列验收。
    for group in (source, target):
        schema = group["schemas"].mapping["evaluation"]
        with group["migration"].engine.begin() as conn:
            conn.exec_driver_sql(
                f"CREATE TABLE `{schema}`.backup_protocol ("
                "id INT PRIMARY KEY, amount DECIMAL(18,6) NOT NULL, data BLOB, "
                "day DATE, clock TIME(6), parent_id INT NULL, "
                "active_id INT GENERATED ALWAYS AS (CASE WHEN amount > 0 THEN id END) STORED, "
                "UNIQUE KEY uq_backup_active (active_id), "
                "CONSTRAINT fk_backup_cycle FOREIGN KEY (parent_id) "
                f"REFERENCES `{schema}`.backup_protocol(id)"
                ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci"
            )
    schema = source["schemas"].mapping["evaluation"]
    with source["migration"].engine.begin() as conn:
        conn.exec_driver_sql("SET SESSION FOREIGN_KEY_CHECKS=0")
        try:
            conn.exec_driver_sql(
                f"INSERT INTO `{schema}`.backup_protocol (id,amount,data,day,clock,parent_id) "
                "VALUES (1,123456789.123456,X'00FF','2026-10-28','12:13:14.123456',2),"
                "(2,0,NULL,NULL,'-25:00:00',1)"
            )
        finally:
            conn.exec_driver_sql("SET SESSION FOREIGN_KEY_CHECKS=1")
        payload = capture(conn, source["schemas"])
    with target["migration"].engine.begin() as conn:
        assert restore_rows(conn, target["schemas"], payload)["data_equal"]
        assert capture(conn, target["schemas"])["rows"] == payload["rows"]
