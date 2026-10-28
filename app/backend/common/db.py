"""仅同步的完整事务工作单元；异步消费适配留到真实消费者阶段。"""

import asyncio
import inspect as pyinspect
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import fields, is_dataclass
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from enum import Enum
from threading import Lock, get_ident
from typing import TypeVar
from uuid import UUID

from fastapi import Request
from pydantic import BaseModel
from sqlalchemy import create_engine, event, inspect
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.orm.state import InstanceState

from common.database_config import SchemaGroup, mysql_url

T = TypeVar("T")


class TransactionBoundaryError(RuntimeError):
    pass


def require_sync_thread() -> None:
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return
    raise TransactionBoundaryError("同步数据库事务不能直接在运行事件循环的线程执行。")


class GuardedSession(Session):
    def __init__(self, *args, **kwargs):
        require_sync_thread()
        super().__init__(*args, **kwargs)
        self._owner_thread = get_ident()
        self._managed_work = False

    def assert_owner(self) -> None:
        require_sync_thread()
        if self._owner_thread != get_ident():
            raise TransactionBoundaryError("禁止跨线程共享Session。")

    def execute(self, *args, **kwargs):
        self.assert_owner()
        return super().execute(*args, **kwargs)

    def flush(self, *args, **kwargs):
        self.assert_owner()
        return super().flush(*args, **kwargs)

    def commit(self):
        self.assert_owner()
        self.assert_transaction_owner()
        return super().commit()

    def rollback(self):
        self.assert_owner()
        self.assert_transaction_owner()
        return super().rollback()

    def close(self):
        self.assert_owner()
        self.assert_transaction_owner()
        return super().close()

    def assert_transaction_owner(self):
        if self._managed_work:
            raise TransactionBoundaryError("事务由工作单元统一结束，回调不能提前提交、回滚或关闭。")

    def add(self, *args, **kwargs):
        self.assert_owner()
        return super().add(*args, **kwargs)

    def add_all(self, *args, **kwargs):
        self.assert_owner()
        return super().add_all(*args, **kwargs)

    def delete(self, *args, **kwargs):
        self.assert_owner()
        return super().delete(*args, **kwargs)

    def get(self, *args, **kwargs):
        self.assert_owner()
        return super().get(*args, **kwargs)

    def merge(self, *args, **kwargs):
        self.assert_owner()
        return super().merge(*args, **kwargs)

    def begin(self, *args, **kwargs):
        self.assert_owner()
        return super().begin(*args, **kwargs)

    def connection(self, *args, **kwargs):
        self.assert_owner()
        self.assert_transaction_owner()
        return super().connection(*args, **kwargs)


@event.listens_for(GuardedSession, "before_commit")
def _guard_commit(session):
    session.assert_owner()
    session.assert_transaction_owner()


@event.listens_for(GuardedSession, "do_orm_execute")
def _guard_orm(state) -> None:
    state.session.assert_owner()


def require_detached_result(value: object, seen: set[int] | None = None) -> None:
    """在提交前拒绝Session／ORM／惰性结果逸出，包含容器和DTO中的嵌套值。"""
    seen = set() if seen is None else seen
    if id(value) in seen:
        return
    seen.add(id(value))
    if isinstance(value, Session) or isinstance(inspect(value, raiseerr=False), InstanceState):
        raise TransactionBoundaryError("事务只能返回DTO或独立数据，不能返回Session或ORM实体。")
    if isinstance(value, Iterator) or pyinspect.isawaitable(value):
        if pyinspect.iscoroutine(value):
            value.close()
        raise TransactionBoundaryError("事务不能返回惰性迭代器或异步操作。")
    if isinstance(value, dict):
        children = list(value.keys()) + list(value.values())
    elif isinstance(value, (list, tuple, set, frozenset)):
        children = value
    elif isinstance(value, BaseModel):
        children = value.__dict__.values()
    elif is_dataclass(value) and not isinstance(value, type):
        children = (getattr(value, field.name) for field in fields(value))
    elif value is None or isinstance(
        value, (str, bytes, bool, int, float, Decimal, UUID, date, datetime, time, timedelta, Enum)
    ):
        children = ()
    else:
        raise TransactionBoundaryError("事务返回值必须是显式DTO、容器或独立标量。")
    for child in children:
        require_detached_result(child, seen)


class Database:
    """注入Database或run方法；不要通过Depends提前创建Session。"""

    def __init__(self, database_url, *, schema_prefix: str = ""):
        self.schemas = SchemaGroup(schema_prefix)
        url = mysql_url(database_url)
        self.schemas.validate_url(url)
        self.engine = create_engine(
            url,
            echo=False,
            hide_parameters=True,
            pool_pre_ping=True,
            connect_args={"charset": "utf8mb4", "connect_timeout": 5},
            execution_options={"schema_translate_map": self.schemas.mapping},
        )

        @event.listens_for(self.engine, "connect")
        def set_utc(connection, record):
            cursor = connection.cursor()
            try:
                cursor.execute("SET time_zone = '+00:00'")
            finally:
                cursor.close()

        @event.listens_for(self.engine, "before_cursor_execute")
        def guard_connection(connection, cursor, statement, parameters, context, executemany):
            require_sync_thread()

        self.session_factory = sessionmaker(
            bind=self.engine,
            class_=GuardedSession,
            expire_on_commit=False,
            autobegin=False,
            close_resets_only=False,
        )

    @contextmanager
    def transaction(self):
        require_sync_thread()
        with self.session_factory() as session, session.begin():
            session._managed_work = True
            try:
                yield session
                if not session.in_transaction() or not session.is_active:
                    raise TransactionBoundaryError("回调提前结束或破坏了事务。")
            finally:
                session._managed_work = False

    def run(self, work: Callable[[GuardedSession], T]) -> T:
        require_sync_thread()
        with self.transaction() as session:
            result = work(session)
            require_detached_result(result)
            return result

    def close(self) -> None:
        require_sync_thread()
        self.engine.dispose()


class DatabaseProvider:
    """每进程惰性共享engine；获取依赖时不创建Session或触发数据库连接。"""

    def __init__(self, database_url, schema_prefix=""):
        self._url, self._prefix = database_url, schema_prefix
        self._database = None
        self._lock = Lock()

    def get(self) -> Database:
        require_sync_thread()
        with self._lock:
            if self._database is None:
                self._database = Database(self._url, schema_prefix=self._prefix)
            return self._database

    def close(self):
        require_sync_thread()
        with self._lock:
            if self._database:
                self._database.close()
                self._database = None


def get_database(request: Request) -> Database:
    """FastAPI Depends依赖只交出事务执行器，不交出Session。"""
    return request.app.state.database_provider.get()
