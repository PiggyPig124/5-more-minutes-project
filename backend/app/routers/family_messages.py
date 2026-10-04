"""Explicit messages authorized against the current family consent epoch."""
from datetime import datetime
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import and_, or_, select
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session
from ..collaboration_models import FamilyMessage
from ..db import get_db
from ..dependencies import get_current_account
from ..models import Account, FamilyLink
from ..family_connection_service import begin_family_guard, pair_is_blocked
from ..memory_service import require_memory_revision

router = APIRouter(prefix="/family-messages", tags=["family-messages"])

class SendFamilyMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")
    recipient_id: str = Field(min_length=1, max_length=36)
    family_link_id: str = Field(min_length=1, max_length=36)
    expected_authorization_epoch: int = Field(strict=True, ge=1)
    content: str = Field(min_length=1, max_length=10000)
    client_message_id: str = Field(min_length=1, max_length=200)
    source_story_id: str | None = Field(default=None, max_length=36)
    @field_validator("content")
    @classmethod
    def trim(cls, value):
        if not value.strip():
            raise ValueError("message cannot be blank")
        return value.strip()

class SentFamilyMessageOut(BaseModel):
    id: str
    sender_id: str
    recipient_id: str
    content: str
    source_story_id: str | None
    created_at: datetime
    link_epoch: int
    access_revoked_at: datetime | None
    access_revocation_reason: str | None

class FamilyMessageOut(SentFamilyMessageOut):
    sender_name: str
    recipient_name: str

def message_out(db, message):
    sender, recipient = db.get(Account, message.sender_id), db.get(Account, message.recipient_id)
    return FamilyMessageOut(**SentFamilyMessageOut.model_validate(message, from_attributes=True).model_dump(),
        sender_name=sender.display_name, recipient_name=recipient.display_name)

def schema_unavailable(db):
    db.rollback()
    raise HTTPException(503, "Family sharing is temporarily unavailable")

@router.get("/sent", response_model=list[SentFamilyMessageOut])
def list_sent(account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    try:
        rows = db.scalars(select(FamilyMessage).where(FamilyMessage.sender_id == account.id)
            .order_by(FamilyMessage.created_at.desc()).limit(200)).all()
        return [SentFamilyMessageOut.model_validate(row, from_attributes=True) for row in rows]
    except SQLAlchemyError:
        schema_unavailable(db)

@router.get("", response_model=list[FamilyMessageOut])
def list_messages(account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    try:
        links = db.scalars(select(FamilyLink).where(
            or_(FamilyLink.elder_id == account.id, FamilyLink.caregiver_id == account.id),
            FamilyLink.status == "active")).all()
        epochs = {link.id: link.authorization_epoch for link in links
            if "family_messages" in (link.scopes or []) and not pair_is_blocked(db, link.elder_id, link.caregiver_id)}
        # Execute even with an empty authorization set: a missing schema must
        # report unavailable rather than imply that a private query succeeded.
        rows = db.scalars(select(FamilyMessage).where(FamilyMessage.link_id.in_(epochs),
            FamilyMessage.access_revoked_at.is_(None),
            or_(FamilyMessage.sender_id == account.id, FamilyMessage.recipient_id == account.id))
            .order_by(FamilyMessage.created_at.desc()).limit(200)).all()
        return [message_out(db, row) for row in rows if row.link_epoch == epochs[row.link_id]]
    except SQLAlchemyError:
        schema_unavailable(db)

def pair_query(sender, recipient):
    return select(FamilyLink).where(or_(
        and_(FamilyLink.elder_id == sender, FamilyLink.caregiver_id == recipient),
        and_(FamilyLink.caregiver_id == sender, FamilyLink.elder_id == recipient)))

@router.post("", response_model=FamilyMessageOut, status_code=201)
def send_message(payload: SendFamilyMessage, account: Account = Depends(get_current_account),
    db: Session = Depends(get_db), expected_revision: int | None = Header(default=None, alias="X-Memory-Revision")):
    sender_id = account.id
    try:
        candidate = db.scalar(pair_query(sender_id, payload.recipient_id))
        if not candidate:
            raise HTTPException(403, "Connection unavailable")
        begin_family_guard(db, candidate.elder_id)
        link = db.scalar(pair_query(sender_id, payload.recipient_id).with_for_update())
        if (not link or link.status != "active" or "family_messages" not in (link.scopes or [])
                or pair_is_blocked(db, link.elder_id, link.caregiver_id)):
            raise HTTPException(403, "Connection unavailable")
        # Check the preview binding while holding the same owner/link guard.
        # A first delivery cannot adopt consent granted after its preview.
        if payload.family_link_id != link.id or payload.expected_authorization_epoch != link.authorization_epoch:
            raise HTTPException(410, "Preview authorization has ended; review a new share")
        if payload.source_story_id:
            require_memory_revision(db, sender_id, expected_revision)
        previous = db.scalar(select(FamilyMessage).where(FamilyMessage.sender_id == sender_id,
            FamilyMessage.client_message_id == payload.client_message_id))
        if previous:
            if (previous.content, previous.recipient_id, previous.source_story_id) != (payload.content, payload.recipient_id, payload.source_story_id):
                raise HTTPException(409, "Retry key belongs to different content")
            if previous.access_revoked_at is not None or previous.link_epoch != link.authorization_epoch or previous.link_id != link.id:
                raise HTTPException(410, "Previous sharing authorization has ended")
            return message_out(db, previous)
        if payload.source_story_id:
            require_memory_revision(db, sender_id, expected_revision)
            from ..memory_models import Story
            story = db.get(Story, payload.source_story_id)
            if story is None or story.owner_id != sender_id:
                raise HTTPException(404, "Story not found")
            if payload.content != f"{story.title}\n{story.content}".strip():
                raise HTTPException(409, "Story changed; review the current content")
        message = FamilyMessage(link_id=link.id, link_epoch=link.authorization_epoch,
            sender_id=sender_id, **payload.model_dump(exclude={"family_link_id", "expected_authorization_epoch"}))
        db.add(message)
        db.commit()
        return message_out(db, message)
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "Retry key already used")
    except SQLAlchemyError:
        schema_unavailable(db)
