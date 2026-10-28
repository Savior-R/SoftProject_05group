"""检查锁中绝对路径、项目 wheel hash 和源代码是否对应。"""

import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path


def inspect_lock(root: Path) -> dict[str, object]:
    lock = root / "requirements.lock"
    content = lock.read_text(encoding="utf-8")
    if re.search(r"[A-Za-z]:[\\/]|file://|\\\\", content):
        raise ValueError("requirements.lock 含本机绝对路径或 file/UNC 依赖。")
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "--hash=")):
            continue
        if stripped.startswith("/") or " @ /" in stripped:
            raise ValueError("requirements.lock 含绝对路径依赖。")
    entries = re.findall(
        r"^\./wheels/([^\s/]+\.whl) --hash=sha256:([a-f0-9]{64})$", content, re.MULTILINE
    )
    if len(entries) != 1:
        raise ValueError("lock 必须恰好包含一条带 sha256 的相对路径项目 wheel。")
    filename, expected_hash = entries[0]
    wheel = root / "wheels" / filename
    actual_hash = hashlib.sha256(wheel.read_bytes()).hexdigest()
    if actual_hash != expected_hash:
        raise ValueError("wheel hash 与 requirements.lock 不一致。")
    packages = ("app", "common", "tools")
    with zipfile.ZipFile(wheel) as archive:
        for package in packages:
            if f"{package}/__init__.py" not in archive.namelist():
                raise ValueError(f"wheel 漏打包：{package}")
            source_files = {
                path.relative_to(root).as_posix(): path
                for path in (root / package).rglob("*")
                if path.is_file() and path.suffix in {".py", ".json"}
            }
            packaged_files = {
                name
                for name in archive.namelist()
                if name.startswith(f"{package}/") and name.endswith((".py", ".json"))
            }
            if set(source_files) != packaged_files:
                raise ValueError(f"wheel 与 {package} 文件清单不同，请重新构建。")
            for name, source_path in source_files.items():
                if archive.read(name) != source_path.read_bytes():
                    raise ValueError(f"wheel 中 {name} 已过期，请重新构建。")
    return {
        "status": "passed",
        "absolute_paths": False,
        "packages": list(packages),
        "wheel": filename,
        "wheel_sha256": actual_hash,
        "lock_sha256": hashlib.sha256(lock.read_bytes()).hexdigest(),
    }


def main() -> None:
    try:
        result = inspect_lock(Path(__file__).resolve().parents[1])
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"T05 lock 检查失败：{error}", file=sys.stderr)
        raise SystemExit(1) from None
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
