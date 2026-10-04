"""Single-card family consent and owner export; helpers never commit."""
from __future__ import annotations

import copy

from fastapi import HTTPException
from sqlalchemy import inspect, select
from sqlalchemy.orm import Session

from . import answer_card_service as public
from .answer_card_models import AnswerCard, AnswerCardShare
from .answer_card_private_service import owner_guard, _owned, _validated, _utc
from .answer_card_schemas import CardShareCreate, CardExportRequest
from .family_connection_service import pair_is_blocked
from .models import Account, FamilyLink, utc_now
from .task_share_service import begin_guard


def require_share_schema(db: Session, *, family=False) -> None:
    inspector = inspect(db.connection())
    models = (AnswerCardShare, FamilyLink) if family else (AnswerCardShare,)
    for model in models:
        if not inspector.has_table(model.__tablename__):
            raise HTTPException(503, 'Answer card sharing schema is unavailable')
        columns = {c['name'] for c in inspector.get_columns(model.__tablename__)}
        if not set(model.__table__.columns.keys()).issubset(columns):
            raise HTTPException(503, 'Answer card sharing schema is unavailable')


def withdraw_answer_card_shares(db: Session, *, card_id=None, link_id=None,
                               reason: str, scrub_payload=False) -> int:
    """Exact-filter withdrawal inside the caller's existing owner transaction."""
    if card_id is None and link_id is None:
        raise ValueError('Answer card withdrawal requires an exact card or link filter')
    require_share_schema(db)
    query = select(AnswerCardShare)
    if card_id is not None:
        query = query.where(AnswerCardShare.card_id == card_id)
    if link_id is not None:
        query = query.where(AnswerCardShare.link_id == link_id)
    changed = 0
    for share in db.scalars(query.order_by(AnswerCardShare.id).with_for_update()).all():
        updated = False
        if share.access_revoked_at is None:
            share.access_revoked_at = utc_now()
            share.access_revocation_reason = reason
            updated = True
        if scrub_payload and share.public_payload:
            share.public_payload = {}
            updated = True
        changed += int(updated)
    db.flush()
    return changed


def _ack(card: AnswerCard, payload: dict, acknowledged: bool) -> None:
    if (card.mode == 'assistant_answer' or payload['verification_state'] != 'reviewed_public_guidance') and not acknowledged:
        raise HTTPException(422, 'Review the selected personal information before continuing')


def _share_out(share: AnswerCardShare, *, sent=False) -> dict:
    payload = _validated(share.public_payload, stored=True) if share.public_payload else None
    if payload is not None and public.payload_hash(payload) != share.payload_hash:
        raise HTTPException(503, 'Stored answer card share is unavailable')
    if not sent and payload is None:
        raise HTTPException(410, 'Answer card share is no longer available')
    result = {'id': share.id, 'mode': share.mode, 'card_version': share.card_version,
        'sender_id': share.sender_id, 'recipient_id': share.recipient_id,
        'link_id': share.link_id, 'link_epoch': share.link_epoch,
        'public_payload': copy.deepcopy(payload), 'public_payload_hash': share.payload_hash,
        'created_at': _utc(share.created_at)}
    if sent:
        result.update(card_id=share.card_id, access_revoked_at=_utc(share.access_revoked_at) if share.access_revoked_at else None,
                      access_revocation_reason=share.access_revocation_reason)
    return result


def _live(db: Session, share: AnswerCardShare, link: FamilyLink | None, card: AnswerCard | None) -> bool:
    if share.access_revoked_at is not None or card is None or link is None:
        return False
    sender = db.get(Account, share.sender_id)
    recipient = db.get(Account, share.recipient_id)
    if not (sender and sender.is_active and sender.role == 'elder'
        and recipient and recipient.is_active and recipient.role == 'caregiver'
        and card.deleted_at is None and card.owner_id == share.sender_id
        and card.version == share.card_version and card.mode == share.mode
        and link.elder_id == share.sender_id and link.caregiver_id == share.recipient_id
        and link.id == share.link_id and link.authorization_epoch == share.link_epoch
        and link.status == 'active' and isinstance(link.scopes, list) and 'family_messages' in link.scopes
        and not pair_is_blocked(db, share.sender_id, share.recipient_id)):
        return False
    return public.payload_hash(_validated(card.public_payload, stored=True)) == share.payload_hash


def share_answer_card(db: Session, sender_id: str, card_id: str, payload: CardShareCreate) -> dict:
    owner_guard(db, sender_id)
    require_share_schema(db, family=True)
    # Read ownership only before family lock. Card row lock follows the link.
    if db.scalar(select(AnswerCard.owner_id).where(AnswerCard.id == card_id)) != sender_id:
        raise HTTPException(404, 'Answer card not found')
    if db.get(Account, sender_id).role != 'elder':
        raise HTTPException(403, 'Only an elder can share an owned answer card')
    link = db.scalar(select(FamilyLink).where(FamilyLink.elder_id == sender_id,
        FamilyLink.caregiver_id == payload.recipient_id).with_for_update())
    card = _owned(db, sender_id, card_id, include_deleted=True)
    digest = public.payload_hash({'card_id': card_id, **payload.model_dump()})
    previous = db.scalar(select(AnswerCardShare).where(AnswerCardShare.sender_id == sender_id,
        AnswerCardShare.client_share_id == payload.client_share_id).with_for_update())
    if previous is not None:
        if previous.request_hash != digest:
            raise HTTPException(409, 'Share key is associated with a different request')
        if not _live(db, previous, link, card):
            raise HTTPException(410, 'Answer card share authorization is no longer available')
        return _share_out(previous)
    if card.deleted_at is not None:
        raise HTTPException(404, 'Answer card not found')
    if link is None:
        raise HTTPException(403, 'Family authorization is unavailable')
    if link.id != payload.expected_link_id or link.authorization_epoch != payload.expected_link_epoch:
        raise HTTPException(409, 'Family authorization changed; open a fresh preview')
    recipient = db.get(Account, payload.recipient_id)
    if not (recipient and recipient.is_active and recipient.role == 'caregiver'
        and link.status == 'active' and isinstance(link.scopes, list) and 'family_messages' in link.scopes
        and not pair_is_blocked(db, sender_id, payload.recipient_id)):
        raise HTTPException(403, 'Family authorization is unavailable')
    current = _validated(card.public_payload, stored=True)
    digest_payload = public.payload_hash(current)
    if card.version != payload.expected_version or digest_payload != payload.previewed_payload_hash:
        raise HTTPException(409, 'Answer card changed; open a fresh preview')
    _ack(card, current, payload.personal_review_ack)
    share = AnswerCardShare(card_id=card.id, card_version=card.version, mode=card.mode,
        sender_id=sender_id, recipient_id=payload.recipient_id, link_id=link.id,
        link_epoch=link.authorization_epoch, client_share_id=payload.client_share_id,
        request_hash=digest, payload_hash=digest_payload, public_payload=copy.deepcopy(current))
    db.add(share)
    db.flush()
    return _share_out(share)


def list_answer_card_inbox(db: Session, recipient_id: str) -> list[dict]:
    require_share_schema(db, family=True)
    owners = {recipient_id} | set(db.scalars(select(AnswerCardShare.sender_id).where(
        AnswerCardShare.recipient_id == recipient_id)).all())
    begin_guard(db, owners)
    db.expire_all()
    require_share_schema(db, family=True)
    account = db.get(Account, recipient_id)
    if not account or not account.is_active:
        raise HTTPException(401, 'Account is unavailable')
    if account.role != 'caregiver':
        return []
    result = []
    shares = db.scalars(select(AnswerCardShare).where(AnswerCardShare.recipient_id == recipient_id,
        AnswerCardShare.access_revoked_at.is_(None)).order_by(AnswerCardShare.created_at.desc(), AnswerCardShare.id)).all()
    for share in shares:
        if share.sender_id not in owners:
            continue  # Newly connected owner is included on the next guarded read.
        link = db.scalar(select(FamilyLink).where(FamilyLink.id == share.link_id).with_for_update())
        card = db.scalar(select(AnswerCard).where(AnswerCard.id == share.card_id).with_for_update())
        if _live(db, share, link, card):
            result.append(_share_out(share))
    return result


def list_answer_card_sent(db: Session, sender_id: str) -> list[dict]:
    owner_guard(db, sender_id)
    require_share_schema(db)
    return [_share_out(s, sent=True) for s in db.scalars(select(AnswerCardShare).where(
        AnswerCardShare.sender_id == sender_id).order_by(AnswerCardShare.created_at.desc(), AnswerCardShare.id)).all()]


def revoke_answer_card_share(db: Session, sender_id: str, share_id: str) -> dict:
    owner_guard(db, sender_id)
    require_share_schema(db, family=True)
    candidate = db.scalar(select(AnswerCardShare).where(AnswerCardShare.id == share_id,
        AnswerCardShare.sender_id == sender_id))
    if candidate is None:
        raise HTTPException(404, 'Answer card share not found')
    db.scalar(select(FamilyLink).where(FamilyLink.id == candidate.link_id).with_for_update())
    db.scalar(select(AnswerCard).where(AnswerCard.id == candidate.card_id).with_for_update())
    share = db.scalar(select(AnswerCardShare).where(AnswerCardShare.id == share_id,
        AnswerCardShare.sender_id == sender_id).with_for_update())
    if share.access_revoked_at is None:
        share.access_revoked_at = utc_now()
        share.access_revocation_reason = 'sender_revoked'
        db.flush()
    return {'id': share.id, 'revoked': True}


def get_export_preview(db: Session, owner_id: str, card_id: str, payload: CardExportRequest) -> dict:
    owner_guard(db, owner_id)
    card = _owned(db, owner_id, card_id)
    current = _validated(card.public_payload, stored=True)
    digest = public.payload_hash(current)
    if card.version != payload.expected_version or digest != payload.previewed_payload_hash:
        raise HTTPException(409, 'Answer card changed; open a fresh preview')
    _ack(card, current, payload.personal_review_ack)
    return {'card_version': card.version, 'public_payload': current, 'public_payload_hash': digest}
