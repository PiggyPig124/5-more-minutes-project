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
import hashlib
from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import Any

import httpx
from sqlalchemy import cast, delete, select, update
from sqlalchemy.orm import Session

from .memory_models import (
    MemoryEmbedding,
    MemoryPreferenceBlock,
    MemoryRevision,
    PersonalMemory,
    Story,
    StoryMemoryLink,
    _PgVector,
    embedding_dimensions,
)
from .memory_consent import memory_consent_enabled
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


def memory_to_dict(
    memory: PersonalMemory,
    score: float | None = None,
    capture_method: str = "owner_saved",
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "id": memory.id,
        "content": memory.content,
        "kind": memory.kind,
        "status": memory.status,
        "suppressed": bool(memory.suppressed),
        "event_time": memory.event_time,
        "source_message_id": memory.source_message_id,
        "capture_method": capture_method,
        "created_at": memory.created_at,
        "updated_at": memory.updated_at,
    }
    if score is not None:
        result["score"] = round(float(score), 6)
    return result


def memory_capture_method(db: Session, memory: PersonalMemory) -> str:
    """Report how a memory entered the library without exposing the source text."""

    if not memory.source_message_id:
        return "owner_added"
    source = db.get(Message, memory.source_message_id)
    metadata = source.metadata_json if source is not None else None
    value = metadata.get("memory_capture_method") if isinstance(metadata, dict) else None
    return value if value in {"agent_auto", "user_saved", "manual"} else "owner_added"


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

    if not memory_consent_enabled(db, owner_id):
        return {"items": [], "retrieval_mode": "disabled"}

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
                "items": [memory_to_dict(row, score, memory_capture_method(db, row)) for score, row in scored[:limit]],
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
        "items": [memory_to_dict(row, score, memory_capture_method(db, row)) for score, row in scored[:limit]],
        "retrieval_mode": mode,
    }


# This is a write-boundary veto only. It never extracts, paraphrases, or
# decides what a memory should say; that decision comes from the configured
# model. The bounded deny list provides an independent guard when a provider
# mistakenly labels clearly sensitive text as ordinary.
_SENSITIVE_MEMORY_RE = re.compile(
    r"政治|政黨|政党|選舉|选举|投票|宗教|信仰|性取向|同性戀|同性恋|色情|性行為|性行为|"
    r"病歷|病史|診斷|诊断|疾病|癌症|糖尿|抑鬱|抑郁|焦慮|焦虑|藥物|药物|服藥|服药|"
    r"財務|财务|債務|债务|收入|資產|资产|移民身份|難民|难民|族裔|種族|种族|"
    r"\b(?:politic(?:s|al)?|religion|religious|sexual|diagnos(?:is|ed)|medical|medication|"
    r"illness|disease|cancer|diabetes|depression|anxiety|income|debt|immigration status|ethnicity)\b",
    re.IGNORECASE,
)


def sensitive_memory_content(*values: str | None) -> bool:
    return any(value and _SENSITIVE_MEMORY_RE.search(value) for value in values)


def _preference_key(topic_key: str) -> str:
    return re.sub(r"[^\w\u3400-\u9fff]+", "", topic_key.casefold())


def _preference_hash(owner_id: str, topic_key: str) -> str:
    # This owner-scoped dedupe key is not an anonymization mechanism.
    return hashlib.sha256(f"{owner_id}\0{_preference_key(topic_key)}".encode("utf-8")).hexdigest()


def _block_preference_topic(
    db: Session,
    owner_id: str,
    content: str,
    reason: str,
    topic_key: str | None = None,
) -> None:
    # New model-maintained memories carry a generic stable key. Content is a
    # fallback only for legacy/manual entries that have no such key.
    topic = (topic_key or content).strip()
    if not topic or len(topic) > 120:
        return
    topic_hash = _preference_hash(owner_id, topic)
    block = db.get(MemoryPreferenceBlock, (owner_id, topic_hash))
    if block is None:
        db.add(MemoryPreferenceBlock(owner_id=owner_id, topic_hash=topic_hash, reason=reason))
    else:
        block.reason = reason


def _clear_preference_topic_block(
    db: Session, owner_id: str, content: str, topic_key: str | None = None
) -> None:
    topic = (topic_key or content).strip()
    if topic and len(topic) <= 120:
        db.execute(delete(MemoryPreferenceBlock).where(
            MemoryPreferenceBlock.owner_id == owner_id,
            MemoryPreferenceBlock.topic_hash == _preference_hash(owner_id, topic),
        ))


def model_memory_context(db: Session, owner_id: str) -> list[dict[str, Any]]:
    """Return only current, owner-scoped records the model may manage."""

    rows = db.scalars(select(PersonalMemory).where(
        PersonalMemory.owner_id == owner_id,
        PersonalMemory.status == "confirmed",
        PersonalMemory.suppressed.is_(False),
        PersonalMemory.superseded_by.is_(None),
        PersonalMemory.deleted_at.is_(None),
        PersonalMemory.kind.in_(RETRIEVABLE_KINDS),
    ).order_by(PersonalMemory.updated_at.desc()).limit(100)).all()
    return [{
        "id": row.id,
        "content": row.content,
        "kind": row.kind,
        "status": row.status,
        "topic_key": row.topic_key,
        "capture_method": memory_capture_method(db, row),
        "updated_at": row.updated_at.isoformat(),
    } for row in rows]


def apply_model_memory_actions(
    db: Session,
    owner_id: str,
    message: Message,
    actions: list[dict[str, Any]],
    memory_snapshot: list[dict[str, Any]],
    source_texts: list[str],
) -> dict[str, Any]:
    """Apply validated, model-authored memory decisions inside the chat write.

    This function never derives memory content from message text. Action IDs
    must match current owner records supplied to the model, and updates can
    target only agent-auto preferences. The route separately rechecks the
    owner-wide revision captured before the model call.
    """

    result: dict[str, Any] = {"saved": [], "suggestion": None, "forgotten_ids": []}
    if message.sender_id != owner_id or not memory_consent_enabled(db, owner_id):
        return result
    supplied = {str(item.get("id")): item for item in memory_snapshot if item.get("id")}

    mutation_done = False
    for action in actions[:3]:
        if not isinstance(action, dict):
            continue
        action_type = action.get("action")
        content = action.get("content")
        kind = action.get("kind")
        sensitivity = action.get("sensitivity")
        topic_key = action.get("topic_key")
        memory_id = action.get("memory_id")
        evidence = action.get("evidence")
        if not isinstance(evidence, str) or not any(evidence in source for source in source_texts):
            continue

        if action_type == "suggest":
            if (isinstance(content, str) and content.strip() and kind in ALLOWED_KINDS
                    and len(content) <= 500):
                result["suggestion"] = {
                    "content": content.strip(),
                    "kind": kind,
                    "source_message_id": message.id,
                    "sensitivity": sensitivity,
                    "requires_confirmation": True,
                    **({"topic_key": topic_key} if isinstance(topic_key, str) and topic_key.strip() else {}),
                }
            continue

        if action_type == "forget":
            if mutation_done:
                continue
            snapshot = supplied.get(str(memory_id))
            if snapshot is None:
                continue
            current = db.scalar(select(PersonalMemory).where(
                PersonalMemory.id == str(memory_id),
                PersonalMemory.owner_id == owner_id,
                PersonalMemory.status == "confirmed",
                PersonalMemory.suppressed.is_(False),
                PersonalMemory.superseded_by.is_(None),
                PersonalMemory.deleted_at.is_(None),
            ))
            if (current is None or current.content != snapshot.get("content")
                    or current.updated_at.isoformat() != snapshot.get("updated_at")):
                continue
            purge_memory(db, current)
            result["forgotten_ids"].append(str(memory_id))
            mutation_done = True
            continue

        # Automatic writes are only for ordinary preferences. The model's
        # sensitivity label is necessary, but the independent bounded guard
        # below can still veto a clearly sensitive source or paraphrase.
        if (action_type not in {"save_preference", "correct_preference"}
                or kind != "preference" or sensitivity != "ordinary"
                or not isinstance(content, str) or not content.strip() or len(content) > 500
                or not isinstance(topic_key, str) or not topic_key.strip() or len(topic_key) > 120
                or sensitive_memory_content(message.content, content)):
            continue

        clean_content = content.strip()
        clean_topic_key = topic_key.strip()
        topic_hash = _preference_hash(owner_id, clean_topic_key)
        if db.get(MemoryPreferenceBlock, (owner_id, topic_hash)) is not None:
            continue

        if action_type == "correct_preference":
            if mutation_done:
                continue
            snapshot = supplied.get(str(memory_id))
            if snapshot is None or snapshot.get("capture_method") != "agent_auto":
                continue
            current = db.scalar(select(PersonalMemory).where(
                PersonalMemory.id == str(memory_id),
                PersonalMemory.owner_id == owner_id,
                PersonalMemory.kind == "preference",
                PersonalMemory.status == "confirmed",
                PersonalMemory.suppressed.is_(False),
                PersonalMemory.superseded_by.is_(None),
                PersonalMemory.deleted_at.is_(None),
            ))
            if (current is None or current.content != snapshot.get("content")
                    or current.updated_at.isoformat() != snapshot.get("updated_at")
                    or memory_capture_method(db, current) != "agent_auto"):
                continue
            if current.topic_key and _preference_hash(owner_id, current.topic_key) != topic_hash:
                _block_preference_topic(db, owner_id, current.content, "corrected", current.topic_key)
            replacement = supersede_memory(
                db, current, clean_content, "preference", suppressed=False,
                topic_key=clean_topic_key,
            )
            replacement.status = "confirmed"
            replacement.source_message_id = message.id
            index_memory(db, replacement, None)
            _mark_memory_capture(message, "agent_auto")
            result["saved"].append(replacement)
            mutation_done = True
            continue

        # New preference: same-key automatic or owner-curated records are
        # deduplicated. Corrections must name the exact agent-auto record.
        duplicate = db.scalar(select(PersonalMemory).where(
            PersonalMemory.owner_id == owner_id,
            PersonalMemory.kind == "preference",
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
            PersonalMemory.topic_key == clean_topic_key,
        ))
        if duplicate is not None:
            continue
        if mutation_done:
            continue
        memory = PersonalMemory(
            owner_id=owner_id,
            content=clean_content,
            kind="preference",
            topic_key=clean_topic_key,
            status="confirmed",
            suppressed=False,
            source_message_id=message.id,
        )
        db.add(memory)
        db.flush()
        _mark_memory_capture(message, "agent_auto")
        index_memory(db, memory, None)
        bump_memory_revision(db, owner_id)
        result["saved"].append(memory)
        mutation_done = True
    return result


def _mark_memory_capture(message: Message, method: str) -> None:
    metadata = dict(message.metadata_json or {})
    metadata["memory_capture_method"] = method
    message.metadata_json = metadata


_COMMUNITY_CONTEXT_CUE_RE = re.compile(
    r"週末|周末|閒暇|闲暇|有空|空閒|空闲|活動|活动|節目|节目|出街|出門|出门|出去|"
    r"有咩做|有什麼做|有甚麼做|參加|参加|興趣班|兴趣班|消遣|hobb(?:y|ies)|"
    r"free\s+time|weekend|activities|events|things\s+to\s+do|go\s+out|join\s+in",
    re.IGNORECASE,
)
_COMMUNITY_BLOCK_CONTEXT_RE = re.compile(
    r"胸痛|心口痛|呼吸困難|呼吸困难|喘不過氣|喘不过气|流血|受傷|受伤|跌倒|急救|救命|緊急|紧急|求救|"
    r"不舒服|發燒|发烧|疼痛|痛楚|醫療|医疗|醫生|医生|診症|诊症|藥物|药物|服藥|服药|覆診|复诊|"
    r"很擔心|很担心|害怕|難過|难过|孤單|孤单|自殺|自杀|傷害自己|伤害自己|"
    r"福利|津貼|津贴|補助|补助|資助|资助|照顧者支援|照顾者支援|長者中心|长者中心|"
    r"預約|预约|提醒|待辦|待办|任務|任务|找工作|"
    r"\b(?:chest pain|shortness of breath|can't breathe|cannot breathe|bleeding|injury|fell down|"
    r"emergency|urgent|help me|worried|upset|lonely|suicid(?:al|e)|doctor|medical|medicine|"
    r"medication|appointment|reminder|task|welfare|subsid(?:y|ies)|caregiver support)\b",
    re.IGNORECASE,
)


def community_memory_prompt(
    db: Session, owner_id: str, user_text: str
) -> dict[str, str] | None:
    """Offer a Community follow-up once per active preference, on a relevant turn.

    The offer is metadata for the client, not input to a configured model and
    does not search a provider. The user must start an approved lookup later.
    """

    if not memory_consent_enabled(db, owner_id) or _COMMUNITY_BLOCK_CONTEXT_RE.search(user_text):
        return None
    active = db.scalars(
        select(PersonalMemory).where(
            PersonalMemory.owner_id == owner_id,
            PersonalMemory.kind == "preference",
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
        ).order_by(PersonalMemory.created_at.asc())
    ).all()
    if not active:
        return None

    prior_assistant_messages = db.scalars(
        select(Message)
        .join(Conversation, Conversation.id == Message.conversation_id)
        .where(Conversation.owner_id == owner_id, Message.role == "assistant")
    ).all()
    prompted_ids = set()
    for prior_message in prior_assistant_messages:
        metadata = prior_message.metadata_json if isinstance(prior_message.metadata_json, dict) else {}
        prompt = metadata.get("community_memory_prompt")
        if isinstance(prompt, dict) and prompt.get("memory_id"):
            prompted_ids.add(str(prompt["memory_id"]))

    normalized_user_text = user_text.casefold()
    context_is_relevant = bool(_COMMUNITY_CONTEXT_CUE_RE.search(user_text))
    for memory in active:
        if memory.id in prompted_ids:
            continue
        topic = (memory.topic_key or memory.content).strip()[:80]
        if not topic:
            continue
        if not context_is_relevant and topic.casefold() not in normalized_user_text:
            continue
        return {
            "memory_id": memory.id,
            "memory_content": memory.content,
            "topic": topic,
            "prompt_zh": f"你之前提過「{topic}」；想唔想看看有沒有相關活動？",
            "prompt_en": f"You previously mentioned “{topic}”. Would you like to see if there are related activities?",
        }
    return None


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


def scrub_memory_references(
    db: Session,
    owner_id: str,
    memory_ids: set[str],
    *,
    scrub_capture_provenance: bool = False,
) -> dict[str, Any]:
    """Remove memory IDs and derived text from history and context snapshots.

    Source and explicitly tagged derived turns are replaced with a tombstone;
    all rolling context is rebuilt from the sanitized messages so deleted or
    corrected evidence cannot return after a restart.
    """

    if not memory_ids:
        return {"source_message_ids": [], "conversation_ids": []}
    try:
        from .community_models import CommunitySkill

        db.execute(
            delete(CommunitySkill).where(
                CommunitySkill.owner_id == owner_id,
                CommunitySkill.memory_id.in_(memory_ids),
            )
        )
    except ImportError:  # pragma: no cover - optional collaboration milestone
        pass
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
            auto_saved_memory = cleaned.get("auto_saved_memory")
            if (
                isinstance(auto_saved_memory, dict)
                and str(auto_saved_memory.get("id") or "") in memory_ids
            ):
                has_memory_reference = True
                cleaned.pop("auto_saved_memory", None)
                changed = True
            memory_suggestion = cleaned.get("memory_suggestion")
            if (
                isinstance(memory_suggestion, dict)
                and str(memory_suggestion.get("source_message_id") or "") in source_message_ids
            ):
                has_memory_reference = True
                cleaned.pop("memory_suggestion", None)
                changed = True
            community_prompt = cleaned.get("community_memory_prompt")
            if (
                isinstance(community_prompt, dict)
                and str(community_prompt.get("memory_id") or "") in memory_ids
            ):
                has_memory_reference = True
                cleaned.pop("community_memory_prompt", None)
                changed = True
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
            if scrub_capture_provenance:
                cleaned.pop("memory_capture_method", None)
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
    topic_key: str | None = None,
) -> PersonalMemory:
    """Create a candidate replacement and retire the previous memory version."""

    replacement = PersonalMemory(
        owner_id=memory.owner_id,
        content=content,
        kind=kind,
        topic_key=topic_key,
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
    chain = db.scalars(
        select(PersonalMemory).where(
            PersonalMemory.owner_id == memory.owner_id,
            PersonalMemory.id.in_(memory_ids),
        )
    ).all()
    for prior in chain:
        if prior.kind == "preference":
            _block_preference_topic(db, memory.owner_id, prior.content, "deleted", prior.topic_key)
    story_ids: list[str] = []
    for memory_id in memory_ids:
        story_ids.extend(_story_ids_for_memory(db, memory_id))
    story_ids = sorted(set(story_ids))
    scrubbed = scrub_memory_references(
        db, memory.owner_id, memory_ids, scrub_capture_provenance=True
    )
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
