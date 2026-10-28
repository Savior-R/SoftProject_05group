"""B–F的最小ORM样板及实库正负例；生产类继承公共Base并按05补全，不复制测试Base。"""

from datetime import UTC, datetime
from decimal import Decimal
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import (
    CheckConstraint,
    Computed,
    ForeignKey,
    MetaData,
    Numeric,
    String,
    UniqueConstraint,
    insert,
    select,
    update,
)
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from common.model_base import NAMING_CONVENTION, TABLE_OPTIONS, Base, UUIDText
from tools.freeze_baseline import compile_metadata


def build_model_examples():
    # 只有测试样板允许独立Base，保证不向生产metadata加入占位表。
    # B–F正式models.py直接从common.model_base导入Base，不定义这个类。
    class ExampleBase(DeclarativeBase):
        metadata = MetaData(naming_convention=NAMING_CONVENTION)
        type_annotation_map = dict(Base.type_annotation_map)

    class User(ExampleBase):
        __tablename__ = "example_user"
        __table_args__ = {"schema": "identity_org", **TABLE_OPTIONS}
        user_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)

    class Session(ExampleBase):
        __tablename__ = "example_trial_session"
        __table_args__ = (
            UniqueConstraint("active_user_id", name="uk_example_active_user"),
            CheckConstraint(
                "status IN ('not_started','running','paused','finished','aborted')", name="status"
            ),
            {"schema": "classroom", **TABLE_OPTIONS},
        )
        session_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
        user_id: Mapped[UUID] = mapped_column(ForeignKey("identity_org.example_user.user_id"))
        status: Mapped[str] = mapped_column(String(16), server_default="not_started")
        active_user_id: Mapped[UUID | None] = mapped_column(
            UUIDText(),
            Computed("CASE WHEN status IN ('running','paused') THEN user_id END", persisted=True),
        )

    class Span(ExampleBase):
        __tablename__ = "example_session_time_span"
        __table_args__ = (
            UniqueConstraint("session_id", "span_no", name="uk_example_span_no"),
            UniqueConstraint("open_session_id", name="uk_example_open_span"),
            {"schema": "classroom", **TABLE_OPTIONS},
        )
        span_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
        session_id: Mapped[UUID] = mapped_column(
            ForeignKey("classroom.example_trial_session.session_id")
        )
        span_no: Mapped[int]
        start_at: Mapped[datetime]
        end_at: Mapped[datetime | None]
        open_session_id: Mapped[UUID | None] = mapped_column(
            UUIDText(), Computed("CASE WHEN end_at IS NULL THEN session_id END", persisted=True)
        )

    class Report(ExampleBase):
        __tablename__ = "example_evaluation_report"
        __table_args__ = {"schema": "evaluation", **TABLE_OPTIONS}
        report_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
        session_id: Mapped[UUID] = mapped_column(
            ForeignKey("classroom.example_trial_session.session_id"), unique=True
        )
        # 与Attempt.report_id形成真实依赖环；创建先NULL，尝试落库后再回填。
        published_attempt_id: Mapped[UUID | None] = mapped_column(
            ForeignKey("evaluation.example_evaluation_attempt.attempt_id")
        )

    class Attempt(ExampleBase):
        __tablename__ = "example_evaluation_attempt"
        __table_args__ = (
            UniqueConstraint("report_id", "attempt_no", name="uk_example_attempt_no"),
            UniqueConstraint("active_report_id", name="uk_example_active_attempt"),
            CheckConstraint(
                "status IN ('queued','running','succeeded','partial','failed')", name="status"
            ),
            {"schema": "evaluation", **TABLE_OPTIONS},
        )
        attempt_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
        report_id: Mapped[UUID] = mapped_column(
            ForeignKey("evaluation.example_evaluation_report.report_id")
        )
        attempt_no: Mapped[int]
        status: Mapped[str] = mapped_column(String(16))
        active_report_id: Mapped[UUID | None] = mapped_column(
            UUIDText(),
            Computed("CASE WHEN status IN ('queued','running') THEN report_id END", persisted=True),
        )

    class Review(ExampleBase):
        __tablename__ = "example_teacher_review"
        __table_args__ = (
            UniqueConstraint("report_id", "teacher_id", name="uk_example_report_teacher"),
            UniqueConstraint("active_primary_report_id", name="uk_example_active_primary"),
            CheckConstraint("status IN ('pending','reviewed','returned')", name="status"),
            CheckConstraint("is_primary IN (0,1)", name="primary"),
            CheckConstraint(
                "status <> 'reviewed' OR (total_score IS NOT NULL AND "
                "total_score BETWEEN 0 AND 100 AND reviewed_at IS NOT NULL)",
                name="reviewed_score",
            ),
            {"schema": "evaluation", **TABLE_OPTIONS},
        )
        review_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
        report_id: Mapped[UUID] = mapped_column(
            ForeignKey("evaluation.example_evaluation_report.report_id")
        )
        # 仅夹具简化teacher_profile；正式模型按05指向identity_org.teacher_profile。
        teacher_id: Mapped[UUID] = mapped_column(ForeignKey("identity_org.example_user.user_id"))
        is_primary: Mapped[int] = mapped_column(server_default="0")
        status: Mapped[str] = mapped_column(String(16), server_default="pending")
        total_score: Mapped[Decimal | None] = mapped_column(Numeric(5, 2))
        reviewed_at: Mapped[datetime | None]
        active_primary_report_id: Mapped[UUID | None] = mapped_column(
            UUIDText(),
            Computed(
                "CASE WHEN is_primary=1 AND status='reviewed' THEN report_id END", persisted=True
            ),
        )

    return SimpleNamespace(
        metadata=ExampleBase.metadata,
        User=User,
        Session=Session,
        Span=Span,
        Report=Report,
        Attempt=Attempt,
        Review=Review,
    )


@pytest.fixture
def sample(model_example_mysql):
    before = set(Base.metadata.tables)
    models = build_model_examples()
    assert set(Base.metadata.tables) == before
    statements = compile_metadata(models.metadata)
    # 循环FK由编译器先CREATE TABLE、再ALTER ADD CONSTRAINT；不关闭FK检查。
    assert any("ALTER TABLE" in sql for sql in statements)
    with model_example_mysql["migration"].engine.begin() as conn:
        for sql in statements:
            for domain, physical in model_example_mysql["schemas"].mapping.items():
                sql = sql.replace(f"__db_{domain}__", physical)
            conn.exec_driver_sql(sql)
    return models, model_example_mysql["database"]


def execute(database, statement):
    database.run(lambda session: (session.execute(statement), None)[1])


def setup_report(models, database):
    user_id, session_id, report_id = uuid4(), uuid4(), uuid4()
    execute(database, insert(models.User).values(user_id=user_id))
    execute(database, insert(models.Session).values(session_id=session_id, user_id=user_id))
    execute(database, insert(models.Report).values(report_id=report_id, session_id=session_id))
    return user_id, session_id, report_id


def rejects(database, statement, code):
    with pytest.raises(DBAPIError) as error:
        execute(database, statement)
    # MySQL8对循环外键/权限不同路径可能返回1216或1452，均为父记录缺失。
    expected = {1216, 1452} if code == 1452 else {code}
    assert error.value.orig.args[0] in expected


def test_example_primary_review_unique_only_when_reviewed(sample):
    m, db = sample
    _, _, report = setup_report(m, db)
    teachers = [uuid4() for _ in range(4)]
    for teacher in teachers:
        execute(db, insert(m.User).values(user_id=teacher))
        execute(db, insert(m.Review).values(report_id=report, teacher_id=teacher, is_primary=1))
    # 多条pending主批不占唯一键；reviewed非主批也不占。
    now = datetime.now(UTC)
    execute(
        db,
        update(m.Review)
        .where(m.Review.teacher_id == teachers[0])
        .values(is_primary=0, status="reviewed", total_score=Decimal("88.00"), reviewed_at=now),
    )

    def activate(teacher):
        return (
            update(m.Review)
            .where(m.Review.teacher_id == teacher)
            .values(status="reviewed", total_score=Decimal("89.00"), reviewed_at=now)
        )

    execute(db, activate(teachers[1]))
    rejects(db, activate(teachers[2]), 1062)
    rejects(
        db,
        update(m.Review).where(m.Review.teacher_id == teachers[3]).values(status="reviewed"),
        3819,
    )
    execute(
        db, update(m.Review).where(m.Review.teacher_id == teachers[1]).values(status="returned")
    )
    execute(db, activate(teachers[2]))


def test_example_active_session_and_open_span_uniqueness(sample):
    m, db = sample
    user, first, _ = setup_report(m, db)
    second = uuid4()
    execute(db, insert(m.Session).values(session_id=second, user_id=user))
    execute(db, update(m.Session).where(m.Session.session_id == first).values(status="running"))
    rejects(
        db, update(m.Session).where(m.Session.session_id == second).values(status="paused"), 1062
    )
    execute(db, update(m.Session).where(m.Session.session_id == first).values(status="paused"))
    rejects(
        db, update(m.Session).where(m.Session.session_id == second).values(status="running"), 1062
    )
    execute(db, update(m.Session).where(m.Session.session_id == first).values(status="finished"))
    execute(db, update(m.Session).where(m.Session.session_id == second).values(status="running"))
    now = datetime.now(UTC)
    for number in (1, 2):
        execute(
            db, insert(m.Span).values(session_id=second, span_no=number, start_at=now, end_at=now)
        )
    execute(db, insert(m.Span).values(session_id=second, span_no=3, start_at=now))
    rejects(db, insert(m.Span).values(session_id=second, span_no=4, start_at=now), 1062)
    execute(db, update(m.Span).where(m.Span.span_no == 3).values(end_at=now))
    execute(db, insert(m.Span).values(session_id=second, span_no=4, start_at=now))


def test_example_cycle_and_single_active_attempt(sample):
    m, db = sample
    _, _, report = setup_report(m, db)
    first = uuid4()
    execute(
        db,
        insert(m.Attempt).values(attempt_id=first, report_id=report, attempt_no=1, status="queued"),
    )
    rejects(db, insert(m.Attempt).values(report_id=report, attempt_no=2, status="running"), 1062)
    execute(db, update(m.Attempt).where(m.Attempt.attempt_id == first).values(status="succeeded"))
    execute(
        db, update(m.Report).where(m.Report.report_id == report).values(published_attempt_id=first)
    )
    execute(db, insert(m.Attempt).values(report_id=report, attempt_no=2, status="running"))
    value = db.run(lambda session: session.scalar(select(m.Report.published_attempt_id)))
    assert value == first
    rejects(
        db,
        update(m.Report).where(m.Report.report_id == report).values(published_attempt_id=uuid4()),
        1452,
    )
    rejects(db, insert(m.Attempt).values(report_id=uuid4(), attempt_no=1, status="failed"), 1452)


def test_example_generated_columns_cannot_be_written(sample):
    m, db = sample
    user, _, _ = setup_report(m, db)
    rejects(db, insert(m.Session).values(user_id=user, status="running", active_user_id=user), 3105)
