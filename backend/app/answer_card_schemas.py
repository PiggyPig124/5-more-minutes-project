"""Closed sharing/export contracts; owner provenance never enters these DTOs."""
from datetime import datetime
from typing import Literal

from pydantic import Field, field_validator

from .answer_card_private_service import StrictRequest, Hash, Identifier
from .answer_card_service import CardPublicPayload


class CardExportRequest(StrictRequest):
    expected_version: int = Field(ge=1)
    previewed_payload_hash: Hash
    personal_review_ack: bool


class CardShareCreate(CardExportRequest):
    recipient_id: str = Field(min_length=1, max_length=36)
    expected_link_id: str = Field(min_length=1, max_length=36)
    expected_link_epoch: int = Field(ge=1)
    client_share_id: Identifier

    @field_validator('recipient_id', 'expected_link_id', 'client_share_id')
    @classmethod
    def nonblank_id(cls, value):
        if not value.strip():
            raise ValueError('Identifier cannot be blank')
        return value


class CardShareRevoke(StrictRequest):
    pass


class CardExportOut(StrictRequest):
    card_version: int = Field(ge=1)
    public_payload: CardPublicPayload
    public_payload_hash: Hash


class CardShareOut(CardExportOut):
    id: str
    mode: Literal['assistant_answer', 'public_template']
    sender_id: str
    recipient_id: str
    link_id: str
    link_epoch: int = Field(ge=1)
    created_at: datetime


class CardSentOut(StrictRequest):
    id: str
    mode: Literal['assistant_answer', 'public_template']
    card_id: str
    card_version: int = Field(ge=1)
    sender_id: str
    recipient_id: str
    link_id: str
    link_epoch: int = Field(ge=1)
    public_payload: CardPublicPayload | None
    public_payload_hash: Hash
    created_at: datetime
    access_revoked_at: datetime | None
    access_revocation_reason: str | None


class CardShareReceipt(StrictRequest):
    id: str
    revoked: Literal[True]
