"""Consent-aware community discovery and owner-controlled skill matching."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Literal
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..community_models import CommunityListing, CommunitySkill
from ..community_search import CommunitySearch
from ..db import get_db
from ..dependencies import require_elder
from ..memory_consent import memory_consent_enabled
from ..memory_models import PersonalMemory
from ..memory_service import (lock_owner_account, memory_capture_method,
                              memory_revision, require_memory_revision)
from ..models import Account

router = APIRouter(prefix="/community", tags=["community"])
FRESHNESS_DAYS = 30

# Conservative phrase map: proposals are generated only from explicit confirmed
# memories containing one of these terms. This deliberately does not inspect chat.
_SKILL_TERMS: tuple[tuple[tuple[str, ...], str], ...] = (
    (("tailor", "sew", "縫紉", "縫衣", "車衣", "裁縫"), "Tailoring and basic sewing"),
    (("cook", "cooking", "烹飪", "煮餸", "煮菜"), "Cooking"),
    (("garden", "gardening", "園藝", "種花", "種菜"), "Gardening"),
    (("teach", "teaching", "教書", "教學", "教人"), "Teaching"),
    (("knit", "knitting", "編織", "織冷衫"), "Knitting"),
    (("woodwork", "carpentry", "木工"), "Woodworking"),
)


class SkillDecision(BaseModel):
    model_config = ConfigDict(extra="forbid")

    decision: Literal["confirm", "edit", "reject"]
    skill: str | None = Field(default=None, min_length=1, max_length=160)

    @field_validator("skill")
    @classmethod
    def trim_skill(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("skill cannot be blank")
        return value.strip() if value is not None else None


class SkillOut(BaseModel):
    id: str
    memory_id: str
    suggestion: str
    status: Literal["suggested", "confirmed", "rejected"]
    reason: str
    revision: int


class SkillList(BaseModel):
    items: list[SkillOut]


class ListingOut(BaseModel):
    id: str
    title: str
    summary: str
    organization: str
    area: str | None
    event_start_at: datetime | None
    event_end_at: datetime | None
    eligibility: str | None
    source_name: str
    source_url: str
    registration_url: str | None
    last_checked_at: datetime
    listing_type: Literal["activity", "opportunity"]
    date_text: str | None = None
    availability_note: str
    verified: bool = False


class CommunitySourceOut(BaseModel):
    name: str
    url: str
    state: Literal["live", "cache", "unavailable"]
    checked_at: datetime | None
    error: str | None = None


class ListingList(BaseModel):
    items: list[ListingOut]
    no_results: bool
    message: str | None = None
    search_state: Literal["live", "cache", "unavailable"]
    checked_at: datetime | None
    requested_at: datetime
    sources: list[CommunitySourceOut]


def _require_consent(db: Session, owner_id: str) -> None:
    if not memory_consent_enabled(db, owner_id):
        raise HTTPException(status_code=403, detail="Memory consent is disabled")


def _active_memory(db: Session, owner_id: str, memory_id: str) -> PersonalMemory | None:
    return db.scalar(
        select(PersonalMemory).where(
            PersonalMemory.id == memory_id,
            PersonalMemory.owner_id == owner_id,
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
            PersonalMemory.kind.in_(("experience", "preference")),
        )
    )


def _suggestion(content: str) -> str | None:
    lowered = content.casefold()
    for terms, label in _SKILL_TERMS:
        if any(term.casefold() in lowered for term in terms):
            return label
    return None


def _fresh_cutoff() -> datetime:
    return datetime.now(timezone.utc) - timedelta(days=FRESHNESS_DAYS)


def _listing_out(row: CommunityListing) -> ListingOut:
    for value in (row.source_url, row.registration_url):
        if value is None:
            continue
        parsed = urlparse(value)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise HTTPException(status_code=503, detail="A community listing has an invalid source URL")
    checked = row.last_checked_at
    if checked.tzinfo is None:  # SQLite drops timezone metadata on round trips.
        checked = checked.replace(tzinfo=timezone.utc)
    return ListingOut(
        id=row.id,
        title=row.title,
        summary=row.summary,
        organization=row.organization,
        area=row.area,
        event_start_at=row.event_start_at,
        event_end_at=row.event_end_at,
        eligibility=row.eligibility,
        source_name=row.source_name,
        source_url=row.source_url,
        registration_url=row.registration_url,
        last_checked_at=checked,
        listing_type=row.listing_type,
        date_text=(row.event_start_at.isoformat() if row.event_start_at else None),
        availability_note="This listing is not a guarantee of current availability. Check the provider before attending.",
        verified=False,
    )


def _safe_to_show(row: CommunityListing) -> bool:
    if not (row.title.strip() and row.organization.strip() and row.source_name.strip()):
        return False
    for value in (row.source_url, row.registration_url):
        if value is None:
            continue
        parsed = urlparse(value)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            return False
    return True


@router.get("/activities", response_model=ListingList)
def browse_activities(
    request: Request,
    topic: str | None = Query(default=None, max_length=40),
    area: str | None = Query(default=None, max_length=50),
) -> ListingList:
    """Search allowlisted public activity providers and locally filter results."""
    allowed_topics = {"tailoring", "sewing", "cooking", "gardening", "teaching", "knitting", "woodworking", "health"}
    if topic is not None and topic.casefold() not in allowed_topics:
        raise HTTPException(status_code=422, detail=f"topic must be one of: {', '.join(sorted(allowed_topics))}")
    if area is not None and (not area.strip() or any(ord(char) < 32 for char in area)):
        raise HTTPException(status_code=422, detail="area must be a plain district name")
    result = request.app.state.community_search.search(listing_type="activity", topic=topic, area=area.strip() if area else None)
    return ListingList(**result)


@router.get("/skills/suggestions", response_model=SkillList)
def skill_suggestions(
    account: Account = Depends(require_elder), db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision"),
) -> SkillList:
    owner_id = account.id
    lock_owner_account(db, owner_id)
    require_memory_revision(db, owner_id, expected_revision)
    _require_consent(db, account.id)
    memories = db.scalars(
        select(PersonalMemory).where(
            PersonalMemory.owner_id == account.id,
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
            PersonalMemory.kind.in_(("experience", "preference")),
        )
    ).all()
    items: list[CommunitySkill] = []
    for memory in memories:
        # Automatic interest capture is not consent to publish a skill or
        # create an opportunity match. Skills continue to require an owner
        # curated memory before their separate review step.
        if memory_capture_method(db, memory) == "agent_auto":
            continue
        label = _suggestion(memory.content)
        if label is None:
            continue
        skill = db.scalar(
            select(CommunitySkill).where(
                CommunitySkill.owner_id == account.id,
                CommunitySkill.memory_id == memory.id,
            )
        )
        if skill is None:
            skill = CommunitySkill(owner_id=account.id, memory_id=memory.id, suggestion=label)
            db.add(skill)
            db.flush()
        if skill.status != "rejected":
            items.append(skill)
    revision = memory_revision(db, owner_id)
    output = SkillList(items=[
        SkillOut(
            id=x.id,
            memory_id=x.memory_id,
            suggestion=x.suggestion,
            status=x.status,
            reason="Suggested from a memory you chose to save or confirm. You decide whether it is accurate and whether to use it.",
            revision=revision,
        )
        for x in items
    ])
    db.commit()
    return output


@router.post("/skills/{skill_id}/decision", response_model=SkillOut)
def decide_skill(
    skill_id: str,
    payload: SkillDecision,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
    expected_revision: int | None = Header(default=None, alias="X-Memory-Revision"),
) -> SkillOut:
    owner_id = account.id
    lock_owner_account(db, owner_id)
    require_memory_revision(db, owner_id, expected_revision)
    _require_consent(db, account.id)
    skill = db.get(CommunitySkill, skill_id)
    if skill is None:
        raise HTTPException(status_code=404, detail="Skill suggestion not found")
    if skill.owner_id != account.id:
        raise HTTPException(status_code=403, detail="Skill suggestion is private to its owner")
    if _active_memory(db, account.id, skill.memory_id) is None:
        raise HTTPException(status_code=404, detail="Source memory is no longer available")
    if payload.decision == "edit" and payload.skill is None:
        raise HTTPException(status_code=422, detail="Edited skill text is required")
    if payload.decision == "confirm" and payload.skill is not None:
        raise HTTPException(status_code=422, detail="Use decision 'edit' to change the skill")
    if payload.decision == "reject":
        skill.status = "rejected"
    else:
        skill.suggestion = payload.skill if payload.decision == "edit" else skill.suggestion
        skill.status = "confirmed"
    skill.updated_at = datetime.now(timezone.utc)
    output = SkillOut(
        id=skill.id,
        memory_id=skill.memory_id,
        suggestion=skill.suggestion,
        status=skill.status,
        reason="Based on your confirmed memory; no profile or message was shared.",
        revision=memory_revision(db, owner_id),
    )
    db.commit()
    return output


@router.get("/opportunities", response_model=ListingList)
def skill_opportunities(
    request: Request,
    skill_id: str = Query(min_length=1),
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> ListingList:
    _require_consent(db, account.id)
    skill = db.get(CommunitySkill, skill_id)
    if skill is None:
        raise HTTPException(status_code=404, detail="Skill not found")
    if skill.owner_id != account.id:
        raise HTTPException(status_code=403, detail="Skill is private to its owner")
    if skill.status != "confirmed":
        raise HTTPException(status_code=409, detail="Skill must be confirmed before matching")
    if _active_memory(db, account.id, skill.memory_id) is None:
        raise HTTPException(status_code=404, detail="Source memory is no longer available")
    skill_topic = next((
        topic for terms, topic in _SKILL_TERMS
        if any(term.casefold() in skill.suggestion.casefold() for term in terms)
    ), skill.suggestion)
    # Only a closed generic topic is used for local result filtering. Neither
    # memory content nor the user's edited free text is sent to providers.
    result = request.app.state.community_search.search(listing_type="opportunity", topic=skill_topic)
    # The provider call can take a few seconds; ensure consent and the source
    # skill still exist before returning personalized matches.
    db.rollback()
    _require_consent(db, account.id)
    refreshed = db.get(CommunitySkill, skill_id)
    if refreshed is None or refreshed.owner_id != account.id or refreshed.status != "confirmed":
        raise HTTPException(status_code=409, detail="Confirmed skill changed while searching")
    if _active_memory(db, account.id, refreshed.memory_id) is None:
        raise HTTPException(status_code=409, detail="Source memory changed while searching")
    return ListingList(**result)
