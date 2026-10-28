"""仅创建随机test_七库及临时账号；不写现有开发／测试库。"""

import os
import secrets
from contextlib import contextmanager
from pathlib import Path

import pytest
from sqlalchemy import CHAR, Column, MetaData, Table, create_engine
from sqlalchemy.engine import URL

from common.database_config import SchemaGroup
from common.db import Database
from common.model_base import TABLE_OPTIONS, Base
from common.model_registry import load_models
from tools.bootstrap_db import bootstrap, grant_platform
from tools.freeze_baseline import compile_metadata


@contextmanager
def mysql_group():
    path = os.environ.get("STEP2_BOOTSTRAP_ENV")
    if not path:
        raise pytest.fail.Exception("真实MySQL集成需要显式STEP2_BOOTSTRAP_ENV；未执行不能判通过。")
    config = dict(
        line.split("=", 1)
        for line in Path(path).read_text("utf-8-sig").splitlines()
        if line.strip() and not line.startswith("#") and "=" in line
    )
    token = secrets.token_hex(5)
    schemas = SchemaGroup(f"test_a{token}_")
    migrate, business = f"a{token}_migration", f"a{token}_business"
    migration_password, password = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    root_url = URL.create(
        "mysql+pymysql",
        username="root",
        password=config["DB_ROOT_PASSWORD"],
        host=config["DB_DEV_HOST"],
        port=int(config["DB_DEV_PORT"]),
    )
    admin = create_engine(root_url, hide_parameters=True, connect_args={"connect_timeout": 5})
    database = None
    migration = None
    created_objects = []
    try:
        with admin.connect() as connection:
            # bootstrap自己检查所有目标原本不存在；命名随机且仅清理本次对象。
            bootstrap(
                connection,
                schemas,
                migrate,
                migration_password,
                business,
                password,
                created_objects=created_objects,
            )
        url = root_url.set(
            username=business, password=password, database=schemas.mapping["identity_org"]
        )
        database = Database(url.render_as_string(hide_password=False), schema_prefix=schemas.prefix)
        migration_url = url.set(username=migrate, password=migration_password)
        migration = Database(
            migration_url.render_as_string(hide_password=False), schema_prefix=schemas.prefix
        )
        load_models(require_complete=False)
        metadata = MetaData(naming_convention=Base.metadata.naming_convention)
        # 只属于测试夹具的最小用户表，用于验证A的跨域FK；不注册到生产Base。
        Table(
            "user",
            metadata,
            Column("user_id", CHAR(36, collation="utf8mb4_0900_ai_ci"), primary_key=True),
            schema="identity_org",
            **TABLE_OPTIONS,
        )
        for table in list(Base.metadata.tables.values()):
            if table.schema == "platform":
                table.to_metadata(metadata)
        with migration.engine.begin() as connection:
            # 验证正式快照采用的DDL编译路径；生产61表快照仍须等待全域交接。
            for statement in compile_metadata(metadata):
                for domain, physical in schemas.mapping.items():
                    statement = statement.replace(f"__db_{domain}__", physical)
                connection.exec_driver_sql(statement)
        with admin.connect() as connection:
            grant_platform(connection, schemas, business)
        yield {
            "database": database,
            "migration": migration,
            "schemas": schemas,
            "admin": admin,
            "metadata": metadata,
        }
    except Exception as error:
        # 不输出驱动异常中的口令／参数。
        arguments = getattr(error, "orig", error).args
        code = arguments[0] if arguments and isinstance(arguments[0], int) else "unknown"
        raise pytest.fail.Exception(
            f"隔离MySQL夹具失败（{type(error).__name__}，阶段{len(created_objects)}，"
            f"错误码{code}），不是G1通过证据。",
            pytrace=False,
        ) from None
    finally:
        if database:
            database.close()
        if migration:
            migration.close()
        if created_objects:
            with admin.connect() as connection:
                for kind, name in reversed(created_objects):
                    if kind == "database":
                        assert name in schemas.mapping.values()
                        connection.exec_driver_sql(f"DROP DATABASE `{name}`")
                    else:
                        assert name in (migrate, business)
                        connection.exec_driver_sql(f"DROP USER '{name}'@'%%'")
                connection.commit()
        admin.dispose()


@pytest.fixture(scope="session")
def isolated_mysql():
    with mysql_group() as database:
        yield database


@pytest.fixture
def backup_pair():
    # 两个独立随机七库／账号组；不访问或清理既有开发库。
    with mysql_group() as source, mysql_group() as target:
        yield source, target


@pytest.fixture
def model_example_mysql():
    # 样板运行在自己的随机库组，不污染61表或其他结构对照夹具。
    with mysql_group() as database:
        yield database
