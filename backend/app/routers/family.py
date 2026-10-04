from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..db import get_db
from ..dependencies import get_current_account, require_elder
from ..models import Account, FamilyInvitation, FamilyLink
from ..task_share_service import begin_guard, revoke_shares
from ..family_connection_service import withdraw_family_access, pair_is_blocked
from ..schemas import (
    AccountPublic,
    FamilyInvitationAccept,
    FamilyInvitationCreate,
    FamilyInvitationOut,
    FamilyLinkOut,
)

router = APIRouter(prefix="/family-links", tags=["family-links"])
INVITATION_DAYS = 7


def _digest(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def _invitation_out(invitation: FamilyInvitation, token: str | None = None) -> FamilyInvitationOut:
    return FamilyInvitationOut(
        id=invitation.id,
        elder_id=invitation.elder_id,
        email=invitation.email,
        scopes=list(invitation.scopes or []),
        status=invitation.status,
        expires_at=_as_utc(invitation.expires_at),
        created_at=_as_utc(invitation.created_at),
        accepted_at=_as_utc(invitation.accepted_at) if invitation.accepted_at else None,
        token=token,
    )


def _link_out(db: Session, link: FamilyLink) -> FamilyLinkOut:
    elder = db.get(Account, link.elder_id)
    caregiver = db.get(Account, link.caregiver_id)
    return FamilyLinkOut(
        authorization_epoch=link.authorization_epoch,
        id=link.id,
        elder_id=link.elder_id,
        caregiver_id=link.caregiver_id,
        scopes=list(link.scopes or []),
        status=link.status,
        created_at=_as_utc(link.created_at),
        revoked_at=_as_utc(link.revoked_at) if link.revoked_at else None,
        elder=AccountPublic.model_validate(elder) if elder else None,
        caregiver=AccountPublic.model_validate(caregiver) if caregiver else None,
    )


@router.post("/invitations", response_model=FamilyInvitationOut, status_code=status.HTTP_201_CREATED)
def create_invitation(
    payload: FamilyInvitationCreate,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> FamilyInvitationOut:
    account_id = account.id
    begin_guard(db, {account_id})
    account = db.get(Account, account_id)
    caregiver = db.scalar(select(Account).where(Account.email == payload.email))
    if caregiver and pair_is_blocked(db, account_id, caregiver.id):
        raise HTTPException(403, 'Connection unavailable')
    if caregiver is not None and caregiver.id == account.id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="An elder cannot invite their own account")
    raw_token = secrets.token_urlsafe(32)
    invitation = FamilyInvitation(
        elder_id=account.id,
        email=payload.email,
        token_digest=_digest(raw_token),
        scopes=list(payload.scopes),
        expires_at=datetime.now(timezone.utc) + timedelta(days=INVITATION_DAYS),
    )
    db.add(invitation)
    db.commit()
    return _invitation_out(invitation, raw_token)


@router.get("/invitations", response_model=list[FamilyInvitationOut])
def list_invitations(account: Account = Depends(get_current_account), db: Session = Depends(get_db)) -> list[FamilyInvitationOut]:
    if account.role == "elder":
        invitations = db.scalars(
            select(FamilyInvitation).where(FamilyInvitation.elder_id == account.id).order_by(FamilyInvitation.created_at.desc())
        ).all()
    else:
        invitations = db.scalars(
            select(FamilyInvitation).where(FamilyInvitation.email == account.email).order_by(FamilyInvitation.created_at.desc())
        ).all()
    now = datetime.now(timezone.utc)
    changed = False
    for invitation in invitations:
        if invitation.status == "pending" and _as_utc(invitation.expires_at) <= now:
            invitation.status = "expired"
            changed = True
    if changed:
        db.commit()
    return [_invitation_out(invitation) for invitation in invitations]


def _accept_invitation(
    invitation_id: str,
    payload: FamilyInvitationAccept,
    account: Account,
    db: Session,
) -> FamilyLinkOut:
    account_id = account.id
    invitation = db.get(FamilyInvitation, invitation_id)
    owner_id = invitation.elder_id if invitation else account_id
    begin_guard(db, {owner_id})
    account = db.get(Account, account_id)
    if account.role != "caregiver":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only caregiver accounts can accept invitations")
    invitation = db.get(FamilyInvitation, invitation_id)
    if invitation is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Invitation not found")
    if not secrets.compare_digest(invitation.token_digest, _digest(payload.token)):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid invitation token")
    if invitation.email != account.email:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This invitation belongs to another email")
    if pair_is_blocked(db, invitation.elder_id, account.id):
        raise HTTPException(403, 'Connection unavailable')
    if invitation.status == "revoked":
        raise HTTPException(status_code=status.HTTP_410_GONE, detail="Invitation has been revoked")
    if invitation.status == "expired" or _as_utc(invitation.expires_at) <= datetime.now(timezone.utc):
        invitation.status = "expired"
        db.commit()
        raise HTTPException(status_code=status.HTTP_410_GONE, detail="Invitation has expired")
    if invitation.status == "accepted":
        link = db.get(FamilyLink, invitation.accepted_link_id) if invitation.accepted_link_id else None
        if (link and link.status == "active" and link.elder_id == invitation.elder_id
                and link.caregiver_id == account.id and invitation.accepted_by == account.id
                and invitation.accepted_epoch == link.authorization_epoch):
            return _link_out(db, link)
        raise HTTPException(410, "Invitation authorization is no longer available")
    if invitation.status != "pending":
        raise HTTPException(410, "Invitation is no longer available")

    link = db.scalar(
        select(FamilyLink).where(
            FamilyLink.elder_id == invitation.elder_id,
            FamilyLink.caregiver_id == account.id,
        )
    )
    if link is None:
        link = FamilyLink(elder_id=invitation.elder_id, caregiver_id=account.id, scopes=list(invitation.scopes), status="active")
        db.add(link)
    else:
        if link.status != "active" or set(link.scopes or []) != set(invitation.scopes or []):
            withdraw_family_access(db, link, "family_link_changed")
        link.status = "active"
        link.scopes = list(invitation.scopes)
        link.revoked_at = None
    db.flush()
    invitation.accepted_link_id = link.id
    invitation.accepted_epoch = link.authorization_epoch
    invitation.status = "accepted"
    invitation.accepted_by = account.id
    invitation.accepted_at = datetime.now(timezone.utc)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Invitation could not be accepted")
    return _link_out(db, link)


@router.post("/invitations/accept", response_model=FamilyLinkOut, status_code=status.HTTP_201_CREATED)
def accept_invitation_by_token(
    payload: FamilyInvitationAccept,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> FamilyLinkOut:
    """Accept an invitation when the client has only the emailed token.

    The token is never stored in plaintext. We narrow the lookup to the
    authenticated caregiver's email, then compare digests in constant time.
    """

    if account.role != "caregiver":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only caregiver accounts can accept invitations")
    invitations = db.scalars(select(FamilyInvitation).where(FamilyInvitation.email == account.email)).all()
    invitation = next(
        (candidate for candidate in invitations if secrets.compare_digest(candidate.token_digest, _digest(payload.token))),
        None,
    )
    if invitation is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid invitation token")
    return _accept_invitation(invitation.id, payload, account, db)


@router.post("/invitations/{invitation_id}/accept", response_model=FamilyLinkOut, status_code=status.HTTP_201_CREATED)
def accept_invitation(
    invitation_id: str,
    payload: FamilyInvitationAccept,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> FamilyLinkOut:
    return _accept_invitation(invitation_id, payload, account, db)


# A short alias is kept for clients that model the invitation as a family-link
# resource. It uses the same token and authorization rules.
@router.post("/{invitation_id}/accept", response_model=FamilyLinkOut, status_code=status.HTTP_201_CREATED)
def accept_invitation_alias(
    invitation_id: str,
    payload: FamilyInvitationAccept,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
) -> FamilyLinkOut:
    return _accept_invitation(invitation_id, payload, account, db)


@router.get("", response_model=list[FamilyLinkOut])
def list_links(account: Account = Depends(get_current_account), db: Session = Depends(get_db)) -> list[FamilyLinkOut]:
    if account.role == "elder":
        links = db.scalars(
            select(FamilyLink).where(FamilyLink.elder_id == account.id).order_by(FamilyLink.created_at.desc())
        ).all()
    else:
        links = db.scalars(
            select(FamilyLink).where(FamilyLink.caregiver_id == account.id).order_by(FamilyLink.created_at.desc())
        ).all()
    return [_link_out(db, link) for link in links]


def _revoke_link(link_id: str, account: Account, db: Session) -> FamilyLinkOut:
    account_id = account.id
    candidate = db.get(FamilyLink, link_id)
    owner_id = candidate.elder_id if candidate else account_id
    begin_guard(db, {owner_id})
    link = db.scalar(select(FamilyLink).where(FamilyLink.id == link_id).with_for_update())
    if link is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Family link not found")
    if account_id not in {link.elder_id, link.caregiver_id}:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You cannot revoke this family link")
    if link.status != "revoked":
        withdraw_family_access(db, link, "family_link_revoked")
        link.status = "revoked"
        link.revoked_at = datetime.now(timezone.utc)
    db.commit()
    return _link_out(db, link)


@router.delete("/{link_id}", response_model=FamilyLinkOut)
def revoke_link(link_id: str, account: Account = Depends(get_current_account), db: Session = Depends(get_db)) -> FamilyLinkOut:
    return _revoke_link(link_id, account, db)


@router.post("/{link_id}/revoke", response_model=FamilyLinkOut)
def revoke_link_action(link_id: str, account: Account = Depends(get_current_account), db: Session = Depends(get_db)) -> FamilyLinkOut:
    return _revoke_link(link_id, account, db)


@router.post("/invitations/{invitation_id}/revoke", response_model=FamilyInvitationOut)
def revoke_invitation(
    invitation_id: str,
    account: Account = Depends(require_elder),
    db: Session = Depends(get_db),
) -> FamilyInvitationOut:
    invitation = db.get(FamilyInvitation, invitation_id)
    if invitation is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Invitation not found")
    if invitation.elder_id != account.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You cannot revoke this invitation")
    if invitation.status == "pending":
        invitation.status = "revoked"
        invitation.revoked_at = datetime.now(timezone.utc)
        db.commit()
    return _invitation_out(invitation)
