"""Private cards, explicit one-recipient snapshots and owner export preview."""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..answer_card_private_service import (CardCreate, CardDelete, CardPrepare, CardUpdate,
    available_templates, create_answer_card, delete_answer_card, get_answer_card, list_answer_cards,
    prepare_answer_card, update_answer_card)
from ..db import get_db
from ..dependencies import get_current_account
from ..models import Account
from ..answer_card_schemas import (CardShareCreate, CardShareRevoke, CardShareOut,
    CardSentOut, CardShareReceipt, CardExportRequest, CardExportOut)
from ..answer_card_share_service import (share_answer_card, list_answer_card_inbox,
    list_answer_card_sent, revoke_answer_card_share, get_export_preview)

router = APIRouter(tags=['answer-cards'])


@router.get('/answer-card-templates')
def list_templates():
    return available_templates()


@router.post('/answer-cards/prepare')
def prepare(payload: CardPrepare, account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    return prepare_answer_card(db, account.id, payload.source_message_id)


@router.post('/answer-cards', status_code=201)
def create(payload: CardCreate, account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    result = create_answer_card(db, account.id, payload)
    db.commit()
    return result


@router.get('/answer-cards')
def list_owned(account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    return list_answer_cards(db, account.id)


@router.get('/answer-cards/{card_id}')
def get_owned(card_id: str, account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    return get_answer_card(db, account.id, card_id)


@router.patch('/answer-cards/{card_id}')
def update(card_id: str, payload: CardUpdate, account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    result = update_answer_card(db, account.id, card_id, payload)
    db.commit()
    return result


@router.delete('/answer-cards/{card_id}')
def delete(card_id: str, payload: CardDelete, account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    result = delete_answer_card(db, account.id, card_id, payload)
    db.commit()
    return result


@router.post('/answer-cards/{card_id}/export-preview', response_model=CardExportOut)
def export_preview(card_id: str, payload: CardExportRequest,
                   account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    return get_export_preview(db, account.id, card_id, payload)


@router.post('/answer-cards/{card_id}/shares', response_model=CardShareOut, status_code=201)
def share(card_id: str, payload: CardShareCreate,
          account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    result = share_answer_card(db, account.id, card_id, payload)
    db.commit()
    return result


@router.get('/answer-card-shares/inbox', response_model=list[CardShareOut])
def inbox(account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    return list_answer_card_inbox(db, account.id)


@router.get('/answer-card-shares/sent', response_model=list[CardSentOut])
def sent(account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    return list_answer_card_sent(db, account.id)


@router.post('/answer-card-shares/{share_id}/revoke', response_model=CardShareReceipt)
def revoke(share_id: str, payload: CardShareRevoke,
           account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    result = revoke_answer_card_share(db, account.id, share_id)
    db.commit()
    return result
