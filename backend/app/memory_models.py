"""Private personal-memory and story-card persistence models.

This module is intentionally separate from the Foundation models. Importing it
registers the tables on the shared SQLAlchemy ``Base``; the application entry
point should import this module before its startup ``create_all`` call.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, ForeignKey, Index, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base

try:  # Optional production storage; SQLite and installations without pgvector use JSON.
    from pgvector.sqlalchemy import Vector as _PgVector
except ImportError:  # pragma: no cover - depends on deployment extras
    _PgVector = None


def new_memory_id() -> str:
    return str(uuid.uuid4())


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def embedding_dimensions() -> int:
    try:
        value = int(os.getenv("EMBEDDING_DIMENSIONS", "1536"))
    except (TypeError, ValueError):
        value = 1536
    return max(1, value)


def _embedding_type():
    """Use JSON on SQLite and native pgvector on PostgreSQL when available."""

    portable = JSON()
    if _PgVector is None:
        return portable
    return portable.with_variant(_PgVector(embedding_dimensions()), "postgresql")


def native_pgvector_available() -> bool:
    return _PgVector is not None


class PersonalMemory(Base):
    __tablename__ = "personal_memories"
    __table_args__ = (
        Index("ix_personal_memories_owner_status", "owner_id", "status", "suppressed"),
        Index("ix_personal_memories_source", "source_message_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_memory_id)
    owner_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    kind: Mapped[str] = mapped_column(String(30), nullable=False, default="experience")
    # A model-authored, generic topic key supports dedupe/tombstones and
    # contextual Community prompts without parsing the memory's wording.
    topic_key: Mapped[str | None] = mapped_column(String(120), nullable=True)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="candidate")
    suppressed: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # Keep the user's ISO representation (date or datetime) without
    # inventing a timezone for date-only memories.
    event_time: Mapped[str | None] = mapped_column(String(64), nullable=True)
    source_message_id: Mapped[str | None] = mapped_column(
        ForeignKey("messages.id", ondelete="SET NULL"), nullable=True
    )
    superseded_by: Mapped[str | None] = mapped_column(
        ForeignKey("personal_memories.id", ondelete="SET NULL"), nullable=True
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


class MemoryEmbedding(Base):
    __tablename__ = "memory_embeddings"
    # pgvector's HNSW index for the standard vector type supports up to 2,000
    # dimensions.  Larger configured embeddings still use the native column
    # and Python/SQL cosine path, without making startup fail on index DDL.
    _hnsw_index = Index(
            "ix_memory_embeddings_embedding_hnsw",
            "embedding",
            postgresql_using="hnsw",
            postgresql_ops={"embedding": "vector_cosine_ops"},
        ).ddl_if(dialect="postgresql") if _PgVector is not None and embedding_dimensions() <= 2000 else None
    _indexes = [_hnsw_index] if _hnsw_index is not None else []
    __table_args__ = tuple([UniqueConstraint("memory_id", name="uq_memory_embedding_memory"), *_indexes])

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_memory_id)
    memory_id: Mapped[str] = mapped_column(
        ForeignKey("personal_memories.id", ondelete="CASCADE"), index=True, nullable=False
    )
    # JSON is the portable fallback. When pgvector is installed and the
    # Postgres URL is present at import time, the same field is a Vector.
    embedding: Mapped[list[float] | None] = mapped_column(_embedding_type(), nullable=True)
    model: Mapped[str | None] = mapped_column(String(160), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class MemoryRevision(Base):
    """Monotonic owner-scoped revision for in-flight memory revalidation.

    Conversation generation can run outside a database transaction while a
    user withdraws or corrects a memory.  The writer can snapshot this value
    before generation and compare it again before persisting the assistant
    turn.  A row is created lazily, so existing accounts continue to read as
    revision zero until their first memory mutation.
    """

    __tablename__ = "memory_revisions"

    owner_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    version: Mapped[int] = mapped_column(nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class MemoryConsent(Base):
    """Per-account long-term memory opt-in.

    Rows are created only after an explicit user choice. Missing rows mean
    consent is disabled, which also makes existing databases safe by default.
    """

    __tablename__ = "memory_consents"

    owner_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)


class MemoryPreferenceBlock(Base):
    """Hashed topics the owner deleted or paused, to prevent silent relearning."""

    __tablename__ = "memory_preference_blocks"

    owner_id: Mapped[str] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    topic_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    reason: Mapped[str] = mapped_column(String(20), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


class Story(Base):
    __tablename__ = "stories"
    __table_args__ = (Index("ix_stories_owner_updated", "owner_id", "updated_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_memory_id)
    owner_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(240), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


class StoryMemoryLink(Base):
    __tablename__ = "story_memory_links"
    __table_args__ = (Index("ix_story_memory_links_memory", "memory_id"),)

    story_id: Mapped[str] = mapped_column(
        ForeignKey("stories.id", ondelete="CASCADE"), primary_key=True, nullable=False
    )
    memory_id: Mapped[str] = mapped_column(
        ForeignKey("personal_memories.id", ondelete="CASCADE"), primary_key=True, nullable=False
    )


# Friendly aliases for code that calls the entity a memory rather than a
# personal memory. The table name remains explicit in migrations and queries.
Memory = PersonalMemory
