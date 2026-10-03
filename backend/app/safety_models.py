"""SQLAlchemy models for safety-assistance workflows.

``SafetyEvent`` records every urgent-risk detection so the elder (and only the
elder) can review when interventions occurred.  ``EmergencyContact`` lets the
elder designate an authorised family link as a safety contact — the system
never auto-broadcasts; a support request requires explicit confirmation of
both the recipient and the message.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .models import new_id, utc_now


class SafetyEvent(Base):
    __tablename__ = "safety_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    elder_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False
    )
    conversation_id: Mapped[str | None] = mapped_column(
        ForeignKey("conversations.id", ondelete="SET NULL"), nullable=True
    )
    trigger_message_id: Mapped[str | None] = mapped_column(
        ForeignKey("messages.id", ondelete="SET NULL"), nullable=True
    )
    intervention_mode: Mapped[str] = mapped_column(
        String(40), nullable=False, default="safety_intervention"
    )
    support_request_sent: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )
    resolved_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    notes: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False
    )


class EmergencyContact(Base):
    """An elder-designated family link for safety support requests.

    Only an active ``FamilyLink`` with ``family_messages`` scope can be designated.
    The elder may add a display label (e.g. ``daughter``) and toggle whether a
    contact is currently enabled.  A support request always requires the
    elder's explicit confirmation of the recipient and the message content
    before anything is sent.
    """

    __tablename__ = "emergency_contacts"
    __table_args__ = (
        UniqueConstraint("elder_id", "family_link_id", name="uq_emergency_contact_elder_link"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    elder_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False
    )
    family_link_id: Mapped[str] = mapped_column(
        ForeignKey("family_links.id", ondelete="CASCADE"), index=True, nullable=False
    )
    caregiver_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False
    )
    label: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    is_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False
    )


class CheckInSchedule(Base):
    """Persisted server-side proactive check-in preference for an elder.

    The Flutter client also schedules local notifications; this server-side
    record lets the backend generate and persist check-in messages so the elder
    sees them even after a device restart or across devices.
    """

    __tablename__ = "check_in_schedules"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    elder_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False
    )
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    frequency: Mapped[str] = mapped_column(String(20), nullable=False, default="daily")
    # Stored as "HH:MM" in 24-hour Hong Kong time.
    check_in_time: Mapped[str] = mapped_column(String(5), nullable=False, default="10:00")
    weekday: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    # ISO 8601 timestamp of the last check-in the backend generated.
    last_check_in_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_check_in_message_id: Mapped[str | None] = mapped_column(
        ForeignKey("messages.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False
    )
