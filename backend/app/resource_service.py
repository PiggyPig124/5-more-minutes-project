"""Grounded retrieval for the public Hong Kong knowledge collection.

The initial collection is a small, reviewed JSON corpus.  Retrieval is
deterministic keyword matching by default, which is intentionally reported as
``keyword``.  If an operator configures ``RESOURCE_EMBEDDING_URL`` or the
shared ``EMBEDDING_BASE_URL``, the service may add real vectors from that
remote OpenAI-compatible embedding endpoint and reports
``hybrid_keyword_embedding`` only after the call succeeds.  It never creates
placeholder vectors or calls a conversational model to invent evidence.
"""

from __future__ import annotations

import json
import hashlib
import math
import os
import re
import urllib.error
import urllib.request
from collections.abc import Mapping
from pathlib import Path
from typing import Any, Protocol

from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError

from .resource_models import KnowledgeSource, ResourceItem, ResourceRecord, ResourceSearchResponse


class EmbeddingProvider(Protocol):
    """Small interface for a real, configured remote embedding provider."""

    def embed(self, text: str) -> list[float]:
        """Return a finite vector or raise when the provider is unavailable."""


class RemoteEmbeddingProvider:
    """Call an OpenAI-compatible ``/embeddings`` endpoint over HTTPS/HTTP.

    This adapter is opt-in.  It does not silently use the chat model or a
    hash-based substitute, so keyword retrieval remains the honest fallback
    when no embedding service is configured.
    """

    def __init__(
        self,
        url: str,
        *,
        api_key: str | None = None,
        model: str = "text-embedding-3-small",
        timeout_seconds: float = 8.0,
    ) -> None:
        self.url = url
        self.api_key = api_key
        self.model = model
        self.timeout_seconds = timeout_seconds

    def embed(self, text: str) -> list[float]:
        body = json.dumps({"model": self.model, "input": text}).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        request = urllib.request.Request(self.url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (OSError, ValueError, urllib.error.URLError) as exc:
            raise RuntimeError("embedding provider request failed") from exc
        vector: Any = None
        data = payload.get("data") if isinstance(payload, dict) else None
        if isinstance(data, list) and data and isinstance(data[0], dict):
            vector = data[0].get("embedding")
        if vector is None and isinstance(payload, dict):
            vector = payload.get("embedding")
        if not isinstance(vector, list) or not vector:
            raise RuntimeError("embedding provider returned no vector")
        try:
            result = [float(value) for value in vector]
        except (TypeError, ValueError) as exc:
            raise RuntimeError("embedding provider returned a malformed vector") from exc
        if any(not math.isfinite(value) for value in result):
            raise RuntimeError("embedding provider returned a non-finite vector")
        return result


_UNSET = object()
_DEFAULT_SERVICE: "ResourceService | None" = None
_TOKEN_RE = re.compile(r"[a-z0-9]+|[\u3400-\u9fff]+")
_STOPWORDS = {
    "a",
    "about",
    "an",
    "and",
    "are",
    "can",
    "for",
    "how",
    "i",
    "in",
    "is",
    "me",
    "my",
    "of",
    "please",
    "the",
    "to",
    "what",
    "where",
    "which",
    "with",
}


def _fold(value: str) -> str:
    """Case-fold and collapse punctuation without translating source text."""

    return " ".join(value.casefold().split())


def _compact(value: str) -> str:
    return re.sub(r"[^a-z0-9\u3400-\u9fff]+", "", _fold(value))


def _tokens(value: str) -> set[str]:
    """Tokenize English and Traditional/Simplified Chinese query text.

    Chinese phrases are retained as complete chunks and also represented by
    short n-grams.  This permits a query such as ``醫療費減免`` to match a
    reviewed source term without pretending that this is semantic retrieval.
    """

    result: set[str] = set()
    for chunk in _TOKEN_RE.findall(_fold(value)):
        if re.fullmatch(r"[a-z0-9]+", chunk):
            if chunk not in _STOPWORDS:
                result.add(chunk)
            continue
        result.add(chunk)
        if len(chunk) >= 2:
            result.update(chunk[index : index + 2] for index in range(len(chunk) - 1))
        if len(chunk) >= 3:
            result.update(chunk[index : index + 3] for index in range(len(chunk) - 2))
    return result


def _configured_embedding_provider() -> EmbeddingProvider | None:
    url = os.getenv("RESOURCE_EMBEDDING_URL", "").strip()
    explicit_resource_url = bool(url)
    if not url:
        shared_base = os.getenv("EMBEDDING_BASE_URL", "").strip()
        if shared_base:
            # Match the shared personal-memory adapter: a configured shared
            # service requires its dedicated embedding secret.  An explicit
            # resource URL may be a local, deliberately unauthenticated test
            # endpoint, so it remains allowed without a key.
            if not os.getenv("EMBEDDING_API_KEY", "").strip():
                return None
            url = shared_base.rstrip("/")
            if not url.endswith("/embeddings"):
                url += "/embeddings"
    if not url:
        return None
    try:
        timeout = float(os.getenv("RESOURCE_EMBEDDING_TIMEOUT_SECONDS", os.getenv("EMBEDDING_TIMEOUT_SECONDS", "8")))
    except ValueError:
        timeout = 8.0
    return RemoteEmbeddingProvider(
        url,
        api_key=(
            os.getenv("RESOURCE_EMBEDDING_API_KEY")
            or os.getenv("EMBEDDING_API_KEY")
            or (os.getenv("MODEL_API_KEY") if explicit_resource_url else None)
        ),
        model=os.getenv("RESOURCE_EMBEDDING_MODEL") or os.getenv("EMBEDDING_MODEL", "text-embedding-3-small"),
        timeout_seconds=max(0.5, min(timeout, 30.0)),
    )


class ResourceService:
    """Search the verified public collection without touching personal data."""

    def __init__(
        self,
        records: list[ResourceRecord] | tuple[ResourceRecord, ...] | None = None,
        *,
        data_path: str | Path | None = None,
        review_status_path: str | Path | None = None,
        embedding_provider: EmbeddingProvider | None | object = _UNSET,
    ) -> None:
        if records is None:
            records = self._load_records(data_path)
        # Keep original evidence intact. Only the eligible manifest is used by
        # retrieval, database reconciliation, embeddings and card bindings.
        self.raw_records = tuple(records)
        review_status = self._load_review_status(review_status_path)
        self.records = tuple(record for record in self.raw_records if record.id not in review_status)
        self.embedding_provider: EmbeddingProvider | None = (
            _configured_embedding_provider() if embedding_provider is _UNSET else embedding_provider  # type: ignore[assignment]
        )
        self._embedding_cache: dict[str, tuple[str, str, list[float]]] = {}

    @staticmethod
    def _load_review_status(review_status_path: str | Path | None) -> dict[str, dict[str, Any]]:
        """Read reversible operator holds; never infer approval from a date/URL.

        Removing a hold after review restores the original record on the next
        service construction/restart. This is separate from immutable source
        evidence and does not migrate/delete any database or saved card.
        """
        path = (Path(review_status_path) if review_status_path is not None else
                Path(__file__).resolve().parents[1] / "data" / "resource_review_status.json")
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise RuntimeError(f"unable to load resource review status: {path}") from exc
        if (not isinstance(raw, dict) or raw.get("schema_version") != 1
                or not isinstance(raw.get("records"), dict)):
            raise RuntimeError("invalid resource review status")
        for source_id, entry in raw["records"].items():
            if (not isinstance(source_id, str) or not source_id.strip()
                    or not isinstance(entry, dict) or entry.get("status") != "unverified"
                    or not isinstance(entry.get("reason"), str) or not entry["reason"].strip()
                    or not isinstance(entry.get("original_evidence"), dict)):
                raise RuntimeError("invalid resource review status entry")
        return raw["records"]

    @staticmethod
    def _load_records(data_path: str | Path | None) -> tuple[ResourceRecord, ...]:
        path = Path(data_path) if data_path is not None else Path(__file__).resolve().parents[1] / "data" / "hk_resources.json"
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise RuntimeError(f"unable to load verified public resource collection: {path}") from exc
        if not isinstance(raw, list) or not raw:
            raise RuntimeError("verified public resource collection must be a non-empty array")
        try:
            records = tuple(ResourceRecord.model_validate(item) for item in raw)
        except Exception as exc:
            raise RuntimeError("verified public resource collection contains an invalid record") from exc
        ids = [record.id for record in records]
        if len(ids) != len(set(ids)):
            raise RuntimeError("verified public resource collection contains duplicate ids")
        return records

    @staticmethod
    def _record_from_row(row: KnowledgeSource) -> ResourceRecord:
        """Convert a persisted public row back to the validated source model."""

        return ResourceRecord(
            id=row.id,
            title=row.title,
            excerpt=row.excerpt,
            url=row.source_url,
            verified_at=row.verified_at,
            effective_date=row.effective_date,
            conditions=list(row.conditions or []),
            missing_information=list(row.missing_information or []),
            next_steps=list(row.next_steps or []),
            search_terms=list(row.search_terms or []),
            category=row.category,
            source_authority=row.source_authority,
            districts=list(row.districts or []),
            conflict_group=row.conflict_group,
            conflict_note=row.conflict_note,
        )

    def _records_and_rows_from_db(
        self, db: object
    ) -> tuple[tuple[ResourceRecord, ...], dict[str, KnowledgeSource]] | None:
        """Read only the public table, returning ``None`` if unavailable.

        A missing table can occur briefly during an older deployment rollout;
        callers may use the reviewed JSON fallback until the migration has
        been applied.  The fallback still reports keyword retrieval honestly.
        """

        if db is None or not hasattr(db, "scalars"):
            return None
        try:
            rows = db.scalars(select(KnowledgeSource).order_by(KnowledgeSource.id)).all()
        except SQLAlchemyError:
            # The public search is read-only.  Do not rollback a caller's
            # unrelated transaction when an older deployment lacks the new
            # table; the caller can handle its own transaction boundary.
            return None
        # The JSON seed is the active reviewed manifest.  A database row is
        # eligible only when its id and content hash still match that manifest;
        # removed or superseded rows remain auditable in the table but cannot
        # leak into current retrieval results.  Unseeded current rows use the
        # validated JSON record until the next idempotent seed pass.
        rows_by_id = {row.id: row for row in rows}
        current_records: list[ResourceRecord] = []
        row_map: dict[str, KnowledgeSource] = {}
        for record in self.records:
            row = rows_by_id.get(record.id)
            if row is not None and row.content_hash == _record_hash(record):
                current_records.append(self._record_from_row(row))
                row_map[record.id] = row
            else:
                current_records.append(record)
        return tuple(current_records), row_map

    def records_from_db(self, db: object) -> tuple[ResourceRecord, ...] | None:
        """Return public records from the persisted table when available."""

        result = self._records_and_rows_from_db(db)
        return result[0] if result is not None else None

    @staticmethod
    def _lexical_score(record: ResourceRecord, query: str, query_terms: set[str]) -> float:
        title = _fold(record.title)
        title_compact = _compact(record.title)
        search_text = " ".join(
            [
                record.title,
                record.excerpt,
                *record.conditions,
                *record.missing_information,
                *record.search_terms,
                record.category,
                *record.districts,
            ]
        )
        search_folded = _fold(search_text)
        search_compact = _compact(search_text)
        query_folded = _fold(query)
        query_compact = _compact(query)

        score = 0.0
        for phrase in record.search_terms:
            phrase_folded = _fold(phrase)
            phrase_compact = _compact(phrase)
            if phrase_folded and phrase_folded in query_folded:
                score += 14.0
            elif phrase_compact and len(phrase_compact) >= 3 and phrase_compact in query_compact:
                score += 10.0

        title_terms = _tokens(record.title)
        keyword_terms = _tokens(" ".join(record.search_terms))
        category_terms = _tokens(record.category)
        for term in query_terms:
            if term in title_terms or (len(term) >= 3 and term in title_compact):
                score += 7.0
            elif term in keyword_terms:
                score += 6.0
            elif term in category_terms:
                score += 3.0
            elif term in search_folded or (len(term) >= 2 and term in search_compact):
                score += 2.0
        # Short exact title matches are a useful deterministic tie-breaker.
        if query_folded and query_folded in title:
            score += 8.0
        # A lone low-signal token found only in explanatory prose should not
        # turn an unrelated question into a welfare result.  Title, keyword,
        # category, or exact phrase matches score above this floor.
        return score if score >= 3.0 else 0.0

    @staticmethod
    def _cosine(left: list[float], right: list[float]) -> float | None:
        if len(left) != len(right) or not left or not right:
            return None
        numerator = sum(a * b for a, b in zip(left, right))
        left_norm = math.sqrt(sum(value * value for value in left))
        right_norm = math.sqrt(sum(value * value for value in right))
        if left_norm == 0 or right_norm == 0:
            return None
        return numerator / (left_norm * right_norm)

    def _hybrid_scores(
        self,
        query: str,
        candidates: list[tuple[ResourceRecord, float]],
        *,
        db: object | None = None,
        db_rows: Mapping[str, KnowledgeSource] | None = None,
    ) -> tuple[dict[str, float], bool]:
        provider = self.embedding_provider
        if provider is None or not candidates:
            return {record.id: score for record, score in candidates}, False
        try:
            query_vector = provider.embed(query)
        except Exception:
            return {record.id: score for record, score in candidates}, False

        semantic: dict[str, float] = {}
        provider_model = str(getattr(provider, "model", "configured-remote"))
        rows_changed = False
        for record, _ in candidates:
            try:
                source_hash = _record_hash(record)
                cached = self._embedding_cache.get(record.id)
                row = db_rows.get(record.id) if db_rows is not None else None
                vector: list[float] | None = None
                if (
                    row is not None
                    and row.embedding_model == provider_model
                    and row.embedding_source_hash == source_hash
                    and isinstance(row.embedding_vector, list)
                ):
                    vector = [float(value) for value in row.embedding_vector]
                elif cached is not None and cached[0] == source_hash and cached[1] == provider_model:
                    vector = cached[2]
                if vector is None:
                    vector = provider.embed(
                        " ".join([record.title, record.excerpt, *record.conditions, *record.search_terms])
                    )
                    self._embedding_cache[record.id] = (source_hash, provider_model, vector)
                    if row is not None:
                        row.embedding_model = provider_model
                        row.embedding_source_hash = source_hash
                        row.embedding_vector = list(vector)
                        rows_changed = True
                similarity = self._cosine(query_vector, vector)
            except Exception:
                similarity = None
            if similarity is not None:
                semantic[record.id] = similarity
        if rows_changed and db is not None and hasattr(db, "commit"):
            try:
                db.commit()
            except SQLAlchemyError:
                # Embedding persistence is an optional cache.  Leave the
                # caller's transaction boundary to its owner if that commit
                # cannot be completed; lexical results remain valid.
                pass
        if not semantic:
            return {record.id: score for record, score in candidates}, False

        max_lexical = max(score for _, score in candidates) or 1.0
        combined: dict[str, float] = {}
        for record, lexical in candidates:
            similarity = semantic.get(record.id)
            if similarity is None:
                combined[record.id] = lexical / max_lexical
            else:
                # Lexical evidence remains the larger component so a remote
                # provider cannot surface a source that keyword abstention
                # would have rejected.
                combined[record.id] = 0.7 * (lexical / max_lexical) + 0.3 * ((similarity + 1.0) / 2.0)
        return combined, True

    @staticmethod
    def _conflicts(records: list[ResourceRecord]) -> list[str]:
        grouped: dict[str, list[ResourceRecord]] = {}
        for record in records:
            if record.conflict_group:
                grouped.setdefault(record.conflict_group, []).append(record)
        conflicts: list[str] = []
        for group, members in grouped.items():
            notes = {record.conflict_note for record in members if record.conflict_note}
            if len(notes) > 1:
                details = "; ".join(
                    f"{record.title}: {record.conflict_note}" for record in members if record.conflict_note
                )
                conflicts.append(f"Conflicting official evidence for {group}: {details}")
        return conflicts

    def search(
        self,
        query: str,
        limit: int = 4,
        *,
        db: object | None = None,
    ) -> ResourceSearchResponse:
        query = query.strip()
        if not query:
            return ResourceSearchResponse(query=query, retrieval_mode="keyword", items=[], conflicts=[])
        limit = max(1, min(int(limit), 20))
        db_rows: dict[str, KnowledgeSource] | None = None
        db_result = self._records_and_rows_from_db(db) if db is not None else None
        if db_result is None:
            records = self.records
        else:
            records, db_rows = db_result
        query_terms = _tokens(query)
        candidates = [
            (record, self._lexical_score(record, query, query_terms))
            for record in records
        ]
        candidates = [(record, score) for record, score in candidates if score > 0]
        if not candidates:
            return ResourceSearchResponse(query=query, retrieval_mode="keyword", items=[], conflicts=[])

        matched_records = [record for record, _ in candidates]
        scores, hybrid = self._hybrid_scores(query, candidates, db=db, db_rows=db_rows)
        ranked = sorted(
            candidates,
            key=lambda pair: (-scores.get(pair[0].id, pair[1]), -pair[1], pair[0].id),
        )[:limit]
        records = [record for record, _ in ranked]
        authorities = {record.id: record.source_authority for record in self.records}
        items = [
            ResourceItem(
                id=record.id,
                title=record.title,
                organisation=authorities.get(record.id),
                excerpt=record.excerpt,
                url=record.url,
                verified_at=record.verified_at,
                effective_date=record.effective_date,
                conditions=list(record.conditions),
                missing_information=list(record.missing_information),
                next_steps=list(record.next_steps),
            )
            for record in records
        ]
        return ResourceSearchResponse(
            query=query,
            retrieval_mode="hybrid_keyword_embedding" if hybrid else "keyword",
            items=items,
            # Conflicts are limited to sources that matched this query, even
            # when the caller asks for fewer result items than matched
            # sources.  We never report a conflict from the entire corpus.
            conflicts=self._conflicts(matched_records),
        )


def _record_hash(record: ResourceRecord) -> str:
    payload = json.dumps(record.model_dump(mode="json"), sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def seed_resources(db: object, records: list[ResourceRecord] | tuple[ResourceRecord, ...] | None = None) -> int:
    """Idempotently upsert the reviewed seed into ``knowledge_sources``.

    This function performs no network access.  It is safe to call from the
    application lifespan after ``initialize_database`` or before the first
    request.  It returns the number of inserted or changed rows.
    """

    if db is None or not hasattr(db, "get") or not hasattr(db, "add"):
        raise TypeError("seed_resources requires a SQLAlchemy Session")
    source_records = tuple(records) if records is not None else get_default_resource_service().records
    changed = 0
    for record in source_records:
        row = db.get(KnowledgeSource, record.id)  # type: ignore[attr-defined]
        values = {
            "title": record.title,
            "excerpt": record.excerpt,
            "source_url": record.url,
            "verified_at": record.verified_at,
            "effective_date": record.effective_date,
            "conditions": list(record.conditions),
            "missing_information": list(record.missing_information),
            "next_steps": list(record.next_steps),
            "search_terms": list(record.search_terms),
            "category": record.category,
            "source_authority": record.source_authority,
            "districts": list(record.districts),
            "conflict_group": record.conflict_group,
            "conflict_note": record.conflict_note,
            "content_hash": _record_hash(record),
        }
        if row is None:
            db.add(KnowledgeSource(id=record.id, **values))  # type: ignore[attr-defined]
            changed += 1
            continue
        if row.content_hash != values["content_hash"]:
            for field, value in values.items():
                setattr(row, field, value)
            # Content changes invalidate persisted document vectors.  They
            # will be rebuilt lazily only after a real provider is available.
            row.embedding_model = None
            row.embedding_source_hash = None
            row.embedding_vector = None
            changed += 1
    db.commit()  # type: ignore[attr-defined]
    return changed


def get_default_resource_service() -> ResourceService:
    """Return the process-local public collection service used by chat/tools."""

    global _DEFAULT_SERVICE
    if _DEFAULT_SERVICE is None:
        _DEFAULT_SERVICE = ResourceService()
    return _DEFAULT_SERVICE


async def search_resources(db: object, query: str, limit: int = 4) -> dict[str, Any]:
    """Async integration seam for chat/tool callers.

    ``db`` is accepted to keep the tool signature compatible with request
    handlers and future persisted source collections.  It is used only for
    the separate public table; personal-memory tables are never searched.
    """

    service = get_default_resource_service()
    # The remote embedding adapter is synchronous and must not block the
    # async chat/event loop.  Keyword-only requests are also kept on the same
    # worker seam so the contract is uniform for configured and fallback
    # deployments.
    from starlette.concurrency import run_in_threadpool

    response = await run_in_threadpool(service.search, query, limit, db=db)
    result = response.model_dump(mode="json")
    # Internal chat provenance, separate from the stable ResourceItem wire DTO.
    # Bind only results matching the reviewed manifest, never arbitrary fields
    # supplied by a model or a database row with stale/tampered display values.
    manifest = {record.id: record for record in service.records}
    result["source_bindings"] = [
        {"source_id": item.id, "content_hash": _record_hash(manifest[item.id])}
        for item in response.items
        if item.id in manifest and item.model_dump(mode="json") ==
        ResourceItem.model_validate(manifest[item.id].model_dump()).model_dump(mode="json")
    ]
    return result
