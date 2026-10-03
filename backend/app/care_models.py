"""Additive care preferences and in-app inbox; existing schedules stay compatible."""
from datetime import datetime

from sqlalchemy import JSON, DateTime, ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .models import new_id, utc_now


class CarePreference(Base):
    __tablename__ = 'care_preferences'
    owner_id: Mapped[str] = mapped_column(ForeignKey('accounts.id'), primary_key=True)
    settings: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class CareNotification(Base):
    __tablename__ = 'care_notifications'
    __table_args__ = (UniqueConstraint('owner_id', 'kind', 'source_id'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    owner_id: Mapped[str] = mapped_column(ForeignKey('accounts.id'), index=True)
    kind: Mapped[str] = mapped_column(String(40))
    source_id: Mapped[str] = mapped_column(String(100))
    body: Mapped[str] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(20), default='pending')
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
