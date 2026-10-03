"""Scam-safety guidance routes.

Provides post-interaction scam guidance, clear verification actions
(verify, pause, protect), and verified anti-scam contacts.  All guidance
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
from ..dependencies import get_current_account, require_elder
from ..models import Account, Conversation
from ..scam_models import ScamLog, ScamResource

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
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> dict:
    """Browse verified anti-scam guidance resources."""
    del account
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
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> dict:
    """Search anti-scam resources by keyword."""
    del account
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
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> dict:
    """Get a single anti-scam guidance resource."""
    del account
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
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> dict:
    """Return the standard three-step scam verification protocol.

    FR SCM 02: The elder is always offered the same three clear actions:
    1. Verify - check the contact/request against official sources
    2. Pause - take time before responding; never act under pressure
    3. Protect - contact verified anti-scam channels or family
    """
    del account, db
    return {
        "actions": [
            {
                "step": 1,
                "action": "verify",
                "title": "核實",
                "title_en": "Verify",
                "description": "查官方資料或致電官方熱線，核實對方的身份和要求是否真確。",
                "description_en": "Check official sources or call official hotlines to verify the caller's identity and request.",
                "icon": "search",
            },
            {
                "step": 2,
                "action": "pause",
                "title": "暫停",
                "title_en": "Pause",
                "description": "不要急於回應。騙徒通常會製造緊迫感，令你倉促決定。",
                "description_en": "Do not rush to respond. Scammers create urgency to force hasty decisions.",
                "icon": "pause",
            },
            {
                "step": 3,
                "action": "protect",
                "title": "保護",
                "title_en": "Protect",
                "description": "聯絡已核實的反詐騙渠道或信任的家人，尋求協助。",
                "description_en": "Contact verified anti-scam channels or a trusted family member for help.",
                "icon": "shield",
            },
        ]
    }


@router.get("/contacts")
def get_verified_contacts(
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> dict:
    """Return verified official anti-scam contacts for Hong Kong.

    FR SCM 03: Only verified, official contacts are displayed.  The app does
    not duplicate caller ID functionality or claim to identify unknown
    numbers.
    """
    del account, db
    return {
        "contacts": [
            {
                "name": "香港警務處反詐騙協調中心",
                "name_en": "Hong Kong Police Anti-Deception Coordination Centre",
                "phone": "18222",
                "url": "https://www.police.gov.hk",
                "description": "24小時反詐騙熱線，可查詢可疑電話或訊息是否騙局。",
                "description_en": "24-hour anti-deception hotline for checking suspicious calls or messages.",
            },
            {
                "name": "消費者委員會",
                "name_en": "Consumer Council",
                "phone": "2929 2222",
                "url": "https://www.consumer.org.hk",
                "description": "消費投訴及預防消費騙局查詢。",
                "description_en": "Consumer complaints and scam prevention enquiries.",
            },
            {
                "name": "香港金融管理局",
                "name_en": "Hong Kong Monetary Authority",
                "phone": "2878 8222",
                "url": "https://www.hkma.gov.hk",
                "description": "金融騙局、偽鈔及銀行帳戶安全查詢。",
                "description_en": "Financial scam, counterfeit, and bank account safety enquiries.",
            },
        ]
    }
