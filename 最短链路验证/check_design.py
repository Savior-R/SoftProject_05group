"""读取当前文档进行静态/参考函数检查，仅写本目录检查结果，不重生成设计文档。"""
from __future__ import annotations

import ast
import hashlib
import json
import re
import sys
from datetime import datetime, timezone, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "设计文档3.x"
OUTPUT = Path(__file__).with_name("检查结果.json")
EXPECTED = ["00-README.md", "01-需求规格说明书-SRS.md", "02-产品需求文档-PRD.md",
    "03-系统概要设计-HLD.md", "04-详细设计-LLD.md", "05-数据库设计文档-V2.md",
    "06-接口设计文档.md", "07-UI-UX原型说明.md", "08-测试计划与测试用例.md",
    "09-部署运维方案.md", "10-本地零成本部署手册.md", "11-实现契约.md",
    "12-修订追踪与验收门禁.md", "V3移交说明.md"]


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def digest():
    return {str(p.relative_to(DOCS)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in DOCS.rglob("*") if p.is_file()}


def main():
    before = digest()
    checks = []
    contents = {}
    contract = {}

    def check(name, fn):
        try:
            detail = fn()
            checks.append({"name": name, "status": "passed", "detail": detail})
            print(f"[PASS] {name}")
        except Exception as exc:
            checks.append({"name": name, "status": "failed", "detail": f"{type(exc).__name__}: {exc}"})
            print(f"[FAIL] {name}: {exc}")

    def structure():
        for filename in EXPECTED:
            path = DOCS / filename
            require(path.is_file(), f"缺少 {filename}")
            contents[filename] = path.read_text(encoding="utf-8-sig")
            require("3.2.0" in contents[filename][:600], f"版本不一致: {filename}")
        return {"markdown": len(contents), "version": "3.2.0"}

    def markup():
        links = 0
        for path in sorted(DOCS.rglob('*.md')):
            filename = path.relative_to(DOCS).as_posix()
            content = path.read_text(encoding='utf-8-sig')
            require(len(re.findall(r"^```", content, re.M)) % 2 == 0, filename + " 代码围栏不配对")
            expected = None
            fenced = False
            for line_number, line in enumerate(content.splitlines(), 1):
                if line.startswith("```"):
                    fenced = not fenced
                    expected = None
                    continue
                if fenced:
                    continue
                if line.startswith("|"):
                    count = len(re.findall(r"(?<!\\)\|", line))
                    if expected is None:
                        expected = count
                    require(count == expected, f"{filename}:{line_number} 表格列数不一致")
                else:
                    expected = None
            for link in re.findall(r"\]\(([^)]+)\)", content):
                if "://" in link or link.startswith("#"):
                    continue
                require((path.parent / link.split("#", 1)[0].strip("<>")).exists(), filename + " 断链 " + link)
                links += 1
        return {"relative_links": links}

    def contracts():
        contract.update(json.loads((DOCS / "api-contract.json").read_text(encoding="utf-8")))
        dtos, enums = contract["dtos"], contract["enums"]
        endpoints = contract["endpoints"]
        keys = [(a["method"], a["path"]) for a in endpoints]
        require(len(set(keys)) == len(keys), "接口方法和路径重复")
        special_permissions = {"公开", "refresh", "已登录", "内部服务凭据", "运维探针"}
        for entry in endpoints:
            for key in ("request", "response"):
                for name in re.findall(r"\b[A-Z][A-Za-z0-9]*\b", entry[key]):
                    require(name in dtos or name in {"Page", "Partial"}, f"{entry['path']} 未定义类型 {name}")
            for permission in entry["permission"].split("|"):
                require(permission in contract["permissions"] or permission in special_permissions, "未知权限 " + permission)
            require(entry["status"] != 204 or entry["response"] == "Empty", "204响应有内容")
        for dto_name, definition in dtos.items():
            if dto_name == "BinaryPart":
                continue
            for field in definition["fields"].split("; "):
                spec = re.sub(r"enum\([^)]*\)|const\([^)]*\)", "", field.partition(":")[2])
                for name in re.findall(r"\b[A-Z][A-Za-z0-9]*\b", spec):
                    require(name in dtos or name in enums or name in {"Page", "Partial"}, f"{dto_name} 未定义嵌套类型 {name}")
        essential = [("POST", p) for p in ["/auth/login", "/rubrics", "/rubrics/{rubric_id}/publish",
            "/tasks", "/tasks/{task_id}/publish", "/sessions", "/sessions/{session_id}/start",
            "/sessions/{session_id}/finish", "/recordings/init", "/media-uploads/{upload_id}/complete",
            "/sessions/{session_id}/submit", "/reports/{session_id}/teacher-reviews",
            "/reports/{session_id}/teacher-reviews/{review_id}/submit",
            "/reports/{session_id}/teacher-reviews/{review_id}/set-primary"]]
        essential += [("PUT", "/media-uploads/{upload_id}/parts/{part_no}"), ("GET", "/reports/{session_id}")]
        for key in essential:
            require(key in keys, "最短闭环缺少接口 " + str(key))
        return {"endpoints": len(endpoints), "dtos": len(dtos), "essential_routes": len(essential)}

    def database():
        text = contents["05-数据库设计文档-V2.md"]
        names = re.findall(r"^####[^\n]*`([a-z_]+\.[a-z_]+)`", text, re.M)
        names += re.findall(r"^### `([a-z_]+\.[a-z_]+)`", text, re.M)
        require(len(names) == len(set(names)) == 61, f"目标实体数应61，实际{len(names)}")
        require("WHERE active_primary_report_id IS NOT NULL" not in text, "残留不支持的过滤索引")
        require(not re.search(r"UNIQUEIDENTIFIER|DATETIME2|NVARCHAR|SYSUTCDATETIME|ISJSON|\[status\]", text), "字段字典残留非MySQL类型或语法")
        require("仅开发全新 61 表数据库" in text and "仅使用MySQL" in text, "数据库范围决定缺失")
        require("JSON_ARRAY()" in text and "JSON_VALID(" in text and "GENERATED ALWAYS AS" in text, "MySQL关键类型与约束定义缺失")
        require("max_score BETWEEN 0 AND 100" not in text, "残留允许满分为0的约束")
        return {"entities": len(names), "scope": "仅61实体字典、MySQL类型及关键约束和范围检查，没有执行DDL"}

    def coverage():
        fr = set(re.findall(r"FR-\d{2}-\d+", contents["01-需求规格说明书-SRS.md"]))
        tests = set(re.findall(r"FR-\d{2}-\d+", contents["08-测试计划与测试用例.md"]))
        require(fr <= tests, "测试缺少需求 " + str(fr - tests))
        return {"FR": len(fr), "scope": "检查追踪编号存在，不代表用例已执行或覆盖充分"}

    def scoring():
        # 文档是输入数据；只加载已审核的四个纯评分函数，不执行整篇代码或生成脚本。
        blocks = re.findall(r"```python\n(.*?)```", contents["04-详细设计-LLD.md"], re.S)
        block = next(b for b in blocks if "def aggregate(" in b)
        tree = ast.parse(block)
        allowed = {"dec", "dimension_score", "aggregate", "grade_of"}
        nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in allowed]
        require({n.name for n in nodes} == allowed, "四个评分函数缺失")
        for node in ast.walk(ast.Module(body=nodes, type_ignores=[])):
            require(not isinstance(node, (ast.Import, ast.ImportFrom, ast.Global, ast.Nonlocal)), "评分函数含非纯函数结构")
            if isinstance(node, ast.Attribute):
                require(not node.attr.startswith("_"), "评分函数使用私有属性")
        dims = tuple(contract["enums"]["Dimension"].split(","))
        env = {"__builtins__": {"str": str, "set": set, "sum": sum, "any": any, "abs": abs, "len": len, "ValueError": ValueError},
               "Decimal": Decimal, "ROUND_HALF_UP": ROUND_HALF_UP, "DIMENSIONS": dims}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), "<selected-scoring-functions>", "exec"), env)
        weights = dict(zip(dims, [.25, .2, .15, .2, .1, .1]))
        scores = {d: 80 for d in dims}
        require(env["aggregate"](scores, weights) == Decimal("80.00"), "六维汇总错误")
        require(env["aggregate"]({d: 80 if i < 3 else None for i, d in enumerate(dims)}, weights) is None, "仅三维不应有总分")
        four = {d: 80 if i < 4 else None for i, d in enumerate(dims)}
        require(env["aggregate"](four, weights) == Decimal("80.00"), "四维重归一错误")
        require(env["aggregate"](four, dict(zip(dims, [0, 0, 0, 0, .5, .5]))) is None, "可用权重零不应有总分")
        item = {"item_id": "a", "max_score": 100, "weight_in_dimension": 1}
        require(env["dimension_score"]([item], {"a": "80.005"}) == Decimal("80.01"), "舍入错误")
        require(env["dimension_score"]([item], {}) is None, "缺分不应补零")
        invalid = [lambda: env["dimension_score"]([{**item, "max_score": 0}], {"a": 0}),
                   lambda: env["aggregate"]({**scores, dims[0]: "NaN"}, weights),
                   lambda: env["grade_of"](101)]
        for fn in invalid:
            try:
                fn()
            except ValueError:
                continue
            raise AssertionError("非法输入未拒绝")
        require(env["grade_of"](80) == "good" and env["grade_of"](None) is None, "等级边界错误")
        return {"assertion_groups": 10, "scope": "评分纯函数参考执行，未执行应用业务"}

    check("文档文件和版本", structure)
    check("链接、代码围栏和表格", markup)
    check("接口、DTO、权限及最短路由", contracts)
    check("数据库字典及已知约束冲突", database)
    check("FR需求追踪", coverage)
    check("评分参考函数边界", scoring)
    check("设计文档未被检查脚本改写", lambda: require(before == digest(), "设计文档内容发生改变"))
    status = "passed" if all(c["status"] == "passed" for c in checks) else "failed"
    report = {"status": status, "generated_at": datetime.now(timezone(timedelta(hours=8))).isoformat(),
        "checks": checks, "application_present": (ROOT / "app/backend/app/main.py").is_file(),
        "not_run": ["真实SQL新库初始化、约束及恢复", "应用HTTP/WS/浏览器", "真实上传与媒体对齐", "真实GLM模型", "效果与性能"],
        "meaning": "passed仅表示所列静态检查和参考函数检查通过，不是开发文档完整正确或系统验收通过"}
    OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"\n结果: {status}; 报告: {OUTPUT}")
    print("尚未验证: 真实SQL、应用、上传、GLM、效果和性能。")
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
