"""Curated, source-attributed community records and private skill decisions."""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, Index, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .models import new_id


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class CommunityListing(Base):
    """An approved activity or contribution opportunity from a verified source."""

    __tablename__ = "community_listings"
    __table_args__ = (Index("ix_community_listings_type_active", "listing_type", "status"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    listing_type: Mapped[str] = mapped_column(String(24), nullable=False, default="activity")
    title: Mapped[str] = mapped_column(String(240), nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False, default="")
    organization: Mapped[str] = mapped_column(String(240), nullable=False)
    area: Mapped[str | None] = mapped_column(String(120), nullable=True)
    event_start_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    event_end_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    eligibility: Mapped[str | None] = mapped_column(Text, nullable=True)
    source_name: Mapped[str] = mapped_column(String(240), nullable=False)
    source_url: Mapped[str] = mapped_column(Text, nullable=False)
    registration_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    last_checked_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    skill_tag: Mapped[str | None] = mapped_column(String(120), nullable=True)
    # Imports must explicitly approve curated rows after checking their sources.
    status: Mapped[str] = mapped_column(String(24), nullable=False, default="draft")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class CommunitySkill(Base):
    """An owner-private skill proposal explicitly confirmed or rejected by its owner."""

    __tablename__ = "community_skills"
    __table_args__ = (
        UniqueConstraint("owner_id", "memory_id", "suggestion", name="uq_community_skill_source"),
        Index("ix_community_skills_owner_status", "owner_id", "status"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    owner_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False)
    memory_id: Mapped[str] = mapped_column(ForeignKey("personal_memories.id", ondelete="CASCADE"), index=True, nullable=False)
    suggestion: Mapped[str] = mapped_column(String(160), nullable=False)
    status: Mapped[str] = mapped_column(String(24), nullable=False, default="suggested")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)
