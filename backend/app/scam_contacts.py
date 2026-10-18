"""Read-only, fail-closed contact approvals bound to the public source DB.

Approval expiry is an internal re-review deadline, not a promise by a provider.
No number is inferred from prose or returned without its exact approved DB entry.
"""
from datetime import date, datetime, timedelta, timezone
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator
from sqlalchemy.orm import Session

from .scam_models import ScamResource

DATA = Path(__file__).resolve().parents[1] / 'data'
CONTACT_APPROVAL_PATH = DATA / 'approved_scam_contacts.json'
SOURCE_PATH = DATA / 'scam_resources.json'
OFFICIAL_HOSTS = {'www.police.gov.hk', 'www.consumer.org.hk', 'www.hkma.gov.hk'}
MAX_REVIEW_AGE = timedelta(days=90)


class ContactApproval(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    id: str = Field(min_length=1, max_length=120)
    source_id: str = Field(min_length=1, max_length=120)
    source_content_hash: str = Field(pattern=r'^[a-f0-9]{64}$')
    source_url: str
    contact_entry: str
    name_en: str
    description: str
    description_en: str
    status: str
    reviewed_at: str | None
    expires_at: str | None
    evidence_url: str = ''
    evidence_excerpt: str = ''

    @field_validator('evidence_url', 'evidence_excerpt', mode='before')
    @classmethod
    def unavailable_evidence(cls, value):
        return value if isinstance(value, str) else ''


def _hash(record: dict) -> str:
    return hashlib.sha256(json.dumps(record, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def _official_url(value: str) -> bool:
    try:
        url = urlsplit(value)
        return (url.scheme == 'https' and url.hostname in OFFICIAL_HOSTS
                and not url.username and not url.password and url.port is None
                and not url.fragment and not url.query and '\\' not in value
                and not any(c.isspace() for c in value))
    except ValueError:
        return False


def _instant(value: str | None) -> datetime | None:
    try:
        if not value or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})', value):
            return None
        offset = re.search(r'[+-](\d{2}):(\d{2})$', value)
        if offset and (int(offset[1]) > 23 or int(offset[2]) > 59):
            return None
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00')) if value else None
        return parsed.astimezone(timezone.utc) if parsed and parsed.tzinfo else None
    except (ValueError, TypeError):
        return None


def approved_contacts(db: Session, path: Path = CONTACT_APPROVAL_PATH, *,
                      now: datetime | None = None) -> list[dict]:
    """Read current approvals on each call; never seed or mutate during GET."""
    try:
        raw = json.loads(path.read_text('utf-8'))
        sources = json.loads(SOURCE_PATH.read_text('utf-8'))
        if not isinstance(raw, list) or len(raw) > 20 or not isinstance(sources, list):
            return []
        source_map = {r['id']: r for r in sources}
        if len(source_map) != len(sources):
            return []
    except (OSError, ValueError, TypeError, KeyError, ValidationError):
        return []
    now = now or datetime.now(timezone.utc)
    result = []
    ids = Counter(item.get('id') for item in raw if isinstance(item, dict) and isinstance(item.get('id'), str))
    for original in raw:
        if not isinstance(original, dict) or not isinstance(original.get('id'), str) or ids[original['id']] != 1:
            continue
        try:
            approval = ContactApproval.model_validate(original)
        except ValidationError:
            continue
        source = source_map.get(approval.source_id)
        row = db.get(ScamResource, approval.source_id)
        try:
            source_review = date.fromisoformat(row.verified_at) if row else None
        except (ValueError, TypeError):
            source_review = None
        source_url_ok = _official_url(approval.source_url)
        evidence_url_ok = (_official_url(approval.evidence_url) and source_url_ok
                           and urlsplit(approval.evidence_url).hostname == urlsplit(approval.source_url).hostname)
        reviewed, expires = _instant(approval.reviewed_at), _instant(approval.expires_at)
        status = approval.status if approval.status in {'approved', 'revoked', 'pending_review'} else 'unavailable'
        phone = ''
        source_valid = (source and row and source_url_ok and source_review and source_review <= now.date()
                        and source.get('source_url') == approval.source_url
                        and _hash(source) == approval.source_content_hash == row.content_hash
                        and all(getattr(row, key, None) == value for key, value in source.items()
                                if key != 'content_hash'))
        if not source_valid:
            status = 'source_unavailable'
        elif status == 'approved':
            if not (reviewed and expires and reviewed <= now < expires
                    and source_review <= reviewed.date()
                    and timedelta(0) < expires - reviewed <= MAX_REVIEW_AGE):
                status = 'expired' if expires and expires <= now else 'unavailable'
            elif not evidence_url_ok or not approval.evidence_excerpt.strip():
                status = 'unavailable'
            elif approval.contact_entry in (row.official_contacts or []):
                match = re.fullmatch(r'.+?[：:]\s*([0-9]{5}|[0-9]{4} ?[0-9]{4})', approval.contact_entry)
                if match:
                    # The value being dialed is extracted from the matched DB item.
                    database_entry = row.official_contacts[row.official_contacts.index(approval.contact_entry)]
                    phone = re.split(r'[：:]', database_entry, maxsplit=1)[1].replace(' ', '')
                    if phone not in re.sub(r'\D', '', approval.evidence_excerpt):
                        phone = ''
                if not phone:
                    status = 'unavailable'
            else:
                status = 'source_unavailable'
        safe_url = approval.evidence_url if evidence_url_ok else approval.source_url if source_url_ok else None
        result.append({
            'id': approval.id, 'name': row.source_authority if row and source_valid else approval.name_en,
            'name_en': approval.name_en, 'description': approval.description,
            'description_en': approval.description_en, 'phone': phone if status == 'approved' else '',
            'url': safe_url, 'source_id': approval.source_id,
            'source_url': approval.source_url if source_url_ok else None,
            'source_content_hash': approval.source_content_hash, 'record_version': _hash(original),
            'source_verified_at': row.verified_at if row and source_valid else None,
            'verified_at': approval.reviewed_at, 'expires_at': approval.expires_at,
            'status': status, 'callable': status == 'approved' and bool(phone),
        })
    return result
