"""SQLAlchemy models for scam-safety guidance resources.

ScamResource holds verified anti-scam guidance material from official Hong
Kong sources (e.g. Police, OFCA, Consumer Council).  Each record follows the
same provenance pattern as welfare resources: source URL, verification date,
conditions, and three actionable next steps.

ScamLog records when an elder received scam-safety guidance during a
conversation, so the elder (and only the elder) can review the history.
"""

from __future__ import annotations

from datetime import datetime, date

from sqlalchemy import JSON, DateTime, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .models import new_id, utc_now


class ScamResource(Base):
    __tablename__ = "scam_resources"

    id: Mapped[str] = mapped_column(String(120), primary_key=True)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    excerpt: Mapped[str] = mapped_column(Text, nullable=False)
    source_url: Mapped[str] = mapped_column(String(2000), nullable=False)
    verified_at: Mapped[str] = mapped_column(String(20), nullable=False)
    scam_type: Mapped[str] = mapped_column(String(80), nullable=False)
    warning_signs: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    verification_steps: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    next_steps: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    official_contacts: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    search_terms: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    source_authority: Mapped[str] = mapped_column(String(200), nullable=False)
    content_hash: Mapped[str] = mapped_column(String(64), nullable=False)


class ScamLog(Base):
    """Records when scam-safety guidance was surfaced in a conversation."""

    __tablename__ = "scam_logs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    elder_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False
    )
    conversation_id: Mapped[str | None] = mapped_column(
        ForeignKey("conversations.id", ondelete="SET NULL"), nullable=True
    )
    scam_resource_id: Mapped[str | None] = mapped_column(String(120), nullable=True)
    scam_type: Mapped[str] = mapped_column(String(80), nullable=False, default="general")
    guidance_summary: Mapped[str] = mapped_column(Text, nullable=False, default="")
    family_notified: Mapped[bool] = mapped_column(default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False
    )
