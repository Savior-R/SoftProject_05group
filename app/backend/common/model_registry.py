"""全域模型注册；缺失必须显式报告，不用占位表补齐61表。"""

import importlib
import json
from importlib.resources import files

from common.database_config import DOMAINS
from common.model_base import Base


def expected_inventory() -> dict:
    return json.loads(
        files("tools").joinpath("data/schema-manifest.expected.json").read_text("utf-8")
    )


def load_models(*, require_complete: bool = True):
    missing_modules = []
    for domain in DOMAINS:
        name = f"app.{domain}.models"
        try:
            importlib.import_module(name)
        except ModuleNotFoundError as error:
            if error.name not in {f"app.{domain}", name}:
                raise
            missing_modules.append(name)
    expected = expected_inventory()
    actual = set(Base.metadata.tables)
    required = set(expected["tables"])
    report = {
        "expected_count": len(required),
        "registered_count": len(actual),
        "missing_tables": sorted(required - actual),
        "unexpected_tables": sorted(actual - required),
        "missing_modules": missing_modules,
    }
    if require_complete:
        if report["missing_tables"] or report["unexpected_tables"] or missing_modules:
            raise RuntimeError("七域模型未齐全；请先运行 tools.db_manifest --models 核对交接清单。")
        # 真实解析跨域FK，不以占位表绕过关联错误。
        for table in Base.metadata.tables.values():
            for fk in table.foreign_keys:
                _ = fk.column
            required_columns = set(expected["tables"][table.key]["columns"])
            if not required_columns.issubset(table.columns.keys()):
                raise RuntimeError("域模型缺少05号字典字段，拒绝初始化。")
    return report
