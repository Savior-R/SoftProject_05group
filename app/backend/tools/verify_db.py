"""真实结构核对；G1未交齐时失败，不能把反射／SELECT 1当整体验收。"""

import argparse
from pathlib import Path

from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from sqlalchemy import CheckConstraint, Column, MetaData
from sqlalchemy.sql import operators
from sqlalchemy.sql.elements import UnaryExpression

from app.settings import Settings
from common.model_base import Base
from common.model_registry import load_models
from tools.check_expression import canonical_check
from tools.db_guard import configured_database, inspect_group, schema_name_filter, write_result
from tools.db_manifest import design_differences, reflect_manifest
from tools.freeze_baseline import load_snapshot


def translated_metadata(mapping, source=None) -> MetaData:
    metadata = MetaData(naming_convention=Base.metadata.naming_convention)
    for table in (Base.metadata if source is None else source).tables.values():
        table.to_metadata(
            metadata,
            schema=mapping[table.schema],
            referred_schema_fn=lambda table, to_schema, constraint, referred: mapping[referred],
        )
    return metadata


def verify_schema(connection, schemas) -> dict:
    load_models()
    load_snapshot()
    tables = reflect_manifest(connection, schemas)
    diff = design_differences(tables)
    physical = translated_metadata(schemas.mapping)
    changes = model_differences(connection, physical, schemas)
    if changes:
        # 不输出可能携带默认参数的第三方对象repr。
        diff.append(f"模型／实库列、类型、默认或索引差异:{len(changes)}")
    diff.extend(index_differences(Base.metadata, tables))
    # Alembic不会完整检测所有CHECK，必须独立核对声明与实库约束。
    for key, table in Base.metadata.tables.items():
        actual = tables.get(key, {})
        checks = {check["name"]: check["sqltext"] for check in actual.get("checks", [])}
        required = {
            str(c.name): str(c.sqltext) for c in table.constraints if isinstance(c, CheckConstraint)
        }
        if set(required) != set(checks):
            diff.append(f"CHECK清单差异:{key}")
        for name in set(required) & set(checks):
            if canonical_check(required[name]) != canonical_check(checks[name]):
                diff.append(f"CHECK表达式差异:{key}.{name}")
    revision = (
        connection.exec_driver_sql(
            f"SELECT version_num FROM `{schemas.version_schema}`.alembic_version"
        )
        .scalars()
        .all()
    )
    if revision != ["0001_baseline_320"]:
        diff.append("迁移版本不是唯一初始head")
    return {
        "status": "passed" if not diff else "failed",
        "differences": diff,
        "business_table_count": len(tables),
        "scope": "仅结构；不替代约束负例和备份恢复证据",
    }


def model_differences(connection, physical, schemas):
    context = MigrationContext.configure(
        connection,
        opts={
            "include_schemas": True,
            "compare_type": True,
            "compare_server_default": True,
            "version_table_schema": schemas.version_schema,
            "include_name": schema_name_filter(schemas, connection.dialect.default_schema_name),
        },
    )
    return compare_metadata(context, physical)


def index_differences(metadata, reflected):
    """MySQL反射/Alembic不会可靠比较DESC，独立核对列顺序和方向。"""
    differences = []
    for key, table in metadata.tables.items():
        actual = {}
        for row in reflected.get(key, {}).get("index_columns", []):
            actual.setdefault(row["INDEX_NAME"], []).append(
                (row["COLUMN_NAME"], row["COLLATION"], row["EXPRESSION"], row["SUB_PART"])
            )
        for index in table.indexes:
            required = []
            for expression in index.expressions:
                direction = "A"
                if isinstance(expression, UnaryExpression):
                    if expression.modifier not in {operators.asc_op, operators.desc_op}:
                        raise ValueError("索引表达式须显式扩展比较，不能跳过。")
                    direction = "D" if expression.modifier is operators.desc_op else "A"
                    expression = expression.element
                if not isinstance(expression, Column):
                    raise ValueError("索引表达式须显式扩展比较，不能跳过。")
                required.append((expression.name, direction, None, None))
            if required != actual.get(index.name):
                differences.append(f"索引列顺序／方向差异:{key}.{index.name}")
    return differences


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["schema"], default="schema")
    parser.add_argument("--purpose", choices=["dev", "test"], default="dev")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    database = None
    try:
        # 先检查模型／冻结，缺失时不进行任何数据库操作。
        load_models()
        load_snapshot()
        database = configured_database(Settings(), args.purpose)
        with database.engine.connect() as connection:
            inspect_group(connection, database.schemas)
            result = verify_schema(connection, database.schemas)
    except Exception:
        result = {
            "status": "blocked",
            "reason": "模型／冻结快照／数据库验收前置不齐或结构检查失败。",
        }
    finally:
        if database:
            database.close()
    write_result(result, args.output)
    if result["status"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
