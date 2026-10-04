"""Pure, allowlisted AnswerCard payloads; never consult personal memories."""
from __future__ import annotations

import copy
import hashlib
import json
import re
from pathlib import Path
from typing import Annotated, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

Text4000 = Annotated[str, Field(strict=True, min_length=1, max_length=4000)]
Text1000 = Annotated[str, Field(strict=True, min_length=1, max_length=1000)]
State = Literal['reviewed_public_guidance', 'ai_unverified', 'user_edited_unverified', 'no_verified_source']

# Exact organisations used by the reviewed resource manifest plus the public
# template dataset. This is a closed list, not a general government-domain rule.
APPROVED_SOURCE_HOSTS = frozenset({'www.swd.gov.hk', 'www.ha.org.hk', 'portal.csdi.gov.hk',
    'www.cheu.gov.hk', 'www.elderly.gov.hk', 'www.hkab.org.hk', 'www.mtr.com.hk', 'www.td.gov.hk'})
APPROVED_QUERY_URLS = frozenset({
    'https://www.ha.org.hk/visitors/ha_visitor_guide.asp?Content_ID=100826',
})


class PublicSource(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    source_id: str = Field(min_length=1, max_length=120)
    organisation: str = Field(min_length=1, max_length=300)
    title: str = Field(min_length=1, max_length=300)
    url: str = Field(min_length=1, max_length=2048)
    reviewed_at: str | None = None
    retrieved_at: str | None = None
    effective_date: str | None = None
    verification_scope: str = Field(min_length=1, max_length=4000)
    content_hash: str | None = None

    @field_validator('url')
    @classmethod
    def official_url(cls, value):
        u = urlsplit(value)
        # urlsplit represents an empty component as '' (and port 0 as 0).
        # Presence, rather than truthiness, must match Flutter's strict parser.
        if (u.scheme != 'https' or u.username is not None or u.password is not None
                or u.port is not None or ':' in u.netloc or '#' in value
                or u.hostname not in APPROVED_SOURCE_HOSTS
                or any(c.isspace() or ord(c) < 32 for c in value)):
            raise ValueError('Only approved ordinary HTTPS source URLs are supported')
        if '?' in value and not (value in APPROVED_QUERY_URLS or
                (u.hostname == 'portal.csdi.gov.hk' and u.query == 'datasetId=swd_rcd_1696994103126_1549')):
            raise ValueError('Source URLs cannot carry personal query parameters')
        return value

    @field_validator('reviewed_at', 'retrieved_at', 'effective_date')
    @classmethod
    def original_date(cls, value):
        if value is not None:
            from datetime import date
            date.fromisoformat(value)
        return value

    @field_validator('content_hash')
    @classmethod
    def source_hash(cls, value):
        if value is not None and not re.fullmatch('[a-f0-9]{64}', value):
            raise ValueError('Invalid source hash')
        return value


class CardPublicPayload(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    title: str = Field(min_length=1, max_length=240)
    selected_sections: list[Text4000] = Field(min_length=1, max_length=12)
    official_terms: list[Text1000] = Field(default_factory=list, max_length=10)
    missing_information: list[Text4000] = Field(default_factory=list, max_length=12)
    next_steps: list[Text1000] = Field(default_factory=list, max_length=10)
    public_sources: list[PublicSource] = Field(default_factory=list, max_length=10)
    verification_state: State
    verification_scope: str = Field(min_length=1, max_length=4000)

    @field_validator('official_terms', 'missing_information', 'next_steps')
    @classmethod
    def nonblank_display_fields(cls, values):
        if any(not value.strip() for value in values):
            raise ValueError('Display fields cannot be blank')
        return values

    @model_validator(mode='after')
    def total_body_limit(self):
        if sum(len(x) for x in self.selected_sections) > 16000:
            raise ValueError('Selected body exceeds limit')
        if not self.title.strip() or any(not x.strip() for x in self.selected_sections):
            raise ValueError('Card text cannot be blank')
        return self


def canonical_bytes(payload: dict) -> bytes:
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')


def payload_hash(payload: dict) -> str:
    return hashlib.sha256(canonical_bytes(payload)).hexdigest()


def render_card_text(payload: dict) -> str:
    """Complete text from public fields only; owner provenance is never accepted."""
    p = CardPublicPayload.model_validate(payload).model_dump()
    parts = [p['title'], *p['selected_sections'], '官方术语', *p['official_terms'],
             '须确认事项', *p['missing_information'], '下一步', *p['next_steps'],
             '核验状态：' + p['verification_state'], '核验范围：' + p['verification_scope']]
    for s in p['public_sources']:
        parts += [s['organisation'] + '：' + s['title'], s['url'],
                  '审阅日期：' + (s['reviewed_at'] or '未提供'),
                  '检索日期：' + (s['retrieved_at'] or '未提供'),
                  '生效日期：' + (s['effective_date'] or '未提供'),
                  '来源核验范围：' + s['verification_scope']]
    if not p['official_terms']:
        parts.append('官方术语：原回答未提供')
    if not p['next_steps']:
        parts.append('下一步：原回答未提供')
    return '\n\n'.join(parts)


def validate_payload(payload: dict) -> dict:
    p = CardPublicPayload.model_validate(payload).model_dump()
    if len(canonical_bytes(p)) > 65536 or len(render_card_text(p)) > 30000:
        raise ValueError('Complete card exceeds export limit')
    return p


def split_sections(text: str) -> list[dict]:
    digest = hashlib.sha256(text.encode('utf-8')).hexdigest()
    return [{'id': f'{digest}:{i}', 'text': chunk.strip()}
            for i, chunk in enumerate(re.split(r'\r?\n[ \t]*\r?\n', text)) if chunk.strip()]


def verification_state(mode: str, edited: bool, has_sources: bool, template_complete: bool) -> str:
    if not has_sources:
        return 'no_verified_source'
    if edited:
        return 'user_edited_unverified'
    if mode == 'assistant_answer':
        return 'ai_unverified'
    return 'reviewed_public_guidance' if template_complete else 'no_verified_source'


class TemplateSection(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    id: str = Field(min_length=1, max_length=200)
    text: Text4000


class ReviewedTemplate(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    template_id: str = Field(min_length=1, max_length=120)
    template_version: int = Field(ge=1)
    language: Literal['zh']
    sections: list[TemplateSection] = Field(min_length=1, max_length=12)
    public_payload: CardPublicPayload


def validate_templates(raw: list) -> list[dict]:
    if not isinstance(raw, list):
        raise ValueError('Template data must be a list')
    rows = [ReviewedTemplate.model_validate(row).model_dump() for row in raw]
    if len(rows) != 3 or len({x['template_id'] for x in rows}) != 3:
        raise ValueError('Exactly three reviewed templates required')
    for row in rows:
        row['public_payload'] = validate_payload(row['public_payload'])
        section_ids = [s['id'] for s in row['sections']]
        if (len(section_ids) != len(set(section_ids))
                or [s['text'] for s in row['sections']] != row['public_payload']['selected_sections']):
            raise ValueError('Template sections must match reviewed public body')
        row['template_hash'] = payload_hash({k: row[k] for k in
            ('template_id', 'template_version', 'sections', 'public_payload')})
    return copy.deepcopy(rows)


def templates() -> list[dict]:
    path = Path(__file__).resolve().parent.parent / 'data' / 'answer_card_templates.json'
    return validate_templates(json.loads(path.read_text(encoding='utf-8')))


def sanitized_sources(metadata: dict) -> list[dict]:
    """Only an exact approved snapshot binding may contribute a public source.

    Legacy message references without a version hash are intentionally omitted:
    matching an ID alone cannot prove their historical date or source version.
    Metadata titles, URLs, dates and private fields are never copied.
    """
    if not isinstance(metadata, dict):
        return []
    result = []
    def versioned_refs(name):
        refs = metadata.get(name)
        return [ref for ref in refs if isinstance(ref, dict)
                and isinstance(ref.get('source_id'), str)
                and isinstance(ref.get('content_hash'), str)
                and re.fullmatch('[a-f0-9]{64}', ref['content_hash'])] if isinstance(refs, list) else []

    bindings = versioned_refs('resource_source_bindings')
    if bindings:
        from .resource_service import get_default_resource_service, _record_hash
        records = {r.id: r for r in get_default_resource_service().records}
        for ref in bindings:
            record = records.get(ref['source_id'])
            if record is None or ref['content_hash'] != _record_hash(record):
                continue
            # Rebuild exclusively from the trusted reviewed manifest. No
            # metadata title, URL, date, private field or supplied scope enters.
            try:
                source = PublicSource(source_id=record.id, organisation=record.source_authority,
                    title=record.title, url=record.url, reviewed_at=record.verified_at.isoformat(),
                    effective_date=record.effective_date.isoformat() if record.effective_date else None,
                    verification_scope='Reviewed resource record only; the AI answer and personal eligibility are not verified.',
                    content_hash=ref['content_hash']).model_dump()
            except ValidationError:
                # Resource search supports more URLs than card export. Omit
                # references outside the approved card URL policy.
                continue
            if source not in result:
                result.append(source)

    refs = versioned_refs('resource_sources')
    if refs:
        approved = {s['source_id']: s for t in templates() for s in t['public_payload']['public_sources']}
        for ref in refs:
            source = approved.get(ref['source_id'])
            if source and source['content_hash'] and ref['content_hash'] == source['content_hash'] and source not in result:
                result.append(copy.deepcopy(source))
    return result[:10]
