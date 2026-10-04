"""Community discovery and contribution routes.

Browse verified activities by district, interest, or mobility preference.
Receive general suggestions or exact, independently confirmed skill matches.
Express interest in an activity.  No booking or registration is performed;
the app provides guidance and official links only.
"""

from __future__ import annotations

from datetime import date, datetime
from heapq import heappush, heapreplace
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select, delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..activity_catalog_models import CommunityActivity, CommunityInterest
from ..db import get_db
from ..dependencies import get_current_account, require_elder
from ..models import Account
from ..memory_consent import memory_consent_enabled
from ..community_models import CommunitySkill
from ..task_share_service import begin_guard

router = APIRouter(prefix="/community/catalog", tags=["community"])


def _availability(activity: CommunityActivity, demo_mode: bool) -> tuple[bool, str]:
    """Apply one availability policy to discovery, details and local interests."""
    try:
        start = date.fromisoformat(activity.start_date) if activity.start_date else None
        end = date.fromisoformat(activity.end_date) if activity.end_date else None
    except (TypeError, ValueError):
        return False, "invalid_date"
    if start and end and end < start:
        return False, "invalid_date"
    if end and end < datetime.now(ZoneInfo("Asia/Hong_Kong")).date():
        return False, "expired"
    if not activity.verified:
        return demo_mode, "unverified"
    if start is None or end is None:
        return True, "date_unknown"
    return True, "current"


def _activity_out(activity: CommunityActivity, demo_mode: bool) -> dict:
    available, availability_status = _availability(activity, demo_mode)
    return {
        "id": activity.id,
        "title": activity.title,
        "description": activity.description,
        "organizer": activity.organizer,
        "district": activity.district,
        "address": activity.address,
        "url": activity.url,
        "start_date": activity.start_date,
        "end_date": activity.end_date,
        "schedule_note": activity.schedule_note,
        "mobility_note": activity.mobility_note,
        "interest_tags": list(activity.interest_tags or []),
        "skill_tags": list(activity.skill_tags or []),
        "contribution_type": activity.contribution_type,
        "verified": activity.verified,
        "verified_at": activity.verified_at,
        "available": available,
        "availability_status": availability_status,
    }


@router.get("/activities")
def list_activities(
    request: Request,
    district: str | None = Query(default=None),
    interest: str | None = Query(default=None),
    mobility: str | None = Query(default=None),
    contribution_type: str | None = Query(default=None),
    limit: int = Query(default=20, ge=1, le=100),
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> dict:
    """Browse verified community activities with optional filters."""
    del account
    query = select(CommunityActivity)
    if not request.app.state.settings.demo_mode:
        query = query.where(CommunityActivity.verified.is_(True))
    if district:
        from sqlalchemy import func
        query = query.where(func.replace(CommunityActivity.district, '區', '') == district.replace('區', ''))
    if contribution_type:
        query = query.where(CommunityActivity.contribution_type == contribution_type)
    query = query.order_by(CommunityActivity.start_date.desc(), CommunityActivity.id.asc())
    interest_lower = (interest or "").lower()
    mobility_lower = (mobility or "").lower()
    rows = []
    result = db.scalars(query.execution_options(yield_per=100))
    try:
        for row in result:
            if not _availability(row, request.app.state.settings.demo_mode)[0]:
                continue
            if interest_lower and not any(
                interest_lower in (tag or "").lower() for tag in (row.interest_tags or [])
            ):
                continue
            if mobility_lower and mobility_lower not in (row.mobility_note or "").lower():
                continue
            rows.append(_activity_out(row, request.app.state.settings.demo_mode))
            if len(rows) == limit:
                break
    finally:
        result.close()
    return {"activities": rows, "count": len(rows)}


@router.get("/activities/{activity_id}")
def get_activity(
    activity_id: str,
    request: Request,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> dict:
    """Get details of a single community activity."""
    del account
    row = db.get(CommunityActivity, activity_id)
    if row is None or not _availability(row, request.app.state.settings.demo_mode)[0]:
        raise HTTPException(status_code=404, detail="Activity not found")
    return _activity_out(row, request.app.state.settings.demo_mode)


@router.get("/recommendations")
def get_recommendations(
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> dict:
    """Explain exact matches to independently confirmed closed skill evidence.

    Return explicitly general suggestions when no eligible source matches.
    """
    # Import here to avoid circular dependency at module load time.
    from ..memory_models import PersonalMemory

    memories = db.scalars(
        select(PersonalMemory).where(
            PersonalMemory.owner_id == account.id,
            PersonalMemory.status == "confirmed",
            PersonalMemory.suppressed.is_(False),
            PersonalMemory.superseded_by.is_(None),
            PersonalMemory.deleted_at.is_(None),
        )
    ).all() if memory_consent_enabled(db, account.id) else []

    from ..catalog_evidence import eligible_skill_topic, protocol_topic
    sources = {memory.id: memory for memory in memories}
    # No field currently expresses preference polarity. Unparsed preferences
    # could conflict even with a confirmed capability; fail closed for now.
    unresolved_preferences = any(memory.kind == "preference" for memory in memories)
    active_ids = {memory.id for memory in memories}
    skills = db.scalars(select(CommunitySkill).where(
        CommunitySkill.owner_id == account.id,
        CommunitySkill.status == "confirmed",
        CommunitySkill.memory_id.in_(active_ids),
    )).all() if active_ids else []

    eligible = [(skill, eligible_skill_topic(skill, sources.get(skill.memory_id)))
                for skill in skills] if not unresolved_preferences else []
    # An unparsed confirmed skill could contradict a closed capability.
    # Absence of parsed evidence is not evidence of absence of conflict.
    if any(topic is None for _, topic in eligible):
        eligible = []
    query = select(CommunityActivity)
    if not request.app.state.settings.demo_mode:
        query = query.where(CommunityActivity.verified.is_(True))
    query = query.order_by(CommunityActivity.start_date.desc(), CommunityActivity.id.asc())
    # Keep only the best ten matches and six fallback cards while scanning in
    # bounded batches. A later high-scoring match must still beat early cards.
    best: list[tuple[float, int, dict]] = []
    fallback = []
    result = db.scalars(query.execution_options(yield_per=100))
    try:
        for index, activity in enumerate(result):
            if not _availability(activity, request.app.state.settings.demo_mode)[0]:
                continue
            if len(fallback) < 6:
                entry = _activity_out(activity, request.app.state.settings.demo_mode)
                entry["recommendation_basis"] = "general"
                entry["recommendation_reasons"] = []
                fallback.append(entry)
            if not eligible:
                if len(fallback) == 6:
                    break
                continue
            reasons = []
            score = 0.0
            for tag in activity.skill_tags or []:
                matches = [skill for skill, topic in eligible if protocol_topic(tag) == topic]
                if matches:
                    score += 10.0
                    reasons.extend({"memory_id": skill.memory_id, "source_type": "skill",
                                    "source_text": skill.suggestion, "matched_tag": tag}
                                   for skill in matches)
            if reasons:
                entry = _activity_out(activity, request.app.state.settings.demo_mode)
                entry["recommendation_basis"] = "memory"
                entry["recommendation_reasons"] = reasons
                candidate = (score, -index, entry)
                if len(best) < 10:
                    heappush(best, candidate)
                elif candidate[:2] > best[0][:2]:
                    heapreplace(best, candidate)
    finally:
        result.close()
    recommendations = [item[2] for item in sorted(best, key=lambda item: (-item[0], -item[1]))] if best else fallback
    matched_ids = {reason["memory_id"] for entry in recommendations
                   for reason in entry["recommendation_reasons"]}
    return {
        "recommendations": recommendations,
        "memory_matches": len(matched_ids),
        "basis": "memory" if matched_ids else "general",
    }


@router.post("/interest/{activity_id}", status_code=status.HTTP_201_CREATED)
def express_interest(
    activity_id: str,
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> dict:
    """Express interest in a community activity."""
    owner_id = account.id
    begin_guard(db, {owner_id})
    activity = db.get(CommunityActivity, activity_id)
    if activity is None or (not activity.verified and not request.app.state.settings.demo_mode):
        raise HTTPException(status_code=404, detail="Activity not found")
    available, availability_status = _availability(activity, request.app.state.settings.demo_mode)
    if not available:
        raise HTTPException(status_code=409, detail=f"Activity unavailable: {availability_status}")
    existing = db.scalar(
        select(CommunityInterest).where(
            CommunityInterest.elder_id == owner_id,
            CommunityInterest.activity_id == activity_id,
        )
    )
    if existing:
        return {"status": existing.status, "already_expressed": True}
    interest = CommunityInterest(
        elder_id=owner_id,
        activity_id=activity_id,
        status="interested",
    )
    db.add(interest)
    try:
        db.commit()
    except IntegrityError as error:
        db.rollback()
        dialect = db.bind.dialect.name
        pair_conflict = (
            dialect == "sqlite" and
            "UNIQUE constraint failed: community_interests.elder_id, community_interests.activity_id" in str(error.orig)
        ) or (
            dialect == "postgresql" and
            getattr(getattr(error.orig, "diag", None), "constraint_name", None) == "uq_community_interest_pair"
        )
        if not pair_conflict:
            raise
        existing = db.scalar(select(CommunityInterest).where(
            CommunityInterest.elder_id == owner_id,
            CommunityInterest.activity_id == activity_id,
        ))
        if existing is None:
            raise
        return {"status": existing.status, "already_expressed": True}
    return {"status": "interested", "already_expressed": False}


@router.get("/interests")
def list_interests(
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> dict:
    """List activities the elder has expressed interest in."""
    rows = db.scalars(
        select(CommunityInterest).where(CommunityInterest.elder_id == account.id)
    ).all()
    result = []
    for interest in rows:
        activity = db.get(CommunityActivity, interest.activity_id)
        if activity:
            entry = _activity_out(activity, request.app.state.settings.demo_mode)
            entry["interest_status"] = interest.status
            entry["interest_created_at"] = interest.created_at.isoformat() if interest.created_at else None
            result.append(entry)
    return {"interests": result, "count": len(result)}


@router.delete("/interest/{activity_id}", status_code=status.HTTP_200_OK)
def withdraw_interest(
    activity_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> dict:
    """Withdraw all records for this owner's selected activity, including legacy duplicates."""
    owner_id = account.id
    begin_guard(db, {owner_id})
    interest = db.scalar(
        select(CommunityInterest).where(
            CommunityInterest.elder_id == owner_id,
            CommunityInterest.activity_id == activity_id,
        )
    )
    if interest is None:
        raise HTTPException(status_code=404, detail="No interest found for this activity")
    db.execute(delete(CommunityInterest).where(
        CommunityInterest.elder_id == owner_id,
        CommunityInterest.activity_id == activity_id,
    ))
    db.commit()
    return {"status": "withdrawn"}
