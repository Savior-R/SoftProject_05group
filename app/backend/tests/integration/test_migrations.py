"""当前验证迁移拒绝边界；完整61表初始化／重复head／恢复待各域交接。"""

import pytest
from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory

from tools.db_guard import require_empty_baseline


def test_single_revision_graph():
    script = ScriptDirectory.from_config(Config("alembic.ini"))
    assert script.get_heads() == ["0001_baseline_320"]
    assert script.get_revision("0001_baseline_320").down_revision is None


def test_nonempty_unmanaged_group_is_refused(isolated_mysql):
    with isolated_mysql["migration"].engine.connect() as connection:
        with pytest.raises(ValueError, match="非空库"):
            require_empty_baseline(connection, isolated_mysql["schemas"])


def test_missing_snapshot_refuses_before_database_access(monkeypatch, tmp_path):
    from sqlalchemy.engine import Engine

    from tools import freeze_baseline

    calls = []

    def unexpected_connect(*args, **kwargs):
        calls.append(True)
        raise AssertionError("不得在缺失快照时连库")

    monkeypatch.setattr(Engine, "connect", unexpected_connect)
    monkeypatch.setattr(freeze_baseline, "files", lambda package: tmp_path)
    monkeypatch.setenv("ENV", "dev")
    monkeypatch.setenv(
        "DATABASE_URL", "mysql+pymysql://business:FAKE_SECRET@localhost/identity_org"
    )
    monkeypatch.setenv(
        "MIGRATION_DATABASE_URL", "mysql+pymysql://migration:FAKE_SECRET@localhost/identity_org"
    )
    with pytest.raises(RuntimeError) as error:
        command.upgrade(Config("alembic.ini"), "head")
    assert not calls
    assert "FAKE_SECRET" not in str(error.value)
