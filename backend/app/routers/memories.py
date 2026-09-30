from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..dependencies import require_elder
from ..memory_models import PersonalMemory
from ..memory_consent import memory_consent_enabled
from ..memory_models import MemoryConsent
from ..memory_service import (
    ALLOWED_KINDS,
    EmbeddingAdapter,
    _block_preference_topic,
    _clear_preference_topic_block,
    bump_memory_revision,
    index_memory,
    index_memory_with_adapter,
    lock_owner_account,
    memory_capture_method,
    memory_to_dict,
    normalize_event_time,
    purge_memory,
    purge_stories,
    retrieve_for_chat,
    scrub_memory_references,
    supersede_memory,
)
from ..models import Account, Conversation, Message

router = APIRouter(prefix="/memories", tags=["memories"])


class MemoryConsentRequest(BaseModel):
    enabled: bool


class MemoryConsentOut(BaseModel):
    enabled: bool


class MemorySaveRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    content: str = Field(min_length=1, max_length=10000)
    kind: Literal["fact", "experience", "preference", "emotion"] = "experience"
    source_message_id: str | None = Field(default=None, max_length=36)
    topic_key: str | None = Field(default=None, max_length=120)

    @field_validator("content")
    @classmethod
    def trim_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("memory content cannot be blank")
        return value


class MemoryCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    content: str = Field(min_length=1, max_length=10000)
    kind: Literal["fact", "experience", "preference", "emotion"] = "experience"
    event_time: str | None = Field(default=None, max_length=64)
    source_message_id: str | None = Field(default=None, max_length=36)
    topic_key: str | None = Field(default=None, max_length=120)
    # Candidate is the only accepted creation status. Confirmation has its own
    # endpoint so an accidental client field cannot bypass review.
    status: Literal["candidate"] = "candidate"

    @field_validator("content")
    @classmethod
    def trim_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("memory content cannot be blank")
        return value

    @field_validator("event_time")
    @classmethod
    def validate_event_time(cls, value: str | None) -> str | None:
        return normalize_event_time(value)


class MemoryPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    content: str | None = Field(default=None, max_length=10000)
    kind: Literal["fact", "experience", "preference", "emotion"] | None = None
    event_time: str | None = Field(default=None, max_length=64)
    suppressed: bool | None = None

    @field_validator("content", "kind", "suppressed", mode="before")
    @classmethod
    def reject_explicit_null(cls, value: object) -> object:
        if value is None:
            raise ValueError("field cannot be null")
        if isinstance(value, str) and not value.strip():
            raise ValueError("value cannot be blank")
        return value

    @field_validator("content")
    @classmethod
    def trim_content(cls, value: str | None) -> str | None:
        return value.strip() if value is not None else None

    @field_validator("event_time")
    @classmethod
    def validate_event_time(cls, value: str | None) -> str | None:
        return normalize_event_time(value)


class MemoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    content: str
    kind: Literal["fact", "experience", "preference", "emotion"]
    status: Literal["candidate", "confirmed"]
    suppressed: bool
    event_time: str | None
    source_message_id: str | None
    capture_method: Literal["agent_auto", "user_saved", "manual", "owner_added"] = "owner_added"
    created_at: datetime
    updated_at: datetime


class MemorySearchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    query: str = Field(min_length=1, max_length=10000)
    limit: int = Field(default=4, ge=1, le=20)

    @field_validator("query")
    @classmethod
    def trim_query(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("search query cannot be blank")
        return value


class MemorySearchItem(MemoryOut):
    score: float


class MemorySearchResponse(BaseModel):
    items: list[MemorySearchItem]
    retrieval_mode: Literal["keyword", "hybrid_python", "hybrid_pgvector", "embedding"]


def _out(memory: PersonalMemory, db: Session) -> MemoryOut:
    return MemoryOut.model_validate(
        memory_to_dict(memory, capture_method=memory_capture_method(db, memory))
    )


def _mark_source_capture(db: Session, source_message_id: str | None, method: str) -> None:
    if source_message_id is None:
        return
    source = db.get(Message, source_message_id)
    if source is None:
        return
    metadata = dict(source.metadata_json or {})
    metadata["memory_capture_method"] = method
    source.metadata_json = metadata


def _owner_memory(db: Session, owner_id: str, memory_id: str) -> PersonalMemory:
    memory = db.get(PersonalMemory, memory_id)
    if memory is None or memory.deleted_at is not None or memory.superseded_by is not None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Memory not found")
    if memory.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Memory is private to its owner")
    return memory


def _lock_memory_for_write(db: Session, owner_id: str, memory_id: str) -> PersonalMemory:
    """Serialize memory mutation with retrieval withdrawal and deletion."""

    # Lock the owner before the memory row.  Conversation writes use the same
    # order when revalidating memory sources.
    lock_owner_account(db, owner_id)
    if db.bind is not None and db.bind.dialect.name == "sqlite":
        # lock_owner_account reserved SQLite's single writer.
        memory = db.get(PersonalMemory, memory_id)
    else:
        memory = db.scalar(
            select(PersonalMemory).where(PersonalMemory.id == memory_id).with_for_update()
        )
    if memory is None or memory.deleted_at is not None or memory.superseded_by is not None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Memory not found")
    if memory.owner_id != owner_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Memory is private to its owner")
    return memory


def _validate_source_message(db: Session, owner_id: str, source_message_id: str | None) -> None:
    if source_message_id is None:
        return
    source = db.scalar(
        select(Message)
        .join(Conversation, Conversation.id == Message.conversation_id)
        .where(Message.id == source_message_id, Conversation.owner_id == owner_id)
    )
    if source is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Source message is not owned by this account")


def _require_memory_enabled(db: Session, owner_id: str) -> None:
    if not memory_consent_enabled(db, owner_id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Memory consent is disabled")


@router.get("/consent", response_model=MemoryConsentOut)
def get_memory_consent(
    account: Account = Depends(require_elder), db: Session = Depends(get_db)
) -> MemoryConsentOut:
    return MemoryConsentOut(enabled=memory_consent_enabled(db, account.id))


@router.put("/consent", response_model=MemoryConsentOut)
def set_memory_consent(
    payload: MemoryConsentRequest,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemoryConsentOut:
    lock_owner_account(db, account.id)
    consent = db.get(MemoryConsent, account.id)
    if consent is None:
        consent = MemoryConsent(owner_id=account.id, enabled=payload.enabled)
        db.add(consent)
    else:
        consent.enabled = payload.enabled
        consent.updated_at = datetime.now(timezone.utc)
    db.commit()
    return MemoryConsentOut(enabled=consent.enabled)


@router.get("", response_model=list[MemoryOut])
def list_memories(account: Account = Depends(require_elder), db: Session = Depends(get_db)) -> list[MemoryOut]:
    rows = db.scalars(
        select(PersonalMemory)
        .where(
            PersonalMemory.owner_id == account.id,
            PersonalMemory.deleted_at.is_(None),
            PersonalMemory.superseded_by.is_(None),
        )
        .order_by(PersonalMemory.updated_at.desc())
    ).all()
    return [_out(memory, db) for memory in rows]


@router.post("", response_model=MemoryOut, status_code=status.HTTP_201_CREATED)
async def create_memory(
    payload: MemoryCreate,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemoryOut:
    lock_owner_account(db, account.id)
    _require_memory_enabled(db, account.id)
    _validate_source_message(db, account.id, payload.source_message_id)
    memory = PersonalMemory(
        owner_id=account.id,
        content=payload.content,
        kind=payload.kind,
        event_time=payload.event_time,
        status="candidate",
        suppressed=False,
        source_message_id=payload.source_message_id,
        topic_key=payload.topic_key,
    )
    db.add(memory)
    db.flush()
    _mark_source_capture(db, payload.source_message_id, "manual")
    await index_memory_with_adapter(db, memory)
    db.commit()
    return _out(memory, db)


@router.post("/save", response_model=MemoryOut, status_code=status.HTTP_201_CREATED)
async def save_memory(
    payload: MemorySaveRequest,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemoryOut:
    """Persist a confirmed memory only after an explicit Save request."""

    lock_owner_account(db, account.id)
    _require_memory_enabled(db, account.id)
    _validate_source_message(db, account.id, payload.source_message_id)
    if payload.source_message_id:
        existing = db.scalar(
            select(PersonalMemory).where(
                PersonalMemory.owner_id == account.id,
                PersonalMemory.source_message_id == payload.source_message_id,
                PersonalMemory.content == payload.content,
                PersonalMemory.status == "confirmed",
                PersonalMemory.deleted_at.is_(None),
            )
        )
        if existing is not None:
            db.rollback()
            return _out(existing, db)
    memory = PersonalMemory(
        owner_id=account.id,
        content=payload.content,
        kind=payload.kind,
        status="confirmed",
        suppressed=False,
        source_message_id=payload.source_message_id,
        topic_key=payload.topic_key,
    )
    db.add(memory)
    db.flush()
    _mark_source_capture(db, payload.source_message_id, "user_saved")
    _clear_preference_topic_block(db, account.id, memory.content, memory.topic_key)
    await index_memory_with_adapter(db, memory)
    db.commit()
    return _out(memory, db)


@router.post("/search", response_model=MemorySearchResponse)
async def search_memories(
    payload: MemorySearchRequest,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemorySearchResponse:
    _require_memory_enabled(db, account.id)
    result = await retrieve_for_chat(db, account.id, payload.query, payload.limit)
    return MemorySearchResponse(**result)


@router.get("/{memory_id}", response_model=MemoryOut)
def get_memory(
    memory_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemoryOut:
    return _out(_owner_memory(db, account.id, memory_id), db)


@router.patch("/{memory_id}", response_model=MemoryOut)
async def patch_memory(
    memory_id: str,
    payload: MemoryPatch,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemoryOut:
    memory = _lock_memory_for_write(db, account.id, memory_id)
    changes = payload.model_dump(exclude_unset=True)
    if not changes:
        return _out(memory, db)

    replacement_needed = "content" in changes or "kind" in changes or "event_time" in changes
    if replacement_needed:
        replacement = supersede_memory(
            db,
            memory,
            str(changes.get("content", memory.content)).strip(),
            str(changes.get("kind", memory.kind)),
            suppressed=bool(changes["suppressed"]) if "suppressed" in changes else bool(memory.suppressed),
            event_time=changes.get("event_time", memory.event_time),
        )
        await index_memory_with_adapter(db, replacement)
        db.commit()
        return _out(replacement, db)

    if "suppressed" in changes:
        memory.suppressed = bool(changes["suppressed"])
        memory.updated_at = datetime.now(timezone.utc)
        if memory.suppressed:
            if memory.kind == "preference":
                _block_preference_topic(db, account.id, memory.content, "paused", memory.topic_key)
            index_memory(db, memory, None)
            from ..memory_service import _story_ids_for_memory

            purge_stories(db, _story_ids_for_memory(db, memory.id))
            scrub_memory_references(db, account.id, {memory.id})
        else:
            if memory.kind == "preference":
                _clear_preference_topic_block(db, account.id, memory.content, memory.topic_key)
            await index_memory_with_adapter(db, memory)
        bump_memory_revision(db, account.id)
        db.commit()
    return _out(memory, db)


@router.post("/{memory_id}/confirm", response_model=MemoryOut)
async def confirm_memory(
    memory_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemoryOut:
    memory = _lock_memory_for_write(db, account.id, memory_id)
    _require_memory_enabled(db, account.id)
    memory.status = "confirmed"
    memory.updated_at = datetime.now(timezone.utc)
    if memory.kind == "preference":
        _clear_preference_topic_block(db, account.id, memory.content, memory.topic_key)
    if memory.suppressed:
        index_memory(db, memory, None)
    else:
        await index_memory_with_adapter(db, memory)
    bump_memory_revision(db, account.id)
    db.commit()
    return _out(memory, db)


@router.delete("/{memory_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_memory(
    memory_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> Response:
    memory = _lock_memory_for_write(db, account.id, memory_id)
    purge_memory(db, memory)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
