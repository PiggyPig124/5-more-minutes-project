"""Models for the public Hong Kong knowledge collection.

The public collection deliberately has its own models instead of reusing the
personal-memory or conversation models.  A resource is a reviewed source
chunk with provenance and an explicit list of conditions that still need to be
checked.  It is information for a person to verify, not an eligibility
decision.
"""

from __future__ import annotations

from datetime import date

from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import JSON, Date, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base


class ResourceRecord(BaseModel):
    """A verified, searchable source chunk loaded from the seed collection."""

    model_config = ConfigDict(extra="forbid")

    id: str = Field(min_length=1, max_length=120)
    title: str = Field(min_length=1, max_length=300)
    excerpt: str = Field(min_length=1, max_length=12000)
    url: str = Field(min_length=1, max_length=2000)
    verified_at: date
    effective_date: date | None = None
    conditions: list[str] = Field(min_length=1, max_length=40)
    missing_information: list[str] = Field(default_factory=list, max_length=40)
    next_steps: list[str] = Field(min_length=3, max_length=3)

    # Retrieval metadata is kept in the source collection but is not exposed
    # as a user assertion.  It lets the service search without inventing a
    # semantic score when an embedding provider is not configured.
    search_terms: list[str] = Field(min_length=1, max_length=100)
    category: str = Field(min_length=1, max_length=80)
    source_authority: str = Field(min_length=1, max_length=200)
    districts: list[str] = Field(default_factory=list, max_length=25)
    conflict_group: str | None = Field(default=None, max_length=120)
    conflict_note: str | None = Field(default=None, max_length=500)

    @field_validator("url")
    @classmethod
    def official_http_url(cls, value: str) -> str:
        value = value.strip()
        if not value.startswith(("https://", "http://")):
            raise ValueError("resource URLs must be absolute HTTP(S) URLs")
        return value

    @field_validator("next_steps")
    @classmethod
    def exactly_three_next_steps(cls, value: list[str]) -> list[str]:
        if len(value) != 3 or any(not step.strip() for step in value):
            raise ValueError("each resource must contain exactly three non-empty next steps")
        return [step.strip() for step in value]

    @field_validator("conditions", "missing_information", "search_terms", "districts")
    @classmethod
    def trim_list_values(cls, value: list[str]) -> list[str]:
        return [item.strip() for item in value if item and item.strip()]


class ResourceItem(BaseModel):
    """The provenance-preserving result returned to either authenticated role."""

    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str
    excerpt: str
    url: str
    verified_at: date
    effective_date: date | None = None
    conditions: list[str]
    missing_information: list[str]
    next_steps: list[str] = Field(min_length=3, max_length=3)


class ResourceSearchRequest(BaseModel):
    """POST body for public-resource retrieval."""

    model_config = ConfigDict(extra="forbid")

    query: str = Field(min_length=1, max_length=500)
    limit: int = Field(default=4, ge=1, le=20)

    @field_validator("query")
    @classmethod
    def non_blank_query(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("query cannot be blank")
        return value


class ResourceSearchResponse(BaseModel):
    """Search response shared by GET and POST endpoints."""

    query: str
    # ``keyword`` means deterministic lexical retrieval.  The service emits
    # ``hybrid_keyword_embedding`` only after a configured remote provider
    # successfully contributes real vectors.
    retrieval_mode: str
    items: list[ResourceItem]
    conflicts: list[str]


class KnowledgeSource(Base):
    """Persisted public-source collection, separate from personal memories.

    The JSON file is the reviewed seed/versioned input.  This table is the
    runtime collection used by the API and future migrations can add vector
    columns or an external index without sharing a table with private memory.
    """

    __tablename__ = "knowledge_sources"

    id: Mapped[str] = mapped_column(String(120), primary_key=True)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    excerpt: Mapped[str] = mapped_column(Text, nullable=False)
    source_url: Mapped[str] = mapped_column(String(2000), nullable=False)
    verified_at: Mapped[date] = mapped_column(Date, nullable=False)
    effective_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    conditions: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    missing_information: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    next_steps: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    search_terms: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    category: Mapped[str] = mapped_column(String(80), nullable=False)
    source_authority: Mapped[str] = mapped_column(String(200), nullable=False)
    districts: Mapped[list[str]] = mapped_column(JSON, nullable=False)
    conflict_group: Mapped[str | None] = mapped_column(String(120), nullable=True)
    conflict_note: Mapped[str | None] = mapped_column(String(500), nullable=True)
    content_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    # Optional real embedding cache.  It is invalidated whenever content_hash
    # or the configured embedding model changes; no vector is seeded at
    # startup and no fake vector is ever written.
    embedding_model: Mapped[str | None] = mapped_column(String(200), nullable=True)
    embedding_source_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    embedding_vector: Mapped[list[float] | None] = mapped_column(JSON, nullable=True)


# A descriptive alias helps integrations that call the entity PublicResource
# while retaining one SQLAlchemy table and one source of truth.
PublicResource = KnowledgeSource
