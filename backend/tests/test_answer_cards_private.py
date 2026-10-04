"""Synthetic private AnswerCard contracts: no models/providers or real DB."""
import hashlib
import json

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, text

from app.main import create_app
from app.models import Conversation, Message
from tests.test_memory_controls import setup, auth, state

PRIVATE = 'UNSELECTED_PRIVATE_INCOME_AND_MEDICAL_20261004'
REDACTED = 'REMOVED_FROM_SELECTED_PARAGRAPH_20261004'


def seed(app, owner, role='assistant', metadata=None):
    with app.state.session_factory() as db:
        conversation = Conversation(owner_id=owner['account']['id'], title='Private conversation title')
        db.add(conversation); db.flush()
        message = Message(conversation_id=conversation.id, role=role,
                          content='Useful public explanation\n\n' + PRIVATE + '\n\n' + REDACTED,
                          metadata_json=metadata or {'mode': 'deterministic_demo',
                              'memory_sources': [{'content': PRIVATE}], 'token': PRIVATE}, ordinal=2)
        db.add(message); db.commit()
        return message.id


def prepare(client, owner, message_id):
    return client.post('/answer-cards/prepare', headers=auth(owner), json={'source_message_id': message_id})


def prepared(client, owner, message_id):
    response = prepare(client, owner, message_id)
    assert response.status_code == 200, response.text
    return response.json()


def body(draft, key='create-key', edited=False):
    return {'origin': {'message_id': draft['source_message_id'], 'source_hash': draft['source_hash']},
            'selected_sections': [{'id': draft['sections'][2 if edited else 0]['id'],
                                   **({'edited_text': 'Safe rewritten explanation'} if edited else {})}],
            'title': 'Private saved answer', 'selected_source_ids': [], 'client_operation_id': key}


def saved(client, owner, draft, key='create-key', edited=False):
    response = client.post('/answer-cards', headers=auth(owner), json=body(draft, key, edited))
    assert response.status_code == 201, response.text
    return response.json()


def edit_body(card, key='edit-key', **changes):
    payload = card['public_payload']
    return {'title': payload['title'], 'selected_sections': payload['selected_sections'],
            'official_terms': payload['official_terms'], 'missing_information': payload['missing_information'],
            'next_steps': payload['next_steps'],
            'selected_source_ids': [source['source_id'] for source in payload['public_sources']],
            'expected_version': card['version'], 'client_operation_id': key, **changes}


def edit(client, owner, card, **changes):
    return client.patch('/answer-cards/' + card['id'], headers=auth(owner), json=edit_body(card, **changes))


def delete(client, owner, card, key='delete-key'):
    return client.request('DELETE', '/answer-cards/' + card['id'], headers=auth(owner),
                          json={'expected_version': card['version'], 'client_operation_id': key})


def test_prepare_cancel_has_zero_card_or_operation_writes_and_zero_defaults(setup):
    app, client, (owner, _, _) = setup
    message_id = seed(app, owner)
    revision = state(client, owner)['revision']
    draft = prepared(client, owner, message_id)
    assert draft['selected_sections'] == [] and draft['selected_source_ids'] == []
    assert draft['source_hash'] == hashlib.sha256(draft['original_text'].encode()).hexdigest()
    assert draft['public_sources'] == [] and PRIVATE in draft['original_text']
    assert client.get('/answer-cards', headers=auth(owner)).json() == []
    from app.answer_card_models import AnswerCard, AnswerCardOperation
    with app.state.session_factory() as db:
        assert list(db.scalars(select(AnswerCard))) == []
        assert list(db.scalars(select(AnswerCardOperation))) == []
    assert state(client, owner)['revision'] == revision


@pytest.mark.parametrize('kind,expected', [('user', 404), ('pending', 409), ('foreign', 404), ('unknown', 404), ('anonymous', 401)])
def test_only_owned_completed_assistant_can_prepare(setup, kind, expected):
    app, client, (owner, other, _) = setup
    message_id = seed(app, other if kind == 'foreign' else owner,
                      role='user' if kind == 'user' else 'assistant',
                      metadata={'status': 'pending'} if kind == 'pending' else None)
    if kind == 'unknown': message_id = 'missing'
    response = (client.post('/answer-cards/prepare', json={'source_message_id': message_id})
                if kind == 'anonymous' else prepare(client, owner, message_id))
    assert response.status_code == expected, response.text
    assert PRIVATE not in response.text


@pytest.mark.parametrize('edited', [False, True])
def test_save_only_selected_final_text_no_hidden_original_or_metadata(setup, edited):
    app, client, (owner, _, _) = setup
    draft = prepared(client, owner, seed(app, owner))
    before_revision = state(client, owner)['revision']
    card = saved(client, owner, draft, edited=edited)
    assert card['mode'] == 'assistant_answer' and card['version'] == 1
    assert card['public_payload']['selected_sections'] == [
        'Safe rewritten explanation' if edited else 'Useful public explanation']
    for field in ('official_terms', 'missing_information', 'next_steps', 'public_sources'):
        assert card['public_payload'][field] == []
    assert card['public_payload']['verification_state'] == 'no_verified_source'
    assert PRIVATE not in json.dumps(card) and REDACTED not in json.dumps(card)
    from app.answer_card_models import AnswerCard, AnswerCardOperation
    with app.state.session_factory() as db:
        row = db.get(AnswerCard, card['id'])
        values = {column.name: getattr(row, column.key) for column in row.__table__.columns}
        assert PRIVATE not in repr(values) and REDACTED not in repr(values)
        operations = list(db.scalars(select(AnswerCardOperation)))
        assert len(operations) == 1
        assert PRIVATE not in repr(operations[0].__dict__) and 'Useful public explanation' not in repr(operations[0].__dict__)
    assert state(client, owner)['revision'] == before_revision


@pytest.mark.parametrize('change,expected', [('changed', 409), ('deleted', 404), ('role', 404), ('owner', 404)])
def test_create_rechecks_source_hash_role_and_owner(setup, change, expected):
    app, client, (owner, other, _) = setup
    message_id = seed(app, owner); draft = prepared(client, owner, message_id)
    with app.state.session_factory() as db:
        message = db.get(Message, message_id)
        if change == 'changed': message.content += '\nChanged since preview'
        if change == 'deleted': db.delete(message)
        if change == 'role': message.role = 'user'
        if change == 'owner': db.get(Conversation, message.conversation_id).owner_id = other['account']['id']
        db.commit()
    response = client.post('/answer-cards', headers=auth(owner), json=body(draft))
    assert response.status_code == expected, response.text
    assert client.get('/answer-cards', headers=auth(owner)).json() == []


@pytest.mark.parametrize('field,value', [('public_sources', []), ('verification_state', 'reviewed_public_guidance'),
    ('reviewed_at', '2099-01-01'), ('metadata', {'token': PRIVATE}), ('owner_id', 'foreign'),
    ('memory_ids', ['private']), ('source_message_id', 'other'), ('selected_source_ids', ['forged-source'])])
def test_create_rejects_client_forged_source_status_dates_private_fields(setup, field, value):
    app, client, (owner, _, _) = setup
    draft = prepared(client, owner, seed(app, owner))
    response = client.post('/answer-cards', headers=auth(owner), json={**body(draft), field: value})
    assert response.status_code == 422, response.text
    assert client.get('/answer-cards', headers=auth(owner)).json() == []


@pytest.mark.parametrize('bad', ['unknown-section', 'duplicate', 'empty'])
def test_create_requires_explicit_valid_unique_selection(setup, bad):
    app, client, (owner, _, _) = setup
    draft = prepared(client, owner, seed(app, owner)); payload = body(draft)
    if bad == 'unknown-section': payload['selected_sections'] = [{'id': 'forged:0'}]
    if bad == 'duplicate': payload['selected_sections'] *= 2
    if bad == 'empty': payload['selected_sections'] = []
    response = client.post('/answer-cards', headers=auth(owner), json=payload)
    assert response.status_code == 422, response.text


def test_owner_list_get_isolated_and_caregiver_can_manage_own_card(setup):
    app, client, (owner, other, caregiver) = setup
    card = saved(client, owner, prepared(client, owner, seed(app, owner)))
    assert client.get('/answer-cards/' + card['id'], headers=auth(other)).status_code == 404
    assert client.get('/answer-cards', headers=auth(other)).json() == []
    assert client.patch('/answer-cards/' + card['id'], headers=auth(other), json=edit_body(card)).status_code == 404
    assert delete(client, other, card).status_code == 404
    assert client.get('/answer-cards').status_code == 401
    own = saved(client, caregiver, prepared(client, caregiver, seed(app, caregiver)))
    assert client.get('/answer-cards/' + own['id'], headers=auth(caregiver)).status_code == 200
    assert edit(client, caregiver, own).status_code == 200


def test_create_retry_same_key_one_card_changed_body_conflicts(setup):
    app, client, (owner, _, _) = setup
    draft = prepared(client, owner, seed(app, owner)); card = saved(client, owner, draft)
    retry = client.post('/answer-cards', headers=auth(owner), json=body(draft))
    assert retry.status_code == 201 and retry.json()['id'] == card['id']
    conflict = client.post('/answer-cards', headers=auth(owner), json={**body(draft), 'title': 'Different'})
    assert conflict.status_code == 409
    assert len(client.get('/answer-cards', headers=auth(owner)).json()) == 1


@pytest.mark.parametrize('bad', ['missing-version', 'stale-version', 'missing-key', 'extra-provenance'])
def test_patch_requires_original_version_key_and_strict_fields(setup, bad):
    app, client, (owner, _, _) = setup
    card = saved(client, owner, prepared(client, owner, seed(app, owner)))
    payload = edit_body(card)
    expected = 422
    if bad == 'missing-version': payload.pop('expected_version')
    if bad == 'stale-version':
        assert edit(client, owner, card, key='advance-before-stale').status_code == 200
        expected = 409
    if bad == 'missing-key': payload.pop('client_operation_id')
    if bad == 'extra-provenance': payload['origin_message_id'] = 'forged'
    response = client.patch('/answer-cards/' + card['id'], headers=auth(owner), json=payload)
    assert response.status_code == expected
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).json()['version'] == (2 if bad == 'stale-version' else 1)


@pytest.mark.parametrize('version', [0, -1, True, '1'])
def test_patch_and_delete_require_strict_positive_versions(setup, version):
    app, client, (owner, _, _) = setup
    card = saved(client, owner, prepared(client, owner, seed(app, owner)))
    response = edit(client, owner, card, expected_version=version)
    assert response.status_code == 422, response.text
    response = client.request('DELETE', '/answer-cards/' + card['id'], headers=auth(owner),
        json={'expected_version': version, 'client_operation_id': 'invalid-delete-version'})
    assert response.status_code == 422, response.text
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).json()['version'] == 1


@pytest.mark.parametrize('target', ['origin', 'section', 'both-origins', 'null-next-steps'])
def test_create_rejects_nested_extras_ambiguous_origin_and_null_arrays(setup, target):
    app, client, (owner, _, _) = setup
    draft = prepared(client, owner, seed(app, owner)); payload = body(draft)
    if target == 'origin': payload['origin']['metadata'] = {'token': PRIVATE}
    if target == 'section': payload['selected_sections'][0]['original_text'] = PRIVATE
    if target == 'both-origins': payload['origin'].update(template_id='other', template_version=1, template_hash='a'*64)
    if target == 'null-next-steps': payload['next_steps'] = None
    response = client.post('/answer-cards', headers=auth(owner), json=payload)
    assert response.status_code == 422, response.text
    assert client.get('/answer-cards', headers=auth(owner)).json() == []


def test_template_hash_rejects_changed_content_at_same_version(setup, monkeypatch):
    _, client, (owner, _, _) = setup
    response = client.get('/answer-card-templates'); assert response.status_code == 200
    template = response.json()[0]
    payload = {'origin': {field: template[field] for field in ('template_id', 'template_version', 'template_hash')},
        'title': template['public_payload']['title'],
        'selected_sections': [{'id': section['id']} for section in template['sections']],
        'selected_source_ids': [], 'client_operation_id': 'changed-template'}
    from app import answer_card_service
    original = answer_card_service.templates
    def changed():
        rows = original()
        rows[0]['sections'][0]['text'] = 'Changed template under old version'
        rows[0]['public_payload']['selected_sections'] = ['Changed template under old version']
        rows[0]['template_hash'] = answer_card_service.payload_hash({key: rows[0][key] for key in
            ('template_id', 'template_version', 'sections', 'public_payload')})
        return rows
    monkeypatch.setattr(answer_card_service, 'templates', changed)
    response = client.post('/answer-cards', headers=auth(owner), json=payload)
    assert response.status_code == 409, response.text
    assert client.get('/answer-cards', headers=auth(owner)).json() == []


def test_prepare_rebuilds_canonical_sources_and_never_trusts_metadata_personal_fields(setup):
    app, client, (owner, _, _) = setup
    from app import answer_card_service
    source = answer_card_service.templates()[0]['public_payload']['public_sources'][0]
    metadata = {'resource_sources': [{**source, 'url': 'https://evil.test/?token=' + PRIVATE,
                                    'title': PRIVATE, 'reviewed_at': '2099-01-01'}],
                'memory_sources': [{'content': PRIVATE}], 'next_steps': [PRIVATE]}
    draft = prepared(client, owner, seed(app, owner, metadata=metadata))
    assert draft['public_sources'] == [source]
    payload = {**body(draft), 'selected_source_ids': [source['source_id']]}
    response = client.post('/answer-cards', headers=auth(owner), json=payload)
    assert response.status_code == 201, response.text
    public = response.json()['public_payload']
    assert public['public_sources'] == [source] and public['verification_state'] == 'ai_unverified'
    assert public['official_terms'] == public['missing_information'] == public['next_steps'] == []
    assert PRIVATE not in json.dumps(public)


def test_mutation_failure_rolls_back_card_body_version_and_operation_receipt(setup):
    app, client, (owner, _, _) = setup
    from sqlalchemy import event
    card = saved(client, owner, prepared(client, owner, seed(app, owner)))
    def fail(conn, cursor, statement, parameters, context, executemany):
        if statement.upper().startswith('INSERT INTO ANSWER_CARD_OPERATIONS '):
            raise RuntimeError('Synthetic failure after operation INSERT')
    event.listen(app.state.engine, 'after_cursor_execute', fail)
    try:
        assert edit(client, owner, card, selected_sections=['New body']).status_code == 500
    finally:
        event.remove(app.state.engine, 'after_cursor_execute', fail)
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).json() == card
    assert edit(client, owner, card, selected_sections=['New body']).status_code == 200


@pytest.mark.parametrize('metadata', [{'status': 'unknown'}, {'status': []}, {'pending': 'false'},
    {'completed': 'true'}, {'mode': 'unknown-provider'}, {'status': 'ready', 'completed': False}])
def test_prepare_explicit_malformed_or_unknown_completion_fails_closed(setup, metadata):
    app, client, (owner, _, _) = setup
    response = prepare(client, owner, seed(app, owner, metadata=metadata))
    assert response.status_code == 409, response.text


def test_saved_card_is_independent_of_later_original_conversation_delete(setup):
    app, client, (owner, _, _) = setup
    message_id = seed(app, owner)
    card = saved(client, owner, prepared(client, owner, message_id))
    with app.state.session_factory() as db:
        message = db.get(Message, message_id)
        db.delete(db.get(Conversation, message.conversation_id)); db.commit()
    response = client.get('/answer-cards/' + card['id'], headers=auth(owner))
    assert response.status_code == 200 and response.json() == card


def test_same_text_patch_increments_and_retry_cannot_rewrite_new_version(setup):
    app, client, (owner, _, _) = setup
    card = saved(client, owner, prepared(client, owner, seed(app, owner)))
    first = edit(client, owner, card)
    assert first.status_code == 200 and first.json()['version'] == 2
    retry = edit(client, owner, card)
    assert retry.status_code == 200 and retry.json()['version'] == 2
    second = edit(client, owner, first.json(), key='second-edit', selected_sections=['Different final text'])
    assert second.status_code == 200 and second.json()['version'] == 3
    assert edit(client, owner, card).status_code == 409
    current = client.get('/answer-cards/' + card['id'], headers=auth(owner)).json()
    assert current['version'] == 3 and current['public_payload']['selected_sections'] == ['Different final text']
    assert PRIVATE not in json.dumps(current) and REDACTED not in json.dumps(current)


def test_delete_scrubs_body_provenance_terminal_operations_survive_restart(setup):
    app, client, (owner, _, _) = setup
    draft = prepared(client, owner, seed(app, owner)); card = saved(client, owner, draft)
    edited = edit(client, owner, card).json()
    removed = delete(client, owner, edited)
    assert removed.status_code == 200 and removed.json()['deleted'] is True
    assert delete(client, owner, edited).json() == removed.json()
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).status_code == 404
    assert client.post('/answer-cards', headers=auth(owner), json=body(draft)).status_code == 410
    assert edit(client, owner, card).status_code == 410
    from app.answer_card_models import AnswerCard
    with app.state.session_factory() as db:
        row = db.get(AnswerCard, card['id'])
        values = {column.name: getattr(row, column.key) for column in row.__table__.columns}
        assert 'Useful public explanation' not in repr(values)
        assert draft['source_message_id'] not in repr(values) and draft['source_hash'] not in repr(values)
        assert row.deleted_at is not None
    restarted = create_app(app.state.settings)
    with TestClient(restarted, raise_server_exceptions=False) as after:
        assert delete(after, owner, edited).json() == removed.json()
        assert after.post('/answer-cards', headers=auth(owner), json=body(draft)).status_code == 410


def test_template_create_original_source_dates_edits_demote_without_date_refresh(setup):
    _, client, (owner, _, _) = setup
    response = client.get('/answer-card-templates')
    assert response.status_code == 200
    template = response.json()[0]; public = template['public_payload']
    payload = {'origin': {'template_id': template['template_id'], 'template_version': template['template_version'],
                          'template_hash': template['template_hash']},
               'selected_sections': [{'id': item['id']} for item in template['sections']],
               'selected_source_ids': [item['source_id'] for item in public['public_sources']],
               'title': public['title'], 'client_operation_id': 'template-create'}
    response = client.post('/answer-cards', headers=auth(owner), json=payload)
    assert response.status_code == 201, response.text
    card = response.json()
    assert card['public_payload'] == public
    changed = edit(client, owner, card, selected_sections=['Edited template explanation'])
    assert changed.status_code == 200
    assert changed.json()['public_payload']['verification_state'] == 'user_edited_unverified'
    assert changed.json()['public_payload']['public_sources'] == public['public_sources']
    absent = edit(client, owner, changed.json(), key='remove-sources', selected_source_ids=[])
    assert absent.status_code == 200 and absent.json()['public_payload']['verification_state'] == 'no_verified_source'


def test_purge_helper_uses_caller_transaction_and_rolls_back(setup):
    app, client, (owner, other, _) = setup
    card = saved(client, owner, prepared(client, owner, seed(app, owner)))
    foreign = saved(client, other, prepared(client, other, seed(app, other)))
    from app.answer_card_private_service import purge_answer_cards
    from app.answer_card_models import AnswerCard
    with app.state.session_factory() as db:
        assert purge_answer_cards(db, owner['account']['id']) == 1
        db.flush()
        assert db.get(AnswerCard, card['id']).deleted_at is not None
        db.rollback()
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).status_code == 200
    with app.state.session_factory() as db:
        assert purge_answer_cards(db, owner['account']['id']) == 1
        db.commit()
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).status_code == 404
    assert client.get('/answer-cards/' + foreign['id'], headers=auth(other)).status_code == 200


def test_missing_schema_fails_closed_with_503(setup):
    app, client, (owner, _, _) = setup
    prepared(client, owner, seed(app, owner))
    with app.state.engine.begin() as connection:
        connection.execute(text('DROP TABLE answer_card_operations'))
    response = client.get('/answer-cards', headers=auth(owner))
    assert response.status_code == 503, response.text


def test_unavailable_templates_return_neutral_503_without_private_diagnostics(setup, monkeypatch):
    _, client, _ = setup
    from app import answer_card_service
    def unavailable():
        raise ValueError(PRIVATE)
    monkeypatch.setattr(answer_card_service, 'templates', unavailable)
    response = client.get('/answer-card-templates')
    assert response.status_code == 503 and PRIVATE not in response.text


def test_corrupt_stored_public_payload_fails_closed_503(setup):
    app, client, (owner, _, _) = setup
    card = saved(client, owner, prepared(client, owner, seed(app, owner)))
    from app.answer_card_models import AnswerCard
    with app.state.session_factory() as db:
        db.get(AnswerCard, card['id']).public_payload = {'metadata': PRIVATE}
        db.commit()
    response = client.get('/answer-cards/' + card['id'], headers=auth(owner))
    assert response.status_code == 503 and PRIVATE not in response.text
    response = client.get('/answer-cards', headers=auth(owner))
    assert response.status_code == 503 and PRIVATE not in response.text


def test_template_operation_hash_distinguishes_omitted_and_explicitly_cleared_fields(setup):
    _, client, (owner, _, _) = setup
    template = client.get('/answer-card-templates').json()[0]
    payload = {'origin': {field: template[field] for field in ('template_id', 'template_version', 'template_hash')},
        'title': template['public_payload']['title'],
        'selected_sections': [{'id': section['id']} for section in template['sections']],
        'selected_source_ids': [source['source_id'] for source in template['public_payload']['public_sources']],
        'client_operation_id': 'optional-field-key'}
    first = client.post('/answer-cards', headers=auth(owner), json=payload)
    assert first.status_code == 201 and first.json()['public_payload']['next_steps']
    changed_request = client.post('/answer-cards', headers=auth(owner), json={**payload, 'next_steps': []})
    assert changed_request.status_code == 409
    assert client.get('/answer-cards/' + first.json()['id'], headers=auth(owner)).json() == first.json()


@pytest.mark.parametrize('field', ['official_terms', 'missing_information', 'next_steps', 'selected_source_ids'])
def test_patch_requires_complete_explicit_display_snapshot(setup, field):
    app, client, (owner, _, _) = setup
    card = saved(client, owner, prepared(client, owner, seed(app, owner)))
    payload = edit_body(card); payload.pop(field)
    response = client.patch('/answer-cards/' + card['id'], headers=auth(owner), json=payload)
    assert response.status_code == 422, response.text
    assert client.get('/answer-cards/' + card['id'], headers=auth(owner)).json() == card
