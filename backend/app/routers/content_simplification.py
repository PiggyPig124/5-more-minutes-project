"""Selected-text display drafts only; never a conversation or memory write."""
from dataclasses import asdict
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator
from sqlalchemy.orm import Session

from ..content_simplification import ContentSimplificationService
from ..db import get_db
from ..dependencies import get_current_account
from ..models import Account
from .guest import _session

router = APIRouter(tags=['content-simplification'])


class SimplificationRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    text: str = Field(min_length=1, max_length=10000)
    locale: Literal['en', 'zh-Hant'] = 'zh-Hant'
    explicit_request: StrictBool

    @field_validator('text')
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError('selected text cannot be blank')
        return value  # Preserve the complete original, including spacing.

    @field_validator('explicit_request')
    @classmethod
    def explicit_only(cls, value):
        if value is not True:
            raise ValueError('an explicit request is required')
        return value


class SimplificationResponse(BaseModel):
    status: Literal['draft', 'unavailable']
    original: str
    simpler: str | None
    reason: str | None
    independently_verified: Literal[False]


async def _draft(request, payload):
    result = await ContentSimplificationService(request.app.state.settings).simplify(
        payload.text, explicitly_requested=payload.explicit_request, locale=payload.locale)
    return asdict(result)


@router.post('/content/simplifications', response_model=SimplificationResponse)
async def simplify_signed(payload: SimplificationRequest, request: Request,
        account: Account = Depends(get_current_account), db: Session = Depends(get_db)):
    owner_id = account.id
    # Authentication is a read. Release that transaction before awaiting a model.
    db.rollback()
    result = await _draft(request, payload)
    current = db.get(Account, owner_id, populate_existing=True)
    if current is None or not current.is_active:
        raise HTTPException(status_code=401, detail='Account is unavailable')
    return result


@router.post('/guest/sessions/{session_id}/simplifications', response_model=SimplificationResponse)
async def simplify_guest(session_id: str, payload: SimplificationRequest, request: Request):
    active = _session(request, session_id)
    result = await _draft(request, payload)
    if _session(request, session_id) is not active:
        raise HTTPException(status_code=404, detail='Guest session no longer active')
    return result
