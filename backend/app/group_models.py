"""Invitation-only human group chat; separate from private AI conversations."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .models import new_id, utc_now


class ChatGroup(Base):
    __tablename__ = "chat_groups"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    owner_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    title: Mapped[str] = mapped_column(String(100), nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="active", nullable=False)
    next_ordinal: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class GroupMember(Base):
    __tablename__ = "chat_group_members"
    __table_args__ = (UniqueConstraint("group_id", "account_id", name="uq_chat_group_member"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    group_id: Mapped[str] = mapped_column(ForeignKey("chat_groups.id"), index=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    role: Mapped[str] = mapped_column(String(20), default="member", nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="active", nullable=False)
    joined_after: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class GroupInvitation(Base):
    __tablename__ = "chat_group_invitations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    group_id: Mapped[str] = mapped_column(ForeignKey("chat_groups.id"), index=True)
    inviter_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    invitee_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    status: Mapped[str] = mapped_column(String(20), default="pending", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class GroupMessage(Base):
    __tablename__ = "chat_group_messages"
    __table_args__ = (
        UniqueConstraint("group_id", "ordinal", name="uq_chat_group_message_ordinal"),
        UniqueConstraint("group_id", "sender_id", "client_message_id", name="uq_chat_group_message_retry"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    group_id: Mapped[str] = mapped_column(ForeignKey("chat_groups.id"), index=True)
    sender_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    ordinal: Mapped[int] = mapped_column(Integer, nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    client_message_id: Mapped[str] = mapped_column(String(200), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class GroupBlock(Base):
    __tablename__ = "chat_group_blocks"
    __table_args__ = (UniqueConstraint("blocker_id", "blocked_id", name="uq_chat_group_block"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    blocker_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    blocked_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class GroupReport(Base):
    __tablename__ = "chat_group_reports"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    reporter_id: Mapped[str] = mapped_column(ForeignKey("accounts.id"), index=True)
    group_id: Mapped[str] = mapped_column(ForeignKey("chat_groups.id"), index=True)
    message_id: Mapped[str | None] = mapped_column(ForeignKey("chat_group_messages.id"), nullable=True)
    reason: Mapped[str] = mapped_column(String(500), nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="open", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
