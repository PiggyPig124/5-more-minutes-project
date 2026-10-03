"""Account-owned care inbox; family revocation is checked on every access."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..care_models import CareNotification
from ..care_service import collect_notifications, visible
from ..db import get_db
from ..dependencies import get_current_account
from ..models import Account, Message

router = APIRouter(prefix='/notifications', tags=['care'])


class NotificationPatch(BaseModel):
    status: Literal['acknowledged', 'handled']


def output(item: CareNotification, db: Session) -> dict:
    result = {key: getattr(item, key) for key in ('id', 'kind', 'body', 'status', 'created_at')}
    if item.kind == 'check_in':
        message = db.get(Message, item.source_id)
        if message:
            result['body'] = message.content
    return result


@router.get('')
def list_notifications(account: Account = Depends(get_current_account), db: Session = Depends(get_db)) -> dict:
    collect_notifications(db, account)
    rows = db.scalars(select(CareNotification).where(CareNotification.owner_id == account.id)
                      .order_by(CareNotification.created_at.desc()).limit(100)).all()
    return {'notifications': [output(row, db) for row in rows if visible(db, row)]}


@router.patch('/{notification_id}')
def update_notification(notification_id: str, payload: NotificationPatch,
                        account: Account = Depends(get_current_account), db: Session = Depends(get_db)) -> dict:
    row = db.get(CareNotification, notification_id)
    if not row or row.owner_id != account.id or not visible(db, row):
        raise HTTPException(404, 'Notification not found')
    row.status = payload.status
    db.commit()
    return output(row, db)
