"""Owner-only AnswerCard operations in a caller-owned transaction."""
from __future__ import annotations

import copy
import hashlib
import logging
from datetime import timezone
from typing import Annotated

from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator
from sqlalchemy import inspect, select
from sqlalchemy.orm import Session

from . import answer_card_service as public
from .answer_card_models import AnswerCard, AnswerCardOperation
from .memory_service import lock_owner_account
from .models import Conversation, Message, utc_now

logger = logging.getLogger(__name__)

ShortText = Annotated[str, Field(strict=True, min_length=1, max_length=1000)]
BodyText = Annotated[str, Field(strict=True, min_length=1, max_length=4000)]
Identifier = Annotated[str, Field(strict=True, min_length=1, max_length=200)]
Hash = Annotated[str, Field(strict=True, pattern=r'^[a-f0-9]{64}$')]


class StrictRequest(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)


class MessageOrigin(StrictRequest):
    message_id: str = Field(min_length=1, max_length=36)
    source_hash: Hash


class TemplateOrigin(StrictRequest):
    template_id: str = Field(min_length=1, max_length=120)
    template_version: int = Field(ge=1)
    template_hash: Hash


class SelectedSection(StrictRequest):
    id: Identifier
    edited_text: BodyText | None = None

    @field_validator('edited_text')
    @classmethod
    def meaningful_edit(cls, value):
        if value is not None and not value.strip():
            raise ValueError('Edited text cannot be blank')
        return value


class CardPrepare(StrictRequest):
    source_message_id: str = Field(min_length=1, max_length=36)


class CardCreate(StrictRequest):
    origin: MessageOrigin | TemplateOrigin
    selected_sections: list[SelectedSection] = Field(min_length=1, max_length=12)
    title: str = Field(min_length=1, max_length=240)
    selected_source_ids: list[Identifier] = Field(default_factory=list, max_length=10)
    official_terms: list[ShortText] = Field(default_factory=list, max_length=10)
    missing_information: list[BodyText] = Field(default_factory=list, max_length=12)
    next_steps: list[ShortText] = Field(default_factory=list, max_length=10)
    client_operation_id: Identifier


class CardUpdate(StrictRequest):
    title: str = Field(min_length=1, max_length=240)
    selected_sections: list[BodyText] = Field(min_length=1, max_length=12)
    official_terms: list[ShortText] = Field(max_length=10)
    missing_information: list[BodyText] = Field(max_length=12)
    next_steps: list[ShortText] = Field(max_length=10)
    selected_source_ids: list[Identifier] = Field(max_length=10)
    expected_version: int = Field(ge=1)
    client_operation_id: Identifier


class CardDelete(StrictRequest):
    expected_version: int = Field(ge=1)
    client_operation_id: Identifier


def require_schema(db: Session) -> None:
    inspector = inspect(db.connection())
    for model in (AnswerCard, AnswerCardOperation):
        if not inspector.has_table(model.__tablename__):
            raise HTTPException(503, 'Answer card schema is unavailable')
        columns = {column['name'] for column in inspector.get_columns(model.__tablename__)}
        if not set(model.__table__.columns.keys()).issubset(columns):
            raise HTTPException(503, 'Answer card schema is unavailable')


def owner_guard(db: Session, owner_id: str) -> None:
    account = lock_owner_account(db, owner_id)
    if account is None or not account.is_active:
        raise HTTPException(401, 'Account is unavailable')
    if account.role not in ('elder', 'caregiver'):
        raise HTTPException(403, 'Answer cards require an elder or caregiver owner')
    require_schema(db)


def _source(db: Session, owner_id: str, message_id: str) -> Message:
    message = db.scalar(select(Message).join(Conversation, Conversation.id == Message.conversation_id)
                        .where(Message.id == message_id, Conversation.owner_id == owner_id,
                               Message.role == 'assistant'))
    if message is None or not message.content.strip():
        raise HTTPException(404, 'Answer source is unavailable')
    metadata = message.metadata_json
    if not isinstance(metadata, dict):
        raise HTTPException(409, 'Answer source completion is unavailable')
    # Persisted legacy assistants need no newly invented completion marker.
    # An explicitly supplied marker must be typed and positively complete.
    if (metadata.get('status') not in (None, 'completed', 'complete', 'ready')
            or ('mode' in metadata and metadata['mode'] not in
                ('deterministic_demo', 'openai_compatible', 'safety_intervention'))
            or ('pending' in metadata and metadata['pending'] is not False)
            or ('completed' in metadata and metadata['completed'] is not True)):
        raise HTTPException(409, 'Answer source is not complete')
    return message


def _text_hash(text: str) -> str:
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def _sources(metadata: dict) -> list[dict]:
    try:
        return public.sanitized_sources(metadata)
    except (OSError, ValueError) as exc:
        # Exception values/tracebacks may contain private input. Log only a
        # stable event and its class; programming errors still propagate.
        logger.error('answer_card_catalog_unavailable error_type=%s', type(exc).__name__)
        raise HTTPException(503, 'Answer sources are unavailable') from None


def _source_hash(text: str, sources: list[dict]) -> str:
    # Keep the established legacy text token for source-free answers. Bound
    # answers must reject changes to their canonical provenance as well.
    return public.payload_hash({'text': text, 'public_sources': sources}) if sources else _text_hash(text)


def prepare_answer_card(db: Session, owner_id: str, message_id: str) -> dict:
    owner_guard(db, owner_id)
    message = _source(db, owner_id, message_id)
    sources = _sources(message.metadata_json)
    return {'source_message_id': message.id, 'source_hash': _source_hash(message.content, sources),
            'original_text': message.content, 'sections': public.split_sections(message.content),
            'public_sources': sources,
            'selected_sections': [], 'selected_source_ids': []}


def _owned(db: Session, owner_id: str, card_id: str, *, include_deleted=False) -> AnswerCard:
    row = db.scalar(select(AnswerCard).where(AnswerCard.id == card_id, AnswerCard.owner_id == owner_id)
                    .with_for_update())
    if row is None or (row.deleted_at is not None and not include_deleted):
        raise HTTPException(404, 'Answer card not found')
    return row


def _validated(payload: dict, *, stored=False) -> dict:
    try:
        return public.validate_payload(payload)
    except (ValidationError, ValueError):
        # Validation diagnostics may contain user text. Never echo it in errors.
        if stored:
            raise HTTPException(503, 'Stored answer card is unavailable') from None
        raise HTTPException(422, 'Invalid answer card display fields or size') from None


def available_templates() -> list[dict]:
    try:
        return public.templates()
    except (OSError, ValueError) as exc:
        logger.error('answer_card_catalog_unavailable error_type=%s', type(exc).__name__)
        raise HTTPException(503, 'Answer templates are unavailable') from None


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def owner_out(row: AnswerCard) -> dict:
    payload = _validated(row.public_payload, stored=True)
    return {'id': row.id, 'mode': row.mode, 'version': row.version,
            'public_payload': payload, 'public_payload_hash': public.payload_hash(payload),
            'provenance': {'origin_message_id': row.origin_message_id, 'origin_hash': row.origin_hash,
                           'template_id': row.template_id, 'template_version': row.template_version,
                           'template_hash': row.template_hash,
                           'selected_original_excerpts': copy.deepcopy(row.selected_original_excerpts)},
            'created_at': _utc(row.created_at), 'updated_at': _utc(row.updated_at)}


def _request_hash(payload: BaseModel) -> str:
    # Omitted template fields inherit the reviewed template; explicit [] clears
    # them. Presence is therefore part of the operation's original request.
    return public.payload_hash(payload.model_dump(exclude_unset=True))


def _operation(db, owner_id, key, action, digest, card_id=None):
    operation = db.scalar(select(AnswerCardOperation).where(
        AnswerCardOperation.owner_id == owner_id, AnswerCardOperation.client_operation_id == key))
    if operation is not None and (operation.action != action or operation.request_hash != digest
                                 or (card_id is not None and operation.card_id != card_id)):
        raise HTTPException(409, 'Operation key is associated with a different request')
    return operation


def _record(db, owner_id, key, action, digest, row):
    db.add(AnswerCardOperation(owner_id=owner_id, client_operation_id=key, action=action,
                              card_id=row.id, result_version=row.version, request_hash=digest))
    db.flush()


def _replay_live(db, owner_id, operation):
    row = _owned(db, owner_id, operation.card_id, include_deleted=True)
    if row.deleted_at is not None:
        raise HTTPException(410, 'Answer card was deleted; this operation cannot be recreated')
    if row.version != operation.result_version:
        raise HTTPException(409, 'Answer card changed after this operation')
    return owner_out(row)


def _selected_sources(available, source_ids):
    if len(source_ids) != len(set(source_ids)):
        raise HTTPException(422, 'Selected source IDs must be unique')
    by_id = {source['source_id']: source for source in available}
    if any(source_id not in by_id for source_id in source_ids):
        raise HTTPException(422, 'Selected source is not available in this snapshot')
    return [copy.deepcopy(by_id[source_id]) for source_id in source_ids]


def create_answer_card(db: Session, owner_id: str, payload: CardCreate) -> dict:
    owner_guard(db, owner_id)
    digest = _request_hash(payload)
    previous = _operation(db, owner_id, payload.client_operation_id, 'create', digest)
    if previous is not None:
        return _replay_live(db, owner_id, previous)
    template = None
    if isinstance(payload.origin, MessageOrigin):
        message = _source(db, owner_id, payload.origin.message_id)
        available = _sources(message.metadata_json)
        if _source_hash(message.content, available) != payload.origin.source_hash:
            raise HTTPException(409, 'Answer source changed; open a fresh draft')
        sections = public.split_sections(message.content)
        base = {'official_terms': [], 'missing_information': [], 'next_steps': [],
                'verification_scope': 'AI answer is not independently verified. Sources are references only.'}
        mode = 'assistant_answer'
    else:
        template = next((row for row in available_templates() if row['template_id'] == payload.origin.template_id), None)
        if template is None:
            raise HTTPException(404, 'Answer template not found')
        if (template['template_version'] != payload.origin.template_version
                or template['template_hash'] != payload.origin.template_hash):
            raise HTTPException(409, 'Answer template changed; open a fresh draft')
        sections, base = template['sections'], template['public_payload']
        available, mode = base['public_sources'], 'public_template'
    by_id = {section['id']: section['text'] for section in sections}
    ids = [section.id for section in payload.selected_sections]
    if len(ids) != len(set(ids)) or any(section_id not in by_id for section_id in ids):
        raise HTTPException(422, 'Selected sections must be valid and unique')
    final_text = [section.edited_text if section.edited_text is not None else by_id[section.id]
                  for section in payload.selected_sections]
    edited = any(section.edited_text is not None and section.edited_text != by_id[section.id]
                 for section in payload.selected_sections)
    sources = _selected_sources(available, payload.selected_source_ids)
    result = {'title': payload.title, 'selected_sections': final_text,
              'public_sources': sources, 'verification_scope': base['verification_scope']}
    for name in ('official_terms', 'missing_information', 'next_steps'):
        supplied = getattr(payload, name)
        result[name] = list(supplied if name in payload.model_fields_set else base[name])
        if name in payload.model_fields_set and ((mode == 'assistant_answer' and supplied) or supplied != base[name]):
            edited = True
    complete = False
    if template is not None:
        display_fields = ('title', 'selected_sections', 'official_terms', 'missing_information', 'next_steps')
        edited = edited or any(result[field] != base[field] for field in display_fields)
        complete = sources == base['public_sources'] and not edited
    result['verification_state'] = public.verification_state(mode, edited, bool(sources), complete)
    final = _validated(result)
    origin = payload.origin
    row = AnswerCard(owner_id=owner_id, mode=mode, version=1, public_payload=final,
                     origin_message_id=origin.message_id if isinstance(origin, MessageOrigin) else None,
                     origin_hash=origin.source_hash if isinstance(origin, MessageOrigin) else None,
                     template_id=origin.template_id if isinstance(origin, TemplateOrigin) else None,
                     template_version=origin.template_version if isinstance(origin, TemplateOrigin) else None,
                     template_hash=origin.template_hash if isinstance(origin, TemplateOrigin) else None,
                     selected_original_excerpts=[{'id': section.id, 'hash': _text_hash(by_id[section.id]),
                                                  'edited': section.edited_text is not None and section.edited_text != by_id[section.id]}
                                                 for section in payload.selected_sections])
    db.add(row); db.flush()
    _record(db, owner_id, payload.client_operation_id, 'create', digest, row)
    return owner_out(row)


def list_answer_cards(db: Session, owner_id: str) -> list[dict]:
    owner_guard(db, owner_id)
    rows = db.scalars(select(AnswerCard).where(AnswerCard.owner_id == owner_id,
        AnswerCard.deleted_at.is_(None)).order_by(AnswerCard.updated_at.desc())).all()
    return [owner_out(row) for row in rows]


def get_answer_card(db: Session, owner_id: str, card_id: str) -> dict:
    owner_guard(db, owner_id)
    return owner_out(_owned(db, owner_id, card_id))


def update_answer_card(db: Session, owner_id: str, card_id: str, payload: CardUpdate) -> dict:
    owner_guard(db, owner_id)
    digest = _request_hash(payload)
    previous = _operation(db, owner_id, payload.client_operation_id, 'patch', digest, card_id)
    if previous is not None:
        return _replay_live(db, owner_id, previous)
    row = _owned(db, owner_id, card_id)
    if row.version != payload.expected_version:
        raise HTTPException(409, 'Answer card version changed')
    original_public = _validated(row.public_payload, stored=True)
    # A private edit can remove existing historical sources, never add a new
    # source or refresh its dates from today's catalog.
    result = {field: getattr(payload, field) for field in
              ('title', 'selected_sections', 'official_terms', 'missing_information', 'next_steps')}
    result['public_sources'] = _selected_sources(original_public['public_sources'], payload.selected_source_ids)
    result['verification_scope'] = original_public['verification_scope']
    result['verification_state'] = public.verification_state(row.mode, True, bool(result['public_sources']), False)
    row.public_payload = _validated(result)
    row.version += 1; row.updated_at = utc_now()
    from .answer_card_share_service import withdraw_answer_card_shares
    withdraw_answer_card_shares(db, card_id=row.id, reason='card_edited')
    # Mark the selected original provenance edited without retaining old text.
    row.selected_original_excerpts = [{**entry, 'edited': True} for entry in row.selected_original_excerpts]
    db.flush()
    _record(db, owner_id, payload.client_operation_id, 'patch', digest, row)
    return owner_out(row)


def _scrub_card(row: AnswerCard) -> None:
    row.public_payload = {}
    row.origin_message_id = row.origin_hash = row.template_id = row.template_hash = None
    row.template_version = None
    row.selected_original_excerpts = []
    row.deleted_at = row.updated_at = utc_now()
    row.version += 1


def delete_answer_card(db: Session, owner_id: str, card_id: str, payload: CardDelete) -> dict:
    owner_guard(db, owner_id)
    digest = _request_hash(payload)
    previous = _operation(db, owner_id, payload.client_operation_id, 'delete', digest, card_id)
    if previous is not None:
        return {'id': card_id, 'deleted': True, 'version': previous.result_version}
    row = _owned(db, owner_id, card_id)
    if row.version != payload.expected_version:
        raise HTTPException(409, 'Answer card version changed')
    _scrub_card(row)
    from .answer_card_share_service import withdraw_answer_card_shares
    withdraw_answer_card_shares(db, card_id=row.id, reason='card_deleted', scrub_payload=True)
    db.flush()
    _record(db, owner_id, payload.client_operation_id, 'delete', digest, row)
    return {'id': row.id, 'deleted': True, 'version': row.version}


def purge_answer_cards(db: Session, owner_id: str) -> int:
    """Scrub one owner's cards in the caller's transaction; never commit/lock.

    Future full-personal-data deletion must call this after its owner guard.
    Memory-only deletion intentionally does not call this independent helper.
    """
    require_schema(db)
    rows = db.scalars(select(AnswerCard).where(AnswerCard.owner_id == owner_id,
        AnswerCard.deleted_at.is_(None)).with_for_update()).all()
    for row in rows:
        _scrub_card(row)
        from .answer_card_share_service import withdraw_answer_card_shares
        withdraw_answer_card_shares(db, card_id=row.id, reason='owner_data_deleted', scrub_payload=True)
    db.flush()
    return len(rows)
