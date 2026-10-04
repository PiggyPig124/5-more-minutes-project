"""Account-pair consent requests, blocks, and operation receipts."""
from datetime import datetime
from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, JSON, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column
from .db import Base
from .models import new_id, utc_now

class FamilyConnectionRequest(Base):
    __tablename__ = "family_connection_requests"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    elder_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    caregiver_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    submitted_email: Mapped[str] = mapped_column(String(320))
    client_request_id: Mapped[str] = mapped_column(String(200))
    status: Mapped[str] = mapped_column(String(20), default="pending")
    version: Mapped[int] = mapped_column(Integer, default=1)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    approved_link_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    approved_epoch: Mapped[int | None] = mapped_column(Integer, nullable=True)
    approved_scopes: Mapped[list | None] = mapped_column(JSON, nullable=True)
    __table_args__ = (UniqueConstraint("caregiver_id", "client_request_id", name="uq_family_request_key"),)

class FamilyBlock(Base):
    __tablename__ = "family_blocks"
    elder_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), primary_key=True)
    caregiver_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), primary_key=True)
    blocked_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    version: Mapped[int] = mapped_column(Integer, default=1)

class FamilyConnectionOperation(Base):
    __tablename__ = "family_connection_operations"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    actor_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"))
    operation_type: Mapped[str] = mapped_column(String(30))
    target_id: Mapped[str] = mapped_column(String(200))
    client_key: Mapped[str] = mapped_column(String(200))
    payload_hash: Mapped[str] = mapped_column(String(64))
    result: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    __table_args__ = (UniqueConstraint("actor_id", "client_key", name="uq_family_operation_key"),)
