"""Family consent guards and permanent, transaction-local withdrawal."""
from datetime import datetime, timezone
from sqlalchemy import select
from .collaboration_models import FamilyMessage
from .task_share_service import begin_guard, revoke_shares

def begin_family_guard(db, elder_id):
    begin_guard(db, {elder_id})

def withdraw_family_access(db, link, reason):
    """No commit: callers atomically change consent and its dependent records."""
    revoke_shares(db, link_id=link.id, reason=reason)
    now = datetime.now(timezone.utc)
    for message in db.scalars(select(FamilyMessage).where(
            FamilyMessage.link_id == link.id,
            FamilyMessage.access_revoked_at.is_(None)).with_for_update()).all():
        message.access_revoked_at = now
        message.access_revocation_reason = reason
    from .answer_card_share_service import withdraw_answer_card_shares
    withdraw_answer_card_shares(db, link_id=link.id, reason=reason)
    link.authorization_epoch += 1


def pair_is_blocked(db, elder_id, caregiver_id):
    from .family_connection_models import FamilyBlock
    block = db.get(FamilyBlock, (elder_id, caregiver_id))
    return bool(block and block.active)


def approve_request(db, request, scopes):
    from fastapi import HTTPException
    from .models import FamilyLink
    link = db.scalar(select(FamilyLink).where(FamilyLink.elder_id == request.elder_id,
        FamilyLink.caregiver_id == request.caregiver_id).with_for_update())
    if link and link.status == "active":
        raise HTTPException(409, "A connection already exists")
    if not link:
        link = FamilyLink(elder_id=request.elder_id, caregiver_id=request.caregiver_id, scopes=list(scopes))
        db.add(link)
    else:
        withdraw_family_access(db, link, "family_link_reconnected")
        link.status = "active"
        link.scopes = list(scopes)
        link.revoked_at = None
    db.flush()
    return link


def set_pair_block(db, elder_id, caregiver_id, caregiver_email):
    from .family_connection_models import FamilyBlock, FamilyConnectionRequest
    from .models import FamilyInvitation, FamilyLink
    block = db.get(FamilyBlock, (elder_id, caregiver_id))
    if not block:
        block = FamilyBlock(elder_id=elder_id, caregiver_id=caregiver_id, version=1, active=True)
        db.add(block)
    elif not block.active:
        block.active = True
        block.version += 1
        block.blocked_at = datetime.now(timezone.utc)
    now = datetime.now(timezone.utc)
    requests = db.scalars(select(FamilyConnectionRequest).where(
        FamilyConnectionRequest.elder_id == elder_id,
        FamilyConnectionRequest.caregiver_id == caregiver_id,
        FamilyConnectionRequest.status == "pending").order_by(FamilyConnectionRequest.id).with_for_update()).all()
    for request in requests:
        request.status = "rejected"
        request.version += 1
        request.decided_at = now
    invitations = db.scalars(select(FamilyInvitation).where(FamilyInvitation.elder_id == elder_id,
        FamilyInvitation.email == caregiver_email, FamilyInvitation.status == "pending")
        .order_by(FamilyInvitation.id).with_for_update()).all()
    for invitation in invitations:
        invitation.status = "revoked"
        invitation.revoked_at = now
    link = db.scalar(select(FamilyLink).where(FamilyLink.elder_id == elder_id,
        FamilyLink.caregiver_id == caregiver_id).with_for_update())
    if link and link.status != "revoked":
        withdraw_family_access(db, link, "family_pair_blocked")
        link.status = "revoked"
        link.revoked_at = now
    return block


def clear_pair_block(db, block):
    if block.active:
        # Repair inconsistent legacy/direct-writer state before removing the
        # block gate: unblocking must never reveal pre-block consent again.
        from .models import FamilyLink
        link = db.scalar(select(FamilyLink).where(FamilyLink.elder_id == block.elder_id,
            FamilyLink.caregiver_id == block.caregiver_id).with_for_update())
        if link and link.status != "revoked":
            withdraw_family_access(db, link, "family_unblock_old_authorization")
            link.status = "revoked"
            link.revoked_at = link.revoked_at or datetime.now(timezone.utc)
        block.active = False
        block.version += 1
