"""P2 regressions through production chat; synthetic DB and deterministic model only."""
import copy
import logging

import pytest

from app import answer_card_service as public
from app.models import Message
from app.resource_service import get_default_resource_service, _record_hash
from tests.test_memory_controls import setup, auth
from tests.test_answer_cards_private import seed, prepared, body


def chat_answer(client, owner, content='Explain medical fee waiver'):
    conversation = client.post('/conversations', headers=auth(owner), json={'title': 'Synthetic'}).json()
    response = client.post('/conversations/' + conversation['id'] + '/messages', headers=auth(owner),
                           json={'content': content, 'client_message_id': 'synthetic-source-turn'})
    assert response.status_code == 200, response.text
    return response.json()['assistant_message']


@pytest.mark.parametrize('record_id', ['swd-elderly-health-centre-2026', 'mtr-journey-planner',
    'transport-rehabus-2026', 'transport-bus-info-2026', 'dh-health-hotline-2026', 'ha-gopc-registration-2026'])
def test_production_manifest_hosts_and_exact_ha_query_are_carried(setup, record_id):
    _, client, (owner, _, _) = setup
    record = next(r for r in get_default_resource_service().records if r.id == record_id)
    message = chat_answer(client, owner, 'welfare ' + record.search_terms[0])
    assert record_id in [b['source_id'] for b in message['metadata_json']['resource_source_bindings']]
    draft = prepared(client, owner, message['id'])
    sources = [s for s in draft['public_sources'] if s['source_id'] == record_id]
    assert len(sources) == 1, 'Approved manifest source must survive card URL policy'
    assert sources[0]['url'] == record.url
    assert sources[0]['content_hash'] == _record_hash(record)
    request = body(draft)
    request['selected_source_ids'] = [record_id]
    response = client.post('/answer-cards', headers=auth(owner), json=request)
    assert response.status_code == 201, response.text
    assert response.json()['public_payload']['public_sources'] == sources
    assert response.json()['public_payload']['verification_state'] == 'ai_unverified'


@pytest.mark.parametrize('url', ['https://www.ha.org.hk/visitors/ha_visitor_guide.asp?Content_ID=100826&token=private',
    'https://www.ha.org.hk/other?Content_ID=100826', 'https://www.td.gov.hk/?token=private',
    'https://unknown.gov.hk/', 'https://www.mtr.com.hk/#private'])
def test_source_url_policy_rejects_unreviewed_queries_hosts_and_fragments(url):
    from pydantic import ValidationError
    with pytest.raises(ValidationError):
        public.PublicSource(source_id='synthetic', organisation='Synthetic', title='Synthetic',
                            url=url, verification_scope='Synthetic')


def test_current_production_chat_binds_manifest_and_carries_honest_reference(setup):
    app, client, (owner, _, _) = setup
    message = chat_answer(client, owner)
    assert message['metadata_json']['resource_sources']
    bindings = message['metadata_json'].get('resource_source_bindings')
    assert bindings, 'Production chat must persist trusted source version bindings'
    record = next(r for r in get_default_resource_service().records if r.id == bindings[0]['source_id'])
    assert bindings[0]['content_hash'] == _record_hash(record)
    draft = prepared(client, owner, message['id'])
    assert draft['public_sources']
    source = next(s for s in draft['public_sources'] if s['source_id'] == record.id)
    assert source['reviewed_at'] == record.verified_at.isoformat()
    assert source['retrieved_at'] is None
    assert source['content_hash'] == _record_hash(record)
    request = body(draft)
    request['selected_source_ids'] = [source['source_id']]
    response = client.post('/answer-cards', headers=auth(owner), json=request)
    assert response.status_code == 201, response.text
    card = response.json()
    assert card['public_payload']['public_sources'] == [source]
    assert card['public_payload']['verification_state'] == 'ai_unverified'
    assert card['provenance']['origin_hash'] == draft['source_hash']
    # Neither metadata display fields nor private fields supply public provenance.
    with app.state.session_factory() as db:
        row = db.get(Message, message['id'])
        metadata = copy.deepcopy(row.metadata_json)
        for ref in metadata['resource_sources'] + metadata['resource_source_bindings']:
            ref.update(title='PRIVATE_SYNTHETIC', url='https://evil.test/', reviewed_at='2099-01-01')
        row.metadata_json = metadata
        db.commit()
    assert prepared(client, owner, message['id']) == draft
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).json() == card


def test_source_version_change_between_prepare_and_create_is_conflict(setup):
    app, client, (owner, _, _) = setup
    message = chat_answer(client, owner)
    draft = prepared(client, owner, message['id'])
    assert draft['public_sources']
    with app.state.session_factory() as db:
        row = db.get(Message, message['id'])
        metadata = copy.deepcopy(row.metadata_json)
        metadata['resource_source_bindings'] = []
        row.metadata_json = metadata
        db.commit()
    response = client.post('/answer-cards', headers=auth(owner), json=body(draft))
    assert response.status_code == 409
    assert client.get('/answer-cards', headers=auth(owner)).json() == []


def test_unversioned_legacy_resource_does_not_invent_current_dates(setup):
    _, client, (owner, _, _) = setup
    record = get_default_resource_service().records[0].model_dump(mode='json')
    message_id = seed(setup[0], owner, metadata={'resource_sources': [record]})
    assert prepared(client, owner, message_id)['public_sources'] == []


def test_manifest_refresh_never_redates_saved_card_or_accepts_stale_draft(setup, monkeypatch):
    _, client, (owner, _, _) = setup
    message = chat_answer(client, owner)
    draft = prepared(client, owner, message['id'])
    assert draft['public_sources']
    request = body(draft)
    request['selected_source_ids'] = [s['source_id'] for s in draft['public_sources']]
    response = client.post('/answer-cards', headers=auth(owner), json=request)
    assert response.status_code == 201
    card = response.json()
    service = get_default_resource_service()
    from datetime import date
    monkeypatch.setattr(service, 'records', tuple(
        r.model_copy(update={'verified_at': date(2099, 1, 1)}) for r in service.records))
    # The old version cannot be resolved against a new manifest, so it is
    # omitted rather than silently acquiring today's/new dates.
    fresh = prepared(client, owner, message['id'])
    assert fresh['public_sources'] == []
    assert fresh['source_hash'] != draft['source_hash']
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).json() == card
    stale = client.post('/answer-cards', headers=auth(owner), json={**request, 'client_operation_id': 'stale-manifest'})
    assert stale.status_code == 409


@pytest.mark.parametrize('binding', [{'source_id': 'ha-medical-fee-waiver', 'content_hash': 'a' * 64},
                                    {'source_id': 'unknown', 'content_hash': 'a' * 64}])
def test_unknown_or_wrong_resource_version_cannot_contribute_metadata(setup, binding):
    app, client, (owner, _, _) = setup
    binding = {**binding, 'title': 'PRIVATE_SYNTHETIC', 'url': 'https://www.ha.org.hk/',
               'reviewed_at': '2099-01-01', 'private': {'income': 'PRIVATE_SYNTHETIC'}}
    message_id = seed(app, owner, metadata={'resource_source_bindings': [binding]})
    assert prepared(client, owner, message_id)['public_sources'] == []


@pytest.mark.parametrize('action', ['prepare', 'create'])
@pytest.mark.parametrize('bound', [False, True])
@pytest.mark.parametrize('failure', [ValueError, OSError])
def test_catalog_fault_is_neutral_and_private_diagnostics_are_not_logged(setup, monkeypatch, caplog, action, bound, failure):
    app, client, (owner, _, _) = setup
    source = public.templates()[0]['public_payload']['public_sources'][0]
    refs = [{'source_id': source['source_id'], 'content_hash': source['content_hash']}] if bound else []
    message_id = seed(app, owner, metadata={'resource_sources': refs})
    draft = prepared(client, owner, message_id)
    def unavailable():
        raise failure('PRIVATE_CATALOG_DIAGNOSTIC')
    monkeypatch.setattr(public, 'templates', unavailable)
    with caplog.at_level(logging.ERROR):
        response = (client.post('/answer-cards/prepare', headers=auth(owner), json={'source_message_id': message_id})
                    if action == 'prepare' else client.post('/answer-cards', headers=auth(owner), json=body(draft)))
    assert response.status_code == (503 if bound else (200 if action == 'prepare' else 201)), response.text
    assert 'PRIVATE_CATALOG_DIAGNOSTIC' not in response.text + caplog.text
    if bound:
        assert response.json() == {'detail': 'Answer sources are unavailable'}
        assert 'answer_card_catalog_unavailable' in caplog.text


def test_unexpected_programming_error_is_not_swallowed(setup, monkeypatch):
    app, client, (owner, _, _) = setup
    source = public.templates()[0]['public_payload']['public_sources'][0]
    message_id = seed(app, owner, metadata={'resource_sources': [source]})
    def bug():
        raise TypeError('Synthetic programming defect')
    monkeypatch.setattr(public, 'templates', bug)
    assert client.post('/answer-cards/prepare', headers=auth(owner), json={'source_message_id': message_id}).status_code == 500
