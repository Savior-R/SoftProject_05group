"""MySQL七域唯一迁移入口；所有预检发生在创建版本表／业务表之前。"""

from alembic import context
from alembic.script import ScriptDirectory
from sqlalchemy import text

from app.settings import Settings
from common.model_base import Base
from common.model_registry import load_models
from tools.db_guard import (
    configured_database,
    inspect_group,
    inspect_permissions,
    require_empty_baseline,
    schema_name_filter,
)
from tools.freeze_baseline import load_snapshot

config = context.config


def run_migrations() -> None:
    if context.is_offline_mode():
        raise RuntimeError("禁止绕过数据库身份检查生成可直接执行的离线迁移。")
    args = context.get_x_argument(as_dictionary=True)
    purpose = args.get("purpose", "dev")
    if purpose not in {"dev", "test"}:
        raise ValueError("迁移purpose只允许dev或test。")
    database = None
    try:
        settings = Settings()
        database = configured_database(settings, purpose, migration=True)
        load_snapshot()  # 没有完整冻结快照时，连alembic_version也不能创建。
        load_models()
        script = ScriptDirectory.from_config(config)
        if len(script.get_heads()) != 1:
            raise RuntimeError("迁移图必须只有一个head。")
        known_revisions = {revision.revision for revision in script.walk_revisions()}
        command = getattr(config.cmd_opts, "cmd", None)
        if command and command[0].__name__ in {"stamp", "downgrade", "ensure_version"}:
            raise RuntimeError("本入口不允许伪造版本、提前建版本表或自动删库回退。")
        with database.engine.connect() as connection:
            identity = inspect_group(connection, database.schemas)
            inspect_permissions(connection, database.schemas, migration=True)
            version_key = f"{database.schemas.version_schema}.alembic_version"
            if version_key not in identity["tables"]:
                require_empty_baseline(connection, database.schemas)
            else:
                revisions = (
                    connection.exec_driver_sql(
                        "SELECT version_num FROM "
                        f"`{database.schemas.version_schema}`.alembic_version"
                    )
                    .scalars()
                    .all()
                )
                if len(revisions) != 1 or revisions[0] not in known_revisions:
                    raise ValueError("未知、空或多分支迁移版本，拒绝自动恢复／覆盖。")
            connection.commit()
            # MySQL DDL隐式提交；不承诺失败后能靠事务自动回滚DDL。
            locked = connection.execute(
                text("SELECT GET_LOCK('ai_teach_baseline_320', 5)")
            ).scalar()
            if locked != 1:
                raise RuntimeError("迁移锁被占用，拒绝并行迁移。")
            connection.commit()
            try:
                # 锁后复查，防止两个初始化进程都在锁前看见空库。
                latest = inspect_group(connection, database.schemas)
                if version_key not in latest["tables"]:
                    require_empty_baseline(connection, database.schemas)
                elif latest["tables"] != identity["tables"]:
                    raise RuntimeError("等待迁移锁期间结构变化，请重新运行预检。")
                connection.commit()
                context.configure(
                    connection=connection,
                    target_metadata=Base.metadata,
                    include_schemas=True,
                    compare_type=True,
                    compare_server_default=True,
                    version_table_schema=database.schemas.version_schema,
                    include_name=schema_name_filter(
                        database.schemas, connection.dialect.default_schema_name
                    ),
                    schema_group=database.schemas,
                )
                with context.begin_transaction():
                    context.run_migrations()
            finally:
                connection.execute(text("SELECT RELEASE_LOCK('ai_teach_baseline_320')"))
                connection.commit()
    except Exception:
        # 第三方连接／DDL异常可能含口令、参数，CLI固定错误防泄露。
        raise RuntimeError("迁移未通过预检或执行失败；请核对模型冻结、库身份及迁移账号。") from None
    finally:
        if database:
            database.close()


run_migrations()
