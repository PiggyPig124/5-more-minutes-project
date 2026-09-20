"""Explicit, idempotent messaging over a currently authorized family link."""
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import and_, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..collaboration_models import FamilyMessage
from ..db import get_db
from ..dependencies import get_current_account
from ..models import Account, FamilyLink

router = APIRouter(prefix="/family-messages", tags=["family-messages"])


class SendFamilyMessage(BaseModel):
    recipient_id: str = Field(min_length=1, max_length=36)
    content: str = Field(min_length=1, max_length=10000)
    client_message_id: str = Field(min_length=1, max_length=200)
    source_story_id: str | None = Field(default=None, max_length=36)

    @field_validator("content")
    @classmethod
    def trim(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("message cannot be blank")
        return value.strip()


class FamilyMessageOut(BaseModel):
    id: str
    sender_id: str
    recipient_id: str
    sender_name: str
    recipient_name: str
    content: str
    source_story_id: str | None
    created_at: datetime


def message_out(db: Session, message: FamilyMessage) -> FamilyMessageOut:
    sender, recipient = db.get(Account, message.sender_id), db.get(Account, message.recipient_id)
    return FamilyMessageOut(
        id=message.id, sender_id=message.sender_id, recipient_id=message.recipient_id,
        sender_name=sender.display_name, recipient_name=recipient.display_name,
        content=message.content, source_story_id=message.source_story_id, created_at=message.created_at,
    )


@router.get("", response_model=list[FamilyMessageOut])
def list_messages(account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    links = db.scalars(select(FamilyLink).where(
        or_(FamilyLink.elder_id == account.id, FamilyLink.caregiver_id == account.id),
        FamilyLink.status == "active",
    )).all()
    ids = [link.id for link in links if "family_messages" in (link.scopes or [])]
    if not ids:
        return []
    rows = db.scalars(select(FamilyMessage).where(
        FamilyMessage.link_id.in_(ids),
        or_(FamilyMessage.sender_id == account.id, FamilyMessage.recipient_id == account.id),
    ).order_by(FamilyMessage.created_at.desc()).limit(200)).all()
    return [message_out(db, row) for row in rows]


@router.post("", response_model=FamilyMessageOut, status_code=201)
def send_message(payload: SendFamilyMessage, account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    sender_id = account.id
    db.rollback()
    if db.bind.dialect.name == "sqlite":
        db.connection().exec_driver_sql("BEGIN IMMEDIATE")
    elif payload.source_story_id:
        db.scalar(select(Account).where(Account.id == sender_id).with_for_update())
    link = db.scalar(select(FamilyLink).where(or_(
        and_(FamilyLink.elder_id == sender_id, FamilyLink.caregiver_id == payload.recipient_id),
        and_(FamilyLink.caregiver_id == sender_id, FamilyLink.elder_id == payload.recipient_id),
    )).with_for_update())
    if not link or link.status != "active" or "family_messages" not in (link.scopes or []):
        raise HTTPException(403, "目前沒有向此家人傳送訊息的授權。")
    previous = db.scalar(select(FamilyMessage).where(
        FamilyMessage.sender_id == sender_id, FamilyMessage.client_message_id == payload.client_message_id,
    ))
    if previous:
        if (previous.content, previous.recipient_id, previous.source_story_id) != (payload.content, payload.recipient_id, payload.source_story_id):
            raise HTTPException(409, "此重試編號已用於另一則訊息。")
        return message_out(db, previous)
    if payload.source_story_id:
        # Import here so the story module can reuse the collaboration model for
        # deletion propagation without a module-level import cycle.
        from ..memory_models import Story
        story = db.get(Story, payload.source_story_id)
        if story is None or story.owner_id != sender_id:
            raise HTTPException(404, "找不到你的故事。")
        if payload.content != f"{story.title}\n{story.content}".strip():
            raise HTTPException(409, "故事已更新，請重新預覽後傳送。")
    message = FamilyMessage(link_id=link.id, sender_id=sender_id, **payload.model_dump())
    db.add(message)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "此重試編號已被使用，請重新核對收件人與內容。")
    return message_out(db, message)
