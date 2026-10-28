"""输出模型缺口或真实MySQL结构；缺少模型时退出非零。"""

import argparse
from pathlib import Path

from sqlalchemy import inspect, text

from app.settings import Settings
from common.model_registry import expected_inventory, load_models
from tools.db_guard import configured_database, inspect_group, write_result


def reflect_manifest(connection, schemas) -> dict:
    inspector = inspect(connection)
    result = {}
    reverse = {value: key for key, value in schemas.mapping.items()}
    for domain, physical in schemas.mapping.items():
        for name in sorted(inspector.get_table_names(schema=physical)):
            if name == "alembic_version":
                continue
            result[f"{domain}.{name}"] = {
                "columns": [
                    {
                        "name": c["name"],
                        "type": str(c["type"]),
                        "nullable": c["nullable"],
                        "default": c.get("default"),
                        "computed": c.get("computed"),
                    }
                    for c in inspector.get_columns(name, schema=physical)
                ],
                "primary_key": inspector.get_pk_constraint(name, schema=physical),
                "foreign_keys": [
                    {
                        **fk,
                        "referred_schema": reverse.get(
                            fk["referred_schema"], fk["referred_schema"]
                        ),
                    }
                    for fk in inspector.get_foreign_keys(name, schema=physical)
                ],
                "indexes": inspector.get_indexes(name, schema=physical),
                "index_columns": [
                    dict(row._mapping)
                    for row in connection.execute(
                        text(
                            "SELECT INDEX_NAME, COLUMN_NAME, COLLATION, EXPRESSION, SUB_PART "
                            "FROM information_schema.STATISTICS "
                            "WHERE TABLE_SCHEMA=:schema AND TABLE_NAME=:name "
                            "ORDER BY INDEX_NAME, SEQ_IN_INDEX"
                        ),
                        {"schema": physical, "name": name},
                    )
                ],
                "unique_constraints": inspector.get_unique_constraints(name, schema=physical),
                "checks": inspector.get_check_constraints(name, schema=physical),
                "options": inspector.get_table_options(name, schema=physical),
            }
    return result


def design_differences(tables: dict) -> list[str]:
    expected = expected_inventory()["tables"]
    differences = [f"缺表:{name}" for name in sorted(set(expected) - set(tables))]
    differences += [f"额外表:{name}" for name in sorted(set(tables) - set(expected))]
    for key in sorted(set(tables) & set(expected)):
        columns = {c["name"]: c for c in tables[key]["columns"]}
        for name, spec in expected[key]["columns"].items():
            if name not in columns:
                differences.append(f"缺列:{key}.{name}")
            elif columns[name]["nullable"] != spec["nullable"]:
                differences.append(f"可空性不符:{key}.{name}")
    return differences


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", action="store_true")
    parser.add_argument("--purpose", choices=["dev", "test"], default="dev")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    database = None
    try:
        if args.models:
            report = load_models(require_complete=False)
            complete = not any(
                report[k] for k in ("missing_modules", "missing_tables", "unexpected_tables")
            )
            result = {
                "status": "passed" if complete else "blocked",
                "scope": "仅模型清单",
                **report,
            }
        else:
            database = configured_database(Settings(), args.purpose)
            with database.engine.connect() as connection:
                identity = inspect_group(connection, database.schemas)
                tables = reflect_manifest(connection, database.schemas)
            diff = design_differences(tables)
            result = {
                "status": "passed" if not diff else "failed",
                "identity": identity,
                "business_table_count": len(tables),
                "tables": tables,
                "differences": diff,
                "scope": "真实结构及字段可空性对照；完整类型／默认／FK／索引比较由verify_db执行。",
            }
    except Exception:
        result = {"status": "failed", "reason": "模型清单或数据库结构反射失败，请核对模型及配置。"}
    finally:
        if database:
            database.close()
    write_result(result, args.output)
    if result["status"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
