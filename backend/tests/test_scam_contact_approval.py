"""SCM03: only current, evidenced contacts bound to the public DB can dial."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, func, select

from app.config import Settings
from app.main import create_app
from app.models import Account
from app.routers import scam
from app.scam_models import ScamLog, ScamResource


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


@pytest.fixture
def approved_client(tmp_path, monkeypatch):
    sources = json.loads((Path(__file__).parents[1] / 'data/scam_resources.json').read_text('utf-8'))
    source = next(r for r in sources if r['id'] == 'scam-phone-fraud')
    now = datetime.now(timezone.utc)
    record = {
        'id': 'approved-adcc', 'source_id': source['id'], 'source_content_hash': digest(source),
        'source_url': source['source_url'], 'contact_entry': source['official_contacts'][0],
        'name_en': 'Police ADCC', 'description': '官方反詐騙查詢',
        'description_en': 'Official anti-scam enquiries', 'status': 'approved',
        'reviewed_at': (now - timedelta(hours=1)).isoformat(),
        'expires_at': (now + timedelta(days=1)).isoformat(),
        'evidence_url': 'https://www.police.gov.hk/ppp_en/04_crime_matters/adcc/index.html',
        'evidence_excerpt': 'Anti-Scam Helpline 18222',
    }
    path = tmp_path / 'approvals.json'
    path.write_text(json.dumps([record], ensure_ascii=False), encoding='utf-8')
    monkeypatch.setattr(scam, 'CONTACT_APPROVAL_PATH', path, raising=False)
    app = create_app(Settings(database_url=f"sqlite:///{tmp_path / 'contacts.db'}",
                              auth_secret='synthetic-contacts', demo_mode=True))
    with TestClient(app) as client:
        yield app, client, path, record


def contact(client):
    response = client.get('/scam/contacts')
    assert response.status_code == 200
    return response.json()['contacts'][0]


def test_contact_returns_database_bound_approval_and_no_personal_writes(approved_client):
    app, client, _, record = approved_client
    c = contact(client)
    assert c['id'] == record['id']
    assert c['source_id'] == record['source_id']
    assert c['source_content_hash'] == record['source_content_hash']
    assert c['record_version'] == digest(record)
    assert c['verified_at'] == record['reviewed_at']
    assert c['expires_at'] == record['expires_at']
    assert c['source_verified_at'] == '2026-09-20'
    assert c['phone'] == '18222' and c['callable'] is True
    assert c['url'] == record['evidence_url']
    with app.state.session_factory() as db:
        for model in (Account, ScamLog):
            assert db.scalar(select(func.count()).select_from(model)) == 0


@pytest.mark.parametrize('field,value', [
    ('status', 'revoked'), ('status', 'pending_review'), ('status', 'unknown'),
    ('reviewed_at', None), ('reviewed_at', 'not-a-date'),
    ('reviewed_at', '2999-01-01T00:00:00Z'), ('reviewed_at', '2026-10-15'),
    ('expires_at', '2020-01-01T00:00:00Z'), ('expires_at', '2999-01-01T00:00:00Z'),
    ('expires_at', None), ('source_content_hash', '0' * 64),
    ('evidence_excerpt', ''), ('evidence_excerpt', 'No phone evidence'),
    ('evidence_url', 'https://www.police.gov.hk.evil.invalid/18222'),
    ('evidence_url', 'javascript:alert(1)'),
    ('evidence_url', 'https://www.consumer.org.hk/18222'),
    ('contact_entry', '警方反詐騙熱線：18222#123'),
])
def test_missing_revoked_expired_or_unsafe_evidence_cannot_enable_call(approved_client, field, value):
    _, client, path, record = approved_client
    record[field] = value
    path.write_text(json.dumps([record]), encoding='utf-8')
    contacts = client.get('/scam/contacts').json()['contacts']
    assert all(c.get('callable') is False and not c.get('phone') for c in contacts)


@pytest.mark.parametrize('mutation', ['remove', 'phone', 'url', 'hash'])
def test_database_removal_or_drift_is_not_hidden_by_a_manifest(approved_client, mutation):
    app, client, _, _ = approved_client
    with app.state.session_factory() as db:
        row = db.get(ScamResource, 'scam-phone-fraud')
        if mutation == 'remove':
            db.delete(row)
        elif mutation == 'phone':
            row.official_contacts = ['警方反詐騙熱線：11111']
        elif mutation == 'url':
            row.source_url = 'https://evil.invalid'
        else:
            row.content_hash = '0' * 64
        db.commit()
    c = contact(client)
    assert c['callable'] is False and c['phone'] == ''


def test_revocation_is_read_on_every_request_not_cached(approved_client):
    _, client, path, record = approved_client
    assert contact(client)['callable'] is True
    record['status'] = 'revoked'
    path.write_text(json.dumps([record]), encoding='utf-8')
    assert contact(client)['callable'] is False


def test_missing_malformed_or_duplicate_approval_manifest_fails_closed(approved_client):
    _, client, path, record = approved_client
    for raw in ('broken json', '{}', json.dumps([record, record])):
        path.write_text(raw, encoding='utf-8')
        assert client.get('/scam/contacts').json()['contacts'] == []
    path.unlink()
    assert client.get('/scam/contacts').json()['contacts'] == []


@pytest.mark.parametrize('change', ['missing_url', 'missing_excerpt', 'null_excerpt', 'wrong_type'])
def test_one_bad_evidence_record_keeps_other_contact_and_official_fallback(approved_client, change):
    _, client, path, record = approved_client
    bad = dict(record, id='missing-evidence')
    if change == 'missing_url':
        bad.pop('evidence_url')
    elif change == 'missing_excerpt':
        bad.pop('evidence_excerpt')
    else:
        bad['evidence_excerpt'] = None if change == 'null_excerpt' else 123
    path.write_text(json.dumps([record, bad]), encoding='utf-8')
    items = client.get('/scam/contacts').json()['contacts']
    assert len(items) == 2
    assert items[0]['callable'] is True
    assert items[1]['callable'] is False and items[1]['phone'] == ''
    assert items[1]['url'].startswith('https://www.police.gov.hk/')


def test_invalid_timezone_component_cannot_be_normalized_into_approval(approved_client):
    _, client, path, record = approved_client
    record['reviewed_at'] = '2026-10-01T00:00:00+00:99'
    path.write_text(json.dumps([record]), encoding='utf-8')
    assert contact(client)['callable'] is False


@pytest.mark.parametrize('source_date', ['not-a-date', '2026-09-31', '2999-01-01'])
def test_bound_source_itself_requires_a_valid_nonfuture_review_date(approved_client, monkeypatch, source_date):
    app, client, path, record = approved_client
    sources = json.loads((Path(__file__).parents[1] / 'data/scam_resources.json').read_text('utf-8'))
    source = next(r for r in sources if r['id'] == record['source_id'])
    source['verified_at'] = source_date
    record['source_content_hash'] = digest(source)
    source_path = path.parent / 'sources.json'
    source_path.write_text(json.dumps([source]), encoding='utf-8')
    monkeypatch.setattr('app.scam_contacts.SOURCE_PATH', source_path)
    path.write_text(json.dumps([record]), encoding='utf-8')
    with app.state.session_factory() as db:
        row = db.get(ScamResource, record['source_id'])
        row.verified_at = source_date
        row.content_hash = record['source_content_hash']
        db.commit()
    assert contact(client)['callable'] is False
