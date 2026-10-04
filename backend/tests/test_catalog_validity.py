"""Catalog availability and honest, owner-private recommendation evidence."""
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete

from app.main import create_app
from app.activity_catalog_models import CommunityActivity, CommunityInterest
from app.community_models import CommunitySkill
from app.memory_models import MemoryConsent, PersonalMemory
from .test_safety_checkin_speech import _settings, _register, _headers


@pytest.fixture
def catalog(tmp_path):
    app = create_app(_settings(tmp_path / 'catalog.db'))
    with TestClient(app) as client:
        elder = _register(client, 'catalog@example.test')
        other = _register(client, 'catalog-other@example.test')
        app.state.settings.demo_mode = False
        with app.state.session_factory() as db:
            db.execute(delete(CommunityActivity))
            db.commit()
        yield app, client, elder, other


def activity(app, id='activity', **values):
    with app.state.session_factory() as db:
        row = CommunityActivity(id=id, title=id, description='Class', organizer='Test',
                                district='Test', verified=True, **values)
        db.add(row)
        db.commit()
    return id


@pytest.mark.parametrize('start,end,expected', [
    ('2020-01-01', '2020-01-02', 'expired'),
    ('not-a-date', '2099-01-02', 'invalid_date'),
    ('2099-01-03', '2099-01-02', 'invalid_date'),
    ('2099-01-01', 'bad', 'invalid_date'),
])
def test_unavailable_dates_hidden_and_interest_rejected(catalog, start, end, expected):
    app, client, elder, _ = catalog
    id = activity(app, start_date=start, end_date=end)
    headers = _headers(elder)
    assert client.get('/community/catalog/activities', headers=headers).json()['activities'] == []
    assert client.get('/community/catalog/recommendations', headers=headers).json()['recommendations'] == []
    assert client.get(f'/community/catalog/activities/{id}', headers=headers).status_code == 404
    assert client.post(f'/community/catalog/interest/{id}', headers=headers).status_code == 409
    with app.state.session_factory() as db:
        db.add(CommunityInterest(elder_id=elder['account']['id'], activity_id=id))
        db.commit()
    historical = client.get('/community/catalog/interests', headers=headers).json()['interests'][0]
    assert historical['available'] is False
    assert historical['availability_status'] == expected
    assert client.delete(f'/community/catalog/interest/{id}', headers=headers).status_code == 200


@pytest.mark.parametrize('start,end,expected', [
    (None, None, 'date_unknown'), ('2099-01-01', None, 'date_unknown'),
    (None, '2099-01-02', 'date_unknown'),
    ('2099-01-01', '2099-01-02', 'current'),
])
def test_available_cards_label_known_and_unknown_dates(catalog, start, end, expected):
    app, client, elder, _ = catalog
    id = activity(app, start_date=start, end_date=end)
    headers = _headers(elder)
    for row in [client.get('/community/catalog/activities', headers=headers).json()['activities'][0],
                client.get(f'/community/catalog/activities/{id}', headers=headers).json(),
                client.get('/community/catalog/recommendations', headers=headers).json()['recommendations'][0]]:
        assert row['available'] is True
        assert row['availability_status'] == expected
    assert client.post(f'/community/catalog/interest/{id}', headers=headers).status_code == 201


def test_unverified_demo_interest_remains_historical_outside_demo(catalog):
    app, client, elder, _ = catalog
    id = activity(app)
    with app.state.session_factory() as db:
        db.get(CommunityActivity, id).verified = False
        db.commit()
    headers = _headers(elder)
    assert client.post(f'/community/catalog/interest/{id}', headers=headers).status_code == 404
    app.state.settings.demo_mode = True
    row = client.get(f'/community/catalog/activities/{id}', headers=headers).json()
    assert row['available'] is True and row['availability_status'] == 'unverified'
    assert client.post(f'/community/catalog/interest/{id}', headers=headers).status_code == 201
    app.state.settings.demo_mode = False
    row = client.get('/community/catalog/interests', headers=headers).json()['interests'][0]
    assert row['available'] is False and row['availability_status'] == 'unverified'
    assert client.delete(f'/community/catalog/interest/{id}', headers=headers).status_code == 200


def test_browse_filters_before_limit(catalog):
    app, client, elder, _ = catalog
    for index in range(5):
        activity(app, id=f'irrelevant-{index}', start_date='2099-01-01', end_date='2099-02-01', interest_tags=['other'])
    activity(app, id='wanted', start_date='2098-01-01', end_date='2098-02-01', interest_tags=['sewing'])
    rows = client.get('/community/catalog/activities?interest=sewing&limit=1', headers=_headers(elder)).json()['activities']
    assert [row['id'] for row in rows] == ['wanted']


def test_expiry_uses_hong_kong_calendar_day(catalog):
    app, client, elder, _ = catalog
    activity(app, start_date='2026-10-02', end_date='2026-10-03')
    with patch('app.routers.activity_catalog.datetime') as clock:
        clock.now.return_value = datetime(2026, 10, 4, 0, 30, tzinfo=timezone(timedelta(hours=8)))
        assert client.get('/community/catalog/activities', headers=_headers(elder)).json()['activities'] == []
        assert clock.now.call_args.args[0].key == 'Asia/Hong_Kong'


def add_memory(app, owner, content, kind='preference', **values):
    with app.state.session_factory() as db:
        row = PersonalMemory(owner_id=owner['account']['id'], content=content, kind=kind,
                             status=values.pop('status', 'confirmed'), **values)
        db.add(row)
        db.commit()
        return row.id


def consent(app, owner):
    with app.state.session_factory() as db:
        db.add(MemoryConsent(owner_id=owner['account']['id'], enabled=True))
        db.commit()


def test_unmatched_memories_have_explicit_general_basis(catalog):
    app, client, elder, _ = catalog
    activity(app, interest_tags=['sewing'])
    consent(app, elder)
    add_memory(app, elder, 'I enjoy astronomy')
    result = client.get('/community/catalog/recommendations', headers=_headers(elder)).json()
    assert result['basis'] == 'general' and result['memory_matches'] == 0
    assert result['recommendations'][0]['recommendation_basis'] == 'general'
    assert result['recommendations'][0]['recommendation_reasons'] == []


def test_recommendations_explain_only_matched_owner_sources(catalog):
    app, client, elder, other = catalog
    activity(app, interest_tags=['sewing', 'craft'], skill_tags=['calligraphy', 'sewing'])
    consent(app, elder)
    preference_id = add_memory(app, elder, 'sewing', kind='fact')
    add_memory(app, elder, 'I enjoy astronomy', kind='fact')
    add_memory(app, other, 'I enjoy sewing')
    skill_memory_id = add_memory(app, elder, 'calligraphy', kind='fact')
    with app.state.session_factory() as db:
        db.add(CommunitySkill(owner_id=elder['account']['id'], memory_id=preference_id, suggestion='sewing', status='confirmed'))
        db.add(CommunitySkill(owner_id=elder['account']['id'], memory_id=skill_memory_id,
                              suggestion='calligraphy', status='confirmed'))
        db.commit()
    result = client.get('/community/catalog/recommendations', headers=_headers(elder)).json()
    assert result['basis'] == 'memory' and result['memory_matches'] == 2
    row = result['recommendations'][0]
    assert row['recommendation_basis'] == 'memory'
    assert row['recommendation_reasons'] == [
        {'memory_id': skill_memory_id, 'source_type': 'skill', 'source_text': 'calligraphy', 'matched_tag': 'calligraphy'},
        {'memory_id': preference_id, 'source_type': 'skill', 'source_text': 'sewing', 'matched_tag': 'sewing'},
    ]


@pytest.mark.parametrize('excluded', ['off', 'deleted', 'suppressed', 'rejected', 'superseded', 'skill_rejected'])
def test_inactive_sources_never_supply_recommendation_reasons(catalog, excluded):
    app, client, elder, _ = catalog
    activity(app, interest_tags=['sewing'], skill_tags=['calligraphy'])
    if excluded != 'off':
        consent(app, elder)
    values = {}
    if excluded == 'deleted': values['deleted_at'] = datetime.now(timezone.utc)
    if excluded == 'suppressed': values['suppressed'] = True
    if excluded == 'rejected': values['status'] = 'rejected'
    if excluded == 'superseded': values['superseded_by'] = add_memory(app, elder, 'astronomy')
    id = add_memory(app, elder, 'I enjoy sewing' if excluded != 'skill_rejected' else 'calligraphy',
                    kind='fact' if excluded == 'skill_rejected' else 'preference', **values)
    with app.state.session_factory() as db:
        db.add(CommunitySkill(owner_id=elder['account']['id'], memory_id=id, suggestion='calligraphy',
                              status='rejected' if excluded == 'skill_rejected' else 'confirmed'))
        db.commit()
    result = client.get('/community/catalog/recommendations', headers=_headers(elder)).json()
    assert result['basis'] == 'general' and result['memory_matches'] == 0
    assert result['recommendations'][0]['recommendation_reasons'] == []
