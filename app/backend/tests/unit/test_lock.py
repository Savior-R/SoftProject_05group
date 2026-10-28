"""验收工具本身必须拒绝绝对路径、错 hash 和过期项目 wheel。"""

import hashlib
import zipfile
from pathlib import Path

import pytest

from tools.verify_lock import inspect_lock


@pytest.fixture
def release(tmp_path: Path) -> Path:
    wheel = tmp_path / "wheels/ai_teach_backend-0.1.0-py3-none-any.whl"
    wheel.parent.mkdir()
    with zipfile.ZipFile(wheel, "w") as archive:
        for package in ("app", "common", "tools"):
            source = tmp_path / package / "__init__.py"
            source.parent.mkdir()
            source.write_text('"""test package"""\n', encoding="utf-8")
            archive.writestr(f"{package}/__init__.py", source.read_bytes())
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    (tmp_path / "requirements.lock").write_text(
        f"./wheels/{wheel.name} --hash=sha256:{digest}\n", encoding="utf-8"
    )
    return tmp_path


def test_valid_relative_wheel(release: Path) -> None:
    assert inspect_lock(release)["absolute_paths"] is False


@pytest.mark.parametrize("absolute", ["D:/private/path", "file:///C:/private", "/private/path"])
def test_reject_absolute_paths(release: Path, absolute: str) -> None:
    with (release / "requirements.lock").open("a", encoding="utf-8") as output:
        output.write(absolute + "\n")
    with pytest.raises(ValueError, match="绝对路径"):
        inspect_lock(release)


def test_reject_stale_wheel(release: Path) -> None:
    (release / "app/__init__.py").write_text("# new source\n", encoding="utf-8")
    with pytest.raises(ValueError, match="过期"):
        inspect_lock(release)


def test_reject_wrong_hash(release: Path) -> None:
    wheel = next((release / "wheels").glob("*.whl"))
    wheel.write_bytes(wheel.read_bytes() + b"tamper")
    with pytest.raises(ValueError, match="hash"):
        inspect_lock(release)
