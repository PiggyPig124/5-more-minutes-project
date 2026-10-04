"""Catalog streaming contracts: bounded browse loading and complete ranking."""
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, event

from app.activity_catalog_models import CommunityActivity
from app.community_models import CommunitySkill
from app.main import create_app
from app.memory_models import MemoryConsent, PersonalMemory
from .test_safety_checkin_speech import _headers, _register, _settings


@pytest.fixture
def catalog(tmp_path):
    app = create_app(_settings(tmp_path / 'streaming.db'))
    with TestClient(app) as client:
        elder = _register(client, 'streaming@example.test')
        app.state.settings.demo_mode = False
        with app.state.session_factory() as db:
            db.execute(delete(CommunityActivity))
            db.commit()
        yield app, client, elder


def seed(app, count, **values):
    with app.state.session_factory() as db:
        db.add_all([CommunityActivity(
            id=f'activity-{index:04d}', title=f'Activity {index}', description='Class',
            organizer='Test', district='Test', verified=True,
            start_date='2099-01-01', end_date='2099-02-01', **values,
        ) for index in range(count)])
        db.commit()


@contextmanager
def loaded_activities():
    loaded = []
    def record(target, _context):
        loaded.append(target.id)
    event.listen(CommunityActivity, 'load', record)
    try:
        yield loaded
    finally:
        event.remove(CommunityActivity, 'load', record)


def test_browse_stops_loading_after_first_full_result_batch(catalog):
    app, client, elder = catalog
    seed(app, 1000, interest_tags=['sewing'])
    with loaded_activities() as loaded:
        response = client.get('/community/catalog/activities?interest=sewing&limit=20', headers=_headers(elder))
    assert response.status_code == 200
    assert len(response.json()['activities']) == 20
    assert 20 <= len(loaded) <= 200, f'browse materialized {len(loaded)} of 1000 activities'


def test_browse_crosses_batches_of_unavailable_and_unmatched_rows(catalog):
    app, client, elder = catalog
    seed(app, 350, interest_tags=['other'])
    with app.state.session_factory() as db:
        for index in range(100):
            db.get(CommunityActivity, f'activity-{index:04d}').end_date = '2020-01-01'
        for index in range(100, 200):
            db.get(CommunityActivity, f'activity-{index:04d}').end_date = 'bad-date'
        for index in range(300, 350):
            db.get(CommunityActivity, f'activity-{index:04d}').interest_tags = ['sewing']
        db.commit()
    response = client.get('/community/catalog/activities?interest=sewing&limit=20', headers=_headers(elder))
    assert response.status_code == 200
    assert [row['id'] for row in response.json()['activities']] == [f'activity-{i:04d}' for i in range(300, 320)]
    assert response.json()['count'] == 20


def test_recommendations_rank_final_batch_and_preserve_source_evidence(catalog):
    app, client, elder = catalog
    seed(app, 350, interest_tags=['sewing'], skill_tags=['sewing'])
    owner_id = elder['account']['id']
    with app.state.session_factory() as db:
        preference = PersonalMemory(owner_id=owner_id, kind='fact', content='sewing', status='confirmed')
        skill_memory = PersonalMemory(owner_id=owner_id, kind='fact', content='calligraphy', status='confirmed')
        db.add_all([preference, skill_memory, MemoryConsent(owner_id=owner_id, enabled=True)])
        db.flush()
        db.add(CommunitySkill(owner_id=owner_id, memory_id=preference.id, suggestion='sewing', status='confirmed'))
        db.add(CommunitySkill(owner_id=owner_id, memory_id=skill_memory.id, suggestion='calligraphy', status='confirmed'))
        db.get(CommunityActivity, 'activity-0349').skill_tags = ['calligraphy', 'sewing']
        db.commit()
        preference_id, skill_id = preference.id, skill_memory.id
    response = client.get('/community/catalog/recommendations', headers=_headers(elder))
    assert response.status_code == 200
    body = response.json()
    rows = body['recommendations']
    assert len(rows) == 10
    assert rows[0]['id'] == 'activity-0349'
    assert [row['id'] for row in rows[1:]] == [f'activity-{i:04d}' for i in range(9)]
    assert rows[0]['recommendation_reasons'] == [
        {'memory_id': skill_id, 'source_type': 'skill', 'source_text': 'calligraphy', 'matched_tag': 'calligraphy'},
        {'memory_id': preference_id, 'source_type': 'skill', 'source_text': 'sewing', 'matched_tag': 'sewing'},
    ]
    assert body['basis'] == 'memory' and body['memory_matches'] == 2
    assert all(row['recommendation_basis'] == 'memory' for row in rows)


def test_general_recommendations_stop_after_six_stable_candidates(catalog):
    app, client, elder = catalog
    seed(app, 1000)
    with loaded_activities() as loaded:
        response = client.get('/community/catalog/recommendations', headers=_headers(elder))
    assert response.status_code == 200
    body = response.json()
    assert [row['id'] for row in body['recommendations']] == [f'activity-{i:04d}' for i in range(6)]
    assert body['basis'] == 'general' and body['memory_matches'] == 0
    assert all(row['recommendation_basis'] == 'general' and row['recommendation_reasons'] == [] for row in body['recommendations'])
    assert 6 <= len(loaded) <= 200, f'general fallback materialized {len(loaded)} activities without eligible sources'
