"""FastAPI dependencies and authorization helpers."""

from __future__ import annotations

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from .db import get_db
from .models import Account, Conversation, FamilyLink
from .security import decode_access_token

bearer_scheme = HTTPBearer(auto_error=False)


def get_current_account(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: Session = Depends(get_db),
) -> Account:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Bearer authentication is required")
    payload = decode_access_token(credentials.credentials, request.app.state.settings.auth_secret)
    if payload is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired access token")
    account = db.get(Account, str(payload["sub"]))
    if account is None or not account.is_active:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Account is unavailable")
    return account


def require_elder(account: Account = Depends(get_current_account)) -> Account:
    if account.role != "elder":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only elder accounts can perform this action")
    return account


def get_owned_conversation(db: Session, account: Account, conversation_id: str) -> Conversation:
    conversation = db.get(Conversation, conversation_id)
    if conversation is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Conversation not found")
    if conversation.owner_id != account.id:
        # Do not disclose a caregiver's access to a private conversation.
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Private conversations are not shared")
    return conversation


def active_care_link(db: Session, caregiver_id: str, elder_id: str) -> FamilyLink | None:
    links = db.scalars(
        select(FamilyLink).where(
            FamilyLink.caregiver_id == caregiver_id,
            FamilyLink.elder_id == elder_id,
            FamilyLink.status == "active",
        )
    ).all()
    return next((link for link in links if "care_tasks" in (link.scopes or [])), None)


def linked_elder_ids(db: Session, caregiver_id: str) -> set[str]:
    links = db.scalars(
        select(FamilyLink).where(
            FamilyLink.caregiver_id == caregiver_id,
            FamilyLink.status == "active",
        )
    ).all()
    return {link.elder_id for link in links if "care_tasks" in (link.scopes or [])}
