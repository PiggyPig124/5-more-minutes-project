"""Additive explicit per-task consent; no consent is inferred from links."""
from datetime import datetime
from sqlalchemy import DateTime, ForeignKey, Index, String, UniqueConstraint, text
from sqlalchemy.orm import Mapped, mapped_column
from .db import Base
from .models import new_id, utc_now

class TaskShare(Base):
    __tablename__ = "task_shares"
    __table_args__ = (
        UniqueConstraint("shared_by", "idempotency_key", name="uq_task_share_request_key"),
        Index("uq_task_share_active_link", "task_id", "family_link_id", unique=True,
              sqlite_where=text("revoked_at IS NULL"), postgresql_where=text("revoked_at IS NULL")),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    task_id: Mapped[str] = mapped_column(ForeignKey("tasks.id", ondelete="CASCADE"), index=True)
    family_link_id: Mapped[str] = mapped_column(ForeignKey("family_links.id", ondelete="CASCADE"), index=True)
    shared_by: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"), index=True)
    content_hash: Mapped[str] = mapped_column(String(64))
    request_hash: Mapped[str] = mapped_column(String(64))
    idempotency_key: Mapped[str] = mapped_column(String(200))
    consented_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revocation_reason: Mapped[str | None] = mapped_column(String(80), nullable=True)
