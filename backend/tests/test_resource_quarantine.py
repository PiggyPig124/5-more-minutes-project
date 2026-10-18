"""Offline source eligibility regressions; only synthetic accounts and databases."""
import json
from pathlib import Path

import pytest

from app.resource_models import KnowledgeSource, ResourceRecord
from app.resource_service import ResourceService, _record_hash, get_default_resource_service, seed_resources
from tests.test_memory_controls import setup, auth, enable, save
from tests.test_answer_card_source_bindings import chat_answer
from tests.test_answer_cards_private import seed, prepared, body

SOURCE_ID = 'transport-rehabus-2026'
CONTROL_ID = 'ha-medical-fee-waiver'
QUERY = 'welfare Rehabus'
DATA_PATH = Path(__file__).resolve().parents[1] / 'data' / 'hk_resources.json'


def original_records():
    return tuple(ResourceRecord.model_validate(row) for row in json.loads(DATA_PATH.read_text(encoding='utf-8')))


def original_source():
    return next(r for r in original_records() if r.id == SOURCE_ID)


def assert_no_quarantined_source(payload):
    text = json.dumps(payload, ensure_ascii=False)
    assert SOURCE_ID not in text
    assert original_source().url not in text
    assert original_source().excerpt not in text


def test_review_pending_record_is_not_an_active_source_but_other_records_are_unchanged():
    original = {r.id: r for r in original_records()}
    active = {r.id: r for r in ResourceService(embedding_provider=None).records}
    assert set(active) == set(original) - {SOURCE_ID}
    assert {key: _record_hash(value) for key, value in active.items()} == {
        key: _record_hash(value) for key, value in original.items() if key != SOURCE_ID}


def test_keyword_and_embedding_candidates_never_use_quarantined_evidence():
    class LocalEmbeddingSpy:
        model = 'synthetic-local-vector'
        def __init__(self): self.calls = []
        def embed(self, text):
            self.calls.append(text)
            return [1.0, 0.0]
    spy = LocalEmbeddingSpy()
    service = ResourceService(embedding_provider=spy)
    for query in (QUERY, '復康巴士', 'medical fee waiver'):
        assert_no_quarantined_source(service.search(query, limit=20).model_dump(mode='json'))
    assert all(original_source().excerpt not in value for value in spy.calls)
    assert any(r.id == CONTROL_ID for r in service.search('medical fee waiver').items)


@pytest.mark.parametrize('role,method', [('guest', 'GET'), ('elder', 'GET'), ('elder', 'POST'),
                                        ('caregiver', 'GET'), ('caregiver', 'POST')])
def test_public_and_authenticated_search_share_review_eligibility(setup, role, method):
    _, client, accounts = setup
    headers = {} if role == 'guest' else auth(accounts[2] if role == 'caregiver' else accounts[0])
    path = '/guest/resources/search' if role == 'guest' else '/resources/search'
    def search(query):
        response = client.request(method, path, headers=headers,
                                  **({'params': {'query': query, 'limit': 20}} if method == 'GET'
                                     else {'json': {'query': query, 'limit': 20}}))
        assert response.status_code == 200, response.text
        return response.json()
    assert_no_quarantined_source(search(QUERY))
    assert any(item['id'] == CONTROL_ID for item in search('medical fee waiver')['items'])


@pytest.mark.parametrize('guest', [False, True])
def test_generic_welfare_chat_does_not_present_pending_evidence_as_reviewed(setup, guest):
    _, client, (owner, _, _) = setup
    if guest:
        session = client.post('/guest/sessions').json()['session_id']
        response = client.post(f'/guest/sessions/{session}/messages', json={'content': QUERY})
        assert response.status_code == 200, response.text
        payload = response.json()
    else:
        payload = chat_answer(client, owner, QUERY)
    assert_no_quarantined_source(payload)


def test_old_exact_binding_cannot_be_prepared_or_selected_on_new_card(setup):
    app, client, (owner, _, _) = setup
    pending = original_source()
    valid = next(r for r in original_records() if r.id == CONTROL_ID)
    message_id = seed(app, owner, metadata={'resource_source_bindings': [
        {'source_id': r.id, 'content_hash': _record_hash(r)} for r in (pending, valid)]})
    draft = prepared(client, owner, message_id)
    assert [s['source_id'] for s in draft['public_sources']] == [CONTROL_ID]
    request = {**body(draft), 'selected_source_ids': [SOURCE_ID]}
    rejected = client.post('/answer-cards', headers=auth(owner), json=request)
    assert rejected.status_code in (409, 422), rejected.text
    assert client.get('/answer-cards', headers=auth(owner)).json() == []
    request['selected_source_ids'] = [CONTROL_ID]
    accepted = client.post('/answer-cards', headers=auth(owner), json=request)
    assert accepted.status_code == 201, accepted.text
    assert_no_quarantined_source(accepted.json()['public_payload'])


def test_archived_database_row_and_personal_memory_survive_but_row_is_not_retrieved(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    memory = save(client, owner, 'Synthetic personal record retained by quarantine')
    with app.state.session_factory() as db:
        seed_resources(db, original_records())  # Simulate an existing older database.
        before = ResourceService._record_from_row(db.get(KnowledgeSource, SOURCE_ID)).model_dump(mode='json')
        seed_resources(db)
        result = ResourceService(embedding_provider=None).search(QUERY, limit=20, db=db)
        assert_no_quarantined_source(result.model_dump(mode='json'))
        after = ResourceService._record_from_row(db.get(KnowledgeSource, SOURCE_ID)).model_dump(mode='json')
        assert after == before == original_source().model_dump(mode='json')
    assert client.get('/memories', headers=auth(owner)).json()[0]['id'] == memory['id']


def test_existing_saved_card_remains_snapshot_but_stale_draft_cannot_retrust_source(setup, monkeypatch):
    app, client, (owner, _, _) = setup
    service = get_default_resource_service()
    active = service.records
    # Build a historical card under the old catalog, without touching real data.
    with monkeypatch.context() as old:
        old.setattr(service, 'records', original_records())
        message = chat_answer(client, owner, QUERY)
        draft = prepared(client, owner, message['id'])
        assert SOURCE_ID in [s['source_id'] for s in draft['public_sources']]
        request = {**body(draft), 'selected_source_ids': [SOURCE_ID]}
        response = client.post('/answer-cards', headers=auth(owner), json=request)
        assert response.status_code == 201, response.text
        saved = response.json()
    assert service.records == active
    fresh = prepared(client, owner, message['id'])
    assert_no_quarantined_source(fresh['public_sources'])
    stale = client.post('/answer-cards', headers=auth(owner),
                        json={**request, 'client_operation_id': 'after-quarantine'})
    assert stale.status_code == 409, stale.text
    assert client.get('/answer-cards/' + saved['id'], headers=auth(owner)).json() == saved


def test_review_status_is_reversible_without_editing_original_evidence(tmp_path):
    raw = DATA_PATH.read_bytes()
    service = ResourceService(embedding_provider=None)
    assert service.raw_records == original_records()
    status = json.loads((DATA_PATH.parent / 'resource_review_status.json').read_text(encoding='utf-8'))
    entry = status['records'][SOURCE_ID]
    assert entry['status'] == 'unverified'
    assert entry['original_evidence'] == {
        'url': original_source().url,
        'claimed_reviewed_at': original_source().verified_at.isoformat(),
        'content_hash': _record_hash(original_source()),
    }
    # A deliberately revised operator policy restores the same record/hash;
    # this proves reversibility, not that the real source has been verified.
    revised = tmp_path / 'revised-review-status.json'
    revised.write_text(json.dumps({'schema_version': 1, 'records': {}}), encoding='utf-8')
    restored = ResourceService(review_status_path=revised, embedding_provider=None)
    assert restored.records == original_records()
    assert DATA_PATH.read_bytes() == raw


@pytest.mark.parametrize('policy', [None, [], {'schema_version': 2, 'records': {}},
    {'schema_version': 1, 'records': {SOURCE_ID: {'status': 'verified'}}}])
def test_missing_or_invalid_policy_cannot_silently_restore_quarantined_source(tmp_path, policy):
    path = tmp_path / 'invalid-policy.json'
    if policy is not None:
        path.write_text(json.dumps(policy), encoding='utf-8')
    with pytest.raises(RuntimeError, match='resource review status'):
        ResourceService(review_status_path=path, embedding_provider=None)
