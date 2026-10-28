"""全域模型交齐后由A冻结初始DDL；不连接数据库，不覆盖已冻结快照。"""

import argparse
import hashlib
import json
from importlib.resources import files
from pathlib import Path

from sqlalchemy.dialects.mysql import dialect
from sqlalchemy.schema import AddConstraint, CreateIndex, CreateTable
from sqlalchemy.sql.ddl import sort_tables_and_constraints

from common.database_config import DOMAINS
from common.model_base import Base
from common.model_registry import expected_inventory, load_models
from tools.db_guard import write_result


def snapshot_statements() -> list[str]:
    load_models()
    return compile_metadata(Base.metadata)


def compile_metadata(metadata) -> list[str]:
    """纯编译器，单独用于验证循环FK排序；正式冻结入口仍强制61表齐全。"""
    translation = {d: f"__db_{d}__" for d in DOMAINS}

    def compile_ddl(value):
        return str(
            value.compile(
                dialect=dialect(),
                schema_translate_map=translation,
                render_schema_translate=True,
            )
        )

    statements = []
    for table, constraints in sort_tables_and_constraints(metadata.tables.values()):
        if table is not None:
            statements.append(
                compile_ddl(CreateTable(table, include_foreign_key_constraints=constraints))
            )
            statements.extend(
                compile_ddl(CreateIndex(idx)) for idx in sorted(table.indexes, key=lambda x: x.name)
            )
        else:
            statements.extend(
                compile_ddl(AddConstraint(fk)) for fk in sorted(constraints, key=lambda x: x.name)
            )
    return statements


def load_snapshot() -> dict:
    resource = files("tools").joinpath("data/baseline_320.json")
    if not resource.is_file():
        raise RuntimeError("61表模型／约束尚未全部交接冻结，拒绝任何初始化DDL。")
    snapshot = json.loads(resource.read_text("utf-8"))
    expected = expected_inventory()
    if (
        snapshot.get("revision") != "0001_baseline_320"
        or snapshot.get("tables") != sorted(expected["tables"])
        or snapshot.get("design_sha256") != expected["source_sha256"]
        or hashlib.sha256("\n".join(snapshot["statements"]).encode()).hexdigest()
        != snapshot.get("ddl_sha256")
    ):
        raise RuntimeError("冻结快照范围或校验摘要无效。")
    return snapshot


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--reviewed-design",
        action="store_true",
        required=True,
        help="A确认全部模型已逐项核对05号字段、类型、默认、FK、CHECK与索引",
    )
    parser.parse_args()
    try:
        target = Path(__file__).resolve().parent / "data/baseline_320.json"
        if target.exists():
            raise RuntimeError("已冻结快照不可覆盖；后续结构变更应新建revision。")
        statements = snapshot_statements()
        snapshot = {
            "revision": "0001_baseline_320",
            "tables": sorted(expected_inventory()["tables"]),
            "design_sha256": expected_inventory()["source_sha256"],
            "ddl_sha256": hashlib.sha256("\n".join(statements).encode()).hexdigest(),
            "statements": statements,
        }
        with target.open("x", encoding="utf-8", newline="\n") as output:
            json.dump(snapshot, output, ensure_ascii=False, indent=2)
            output.write("\n")
        write_result({"status": "passed", "scope": "仅冻结DDL；仍须真实MySQL G1验证"})
    except Exception:
        write_result(
            {"status": "blocked", "reason": "模型未齐全、字段／FK有误或快照已冻结；未覆盖快照。"}
        )
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
