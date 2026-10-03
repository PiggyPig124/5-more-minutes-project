"""SQLAlchemy models for community discovery and contribution.

CommunityActivity represents a verified activity listing from elderly centres,
district organisations, or volunteer groups.  The elder can browse by district,
interest, or mobility preference, express interest, and receive
recommendations derived from their confirmed memories (e.g. a skill or hobby
they mentioned in conversation).

CommunityInterest records the elder's expressed interest in an activity so the
app can surface relevant opportunities proactively without making a booking.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, Boolean, DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .models import new_id, utc_now


class CommunityActivity(Base):
    __tablename__ = "community_activities"

    id: Mapped[str] = mapped_column(String(120), primary_key=True)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False)
    organizer: Mapped[str] = mapped_column(String(200), nullable=False)
    district: Mapped[str] = mapped_column(String(80), nullable=False)
    address: Mapped[str] = mapped_column(Text, nullable=False, default="")
    url: Mapped[str] = mapped_column(String(2000), nullable=False, default="")
    start_date: Mapped[str | None] = mapped_column(String(20), nullable=True)
    end_date: Mapped[str | None] = mapped_column(String(20), nullable=True)
    schedule_note: Mapped[str] = mapped_column(Text, nullable=False, default="")
    mobility_note: Mapped[str] = mapped_column(Text, nullable=False, default="")
    interest_tags: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    skill_tags: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    contribution_type: Mapped[str] = mapped_column(String(60), nullable=False, default="participate")
    verified: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    verified_at: Mapped[str | None] = mapped_column(String(20), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class CommunityInterest(Base):
    """An elder's expressed interest in a community activity."""

    __tablename__ = "community_interests"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    elder_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False
    )
    activity_id: Mapped[str] = mapped_column(
        ForeignKey("community_activities.id", ondelete="CASCADE"), index=True, nullable=False
    )
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="interested")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False
    )
