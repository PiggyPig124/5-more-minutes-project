"""Owner-only safety assistance; support messages always require explicit confirmation."""

from __future__ import annotations

import hashlib
import json

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..collaboration_models import FamilyMessage
from ..db import get_db
from ..dependencies import require_elder
from ..models import Account, FamilyLink
from ..safety_models import EmergencyContact, SafetyEvent
from ..schemas import (
    EmergencyContactCreate,
    EmergencyContactOut,
    SafetyEventOut,
    SafetySupportRequest,
    SafetySupportRequestOut,
)

router = APIRouter(prefix="/safety", tags=["safety"])


def _lock_owner(db: Session, owner_id: str) -> None:
    # Discard the auth read transaction before taking a fresh writer snapshot.
    db.rollback()
    if db.bind.dialect.name == "sqlite":
        db.connection().exec_driver_sql("BEGIN IMMEDIATE")
    else:
        db.scalar(select(Account).where(Account.id == owner_id).with_for_update())


def _emergency_contact_out(contact: EmergencyContact, caregiver_name: str = "") -> EmergencyContactOut:
    return EmergencyContactOut(
        id=contact.id,
        elder_id=contact.elder_id,
        family_link_id=contact.family_link_id,
        caregiver_id=contact.caregiver_id,
        caregiver_name=caregiver_name,
        label=contact.label,
        is_enabled=contact.is_enabled,
        created_at=contact.created_at,
    )


def _safety_event_out(event: SafetyEvent) -> SafetyEventOut:
    return SafetyEventOut(
        id=event.id,
        elder_id=event.elder_id,
        conversation_id=event.conversation_id,
        trigger_message_id=event.trigger_message_id,
        intervention_mode=event.intervention_mode,
        support_request_sent=event.support_request_sent,
        resolved_at=event.resolved_at,
        notes=event.notes,
        created_at=event.created_at,
    )


@router.get("/emergency-contacts", response_model=list[EmergencyContactOut])
def list_emergency_contacts(
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> list[EmergencyContactOut]:
    contacts = db.scalars(
        select(EmergencyContact).where(EmergencyContact.elder_id == account.id).order_by(EmergencyContact.created_at)
    ).all()
    result = []
    for contact in contacts:
        caregiver = db.get(Account, contact.caregiver_id)
        result.append(_emergency_contact_out(contact, caregiver.display_name if caregiver else ""))
    return result


@router.post("/emergency-contacts", response_model=EmergencyContactOut, status_code=status.HTTP_201_CREATED)
def add_emergency_contact(
    payload: EmergencyContactCreate,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> EmergencyContactOut:
    owner_id = account.id
    _lock_owner(db, owner_id)
    link = db.scalar(select(FamilyLink).where(FamilyLink.id == payload.family_link_id).with_for_update())
    from ..family_connection_service import pair_is_blocked
    if link and pair_is_blocked(db, link.elder_id, link.caregiver_id):
        raise HTTPException(403, "Connection unavailable")
    if link is None or link.elder_id != owner_id or link.status != "active":
        raise HTTPException(404, "Family link not found or not active")
    if "family_messages" not in (link.scopes or []):
        raise HTTPException(403, "This family link does not have family_messages scope.")
    existing = db.scalar(select(EmergencyContact).where(
        EmergencyContact.elder_id == owner_id,
        EmergencyContact.family_link_id == payload.family_link_id,
    ))
    if existing is not None:
        raise HTTPException(409, "This family link is already an emergency contact")
    contact = EmergencyContact(
        elder_id=owner_id,
        family_link_id=link.id,
        caregiver_id=link.caregiver_id,
        label=payload.label.strip(),
        is_enabled=True,
    )
    db.add(contact)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "This family link is already an emergency contact") from None
    caregiver = db.get(Account, contact.caregiver_id)
    return _emergency_contact_out(contact, caregiver.display_name if caregiver else "")


@router.delete("/emergency-contacts/{contact_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_emergency_contact(
    contact_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
):
    owner_id = account.id
    _lock_owner(db, owner_id)
    contact = db.scalar(select(EmergencyContact).where(EmergencyContact.id == contact_id).with_for_update())
    if contact is None or contact.elder_id != owner_id:
        raise HTTPException(404, "Emergency contact not found")
    db.delete(contact)
    db.commit()


@router.get("/events", response_model=list[SafetyEventOut])
def list_safety_events(
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> list[SafetyEventOut]:
    events = db.scalars(
        select(SafetyEvent).where(SafetyEvent.elder_id == account.id).order_by(SafetyEvent.created_at.desc())
    ).all()
    return [_safety_event_out(event) for event in events]


@router.post("/support-request", response_model=SafetySupportRequestOut)
def send_support_request(
    payload: SafetySupportRequest,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> SafetySupportRequestOut:
    owner_id = account.id
    _lock_owner(db, owner_id)
    contact = db.get(EmergencyContact, payload.emergency_contact_id)
    if contact is None or contact.elder_id != owner_id:
        raise HTTPException(404, "Emergency contact not found")
    # Same link lock used by revocation; keep it through the send commit.
    link = db.scalar(select(FamilyLink).where(FamilyLink.id == contact.family_link_id).with_for_update())
    contact = db.scalar(select(EmergencyContact).where(EmergencyContact.id == contact.id)
                        .with_for_update().execution_options(populate_existing=True))
    from ..family_connection_service import pair_is_blocked
    if link and pair_is_blocked(db, link.elder_id, link.caregiver_id):
        raise HTTPException(403, "Connection unavailable")
    if not contact.is_enabled:
        raise HTTPException(403, "This emergency contact is disabled")
    if (link is None or link.status != "active" or link.elder_id != owner_id
            or link.caregiver_id != contact.caregiver_id or "family_messages" not in (link.scopes or [])):
        raise HTTPException(403, "The family link is no longer active or lacks family_messages scope.")

    if payload.family_link_id != link.id or payload.expected_authorization_epoch != link.authorization_epoch:
        raise HTTPException(410, "Preview authorization has ended; review a new share")

    # Preserve event/contact binding without putting private event IDs or text
    # in recipient-visible message content. Lookup uses only the stable key;
    # the owner lock serializes even retries aimed at different family links.
    key_prefix = "safety:" + hashlib.sha256(payload.idempotency_key.encode()).hexdigest() + ":"
    binding = hashlib.sha256(json.dumps(
        [contact.id, payload.safety_event_id], separators=(",", ":")
    ).encode()).hexdigest()
    client_message_id = key_prefix + binding
    existing = db.scalar(select(FamilyMessage).where(
        FamilyMessage.sender_id == owner_id,
        FamilyMessage.client_message_id.startswith(key_prefix),
    ))
    if existing is not None and (
        existing.client_message_id != client_message_id
        or existing.content != payload.message
        or existing.recipient_id != contact.caregiver_id
        or existing.link_id != link.id
        or existing.source_story_id is not None
    ):
        raise HTTPException(409, "This idempotency key was used for a different content, recipient, or event.")

    event = None
    if payload.safety_event_id is not None:
        event = db.scalar(select(SafetyEvent).where(
            SafetyEvent.id == payload.safety_event_id, SafetyEvent.elder_id == owner_id,
        ).with_for_update())
        if event is None:
            raise HTTPException(404, "Safety event not found")
    if existing is not None:
        if existing.access_revoked_at is not None or existing.link_epoch != link.authorization_epoch:
            raise HTTPException(410, "Previous sharing authorization has ended")
        return SafetySupportRequestOut(
            sent=True, family_message_id=existing.id,
            emergency_contact_id=contact.id, message=existing.content,
        )
    message = FamilyMessage(
        link_epoch=link.authorization_epoch,
        link_id=link.id,
        sender_id=owner_id,
        recipient_id=contact.caregiver_id,
        content=payload.message,
        client_message_id=client_message_id,
    )
    db.add(message)
    if event is not None:
        event.support_request_sent = True
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "This idempotency key has already been used; review the request.") from None
    return SafetySupportRequestOut(
        sent=True, family_message_id=message.id,
        emergency_contact_id=contact.id, message=message.content,
    )
