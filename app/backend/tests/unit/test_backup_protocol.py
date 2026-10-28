"""仅验证会造成数据丢失或错误恢复的备份协议缺陷，不冒充完整G1。"""

import json
from datetime import date, datetime, time, timedelta
from decimal import Decimal

import pytest

from tools import backup_db, restore_db


@pytest.mark.parametrize(
    "value",
    [
        None,
        "中文'\\\n",
        42,
        0.125,
        True,
        b"\x00\xff",
        Decimal("123.450"),
        datetime(2026, 10, 28, 1, 2, 3, 456000),
        date(2026, 10, 28),
        time(1, 2, 3, 456000),
        timedelta(days=-2, microseconds=123),
    ],
)
def test_data_types_roundtrip_without_precision_loss(value):
    assert backup_db.unpack(json.loads(backup_db.canonical(backup_db.pack(value)))) == value


def sample_payload():
    return {
        "format": "g1-test-data-v1",
        "manifest": {"platform.example": {"columns": [{"name": "id"}]}},
        "rows": {"platform.example": [[1]]},
        "source": {"prefix": "test_source_"},
    }


def test_backup_detects_corruption_and_refuses_overwrite(tmp_path):
    path = tmp_path / "sample.g1-backup.json"
    payload = sample_payload()
    backup_db.save_backup(payload, path)
    assert backup_db.load_backup(path) == payload
    with pytest.raises(FileExistsError):
        backup_db.save_backup(payload, path)
    envelope = json.loads(path.read_text("utf-8"))
    envelope["payload"]["rows"]["platform.example"] = [[2]]
    path.write_text(json.dumps(envelope), "utf-8")
    with pytest.raises(ValueError, match="校验失败"):
        backup_db.load_backup(path)


def test_restore_defaults_to_plan_without_database(monkeypatch, tmp_path, capsys):
    path = tmp_path / "preview.g1-backup.json"
    backup_db.save_backup(sample_payload(), path)
    monkeypatch.setattr("sys.argv", ["restore_db", "--input", str(path)])
    monkeypatch.setattr(restore_db, "configured_database", lambda *a, **k: pytest.fail("不应连库"))
    restore_db.main()
    assert json.loads(capsys.readouterr().out)["status"] == "planned"


def test_restore_refuses_same_group_or_formal_group_before_query():
    from common.database_config import SchemaGroup

    for schemas in (SchemaGroup("test_source_"), SchemaGroup("")):
        with pytest.raises(ValueError, match="隔离"):
            restore_db.validate_target(None, schemas, sample_payload())


def test_unrecognized_value_and_identifier_are_rejected():
    with pytest.raises(ValueError):
        backup_db.pack(object())
    with pytest.raises(ValueError):
        backup_db.identifier("id`; DROP DATABASE test_identity_org;--")


def test_incomplete_baseline_blocks_backup_before_database(monkeypatch, tmp_path, capsys):
    def incomplete():
        raise RuntimeError("模型未齐")

    monkeypatch.setattr(backup_db, "load_models", incomplete)
    monkeypatch.setattr(backup_db, "configured_database", lambda *a, **k: pytest.fail("不应连库"))
    path = tmp_path / "blocked.g1-backup.json"
    monkeypatch.setattr("sys.argv", ["backup_db", "--output", str(path)])
    with pytest.raises(SystemExit) as result:
        backup_db.main()
    assert result.value.code == 1
    assert json.loads(capsys.readouterr().out)["status"] == "blocked"
    assert not path.exists()
