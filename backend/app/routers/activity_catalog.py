"""Community discovery and contribution routes.

Browse verified activities by district, interest, or mobility preference.
Receive recommendations derived from confirmed memories (skills/hobbies).
Express interest in an activity.  No booking or registration is performed;
the app provides guidance and official links only.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..activity_catalog_models import CommunityActivity, CommunityInterest
from ..db import get_db
from ..dependencies import get_current_account, require_elder
from ..models import Account
from ..memory_consent import memory_consent_enabled
from ..community_models import CommunitySkill

router = APIRouter(prefix="/community/catalog", tags=["community"])


def _activity_out(activity: CommunityActivity) -> dict:
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
    query = query.order_by(CommunityActivity.start_date.desc()).limit(limit * 2)
    rows = db.scalars(query).all()
    # Filter by interest and mobility in Python for SQLite compatibility.
    if interest:
        interest_lower = interest.lower()
        rows = [
            r for r in rows
            if any(interest_lower in (t or "").lower() for t in (r.interest_tags or []))
        ]
    if mobility:
        mobility_lower = mobility.lower()
        rows = [
            r for r in rows
            if r.mobility_note and mobility_lower in r.mobility_note.lower()
        ]
    rows = rows[:limit]
    return {"activities": [_activity_out(r) for r in rows], "count": len(rows)}


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
    if row is None or (not row.verified and not request.app.state.settings.demo_mode):
        raise HTTPException(status_code=404, detail="Activity not found")
    return _activity_out(row)


@router.get("/recommendations")
def get_recommendations(
    request: Request,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> dict:
    """Recommend activities based on the elder's confirmed memories.

    Searches confirmed personal memories for skills, hobbies, or interests
    and matches them against activity skill_tags and interest_tags.  Falls
    back to general activities if no memory-derived interests are found.
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

    # Extract potential skills/interests from memory content.
    # Preferences may personalize interests; a skill requires its own explicit
    # confirmation, matching the primary community workflow.
    memory_text = " ".join(m.content for m in memories if m.kind == "preference").lower()
    active_ids = {m.id for m in memories}
    skills = db.scalars(select(CommunitySkill).where(
        CommunitySkill.owner_id == account.id, CommunitySkill.status == "confirmed")).all() if active_ids else []
    skill_text = " ".join(s.suggestion for s in skills if s.memory_id in active_ids).lower()

    query = select(CommunityActivity)
    if not request.app.state.settings.demo_mode:
        query = query.where(CommunityActivity.verified.is_(True))
    all_activities = db.scalars(query).all()

    scored: list[tuple[CommunityActivity, float]] = []
    for activity in all_activities:
        score = 0.0
        for tag in (activity.skill_tags or []):
            if tag.lower() in skill_text:
                score += 10.0
        for tag in (activity.interest_tags or []):
            if tag.lower() in memory_text:
                score += 8.0
        if score > 0:
            scored.append((activity, score))

    if not scored:
        # Fallback: return a few general activities.
        scored = [(a, 0.0) for a in all_activities[:6]]

    scored.sort(key=lambda pair: -pair[1])
    return {
        "recommendations": [_activity_out(a) for a, _ in scored[:10]],
        "memory_matches": len(memories),
        "basis": "memory" if memories else "general",
    }


@router.post("/interest/{activity_id}", status_code=status.HTTP_201_CREATED)
def express_interest(
    activity_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> dict:
    """Express interest in a community activity."""
    activity = db.get(CommunityActivity, activity_id)
    if activity is None:
        raise HTTPException(status_code=404, detail="Activity not found")
    existing = db.scalar(
        select(CommunityInterest).where(
            CommunityInterest.elder_id == account.id,
            CommunityInterest.activity_id == activity_id,
        )
    )
    if existing:
        return {"status": existing.status, "already_expressed": True}
    interest = CommunityInterest(
        elder_id=account.id,
        activity_id=activity_id,
        status="interested",
    )
    db.add(interest)
    db.commit()
    return {"status": "interested", "already_expressed": False}


@router.get("/interests")
def list_interests(
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
            entry = _activity_out(activity)
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
    """Withdraw interest in a community activity."""
    interest = db.scalar(
        select(CommunityInterest).where(
            CommunityInterest.elder_id == account.id,
            CommunityInterest.activity_id == activity_id,
        )
    )
    if interest is None:
        raise HTTPException(status_code=404, detail="No interest found for this activity")
    db.delete(interest)
    db.commit()
    return {"status": "withdrawn"}
