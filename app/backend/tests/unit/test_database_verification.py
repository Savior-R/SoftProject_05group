"""防止暖认证缓存或缺少测试库配置掩盖真实数据库验证缺失。"""

import importlib

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from pymysql import _auth

from tools.verify_database import require_rsa_support, validate_test_database_url


def test_mysql_rsa_full_authentication_dependency() -> None:
    require_rsa_support()
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_key = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    password, salt = b"FAKE_TEST_PASSWORD", b"12345678901234567890"
    encrypted = _auth.sha2_rsa_encrypt(password, salt, public_key)
    decrypted = key.decrypt(
        encrypted,
        padding.OAEP(mgf=padding.MGF1(hashes.SHA1()), algorithm=hashes.SHA1(), label=None),
    )
    assert decrypted == _auth._xor_password(password + b"\0", salt)


def test_missing_rsa_dependency_is_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    def missing(name: str):
        raise ImportError(name)

    monkeypatch.setattr(importlib, "import_module", missing)
    with pytest.raises(RuntimeError, match="RSA"):
        require_rsa_support()


@pytest.mark.parametrize(
    "url",
    [
        None,
        "",
        "invalid-secret",
        "mysql+aiomysql://u:FAKE_SECRET@localhost/identity_org",
        "sqlite:///test_identity_org",
        "mysql+aiomysql://u:FAKE_SECRET@localhost/test_arbitrary",
    ],
)
def test_missing_or_unsafe_database_cannot_pass(url: str | None) -> None:
    with pytest.raises(ValueError) as error:
        validate_test_database_url(url)
    assert "FAKE_SECRET" not in str(error.value)
    assert "invalid-secret" not in str(error.value)


def test_only_explicit_test_database_is_accepted() -> None:
    value = "mysql+aiomysql://u:FAKE_SECRET@127.0.0.1/test_identity_org"
    assert validate_test_database_url(value) == value
