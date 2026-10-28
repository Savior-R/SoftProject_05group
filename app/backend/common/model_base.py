"""所有域共用的唯一Base／metadata及MySQL类型约定。"""

from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import CHAR, JSON, MetaData, Numeric
from sqlalchemy.dialects.mysql import DATETIME
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy.types import TypeDecorator

COLLATION = "utf8mb4_0900_ai_ci"
TABLE_OPTIONS = {"mysql_engine": "InnoDB", "mysql_charset": "utf8mb4", "mysql_collate": COLLATION}
NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_name)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class UUIDText(TypeDecorator):
    impl = CHAR(36, collation=COLLATION)
    cache_ok = True

    def process_bind_param(self, value, dialect):
        return None if value is None else str(UUID(str(value)))

    def process_result_value(self, value, dialect):
        return None if value is None else UUID(value)


class UTCDateTime(TypeDecorator):
    impl = DATETIME(fsp=3)
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is None:
            return None
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("时间必须带时区；写入时统一转换为UTC。")
        return value.astimezone(UTC).replace(tzinfo=None)

    def process_result_value(self, value, dialect):
        return None if value is None else value.replace(tzinfo=UTC)


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)
    type_annotation_map = {
        UUID: UUIDText(),
        datetime: UTCDateTime(),
        Decimal: Numeric(5, 2, asdecimal=True),
        dict[str, object]: JSON(),
        list[object]: JSON(),
    }
