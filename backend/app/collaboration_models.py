"""Consented family messages live outside private conversations."""
from datetime import datetime

from sqlalchemy import Integer, DateTime, ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .models import new_id, utc_now


class FamilyMessage(Base):
    __tablename__ = "family_messages"
    __table_args__ = (UniqueConstraint("sender_id", "client_message_id", name="uq_family_message_retry"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    link_id: Mapped[str] = mapped_column(ForeignKey("family_links.id"), index=True)
    sender_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    recipient_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    content: Mapped[str] = mapped_column(Text)
    client_message_id: Mapped[str] = mapped_column(String(200))
    link_epoch: Mapped[int] = mapped_column(Integer, default=1, server_default="1", nullable=False)
    access_revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    access_revocation_reason: Mapped[str | None] = mapped_column(String(120), nullable=True)
    source_story_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
