"""Scam-safety guidance routes.

Provides post-interaction scam guidance, clear verification actions
(pause, protect, verify), and verified anti-scam contacts.  All guidance
is sourced from official Hong Kong authorities with provenance.  The app
never auto-notifies family; optional family support requires explicit elder
confirmation.
"""

from __future__ import annotations

import hashlib
import json

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session
from pydantic import BaseModel, Field

from ..db import get_db
from ..dependencies import require_elder
from ..models import Account, Conversation
from ..scam_models import ScamLog, ScamResource
from ..scam_contacts import CONTACT_APPROVAL_PATH, approved_contacts

router = APIRouter(prefix="/scam", tags=["scam-safety"])


class ScamLogCreate(BaseModel):
    scam_type: str = Field(default='general', max_length=80)
    guidance_summary: str = Field(default='', max_length=5000)
    scam_resource_id: str | None = Field(default=None, max_length=80)
    conversation_id: str | None = Field(default=None, max_length=36)


def _resource_out(resource: ScamResource) -> dict:
    return {
        "id": resource.id,
        "title": resource.title,
        "excerpt": resource.excerpt,
        "source_url": resource.source_url,
        "verified_at": resource.verified_at,
        "scam_type": resource.scam_type,
        "warning_signs": list(resource.warning_signs or []),
        "verification_steps": list(resource.verification_steps or []),
        "next_steps": list(resource.next_steps or []),
        "official_contacts": list(resource.official_contacts or []),
        "source_authority": resource.source_authority,
    }


@router.get("/resources")
def list_scam_resources(
    scam_type: str | None = Query(default=None),
    limit: int = Query(default=10, ge=1, le=50),
    db: Session = Depends(get_db),
) -> dict:
    """Browse verified anti-scam guidance resources."""
    query = select(ScamResource)
    if scam_type:
        query = query.where(ScamResource.scam_type == scam_type)
    query = query.limit(limit)
    rows = db.scalars(query).all()
    return {"resources": [_resource_out(r) for r in rows], "count": len(rows)}


@router.get("/resources/search")
def search_scam_resources(
    query: str = Query(min_length=1, max_length=500),
    limit: int = Query(default=5, ge=1, le=20),
    db: Session = Depends(get_db),
) -> dict:
    """Search anti-scam resources by keyword."""
    q_lower = query.strip().lower()
    rows = db.scalars(select(ScamResource)).all()
    scored = []
    for row in rows:
        text = " ".join([
            row.title, row.excerpt, row.scam_type,
            " ".join(row.warning_signs or []),
            " ".join(row.verification_steps or []),
            " ".join(row.next_steps or []),
            " ".join(row.official_contacts or []),
            " ".join(row.search_terms or []),
            row.source_authority,
        ]).lower()
        score = 0.0
        for term in q_lower.split():
            if term in text:
                score += 1.0
        if q_lower in text:
            score += 5.0
        if score > 0:
            scored.append((row, score))
    scored.sort(key=lambda pair: -pair[1])
    return {
        "query": query.strip(),
        "results": [_resource_out(r) for r, _ in scored[:limit]],
        "count": min(len(scored), limit),
    }


@router.get("/resources/{resource_id}")
def get_scam_resource(
    resource_id: str,
    db: Session = Depends(get_db),
) -> dict:
    """Get a single anti-scam guidance resource."""
    row = db.get(ScamResource, resource_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Scam resource not found")
    return _resource_out(row)


@router.post("/log", status_code=status.HTTP_201_CREATED)
def log_scam_guidance(
    payload: ScamLogCreate,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> dict:
    """Record that scam-safety guidance was provided in a conversation.

    The elder can review their scam-safety history.  No automatic family
    notification is performed; optional family support requires a separate
    explicit confirmation.
    """
    scam_type = payload.scam_type
    guidance_summary = payload.guidance_summary
    scam_resource_id = payload.scam_resource_id
    conversation_id = payload.conversation_id
    if conversation_id:
        conversation = db.get(Conversation, conversation_id)
        if not conversation or conversation.owner_id != account.id:
            raise HTTPException(404, 'Conversation not found')
    if scam_resource_id and not db.get(ScamResource, scam_resource_id):
        raise HTTPException(404, 'Scam resource not found')

    log = ScamLog(
        elder_id=account.id,
        conversation_id=conversation_id,
        scam_resource_id=scam_resource_id,
        scam_type=scam_type,
        guidance_summary=guidance_summary,
        family_notified=False,
    )
    db.add(log)
    db.commit()
    return {"id": log.id, "status": "logged", "family_notified": False}


@router.get("/log")
def list_scam_logs(
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> dict:
    """List the elder's scam-safety guidance history."""
    rows = db.scalars(
        select(ScamLog).where(ScamLog.elder_id == account.id).order_by(ScamLog.created_at.desc())
    ).all()
    return {
        "logs": [
            {
                "id": log.id,
                "scam_type": log.scam_type,
                "guidance_summary": log.guidance_summary,
                "family_notified": log.family_notified,
                "created_at": log.created_at.isoformat() if log.created_at else None,
            }
            for log in rows
        ],
        "count": len(rows),
    }


@router.get("/verify-actions")
def get_verify_actions(
    db: Session = Depends(get_db),
) -> dict:
    """Return the public FR SCM 02 pause, protect, verify protocol."""
    del db
    return {
        "actions": [
            {
                "step": 1,
                "action": "pause",
                "title": "暫停",
                "title_en": "Pause",
                "description": "先暫停，不要在催促或壓力下行動。",
                "description_en": "Pause. Do not act under pressure or urgency.",
                "icon": "pause",
            },
            {
                "step": 2,
                "action": "protect",
                "title": "保護金錢和資料",
                "title_en": "Protect money and information",
                "description": "不要轉帳，也不要提供密碼或個人資料。",
                "description_en": "Do not transfer money or provide passwords or personal information.",
                "icon": "shield",
            },
            {
                "step": 3,
                "action": "verify",
                "title": "獨立核實",
                "title_en": "Verify independently",
                "description": "透過獨立取得的官方渠道或信任的人核實；不要只用可疑來電或訊息提供的聯絡方式。",
                "description_en": "Verify through an independently obtained official channel or a trusted person, rather than only using contact details in the suspicious call or message.",
                "icon": "search",
            },
        ]
    }


@router.get("/contacts")
def get_verified_contacts(db: Session = Depends(get_db)) -> dict:
    """SCM03: current approvals bound to exact public database source entries."""
    return {"contacts": approved_contacts(db, CONTACT_APPROVAL_PATH)}
