"""Independent private answer cards; no personal-memory relationships."""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, JSON, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .models import new_id, utc_now


class AnswerCard(Base):
    __tablename__ = 'answer_cards'
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    owner_id: Mapped[str] = mapped_column(ForeignKey('accounts.id', ondelete='CASCADE'), index=True)
    mode: Mapped[str] = mapped_column(String(30))
    version: Mapped[int] = mapped_column(Integer, default=1)
    public_payload: Mapped[dict] = mapped_column(JSON, default=dict)
    # Provenance uses IDs and hashes only. It never retains prior source text.
    origin_message_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    origin_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    template_id: Mapped[str | None] = mapped_column(String(120), nullable=True)
    template_version: Mapped[int | None] = mapped_column(Integer, nullable=True)
    template_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    selected_original_excerpts: Mapped[list] = mapped_column(JSON, default=list)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)


class AnswerCardOperation(Base):
    __tablename__ = 'answer_card_operations'
    __table_args__ = (UniqueConstraint('owner_id', 'client_operation_id', name='uq_answer_card_operation'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    owner_id: Mapped[str] = mapped_column(ForeignKey('accounts.id', ondelete='CASCADE'), index=True)
    client_operation_id: Mapped[str] = mapped_column(String(200))
    action: Mapped[str] = mapped_column(String(20))
    card_id: Mapped[str] = mapped_column(String(36), index=True)
    result_version: Mapped[int] = mapped_column(Integer)
    request_hash: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class AnswerCardShare(Base):
    """Explicit one-recipient snapshot and independent permanent share receipt."""
    __tablename__ = 'answer_card_shares'
    __table_args__ = (UniqueConstraint('sender_id', 'client_share_id', name='uq_answer_card_share_key'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    card_id: Mapped[str] = mapped_column(ForeignKey('answer_cards.id', ondelete='CASCADE'), index=True)
    card_version: Mapped[int] = mapped_column(Integer)
    mode: Mapped[str] = mapped_column(String(30))
    sender_id: Mapped[str] = mapped_column(ForeignKey('accounts.id', ondelete='CASCADE'), index=True)
    recipient_id: Mapped[str] = mapped_column(ForeignKey('accounts.id', ondelete='CASCADE'), index=True)
    link_id: Mapped[str] = mapped_column(ForeignKey('family_links.id', ondelete='CASCADE'), index=True)
    link_epoch: Mapped[int] = mapped_column(Integer)
    client_share_id: Mapped[str] = mapped_column(String(200))
    request_hash: Mapped[str] = mapped_column(String(64))
    payload_hash: Mapped[str] = mapped_column(String(64))
    public_payload: Mapped[dict] = mapped_column(JSON, default=dict)
    access_revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    access_revocation_reason: Mapped[str | None] = mapped_column(String(100), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
