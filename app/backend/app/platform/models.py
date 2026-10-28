"""A所有的四张platform表；不包含导出／事件调度业务实现。"""

from datetime import datetime
from decimal import Decimal
from uuid import UUID, uuid4

from sqlalchemy import (
    CHAR,
    JSON,
    BigInteger,
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
    event,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.schema import conv
from uuid6 import uuid7

from common.model_base import TABLE_OPTIONS, Base, UUIDText


class ExportTask(Base):
    __tablename__ = "export_task"
    __table_args__ = (
        CheckConstraint(
            "export_scope IN ('class_score','training_report','leaderboard',"
            "'student_profile','eval_detail')",
            name="scope",
        ),
        CheckConstraint("export_format IN ('xlsx','csv','pdf')", name="format"),
        CheckConstraint(
            "status IN ('queued','running','success','failed','expired')", name="status"
        ),
        CheckConstraint("status <> 'success' OR file_url IS NOT NULL", name=conv("ck_et_file")),
        CheckConstraint(
            "filter_cond IS NULL OR JSON_VALID(filter_cond) = 1", name=conv("ck_et_filter")
        ),
        CheckConstraint("progress BETWEEN 0 AND 1", name="progress"),
        CheckConstraint("status <> 'success' OR progress = 1", name="success_progress"),
        CheckConstraint("row_count IS NULL OR row_count >= 0", name="row_count"),
        CheckConstraint(
            "status <> 'failed' OR (error IS NOT NULL AND LENGTH(error) > 0)", name="error"
        ),
        Index("idx_et_status", "status"),
        Index("idx_et_expire", "expire_at"),
        {"schema": "platform", **TABLE_OPTIONS},
    )

    export_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    operator_id: Mapped[UUID] = mapped_column(
        ForeignKey("identity_org.user.user_id", ondelete="RESTRICT")
    )
    export_scope: Mapped[str] = mapped_column(String(15))
    filter_cond: Mapped[dict | None] = mapped_column(JSON(none_as_null=True))
    export_format: Mapped[str] = mapped_column(String(4))
    file_url: Mapped[str | None] = mapped_column(String(512))
    status: Mapped[str] = mapped_column(String(7), server_default="queued")
    expire_at: Mapped[datetime]
    created_at: Mapped[datetime] = mapped_column(server_default=text("CURRENT_TIMESTAMP(3)"))
    updated_at: Mapped[datetime] = mapped_column(server_default=text("CURRENT_TIMESTAMP(3)"))
    progress: Mapped[Decimal] = mapped_column(Numeric(4, 3), server_default=text("0.000"))
    row_count: Mapped[int | None] = mapped_column(Integer)
    error: Mapped[str | None] = mapped_column(String(500))


Index("idx_et_operator_time", ExportTask.operator_id, ExportTask.created_at.desc())


class AuditLog(Base):
    __tablename__ = "audit_log"
    __table_args__ = (
        CheckConstraint(
            "action IN ('login','publish_task','modify_score','review','export',"
            "'delete_recording','revoke_cert','change_permission')",
            name="action",
        ),
        CheckConstraint("JSON_TYPE(details) = 'OBJECT'", name="details"),
        Index("idx_al_target", "target_type", "target_id"),
        Index("idx_al_action_time", "action", "created_at"),
        {"schema": "platform", **TABLE_OPTIONS},
    )

    log_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid7)
    user_id: Mapped[UUID] = mapped_column(
        ForeignKey("identity_org.user.user_id", ondelete="RESTRICT")
    )
    action: Mapped[str] = mapped_column(String(17))
    target_type: Mapped[str] = mapped_column(String(30))
    target_id: Mapped[UUID]
    ip: Mapped[str | None] = mapped_column(String(45))
    user_agent: Mapped[str | None] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(server_default=text("CURRENT_TIMESTAMP(3)"))
    # 操作当时快照，不随组织删除或迁移改变。
    department_id: Mapped[UUID | None] = mapped_column(UUIDText())
    details: Mapped[dict] = mapped_column(JSON, server_default=text("(JSON_OBJECT())"))


Index("idx_al_user_time", AuditLog.user_id, AuditLog.created_at.desc())


@event.listens_for(AuditLog, "before_update")
@event.listens_for(AuditLog, "before_delete")
def _reject_audit_change(mapper, connection, target):
    raise ValueError("审计记录只能追加；保留期清理由独立运维权限执行。")


class OutboxEvent(Base):
    __tablename__ = "outbox_event"
    __table_args__ = (
        UniqueConstraint("dedupe_key", name="uk_outbox_dedupe"),
        CheckConstraint("status IN ('pending','delivered','dead_letter')", name="status"),
        CheckConstraint("attempts >= 0", name="attempts"),
        Index("idx_outbox_pending", "status", "next_attempt_at"),
        {"schema": "platform", **TABLE_OPTIONS},
    )

    event_id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid7)
    aggregate_type: Mapped[str] = mapped_column(String(40))
    aggregate_id: Mapped[UUID]
    aggregate_version: Mapped[int] = mapped_column(BigInteger)
    topic: Mapped[str] = mapped_column(String(80))
    payload: Mapped[dict] = mapped_column(JSON)
    dedupe_key: Mapped[str | None] = mapped_column(String(255))
    request_hash: Mapped[str | None] = mapped_column(CHAR(64))
    status: Mapped[str] = mapped_column(String(11))
    attempts: Mapped[int] = mapped_column(Integer, server_default="0")
    next_attempt_at: Mapped[datetime]
    created_at: Mapped[datetime]
    delivered_at: Mapped[datetime | None]


class ConsumerReceipt(Base):
    __tablename__ = "consumer_receipt"
    __table_args__ = (
        Index("idx_receipt_source", "consumer", "aggregate_id", "aggregate_version"),
        {"schema": "platform", **TABLE_OPTIONS},
    )

    consumer: Mapped[str] = mapped_column(String(80), primary_key=True)
    event_id: Mapped[UUID] = mapped_column(primary_key=True)
    aggregate_id: Mapped[UUID]
    aggregate_version: Mapped[int] = mapped_column(BigInteger)
    processed_at: Mapped[datetime]
    result_json: Mapped[dict | None] = mapped_column(JSON(none_as_null=True))
