"""A四张表的真实MySQL证据；其余57表约束由域负责人交接后扩展。"""

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

import pytest
from sqlalchemy import CheckConstraint, insert, select, text
from sqlalchemy.exc import DBAPIError

from app.platform.models import AuditLog, ConsumerReceipt, ExportTask, OutboxEvent
from common.model_base import Base
from tools.check_expression import canonical_check
from tools.db_guard import inspect_group, inspect_permissions
from tools.db_manifest import reflect_manifest
from tools.verify_db import index_differences, model_differences, translated_metadata


def test_schema_compare_detects_drift_in_default_database(isolated_mysql):
    migration = isolated_mysql["migration"]
    physical = translated_metadata(migration.schemas.mapping, isolated_mysql["metadata"])
    schema = migration.schemas.mapping["identity_org"]
    with migration.engine.connect() as connection:
        assert model_differences(connection, physical, migration.schemas) == []
        assert (
            index_differences(
                isolated_mysql["metadata"], reflect_manifest(connection, migration.schemas)
            )
            == []
        )
        try:
            connection.exec_driver_sql(f"ALTER TABLE `{schema}`.user ADD COLUMN unexpected INT")
            changes = model_differences(connection, physical, migration.schemas)
            assert any(
                change[0] == "remove_column" and change[3].name == "unexpected"
                for change in changes
            )
        finally:
            connection.exec_driver_sql(f"ALTER TABLE `{schema}`.user DROP COLUMN unexpected")


def test_descending_index_drift_is_detected(isolated_mysql):
    migration = isolated_mysql["migration"]
    schema = migration.schemas.version_schema
    with migration.engine.connect() as connection:
        try:
            connection.exec_driver_sql(
                f"ALTER TABLE `{schema}`.export_task DROP INDEX idx_et_operator_time, "
                "ADD INDEX idx_et_operator_time "
                "(operator_id, created_at ASC)"
            )
            differences = index_differences(
                isolated_mysql["metadata"], reflect_manifest(connection, migration.schemas)
            )
            assert any("idx_et_operator_time" in value for value in differences)
        finally:
            connection.exec_driver_sql(
                f"ALTER TABLE `{schema}`.export_task DROP INDEX idx_et_operator_time, "
                "ADD INDEX idx_et_operator_time "
                "(operator_id, created_at DESC)"
            )


def test_identity_permissions_and_reflected_constraints(isolated_mysql):
    database = isolated_mysql["database"]
    with database.engine.connect() as connection:
        assert inspect_group(connection, database.schemas)["time_zone"] == "+00:00"
        assert inspect_permissions(connection, database.schemas)["audit_append_only"]
        reflected = reflect_manifest(connection, database.schemas)
    with isolated_mysql["migration"].engine.connect() as connection:
        assert inspect_permissions(connection, database.schemas, migration=True)["isolated_grants"]
    for key, table in Base.metadata.tables.items():
        if table.schema != "platform":
            continue
        checks = {check["name"]: check["sqltext"] for check in reflected[key]["checks"]}
        for constraint in table.constraints:
            if isinstance(constraint, CheckConstraint):
                assert canonical_check(constraint.sqltext) == canonical_check(
                    checks[constraint.name]
                )


def user(database):
    identifier = uuid4()
    schema = database.schemas.mapping["identity_org"]
    database.run(
        lambda s: (
            s.execute(
                text(f"INSERT INTO `{schema}`.user (user_id) VALUES (:id)"), {"id": str(identifier)}
            ),
            None,
        )[1]
    )
    return identifier


def event(**changes):
    return {
        "aggregate_type": "report",
        "aggregate_id": uuid4(),
        "aggregate_version": 1,
        "topic": "score.changed",
        "payload": {"version": 1},
        "status": "pending",
        "next_attempt_at": datetime.now(UTC),
        "created_at": datetime.now(UTC),
        **changes,
    }


def test_utc_json_decimal_and_export_checks(isolated_mysql):
    database = isolated_mysql["database"]
    operator = user(database)
    identifier = uuid4()
    values = {
        "export_id": identifier,
        "operator_id": operator,
        "export_scope": "class_score",
        "filter_cond": {"dimension": "speech"},
        "export_format": "xlsx",
        "expire_at": datetime.now(UTC) + timedelta(days=7),
        "progress": Decimal("0.125"),
    }
    database.run(lambda s: (s.execute(insert(ExportTask).values(**values)), None)[1])
    result = database.run(
        lambda s: dict(
            s.execute(
                select(ExportTask.progress, ExportTask.filter_cond, ExportTask.created_at).where(
                    ExportTask.export_id == identifier
                )
            )
            .one()
            ._mapping
        )
    )
    assert result["progress"] == Decimal("0.125")
    assert result["filter_cond"] == {"dimension": "speech"}
    assert result["created_at"].tzinfo == UTC
    for changes in (
        {"status": "success"},
        {"progress": Decimal("1.1")},
        {"status": "failed"},
        {"export_format": "bad"},
        {"operator_id": uuid4()},
    ):
        with pytest.raises(DBAPIError) as rejected:
            database.run(
                lambda s, changes=changes: (
                    s.execute(
                        insert(ExportTask).values(**{**values, "export_id": uuid4(), **changes})
                    ),
                    None,
                )[1]
            )
        assert rejected.value.orig.args[0] in {1216, 1452, 3819}


def test_outbox_unique_status_and_receipt_independence(isolated_mysql):
    database = isolated_mysql["database"]
    dedupe = str(uuid4())
    database.run(
        lambda s: (s.execute(insert(OutboxEvent).values(**event(dedupe_key=dedupe))), None)[1]
    )
    for values in (event(dedupe_key=dedupe), event(status="invalid"), event(attempts=-1)):
        with pytest.raises(DBAPIError) as rejected:
            database.run(
                lambda s, values=values: (s.execute(insert(OutboxEvent).values(**values)), None)[1]
            )
        assert rejected.value.orig.args[0] in {1062, 3819}
    values = {
        "consumer": "stats.v1",
        "event_id": uuid4(),
        "aggregate_id": uuid4(),
        "aggregate_version": 1,
        "processed_at": datetime.now(UTC),
    }
    database.run(lambda s: (s.execute(insert(ConsumerReceipt).values(**values)), None)[1])
    with pytest.raises(DBAPIError) as rejected:
        database.run(lambda s: (s.execute(insert(ConsumerReceipt).values(**values)), None)[1])
    assert rejected.value.orig.args[0] == 1062


def test_cross_schema_transaction_rollback(isolated_mysql):
    database = isolated_mysql["database"]
    identifier, event_id = uuid4(), uuid4()
    schema = database.schemas.mapping["identity_org"]

    def fail(session):
        session.execute(
            text(f"INSERT INTO `{schema}`.user (user_id) VALUES (:id)"), {"id": str(identifier)}
        )
        session.execute(insert(OutboxEvent).values(**event(event_id=event_id)))
        raise ValueError("rollback")

    with pytest.raises(ValueError):
        database.run(fail)
    assert (
        database.run(
            lambda s: s.scalar(
                text(f"SELECT COUNT(*) FROM `{schema}`.user WHERE user_id=:id"),
                {"id": str(identifier)},
            )
        )
        == 0
    )

    assert (
        database.run(
            lambda s: s.scalar(select(OutboxEvent.event_id).where(OutboxEvent.event_id == event_id))
        )
        is None
    )


def test_orm_defaults_and_entity_must_not_escape(isolated_mysql):
    from common.db import TransactionBoundaryError

    database = isolated_mysql["database"]

    def create(session):
        instance = OutboxEvent(**event())
        session.add(instance)
        session.flush()
        return instance.event_id

    identifier = database.run(create)
    assert identifier.version == 7
    with pytest.raises(TransactionBoundaryError):
        database.run(lambda s: s.get(OutboxEvent, identifier))


def test_audit_append_only_enforced_by_business_permissions(isolated_mysql):
    database = isolated_mysql["database"]
    identifier = uuid4()
    operator = user(database)
    schema = database.schemas.mapping["platform"]
    database.run(
        lambda s: (
            s.execute(
                insert(AuditLog).values(
                    log_id=identifier,
                    user_id=operator,
                    action="login",
                    target_type="user",
                    target_id=uuid4(),
                )
            ),
            None,
        )[1]
    )
    assert (
        database.run(
            lambda s: s.scalar(select(AuditLog.details).where(AuditLog.log_id == identifier))
        )
        == {}
    )
    for statement in (
        f"UPDATE `{schema}`.audit_log SET action='review' WHERE log_id=:id",
        f"DELETE FROM `{schema}`.audit_log WHERE log_id=:id",
    ):
        with pytest.raises(DBAPIError):
            database.run(
                lambda s, statement=statement: (
                    s.execute(text(statement), {"id": str(identifier)}),
                    None,
                )[1]
            )
    with pytest.raises(DBAPIError):
        with database.engine.begin() as connection:
            connection.exec_driver_sql(f"CREATE TABLE `{schema}`.forbidden (id INT)")
