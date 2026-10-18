from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from threading import RLock
from time import monotonic
from typing import Any, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import select
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from ..db import get_db
from ..dependencies import require_elder
from ..memory_models import PersonalMemory, MemoryDeletionReceipt, new_memory_id
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
    purge_memory_set,
    _memory_chain_ids,
    memory_revision,
    require_memory_revision,
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
    revision: int
    counts: dict[str, int]


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
    revision: int
    content: str
    kind: Literal["fact", "experience", "preference", "emotion"]
    status: Literal["candidate", "confirmed"]
    suppressed: bool
    event_time: str | None
    source_message_id: str | None
    capture_method: Literal["agent_auto", "user_saved", "manual", "owner_added"] = "owner_added"
    created_at: datetime
    updated_at: datetime


@dataclass(frozen=True)
class _PendingMemory:
    owner_id: str
    value: MemoryOut
    topic_key: str | None
    expires_at: float


_draft_lock = RLock()
_DRAFT_TTL_SECONDS = 30 * 60


def _drafts(request: Request) -> dict[str, _PendingMemory]:
    """Caller holds _draft_lock; expired bodies are purged on draft access.

    Drafts belong to this app process, never the database or an external cache.
    A restart/another worker cannot restore them; the client must review again.
    """
    store = getattr(request.app.state, "pending_memories", None)
    if store is None:
        store = request.app.state.pending_memories = {}
    now = monotonic()
    for key in [key for key, draft in store.items() if draft.expires_at <= now]:
        del store[key]
    return store


def _pending(request: Request, db: Session, owner_id: str, memory_id: str) -> _PendingMemory | None:
    with _draft_lock:
        store = _drafts(request)
        draft = store.get(memory_id)
        if draft is None:
            return None
        if draft.owner_id != owner_id:
            raise HTTPException(404, "Memory not found")
        if draft.value.revision != memory_revision(db, owner_id):
            del store[memory_id]
            raise HTTPException(409, "Memory changed; review a new draft before saving.")
        return draft


def _forget_drafts(request: Request, owner_id: str, ids: set[str] | None = None) -> None:
    with _draft_lock:
        store = _drafts(request)
        for key in [key for key, value in store.items()
                    if value.owner_id == owner_id and (ids is None or key in ids)]:
            del store[key]


def _stage_draft(request: Request, db: Session, owner_id: str, payload: MemoryCreate,
                 *, suppressed: bool = False, replace_id: str | None = None) -> MemoryOut:
    now = datetime.now(timezone.utc)
    value = MemoryOut(id=new_memory_id(), revision=memory_revision(db, owner_id),
        content=payload.content, kind=payload.kind, status="candidate", suppressed=suppressed,
        event_time=payload.event_time, source_message_id=payload.source_message_id,
        capture_method="manual" if payload.source_message_id else "owner_added",
        created_at=now, updated_at=now)
    with _draft_lock:
        store = _drafts(request)
        count = sum(item.owner_id == owner_id for item in store.values())
        if replace_id is None and (len(store) >= 2048 or count >= 64):
            raise HTTPException(429, "Too many pending memories; save or discard a draft first.")
        store[value.id] = _PendingMemory(owner_id, value, payload.topic_key, monotonic() + _DRAFT_TTL_SECONDS)
        if replace_id is not None:
            store.pop(replace_id, None)
    return value


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
        {**memory_to_dict(memory, capture_method=memory_capture_method(db, memory)), "revision": memory_revision(db, memory.owner_id)}
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


def _lock_memory_for_write(db: Session, owner_id: str, memory_id: str,
                           *, owner_locked: bool = False) -> PersonalMemory:
    """Serialize memory mutation with retrieval withdrawal and deletion."""

    # Lock the owner before the memory row.  Conversation writes use the same
    # order when revalidating memory sources.
    # Reacquiring rolls back the current transaction. Preserve an owner guard
    # already validated by a route instead of opening a stale-revision window.
    if not owner_locked:
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
    lock_owner_account(db, account.id)
    return MemoryConsentOut(enabled=memory_consent_enabled(db, account.id), revision=memory_revision(db, account.id), counts=_control_counts(db, account.id))


@router.put("/consent", response_model=MemoryConsentOut)
def set_memory_consent(
    payload: MemoryConsentRequest,
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision", ge=0),
) -> MemoryConsentOut:
    lock_owner_account(db, account.id)
    require_memory_revision(db, account.id, expected_revision)
    consent = db.get(MemoryConsent, account.id)
    if consent is None:
        consent = MemoryConsent(owner_id=account.id, enabled=payload.enabled)
        db.add(consent)
    else:
        consent.enabled = payload.enabled
        consent.updated_at = datetime.now(timezone.utc)
    bump_memory_revision(db, account.id)
    output = MemoryConsentOut(enabled=consent.enabled, revision=memory_revision(db, account.id), counts=_control_counts(db, account.id))
    db.commit()
    if not payload.enabled:
        _forget_drafts(request, account.id)
    return output


class MemoryDeletionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    mode: Literal["all", "selected"]
    memory_ids: list[str] = Field(default_factory=list, max_length=500)
    expected_revision: int = Field(ge=0)
    idempotency_key: str = Field(min_length=1, max_length=200)


def _control_counts(db, owner_id):
    rows = db.scalars(select(PersonalMemory).where(PersonalMemory.owner_id == owner_id)).all()
    return {"total": len(rows), "current": sum(row.deleted_at is None and row.superseded_by is None for row in rows)}


@router.get("/control-state")
def control_state(account: Account = Depends(require_elder), db: Session = Depends(get_db)):
    lock_owner_account(db, account.id)
    return {"enabled": memory_consent_enabled(db, account.id), "revision": memory_revision(db, account.id), "counts": _control_counts(db, account.id)}


def _delete_memories(db, owner_id, payload, request: Request):
    import hashlib, json
    lock_owner_account(db, owner_id)
    request_body = {"mode": payload.mode, "memory_ids": sorted(payload.memory_ids), "expected_revision": payload.expected_revision}
    request_hash = hashlib.sha256(json.dumps(request_body, sort_keys=True).encode()).hexdigest()
    key_hash = hashlib.sha256(payload.idempotency_key.encode()).hexdigest()
    previous = db.scalar(select(MemoryDeletionReceipt).where(MemoryDeletionReceipt.owner_id == owner_id,
        MemoryDeletionReceipt.key_hash == key_hash))
    if previous is not None:
        if previous.request_hash != request_hash:
            raise HTTPException(409, "Deletion key belongs to a different request.")
        return {"request_id": previous.id, "revision": previous.revision, "counts": previous.counts}
    require_memory_revision(db, owner_id, payload.expected_revision)
    draft_ids = set()
    if payload.mode == "all":
        if payload.memory_ids:
            raise HTTPException(422, "Delete all must not include selected IDs.")
        ids = set(db.scalars(select(PersonalMemory.id).where(PersonalMemory.owner_id == owner_id)).all())
        with _draft_lock:
            draft_ids = {key for key, item in _drafts(request).items() if item.owner_id == owner_id}
    else:
        if not payload.memory_ids or len(set(payload.memory_ids)) != len(payload.memory_ids):
            raise HTTPException(422, "Selected current memory IDs must be nonempty and unique.")
        ids = set()
        for memory_id in payload.memory_ids:
            if _pending(request, db, owner_id, memory_id) is not None:
                draft_ids.add(memory_id)
                continue
            memory = _owner_memory(db, owner_id, memory_id)
            ids.update(_memory_chain_ids(db, memory.id))
    result = (purge_memory_set(db, owner_id, ids) if ids else
              {"memory_ids": [], "story_ids": [], "revision": bump_memory_revision(db, owner_id)})
    counts = {"memories": len(result["memory_ids"]) + len(draft_ids), "stories": len(result["story_ids"])}
    receipt = MemoryDeletionReceipt(owner_id=owner_id, key_hash=key_hash, request_hash=request_hash,
        revision=result["revision"], counts=counts)
    db.add(receipt)
    db.flush()
    out = {"request_id": receipt.id, "revision": receipt.revision, "counts": counts}
    db.commit()
    _forget_drafts(request, owner_id, None if payload.mode == "all" else draft_ids)
    return out


@router.post("/deletions")
def delete_memories(payload: MemoryDeletionRequest, request: Request, account: Account = Depends(require_elder), db: Session = Depends(get_db)):
    return _delete_memories(db, account.id, payload, request)


@router.get("", response_model=list[MemoryOut])
def list_memories(request: Request, account: Account = Depends(require_elder), db: Session = Depends(get_db)) -> list[MemoryOut]:
    lock_owner_account(db, account.id)
    rows = db.scalars(
        select(PersonalMemory)
        .where(
            PersonalMemory.owner_id == account.id,
            PersonalMemory.deleted_at.is_(None),
            PersonalMemory.superseded_by.is_(None),
        )
        .order_by(PersonalMemory.updated_at.desc())
    ).all()
    revision = memory_revision(db, account.id)
    with _draft_lock:
        store = _drafts(request)
        stale = [key for key, item in store.items()
                 if item.owner_id == account.id and item.value.revision != revision]
        for key in stale:
            del store[key]
        pending = [item.value for item in store.values() if item.owner_id == account.id]
    return sorted([*[_out(memory, db) for memory in rows], *pending],
                  key=lambda item: item.updated_at.replace(tzinfo=timezone.utc), reverse=True)


@router.post("", response_model=MemoryOut, status_code=status.HTTP_201_CREATED)
async def create_memory(
    payload: MemoryCreate,
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision", ge=0),
) -> MemoryOut:
    # A contended synchronous SQL lock must not block ASGI request cleanup.
    await run_in_threadpool(lock_owner_account, db, account.id)
    require_memory_revision(db, account.id, expected_revision)
    _require_memory_enabled(db, account.id)
    _validate_source_message(db, account.id, payload.source_message_id)
    output = _stage_draft(request, db, account.id, payload)
    # Release the SQL owner guard without committing candidate text or metadata.
    db.rollback()
    return output


@router.post("/save", response_model=MemoryOut, status_code=status.HTTP_201_CREATED)
async def save_memory(
    payload: MemorySaveRequest,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision", ge=0),
) -> MemoryOut:
    """Persist a confirmed memory only after an explicit Save request."""

    await run_in_threadpool(lock_owner_account, db, account.id)
    require_memory_revision(db, account.id, expected_revision)
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
            output = _out(existing, db)
            db.rollback()
            return output
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
    bump_memory_revision(db, account.id)
    output = _out(memory, db)
    db.commit()
    return output


@router.post("/search", response_model=MemorySearchResponse)
async def search_memories(
    payload: MemorySearchRequest,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemorySearchResponse:
    revision = memory_revision(db, account.id)
    _require_memory_enabled(db, account.id)
    result = await retrieve_for_chat(db, account.id, payload.query, payload.limit)
    await run_in_threadpool(lock_owner_account, db, account.id)
    require_memory_revision(db, account.id, revision)
    _require_memory_enabled(db, account.id)
    for item in result["items"]:
        current = _owner_memory(db, account.id, item["id"])
        if current.status != "confirmed" or current.suppressed or current.content != item["content"]:
            raise HTTPException(409, "Memory search data changed; reload.")
    result["items"] = [{**item, "revision": revision} for item in result["items"]]
    return MemorySearchResponse(**result)


@router.get("/{memory_id}", response_model=MemoryOut)
def get_memory(
    memory_id: str,
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> MemoryOut:
    lock_owner_account(db, account.id)
    draft = _pending(request, db, account.id, memory_id)
    if draft is not None:
        return draft.value
    return _out(_owner_memory(db, account.id, memory_id), db)


@router.patch("/{memory_id}", response_model=MemoryOut)
async def patch_memory(
    memory_id: str,
    payload: MemoryPatch,
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision", ge=0),
) -> MemoryOut:
    await run_in_threadpool(lock_owner_account, db, account.id)
    require_memory_revision(db, account.id, expected_revision)
    changes = payload.model_dump(exclude_unset=True)
    draft = _pending(request, db, account.id, memory_id)
    if draft is not None:
        _require_memory_enabled(db, account.id)
        if not changes:
            return draft.value
        value = draft.value
        edited = MemoryCreate(content=changes.get("content", value.content),
            kind=changes.get("kind", value.kind), event_time=changes.get("event_time", value.event_time),
            source_message_id=value.source_message_id, topic_key=draft.topic_key)
        output = _stage_draft(request, db, account.id, edited,
            suppressed=changes.get("suppressed", value.suppressed), replace_id=memory_id)
        db.rollback()
        return output
    memory = await run_in_threadpool(_lock_memory_for_write, db, account.id, memory_id, owner_locked=True)
    if not changes:
        return _out(memory, db)

    replacement_needed = "content" in changes or "kind" in changes or "event_time" in changes
    if replacement_needed:
        if memory.status != "confirmed":
            _require_memory_enabled(db, account.id)
        replacement = supersede_memory(
            db,
            memory,
            str(changes.get("content", memory.content)).strip(),
            str(changes.get("kind", memory.kind)),
            suppressed=bool(changes["suppressed"]) if "suppressed" in changes else bool(memory.suppressed),
            event_time=changes.get("event_time", memory.event_time),
        )
        # PATCH is the existing owner's explicit "Save changes" action.
        # Persist its final replacement, never another unconfirmed candidate.
        replacement.status = "confirmed"
        if replacement.kind == "preference":
            _clear_preference_topic_block(db, account.id, replacement.content, replacement.topic_key)
        await index_memory_with_adapter(db, replacement)
        output = _out(replacement, db)
        db.commit()
        return output

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
        output = _out(memory, db)
        db.commit()
        return output
    return _out(memory, db)


@router.post("/{memory_id}/confirm", response_model=MemoryOut)
async def confirm_memory(
    memory_id: str,
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision", ge=0),
) -> MemoryOut:
    await run_in_threadpool(lock_owner_account, db, account.id)
    require_memory_revision(db, account.id, expected_revision)
    _require_memory_enabled(db, account.id)
    draft = _pending(request, db, account.id, memory_id)
    if draft is not None:
        value = draft.value
        _validate_source_message(db, account.id, value.source_message_id)
        memory = PersonalMemory(id=value.id, owner_id=account.id, content=value.content,
            kind=value.kind, event_time=value.event_time, status="confirmed", suppressed=value.suppressed,
            source_message_id=value.source_message_id, topic_key=draft.topic_key,
            created_at=value.created_at, updated_at=datetime.now(timezone.utc))
        db.add(memory)
        db.flush()
        _mark_source_capture(db, value.source_message_id, "manual")
    else:
        memory = await run_in_threadpool(_lock_memory_for_write, db, account.id, memory_id, owner_locked=True)
        if memory.status == "confirmed":
            return _out(memory, db)
    memory.status = "confirmed"
    memory.updated_at = datetime.now(timezone.utc)
    if memory.kind == "preference":
        _clear_preference_topic_block(db, account.id, memory.content, memory.topic_key)
    if memory.suppressed:
        index_memory(db, memory, None)
    else:
        await index_memory_with_adapter(db, memory)
    bump_memory_revision(db, account.id)
    db.flush()
    db.refresh(memory)
    output = _out(memory, db)
    db.commit()
    _forget_drafts(request, account.id, {memory_id})
    return output


@router.delete("/{memory_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_memory(memory_id: str, request: Request, account: Account = Depends(require_elder), db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision", ge=0),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key", min_length=1, max_length=200)) -> Response:
    if expected_revision is None or idempotency_key is None:
        raise HTTPException(422, "Deletion requires X-Memory-Revision and Idempotency-Key.")
    result = _delete_memories(db, account.id, MemoryDeletionRequest(mode="selected", memory_ids=[memory_id],
        expected_revision=expected_revision, idempotency_key=idempotency_key), request)
    return Response(status_code=204, headers={"X-Memory-Revision": str(result["revision"])})
