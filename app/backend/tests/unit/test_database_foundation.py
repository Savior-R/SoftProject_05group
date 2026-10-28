"""验证真实会影响消费者的事务、驱动和交接边界；不作为MySQL G1证据。"""

import asyncio
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import Column, ForeignKey, Integer, MetaData, Table, create_engine, text
from sqlalchemy.exc import InvalidRequestError
from sqlalchemy.orm import sessionmaker

from app.settings import Settings
from common.database_config import SchemaGroup, mysql_url
from common.db import Database, GuardedSession, TransactionBoundaryError, require_detached_result
from common.model_base import UTCDateTime, UUIDText
from common.model_registry import expected_inventory, load_models
from tools.db_guard import configured_database
from tools.freeze_baseline import compile_metadata, load_snapshot, snapshot_statements


@pytest.fixture
def transaction_database():
    # SQLite只验证Session控制流；MySQL表约束另有真实集成测试。
    engine = create_engine("sqlite://")
    with engine.begin() as connection:
        connection.execute(text("CREATE TABLE sample (id INTEGER PRIMARY KEY)"))
    database = object.__new__(Database)
    database.engine = engine
    database.session_factory = sessionmaker(
        bind=engine,
        class_=GuardedSession,
        expire_on_commit=False,
        autobegin=False,
        close_resets_only=False,
    )
    yield database
    database.close()


def count(database):
    return database.run(lambda s: s.scalar(text("SELECT COUNT(*) FROM sample")))


def test_commit_rollback_and_no_session_escape(transaction_database):
    database = transaction_database
    database.run(lambda s: (s.execute(text("INSERT INTO sample VALUES (1)")), None)[1])
    assert count(database) == 1

    def fail(session):
        session.execute(text("INSERT INTO sample VALUES (2)"))
        raise ValueError("rollback")

    with pytest.raises(ValueError):
        database.run(fail)

    def leak(session):
        session.execute(text("INSERT INTO sample VALUES (3)"))
        return {"nested": [session]}

    with pytest.raises(TransactionBoundaryError):
        database.run(leak)
    assert count(database) == 1


@pytest.mark.parametrize("operation", ["commit", "rollback", "close"])
def test_callback_cannot_end_transaction(transaction_database, operation):
    def work(session):
        session.execute(text("INSERT INTO sample VALUES (1)"))
        getattr(session, operation)()

    with pytest.raises(TransactionBoundaryError):
        transaction_database.run(work)
    assert count(transaction_database) == 0


def test_event_loop_and_thread_misuse_rejected(transaction_database):
    async def wrong():
        with pytest.raises(TransactionBoundaryError):
            transaction_database.run(lambda s: None)

    asyncio.run(wrong())
    with transaction_database.transaction() as session, ThreadPoolExecutor(1) as pool:
        for operation in (
            lambda: session.execute(text("SELECT 1")),
            lambda: session.add(object()),
            lambda: session.close(),
        ):
            with pytest.raises(TransactionBoundaryError):
                pool.submit(operation).result()


def test_result_is_independent_data():
    require_detached_result({"id": uuid4(), "amount": Decimal("1.25"), "at": datetime.now(UTC)})
    for value in (iter([1]), object()):
        with pytest.raises(TransactionBoundaryError):
            require_detached_result(value)


@pytest.mark.parametrize("driver", ["pymysql", "aiomysql"])
def test_url_driver_compatibility(driver):
    value = f"mysql+{driver}://user:p%40ss@localhost/identity_org?charset=utf8mb4"
    assert mysql_url(value).drivername == "mysql+pymysql"
    assert mysql_url(value, asynchronous=True).drivername == "mysql+aiomysql"
    assert mysql_url(value).password == "p@ss"


@pytest.mark.parametrize(
    "value",
    [
        "sqlite:///x",
        "mysql://u:SECRET@host/db",
        "mysql+pymysql://u:SECRET@host/db?init_command=BAD",
    ],
)
def test_unsafe_url_hidden(value):
    with pytest.raises(ValueError) as error:
        mysql_url(value)
    assert "SECRET" not in str(error.value)


def test_test_group_cannot_overlap_development():
    settings = Settings(
        _env_file=None,
        database_url="mysql+pymysql://u:p@localhost/test_identity_org",
        db_schema_prefix="test_",
        test_database_url="mysql+pymysql://u:p@127.0.0.1/test_platform",
    )
    with pytest.raises(ValueError, match="交集"):
        configured_database(settings, "test")
    with pytest.raises(ValueError):
        SchemaGroup("production_")


def test_uuid_and_utc_types():
    identifier = uuid4()
    assert UUIDText().process_bind_param(identifier, None) == str(identifier)
    assert UUIDText().process_result_value(str(identifier), None) == identifier
    value = datetime(2026, 10, 28, 8, tzinfo=timezone(timedelta(hours=8)))
    stored = UTCDateTime().process_bind_param(value, None)
    assert stored == datetime(2026, 10, 28)
    assert UTCDateTime().process_result_value(stored, None).tzinfo == UTC
    with pytest.raises(ValueError):
        UTCDateTime().process_bind_param(datetime(2026, 10, 28), None)


def test_inventory_and_missing_models_block_initialization(monkeypatch, tmp_path):
    from tools import freeze_baseline

    root = Path(__file__).resolve().parents[2]
    expected = expected_inventory()
    assert expected == json.loads((root / "data/schema-manifest.expected.json").read_text("utf-8"))
    assert len(expected["tables"]) == 61
    report = load_models(require_complete=False)
    assert report["registered_count"] + len(report["missing_tables"]) == 61
    assert not report["unexpected_tables"]
    source = root.parents[1] / expected["source"]
    assert hashlib.sha256(source.read_bytes()).hexdigest() == expected["source_sha256"]

    def incomplete():
        raise RuntimeError("测试缺少域模型")

    monkeypatch.setattr(freeze_baseline, "load_models", incomplete)
    with pytest.raises(RuntimeError):
        snapshot_statements()
    monkeypatch.setattr(freeze_baseline, "files", lambda package: tmp_path)
    with pytest.raises(RuntimeError):
        load_snapshot()


def test_session_closed_after_success_and_failure(transaction_database):
    captured = []
    transaction_database.run(lambda session: captured.append(session))
    with pytest.raises(InvalidRequestError):
        captured[0].begin()


def test_cyclic_foreign_keys_are_emitted_after_both_tables():
    from common.model_base import NAMING_CONVENTION

    metadata = MetaData(naming_convention=NAMING_CONVENTION)
    Table(
        "left",
        metadata,
        Column("id", Integer, primary_key=True),
        Column("right_id", ForeignKey("classroom.right.id")),
        schema="identity_org",
    )
    Table(
        "right",
        metadata,
        Column("id", Integer, primary_key=True),
        Column("left_id", ForeignKey("identity_org.left.id")),
        schema="classroom",
    )
    statements = compile_metadata(metadata)
    assert len(statements) == 4
    assert all("CREATE TABLE" in s for s in statements[:2])
    assert all("ALTER TABLE" in s for s in statements[2:])
    assert "__db_identity_org__" in "\n".join(statements)


def test_check_expression_keeps_boolean_meaning():
    from tools.check_expression import canonical_check

    assert canonical_check("a = 'X' OR b >= 0") == canonical_check(
        "((`a` = _utf8mb4'X') or (`b` >= 0.0))"
    )
    assert canonical_check("a = 1 OR b = 2 AND c = 3") != canonical_check(
        "(a = 1 OR b = 2) AND c = 3"
    )
