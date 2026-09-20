"""Private personal-memory storage, retrieval, and deletion propagation.

The service is deliberately conservative: only confirmed, unsuppressed,
non-emotion memories can be retrieved for chat. A missing embedding provider
uses a real keyword scorer and reports ``keyword`` mode; it never pretends
that lexical matching is semantic retrieval.
"""

from __future__ import annotations

import math
import os
import re
from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import Any

import httpx
from sqlalchemy import cast, delete, select, update
from sqlalchemy.orm import Session

from .memory_models import (
    MemoryEmbedding,
    MemoryRevision,
    PersonalMemory,
    Story,
    StoryMemoryLink,
    _PgVector,
    embedding_dimensions,
)
from .models import Account, Conversation, Message

try:  # The collaboration milestone may not be installed in an isolated test.
    from .collaboration_models import FamilyMessage
except ImportError:  # pragma: no cover - only minimal foundation checkouts
    FamilyMessage = None


ALLOWED_KINDS = {"fact", "experience", "preference", "emotion"}
RETRIEVABLE_KINDS = {"fact", "experience", "preference"}
ALLOWED_STATUSES = {"candidate", "confirmed"}
_TOKEN_RE = re.compile(r"[A-Za-z0-9_]+|[\u3400-\u9fff]")
_STOPWORDS = {
    "a", "an", "am", "and", "are", "do", "did", "i", "is", "it", "of", "please", "the", "to", "what", "you",
    "你", "我", "他", "她", "它", "們", "的", "了", "是", "在", "有", "和", "與", "及", "請", "嗎", "吗", "呢",
    "記得", "记得", "什麼", "什么", "甚麼", "是否", "怎麼", "怎么", "哪裡", "哪里",
}


@dataclass(frozen=True, slots=True)
class EmbeddingSettings:
    api_key: str | None
    base_url: str
    model: str
    timeout_seconds: float
    dimensions: int = 1536

    @classmethod
    def from_env(cls) -> "EmbeddingSettings":
        # Keep embedding configuration explicit.  A general-purpose
        # OPENAI_API_KEY must not silently turn on personal-memory indexing.
        base_url = (os.getenv("EMBEDDING_BASE_URL") or "https://api.openai.com/v1").strip()
        model = (os.getenv("EMBEDDING_MODEL") or "text-embedding-3-small").strip()
        return cls(
            api_key=(os.getenv("EMBEDDING_API_KEY") or "").strip() or None,
            base_url=base_url,
            model=model,
            timeout_seconds=float(os.getenv("EMBEDDING_TIMEOUT_SECONDS", "30")),
            dimensions=embedding_dimensions(),
        )

    @property
    def configured(self) -> bool:
        return bool(self.api_key and self.base_url and self.model)


class EmbeddingAdapter:
    """Minimal OpenAI-compatible embeddings client with server-side secrets."""

    def __init__(self, settings: EmbeddingSettings | None = None):
        self.settings = settings or EmbeddingSettings.from_env()

    @property
    def mode(self) -> str:
        return "embedding" if self.settings.configured else "keyword"

    async def embed(self, text: str) -> list[float] | None:
        if not self.settings.configured or not text.strip():
            return None
        url = self.settings.base_url.rstrip("/")
        if not url.endswith("/embeddings"):
            url += "/embeddings"
        try:
            async with httpx.AsyncClient(timeout=self.settings.timeout_seconds) as client:
                response = await client.post(
                    url,
                    headers={
                        "Authorization": f"Bearer {self.settings.api_key}",
                        "Content-Type": "application/json",
                    },
                    json={"model": self.settings.model, "input": text},
                )
                response.raise_for_status()
                payload = response.json()
            vector = payload["data"][0]["embedding"]
            if not isinstance(vector, list) or not vector:
                return None
            numbers = [float(value) for value in vector]
            if not all(math.isfinite(value) for value in numbers):
                return None
            if len(numbers) != self.settings.dimensions:
                return None
            return numbers
        except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError):
            return None


def memory_to_dict(memory: PersonalMemory, score: float | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "id": memory.id,
        "content": memory.content,
        "kind": memory.kind,
        "status": memory.status,
        "suppressed": bool(memory.suppressed),
        "event_time": memory.event_time,
        "source_message_id": memory.source_message_id,
        "created_at": memory.created_at,
        "updated_at": memory.updated_at,
    }
    if score is not None:
        result["score"] = round(float(score), 6)
    return result


def normalize_event_time(value: object) -> str | None:
    """Validate an ISO date/datetime while preserving the supplied timezone.

    Date-only values remain date-only.  The service never derives this field
    from free-form conversation text and never assigns a timezone to a date
    that did not include one.
    """

    if value is None:
        return None
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if not isinstance(value, str):
        raise ValueError("event_time must be an ISO date or datetime")
    value = value.strip()
    if not value:
        raise ValueError("event_time cannot be blank")
    candidate = value[:-1] + "+00:00" if value.endswith(("Z", "z")) else value
    try:
        try:
            parsed = datetime.fromisoformat(candidate)
        except ValueError:
            date.fromisoformat(candidate)
        else:
            # Force validation of malformed offsets; retain the exact user
            # representation after validation.
            if parsed.tzinfo is not None:
                parsed.utcoffset()
    except (TypeError, ValueError):
        raise ValueError("event_time must be an ISO date or datetime") from None
    return value


def _tokens(value: str) -> set[str]:
    lowered = value.casefold()
    tokens = {
        token
        for token in _TOKEN_RE.findall(lowered)
        if token not in _STOPWORDS and not re.fullmatch(r"[\u3400-\u9fff]", token)
    }
    # Character bigrams make short Traditional Chinese queries useful without
    # claiming a semantic model is available.
    cjk = "".join(re.findall(r"[\u3400-\u9fff]", lowered))
    tokens.update(
        cjk[index : index + 2]
        for index in range(max(0, len(cjk) - 1))
        if cjk[index : index + 2] not in _STOPWORDS
    )
    return tokens


def keyword_score(query: str, content: str) -> float:
    query = query.strip()
    if not query or not content:
        return 0.0
    query_tokens = _tokens(query)
    if query.casefold() in content.casefold() and query_tokens:
        return 1.0
    content_tokens = _tokens(content)
    if not query_tokens or not content_tokens:
        return 0.0
    overlap = len(query_tokens & content_tokens)
    if not overlap:
        return 0.0
    return overlap / math.sqrt(len(query_tokens) * len(content_tokens))


def cosine_similarity(left: list[float] | None, right: list[float] | None) -> float:
    if not left or not right or len(left) != len(right):
        return 0.0
    denominator = math.sqrt(sum(value * value for value in left)) * math.sqrt(sum(value * value for value in right))
    if denominator == 0:
        return 0.0
    return max(-1.0, min(1.0, sum(a * b for a, b in zip(left, right)) / denominator))


def _coerce_vector(value: object, dimensions: int) -> list[float] | None:
    """Convert JSON/pgvector/numpy-like values into a validated list."""

    if value is None or isinstance(value, (str, bytes, bytearray)):
        return None
    try:
        vector = [float(item) for item in value]  # type: ignore[union-attr]
    except (TypeError, ValueError):
        return None
    if len(vector) != dimensions or not all(math.isfinite(item) for item in vector):
        return None
    return vector


def index_memory(
    db: Session,
    memory: PersonalMemory,
    vector: list[float] | None,
    model: str | None = None,
) -> None:
    """Replace a memory's private embedding index entry in the current transaction."""

    db.execute(delete(MemoryEmbedding).where(MemoryEmbedding.memory_id == memory.id))
    if vector:
        db.add(MemoryEmbedding(memory_id=memory.id, embedding=vector, model=model))


async def index_memory_with_adapter(
    db: Session,
    memory: PersonalMemory,
    adapter: EmbeddingAdapter | None = None,
) -> str:
    adapter = adapter or EmbeddingAdapter()
    vector = await adapter.embed(memory.content)
    index_memory(db, memory, vector, adapter.settings.model if vector else None)
    return "embedding" if vector else "keyword"


def _active_memory_rows(db: Session, owner_id: str) -> list[PersonalMemory]:
    return db.scalars(
        select(PersonalMemory).where(
            PersonalMemory.owner_id == owner_id,
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
            PersonalMemory.kind.in_(RETRIEVABLE_KINDS),
        )
    ).all()


def _native_pgvector_candidates(
    db: Session,
    owner_id: str,
    query_vector: list[float],
    adapter: EmbeddingAdapter,
    limit: int,
) -> list[tuple[PersonalMemory, float]]:
    """Use a permission-filtered native cosine query on PostgreSQL.

    The mapped field is a JSON/Vector variant so SQLite remains portable.  A
    cast gives SQLAlchemy pgvector's comparator explicitly and keeps the
    distance calculation in PostgreSQL, where the HNSW index can be used.
    """

    if _PgVector is None or db.bind is None or db.bind.dialect.name != "postgresql":
        return []
    vector_column = cast(MemoryEmbedding.embedding, _PgVector(adapter.settings.dimensions))
    distance = vector_column.cosine_distance(query_vector).label("distance")
    candidate_limit = max(limit * 10, 40)
    statement = (
        select(PersonalMemory, distance)
        .join(MemoryEmbedding, MemoryEmbedding.memory_id == PersonalMemory.id)
        .where(
            PersonalMemory.owner_id == owner_id,
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
            PersonalMemory.kind.in_(RETRIEVABLE_KINDS),
            MemoryEmbedding.model == adapter.settings.model,
        )
        .order_by(distance)
        .limit(candidate_limit)
    )
    candidates: list[tuple[PersonalMemory, float]] = []
    for memory, raw_distance in db.execute(statement).all():
        try:
            distance_value = float(raw_distance)
        except (TypeError, ValueError):
            continue
        if not math.isfinite(distance_value):
            continue
        candidates.append((memory, max(-1.0, min(1.0, 1.0 - distance_value))))
    return candidates


async def retrieve_for_chat(
    db: Session,
    owner_id: str,
    query: str,
    limit: int = 4,
    adapter: EmbeddingAdapter | None = None,
) -> dict[str, Any]:
    """Retrieve permission-filtered personal-memory source records for chat.

    The returned dictionary is intentionally provider-neutral:
    ``{"items": [...], "retrieval_mode": "keyword"|"hybrid"}``.
    """

    limit = max(1, min(int(limit), 20))
    if not query.strip():
        return {"items": [], "retrieval_mode": "keyword"}
    adapter = adapter or EmbeddingAdapter()
    query_vector = await adapter.embed(query) if adapter.settings.configured else None
    if query_vector is not None:
        native_candidates = _native_pgvector_candidates(db, owner_id, query_vector, adapter, limit)
        if native_candidates:
            # Include owner-filtered keyword candidates that were created
            # before embeddings were configured or indexed with another model.
            # Native vector ranking remains the primary signal, while exact
            # lexical evidence is never lost when the provider is enabled.
            rows = _active_memory_rows(db, owner_id)
            semantic_by_memory = {row.id: semantic for row, semantic in native_candidates}
            scored: list[tuple[float, PersonalMemory]] = []
            for row in rows:
                lexical = keyword_score(query, row.content)
                semantic = semantic_by_memory.get(row.id)
                if semantic is None:
                    score = lexical
                    accepted = lexical >= 0.12
                else:
                    score = 0.65 * max(semantic, 0.0) + 0.35 * lexical
                    accepted = semantic >= 0.65 or lexical >= 0.12
                if accepted:
                    scored.append((score, row))
            scored.sort(key=lambda pair: (pair[0], pair[1].updated_at), reverse=True)
            return {
                "items": [memory_to_dict(row, score) for score, row in scored[:limit]],
                "retrieval_mode": "hybrid_pgvector",
            }

    rows = _active_memory_rows(db, owner_id)
    if not rows:
        return {"items": [], "retrieval_mode": "keyword"}

    embedding_by_memory: dict[str, list[float]] = {}
    if query_vector is not None:
        indexes = db.scalars(
            select(MemoryEmbedding).where(
                MemoryEmbedding.memory_id.in_([row.id for row in rows]),
                MemoryEmbedding.model == adapter.settings.model,
            )
        ).all()
        for index in indexes:
            vector = _coerce_vector(index.embedding, adapter.settings.dimensions)
            if vector is not None:
                embedding_by_memory[index.memory_id] = vector

    # The mode describes what actually contributed to ranking.  A configured
    # provider with no matching, dimension-valid local index is still honest
    # keyword retrieval; it must not imply that an unrelated model's vector
    # was used.
    mode = "hybrid_python" if query_vector is not None and embedding_by_memory else "keyword"
    scored: list[tuple[float, PersonalMemory]] = []
    for row in rows:
        lexical = keyword_score(query, row.content)
        row_vector = embedding_by_memory.get(row.id)
        if query_vector is not None and row_vector is not None:
            semantic = cosine_similarity(query_vector, row_vector)
            score = 0.65 * max(semantic, 0.0) + 0.35 * lexical
            # A vector must be meaningfully close, or the lexical evidence
            # must independently support the hit.  This prevents a small
            # positive cosine value from surfacing an unrelated memory.
            accepted = semantic >= 0.65 or lexical >= 0.12
        else:
            # Confirmed memories created before embeddings were configured (or
            # with a different model) remain searchable by honest keyword
            # fallback until a reindex pass supplies a matching vector.
            score = lexical
            accepted = lexical >= 0.12
        if accepted:
            scored.append((score, row))
    scored.sort(key=lambda pair: (pair[0], pair[1].updated_at), reverse=True)
    return {
        "items": [memory_to_dict(row, score) for score, row in scored[:limit]],
        "retrieval_mode": mode,
    }


def _extract_explicit_memory(text: str) -> str | None:
    patterns = (
        r"^\s*(?:please\s+)?remember\s+(?:that|this)\s+(.+)$",
        r"^\s*(?:請|请)?(?:幫我|帮我)?(?:記住|记住|記下|记下)\s*(.+)$",
    )
    for pattern in patterns:
        match = re.match(pattern, text.strip(), flags=re.IGNORECASE)
        if match:
            value = match.group(1).strip().rstrip("。.!！")
            return value[:10000] or None
    return None


def _infer_kind(content: str) -> str:
    normalized = content.casefold()
    if any(word in normalized for word in ("prefer", "like", "喜歡", "喜欢", "偏好")):
        return "preference"
    if any(word in normalized for word in ("sad", "lonely", "worried", "難過", "孤單", "擔心", "內疚", "愧疚")):
        return "emotion"
    if any(word in normalized for word in ("is", "am", "住在", "叫做", "生日", "出生")):
        return "fact"
    return "experience"


def propose_from_message(
    db: Session,
    owner_id: str,
    message: Message,
    extracted: dict[str, Any] | None = None,
) -> PersonalMemory | None:
    """Create a candidate only from explicit save language or supplied extraction.

    This helper is intentionally synchronous so the conversation writer can
    call it inside its existing transaction. The caller may subsequently call
    ``index_memory_with_adapter`` before committing.
    """

    if message.sender_id != owner_id:
        return None
    content = _extract_explicit_memory(message.content)
    kind: str | None = None
    if extracted and isinstance(extracted, dict):
        candidate = str(extracted.get("content") or extracted.get("text") or "").strip()
        if candidate:
            content = candidate[:10000]
        kind_value = str(extracted.get("kind") or "").strip().lower()
        if kind_value in ALLOWED_KINDS:
            kind = kind_value
    if not content:
        return None
    existing = db.scalar(
        select(PersonalMemory).where(
            PersonalMemory.owner_id == owner_id,
            PersonalMemory.source_message_id == message.id,
            PersonalMemory.deleted_at.is_(None),
        )
    )
    if existing is not None:
        return existing
    memory = PersonalMemory(
        owner_id=owner_id,
        content=content,
        kind=kind or _infer_kind(content),
        status="candidate",
        suppressed=False,
        source_message_id=message.id,
    )
    db.add(memory)
    db.flush()
    return memory


def _story_ids_for_memory(db: Session, memory_id: str) -> list[str]:
    return list(
        db.scalars(select(StoryMemoryLink.story_id).where(StoryMemoryLink.memory_id == memory_id)).all()
    )


def _memory_chain_ids(db: Session, memory_id: str) -> set[str]:
    """Return a current memory plus all superseded predecessors."""

    rows = db.scalars(select(PersonalMemory)).all()
    ids = {memory_id}
    changed = True
    while changed:
        changed = False
        for row in rows:
            if row.superseded_by in ids and row.id not in ids:
                ids.add(row.id)
                changed = True
    return ids


def _redact_family_messages(db: Session, story_ids: list[str]) -> None:
    if not story_ids or FamilyMessage is None:
        return
    db.execute(
        update(FamilyMessage)
        .where(FamilyMessage.source_story_id.in_(story_ids))
        .values(content="[故事已由擁有人撤回]")
    )


def memory_revision(db: Session, owner_id: str) -> int:
    """Return the current owner-scoped memory revision, or zero if absent."""

    row = db.get(MemoryRevision, owner_id)
    return int(row.version) if row is not None else 0


def bump_memory_revision(db: Session, owner_id: str) -> int:
    """Advance and return the owner revision in the current transaction."""

    row = db.get(MemoryRevision, owner_id)
    if row is None:
        row = MemoryRevision(owner_id=owner_id, version=1)
        db.add(row)
        db.flush()
        return 1
    row.version = int(row.version) + 1
    row.updated_at = datetime.now(timezone.utc)
    db.flush()
    return int(row.version)


def lock_owner_account(db: Session, owner_id: str) -> Account | None:
    """Serialize owner-scoped memory/story mutations in a stable lock order."""

    if db.bind is not None and db.bind.dialect.name == "sqlite":
        db.rollback()
        db.connection().exec_driver_sql("BEGIN IMMEDIATE")
        return db.get(Account, owner_id)
    return db.scalar(select(Account).where(Account.id == owner_id).with_for_update())


def purge_stories(db: Session, story_ids: list[str]) -> list[str]:
    """Delete derived story content and redact already-sent family copies."""

    if not story_ids:
        return []
    _redact_family_messages(db, story_ids)
    db.execute(delete(StoryMemoryLink).where(StoryMemoryLink.story_id.in_(story_ids)))
    db.execute(delete(Story).where(Story.id.in_(story_ids)))
    return story_ids


def scrub_memory_references(db: Session, owner_id: str, memory_ids: set[str]) -> dict[str, Any]:
    """Remove memory IDs and derived text from history and context snapshots.

    Source and explicitly tagged derived turns are replaced with a tombstone;
    all rolling context is rebuilt from the sanitized messages so deleted or
    corrected evidence cannot return after a restart.
    """

    if not memory_ids:
        return {"source_message_ids": [], "conversation_ids": []}
    memory_rows = db.scalars(
        select(PersonalMemory).where(PersonalMemory.owner_id == owner_id, PersonalMemory.id.in_(memory_ids))
    ).all()
    memory_contents = [row.content for row in memory_rows if row.content]
    source_message_ids = {row.source_message_id for row in memory_rows if row.source_message_id}
    affected_messages: list[str] = []
    messages = db.scalars(
        select(Message)
        .join(Conversation, Conversation.id == Message.conversation_id)
        .where(Conversation.owner_id == owner_id)
    ).all()
    for message in messages:
        original_content = message.content
        metadata = message.metadata_json
        changed = False
        has_memory_reference = False
        cleaned = dict(metadata) if isinstance(metadata, dict) else {}
        if isinstance(metadata, dict):
            for key in ("memory_sources", "memory_ids", "source_memory_ids"):
                value = cleaned.get(key)
                if isinstance(value, list):
                    filtered = []
                    for item in value:
                        item_id = item.get("id") if isinstance(item, dict) else item
                        item_id = item_id or (item.get("memory_id") if isinstance(item, dict) else None)
                        if str(item_id) in memory_ids:
                            # Preserve the fact that this turn was derived
                            # from the memory before removing the provenance
                            # field.  This catches paraphrased user questions
                            # whose text contains no exact memory content.
                            has_memory_reference = True
                        if str(item_id) not in memory_ids:
                            filtered.append(item)
                    if filtered != value:
                        cleaned[key] = filtered
                        changed = True
                elif value is not None and str(value) in memory_ids:
                    has_memory_reference = True
                    cleaned.pop(key, None)
                    changed = True
            for key in ("memory_source_content", "memory_context", "retrieved_memories"):
                if key in cleaned:
                    cleaned.pop(key, None)
                    changed = True
        if message.id in source_message_ids:
            message.content = "[記憶已由擁有人移除]"
            changed = True
        elif has_memory_reference:
            # A tagged turn may be a paraphrase or a question about the
            # memory.  Redact the whole text so it cannot reproduce deleted
            # evidence after a restart or through the rolling summary.
            message.content = "[記憶已由擁有人移除]"
            changed = True
        else:
            for old_content in memory_contents:
                if old_content and old_content in message.content:
                    message.content = message.content.replace(old_content, "[記憶已移除]")
                    changed = True
        if changed:
            message.metadata_json = cleaned
            affected_messages.append(message.id)

    affected_conversations: list[str] = []
    conversations = db.scalars(select(Conversation).where(Conversation.owner_id == owner_id)).all()
    for conversation in conversations:
        context = conversation.recent_context if isinstance(conversation.recent_context, list) else []
        changed = False
        cleaned_context: list[Any] = []
        for item in context:
            if not isinstance(item, dict):
                cleaned_context.append(item)
                continue
            cleaned_item = dict(item)
            item_content = str(cleaned_item.get("content") or "")
            for old_content in memory_contents:
                if old_content and old_content in item_content:
                    cleaned_item["content"] = item_content.replace(old_content, "[記憶已移除]")
                    item_content = cleaned_item["content"]
                    changed = True
            for key in ("memory_sources", "memory_ids", "source_memory_ids"):
                value = cleaned_item.get(key)
                if isinstance(value, list):
                    filtered = []
                    for entry in value:
                        entry_id = entry.get("id") if isinstance(entry, dict) else entry
                        entry_id = entry_id or (entry.get("memory_id") if isinstance(entry, dict) else None)
                        if str(entry_id) not in memory_ids:
                            filtered.append(entry)
                    if filtered != value:
                        cleaned_item[key] = filtered
                        changed = True
                elif value is not None and str(value) in memory_ids:
                    cleaned_item.pop(key, None)
                    changed = True
            cleaned_context.append(cleaned_item)
        # Rebuild the persisted context from sanitized messages. This removes
        # stale recent turns and prevents a deleted memory from returning after
        # an application restart.
        owner_messages = db.scalars(
            select(Message).where(Message.conversation_id == conversation.id).order_by(Message.ordinal.asc())
        ).all()
        rebuilt = [
            {"role": item.role, "content": item.content, "ordinal": item.ordinal}
            for item in owner_messages[-12:]
        ]
        rebuilt_summary = " | ".join(f"{item.role}: {item.content}" for item in owner_messages[:-12])[-3000:]
        if rebuilt != cleaned_context or rebuilt_summary != (conversation.rolling_summary or ""):
            cleaned_context = rebuilt
            changed = True
        if changed:
            conversation.recent_context = cleaned_context
            conversation.rolling_summary = rebuilt_summary
            conversation.updated_at = datetime.now(timezone.utc)
            affected_conversations.append(conversation.id)
    return {"source_message_ids": affected_messages, "conversation_ids": affected_conversations}


def supersede_memory(
    db: Session,
    memory: PersonalMemory,
    content: str,
    kind: str,
    suppressed: bool = False,
    event_time: str | None = None,
) -> PersonalMemory:
    """Create a candidate replacement and retire the previous memory version."""

    replacement = PersonalMemory(
        owner_id=memory.owner_id,
        content=content,
        kind=kind,
        event_time=event_time,
        status="candidate",
        suppressed=suppressed,
        source_message_id=memory.source_message_id,
    )
    db.add(replacement)
    db.flush()
    memory.superseded_by = replacement.id
    memory.suppressed = True
    memory.updated_at = datetime.now(timezone.utc)
    db.execute(delete(MemoryEmbedding).where(MemoryEmbedding.memory_id == memory.id))
    scrub_memory_references(db, memory.owner_id, {memory.id})
    purge_stories(db, _story_ids_for_memory(db, memory.id))
    memory.content = "[記憶已由擁有人修正]"
    bump_memory_revision(db, memory.owner_id)
    return replacement


def purge_memory(db: Session, memory: PersonalMemory) -> dict[str, Any]:
    """Permanently purge memory content, indexes, stories, and references."""

    memory_ids = _memory_chain_ids(db, memory.id)
    story_ids: list[str] = []
    for memory_id in memory_ids:
        story_ids.extend(_story_ids_for_memory(db, memory_id))
    story_ids = sorted(set(story_ids))
    scrubbed = scrub_memory_references(db, memory.owner_id, memory_ids)
    db.execute(delete(MemoryEmbedding).where(MemoryEmbedding.memory_id.in_(memory_ids)))
    purge_stories(db, story_ids)
    db.execute(delete(PersonalMemory).where(PersonalMemory.id.in_(memory_ids)))
    bump_memory_revision(db, memory.owner_id)
    return {"memory_id": memory.id, "memory_ids": sorted(memory_ids), "story_ids": story_ids, **scrubbed}


def memory_snapshot_valid(db: Session, owner_id: str, source_ids: list[str] | set[str]) -> bool:
    """Revalidate model-provided memory sources before chat persistence."""

    expected = {str(source_id) for source_id in source_ids}
    if not expected:
        return True
    rows = db.scalars(
        select(PersonalMemory).where(
            PersonalMemory.owner_id == owner_id,
            PersonalMemory.id.in_(expected),
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
            PersonalMemory.kind.in_(RETRIEVABLE_KINDS),
        )
    ).all()
    return {row.id for row in rows} == expected
