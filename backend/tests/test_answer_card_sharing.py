"""Single-card family sharing: synthetic SQLite and existing family consent routes."""
import copy
from concurrent.futures import ThreadPoolExecutor
from threading import Event

import pytest
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from app.models import FamilyLink
from tests.test_family_requests import requests, create_request, decision
from tests.test_family_messages import link_accounts
from tests.test_family_blocks import block, unblock
from tests.test_integration import _headers as auth
from tests.test_answer_cards_private import seed, prepared, body


SHARE_FIELDS = {'id', 'mode', 'card_version', 'sender_id', 'recipient_id', 'link_id', 'link_epoch',
                'public_payload', 'public_payload_hash', 'created_at'}


def card(app, client, owner, mode='ai', key='card-one'):
    if mode == 'ai':
        payload = body(prepared(client, owner, seed(app, owner)), key=key)
    else:
        template = client.get('/answer-card-templates').json()[0]
        base = template['public_payload']
        payload = {'origin': {k: template[k] for k in ('template_id', 'template_version', 'template_hash')},
            'title': base['title'], 'selected_sections': [{'id': s['id']} for s in template['sections']],
            'selected_source_ids': [s['source_id'] for s in base['public_sources']], 'client_operation_id': key}
    response = client.post('/answer-cards', headers=auth(owner), json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def preview(c, recipient, link, key='share-one', ack=True):
    return {'expected_version': c['version'], 'previewed_payload_hash': c['public_payload_hash'],
        'recipient_id': recipient['account']['id'], 'expected_link_id': link['id'],
        'expected_link_epoch': link['authorization_epoch'], 'client_share_id': key, 'personal_review_ack': ack}


def send(client, elder, c, payload):
    return client.post('/answer-cards/' + c['id'] + '/shares', headers=auth(elder), json=payload)


def inbox(client, child):
    response = client.get('/answer-card-shares/inbox', headers=auth(child))
    assert response.status_code == 200, response.text
    return response.json()


def sent(client, elder):
    response = client.get('/answer-card-shares/sent', headers=auth(elder))
    assert response.status_code == 200, response.text
    return response.json()


def patch(client, owner, c, key='edit-card'):
    base = c['public_payload']
    return client.patch('/answer-cards/' + c['id'], headers=auth(owner), json={
        **{k: base[k] for k in ('title', 'selected_sections', 'official_terms', 'missing_information', 'next_steps')},
        'selected_source_ids': [s['source_id'] for s in base['public_sources']],
        'expected_version': c['version'], 'client_operation_id': key})


def change_scopes(client, elder, child, scopes):
    invitation = client.post('/family-links/invitations', headers=auth(elder), json={
        'email': child['account']['email'], 'scopes': scopes})
    assert invitation.status_code == 201
    return client.post('/family-links/invitations/accept', headers=auth(child),
        json={'token': invitation.json()['token']})


@pytest.fixture
def connected(requests):
    app, client, elder, child, other_elder, other_child = requests
    link = link_accounts(client, elder, child, ['family_messages'])
    c = card(app, client, elder)
    return app, client, elder, child, other_elder, other_child, link, c


def test_share_server_snapshot_closed_dto_and_private_card_isolation(connected):
    app, client, elder, child, other_elder, other_child, link, c = connected
    result = send(client, elder, c, preview(c, child, link))
    assert result.status_code == 201, result.text
    shared = result.json()
    assert set(shared) == SHARE_FIELDS
    assert shared['public_payload'] == c['public_payload']
    assert shared['public_payload_hash'] == c['public_payload_hash']
    assert shared['mode'] == c['mode']
    assert shared['recipient_id'] == child['account']['id']
    assert inbox(client, child) == [shared]
    assert inbox(client, other_child) == []
    assert client.get('/answer-cards', headers=auth(child)).json() == []
    assert client.get('/answer-cards/' + c['id'], headers=auth(child)).status_code == 404
    assert not any(key in shared for key in ('provenance', 'origin_hash', 'card_id', 'client_share_id'))


@pytest.mark.parametrize('field', ['expected_version', 'previewed_payload_hash', 'recipient_id',
    'expected_link_id', 'expected_link_epoch', 'client_share_id', 'personal_review_ack'])
def test_all_captured_preview_fields_are_required(connected, field):
    _, client, elder, child, _, _, link, c = connected
    payload = preview(c, child, link)
    payload.pop(field)
    assert send(client, elder, c, payload).status_code == 422
    assert inbox(client, child) == []


@pytest.mark.parametrize('change,code', [({'content': 'forged'}, 422), ({'public_payload': {}}, 422),
    ({'expected_version': True}, 422), ({'expected_link_epoch': '1'}, 422),
    ({'personal_review_ack': False}, 422), ({'expected_version': 2}, 409),
    ({'previewed_payload_hash': 'a' * 64}, 409), ({'expected_link_id': 'different'}, 409),
    ({'expected_link_epoch': 2}, 409), ({'recipient_id': 'missing-account'}, 403)])
def test_strict_request_server_payload_and_exact_binding(connected, change, code):
    _, client, elder, child, _, _, link, c = connected
    assert send(client, elder, c, {**preview(c, child, link), **change}).status_code == code
    assert inbox(client, child) == []


def test_share_key_is_independent_idempotent_and_never_replays_changed_request(connected):
    _, client, elder, child, _, _, link, c = connected
    payload = preview(c, child, link, key='card-one')  # same as CRUD key, independent namespace
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: send(client, elder, c, payload), range(2)))
    assert [r.status_code for r in results] == [201, 201]
    assert results[0].json() == results[1].json()
    assert len(inbox(client, child)) == 1
    assert send(client, elder, c, {**payload, 'expected_version': 2}).status_code == 409


@pytest.mark.parametrize('mode', ['ai', 'template'])
def test_unknown_unsent_old_epoch_key_cannot_acquire_reconnected_authorization(connected, mode):
    app, client, elder, child, _, _, link, c = connected
    if mode == 'template':
        c = card(app, client, elder, mode, key='template-one')
    old = preview(c, child, link, key='never-delivered')
    assert block(client, elder, child, link_id=link['id']).status_code == 200
    assert unblock(client, elder, child).status_code == 200
    request = create_request(client, child, elder, key='new-approval')
    renewed = decision(client, elder, request['id'], scopes=['family_messages']).json()
    assert renewed['authorization_epoch'] > link['authorization_epoch']
    assert send(client, elder, c, old).status_code == 409
    assert inbox(client, child) == []
    assert send(client, elder, c, preview(c, child, renewed, key='fresh-explicit-preview')).status_code == 201


@pytest.mark.parametrize('action', ['edit', 'delete', 'block', 'remove_scope', 'remove_link'])
@pytest.mark.parametrize('order', ['share_first', 'change_first'])
def test_share_and_authorization_mutations_both_orders(connected, action, order):
    _, client, elder, child, _, _, link, c = connected
    payload = preview(c, child, link)
    if order == 'share_first':
        assert send(client, elder, c, payload).status_code == 201
    if action == 'edit':
        changed = patch(client, elder, c)
    elif action == 'delete':
        changed = client.request('DELETE', '/answer-cards/' + c['id'], headers=auth(elder),
            json={'expected_version': 1, 'client_operation_id': 'delete-card'})
    elif action == 'block':
        changed = block(client, elder, child, link_id=link['id'])
    elif action == 'remove_scope':
        changed = change_scopes(client, elder, child, ['care_tasks'])
    else:
        changed = client.post('/family-links/' + link['id'] + '/revoke', headers=auth(elder))
    assert changed.status_code == (201 if action == 'remove_scope' else 200), changed.text
    assert inbox(client, child) == []
    retry = send(client, elder, c, payload)
    if order == 'share_first':
        assert retry.status_code == 410
        history = sent(client, elder)[0]
        assert history['access_revoked_at'] is not None
        assert history['public_payload'] == (None if action == 'delete' else c['public_payload'])
    else:
        assert retry.status_code in (403, 404, 409)


def test_revoke_sender_only_idempotent_and_old_key_permanently_gone(connected):
    _, client, elder, child, other_elder, _, link, c = connected
    payload = preview(c, child, link)
    result = send(client, elder, c, payload)
    assert result.status_code == 201
    share_id = result.json()['id']
    url = '/answer-card-shares/' + share_id + '/revoke'
    assert client.post(url, headers=auth(child), json={}).status_code == 404
    first = client.post(url, headers=auth(elder), json={})
    assert first.status_code == 200 and first.json() == {'id': share_id, 'revoked': True}
    assert client.post(url, headers=auth(elder), json={}).json() == first.json()
    assert inbox(client, child) == []
    assert send(client, elder, c, payload).status_code == 410
    assert send(client, elder, c, {**payload, 'personal_review_ack': False}).status_code == 409
    assert client.get('/answer-cards/' + c['id'], headers=auth(elder)).status_code == 200


def test_scope_restoration_does_not_restore_snapshot_and_other_pair_is_unchanged(connected):
    app, client, elder, child, _, other_child, link, c = connected
    other_link = link_accounts(client, elder, other_child, ['family_messages'])
    for who, current, key in [(child, link, 'first-pair'), (other_child, other_link, 'other-pair')]:
        assert send(client, elder, c, preview(c, who, current, key)).status_code == 201
    assert change_scopes(client, elder, child, ['care_tasks']).status_code == 201
    restored = change_scopes(client, elder, child, ['family_messages'])
    assert restored.status_code == 201, restored.text
    assert inbox(client, child) == []
    assert len(inbox(client, other_child)) == 1
    assert send(client, elder, c, preview(c, child, restored.json(), 'explicit-new-share')).status_code == 201


def test_caregiver_own_card_exportable_but_reverse_share_forbidden(connected):
    app, client, elder, child, _, _, link, c = connected
    own = card(app, client, child, key='caregiver-own')
    assert send(client, child, own, preview(own, elder, link)).status_code == 403
    assert send(client, child, c, preview(c, elder, link)).status_code == 404


def test_delete_scrubs_snapshot_and_receipt_has_no_private_body(connected):
    app, client, elder, child, _, _, link, c = connected
    result = send(client, elder, c, preview(c, child, link))
    assert result.status_code == 201
    assert client.request('DELETE', '/answer-cards/' + c['id'], headers=auth(elder),
        json={'expected_version': 1, 'client_operation_id': 'scrub-delete'}).status_code == 200
    from app.answer_card_models import AnswerCardShare
    with app.state.session_factory() as db:
        row = db.get(AnswerCardShare, result.json()['id'])
        assert row.public_payload == {} and row.access_revoked_at is not None
        assert all(c['public_payload']['selected_sections'][0] not in repr(getattr(row, column.key))
                   for column in row.__table__.columns)


@pytest.mark.parametrize('action', ['edit', 'delete', 'block'])
def test_failure_after_withdrawal_rolls_back_card_share_and_authorization(connected, monkeypatch, action):
    app, client, elder, child, _, _, link, c = connected
    assert send(client, elder, c, preview(c, child, link)).status_code == 201
    from app import answer_card_share_service as service
    original = service.withdraw_answer_card_shares
    def fail_after(*args, **kwargs):
        original(*args, **kwargs)
        raise RuntimeError('Synthetic withdrawal failure')
    monkeypatch.setattr(service, 'withdraw_answer_card_shares', fail_after)
    with pytest.raises(RuntimeError, match='Synthetic withdrawal failure'):
        if action == 'edit':
            patch(client, elder, c)
        elif action == 'delete':
            client.request('DELETE', '/answer-cards/' + c['id'], headers=auth(elder),
                json={'expected_version': 1, 'client_operation_id': 'rollback-delete'})
        else:
            block(client, elder, child, link_id=link['id'])
    assert client.get('/answer-cards/' + c['id'], headers=auth(elder)).json() == c
    assert len(inbox(client, child)) == 1
    with app.state.session_factory() as db:
        assert db.get(FamilyLink, link['id']).authorization_epoch == link['authorization_epoch']


def test_lost_share_ack_replays_durable_receipt(connected, monkeypatch):
    _, client, elder, child, _, _, link, c = connected
    payload = preview(c, child, link)
    original = Session.commit
    def lost(self):
        original(self)
        raise RuntimeError('Synthetic response loss')
    monkeypatch.setattr(Session, 'commit', lost)
    with pytest.raises(RuntimeError, match='Synthetic response loss'):
        send(client, elder, c, payload)
    monkeypatch.setattr(Session, 'commit', original)
    replay = send(client, elder, c, payload)
    assert replay.status_code == 201
    assert inbox(client, child) == [replay.json()]


@pytest.mark.parametrize('action', ['edit', 'delete', 'block'])
@pytest.mark.parametrize('winner', ['share', 'mutation'])
def test_concurrent_writers_follow_owner_mutex_in_both_orders(connected, monkeypatch, action, winner):
    _, client, elder, child, _, _, link, c = connected
    from app import answer_card_share_service as shares, answer_card_private_service as private
    from app import family_connection_service as family
    held, release, attempted = Event(), Event(), Event()
    target = shares if winner == 'share' else (family if action == 'block' else private)
    name = 'withdraw_family_access' if winner == 'mutation' and action == 'block' else '_owned'
    original = getattr(target, name)
    def hold_after_owner_guard(*args, **kwargs):
        held.set()
        assert release.wait(5), 'Synthetic lock holder was not released'
        return original(*args, **kwargs)
    monkeypatch.setattr(target, name, hold_after_owner_guard)
    def mutation():
        if action == 'edit':
            return patch(client, elder, c)
        if action == 'delete':
            return client.request('DELETE', '/answer-cards/' + c['id'], headers=auth(elder),
                json={'expected_version': 1, 'client_operation_id': 'concurrent-delete'})
        return block(client, elder, child, link_id=link['id'])
    send_call = lambda: send(client, elder, c, preview(c, child, link))
    first_call, second_call = (send_call, mutation) if winner == 'share' else (mutation, send_call)
    def contender():
        attempted.set()
        return second_call()
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(first_call)
        try:
            assert held.wait(5), 'First writer did not acquire the synthetic owner guard'
            second = pool.submit(contender)
            assert attempted.wait(5)
        finally:
            release.set()
        results = first.result(), second.result()
    share_result = results[0] if winner == 'share' else results[1]
    assert share_result.status_code == (201 if winner == 'share' else (404 if action == 'delete' else 409))
    assert inbox(client, child) == []


def test_missing_share_schema_fails_closed_and_preserves_family_consent(connected):
    app, client, elder, child, _, _, link, c = connected
    with app.state.session_factory() as db:
        db.execute(text('DROP TABLE answer_card_shares'))
        db.commit()
    assert send(client, elder, c, preview(c, child, link)).status_code == 503
    assert client.get('/answer-card-shares/inbox', headers=auth(child)).status_code == 503
    assert client.get('/answer-card-shares/sent', headers=auth(elder)).status_code == 503
    assert patch(client, elder, c).status_code == 503
    assert block(client, elder, child, link_id=link['id']).status_code == 503
    assert client.get('/answer-cards/' + c['id'], headers=auth(elder)).json() == c
    with app.state.session_factory() as db:
        current = db.get(FamilyLink, link['id'])
        assert current.status == 'active' and current.authorization_epoch == link['authorization_epoch']


def test_withdrawal_exact_filter_and_purge_are_caller_transaction_local(connected):
    app, client, elder, child, _, _, link, c = connected
    assert send(client, elder, c, preview(c, child, link)).status_code == 201
    from app.answer_card_share_service import withdraw_answer_card_shares
    from app.answer_card_private_service import owner_guard, purge_answer_cards
    from app.answer_card_models import AnswerCardShare
    with app.state.session_factory() as db:
        owner_guard(db, elder['account']['id'])
        with pytest.raises(ValueError, match='exact card or link'):
            withdraw_answer_card_shares(db, reason='synthetic')
        assert purge_answer_cards(db, elder['account']['id']) == 1
        assert db.scalar(select(AnswerCardShare)).public_payload == {}
        db.rollback()  # Helpers did not commit; caller owns the transaction.
    assert client.get('/answer-cards/' + c['id'], headers=auth(elder)).json() == c
    assert len(inbox(client, child)) == 1


def test_failure_after_share_flush_leaves_no_snapshot_or_receipt(connected, monkeypatch):
    app, client, elder, child, _, _, link, c = connected
    from app import answer_card_share_service as service
    original = service._share_out
    def fail_after_out(*args, **kwargs):
        original(*args, **kwargs)
        raise RuntimeError('Synthetic receipt failure')
    monkeypatch.setattr(service, '_share_out', fail_after_out)
    with pytest.raises(RuntimeError, match='Synthetic receipt failure'):
        send(client, elder, c, preview(c, child, link))
    monkeypatch.setattr(service, '_share_out', original)
    assert inbox(client, child) == []
    assert sent(client, elder) == []
    assert send(client, elder, c, preview(c, child, link)).status_code == 201


def test_reviewed_template_preserves_mode_and_explicit_false_ack(connected):
    app, client, elder, child, _, _, link, _ = connected
    c = card(app, client, elder, mode='template', key='public-template')
    result = send(client, elder, c, preview(c, child, link, ack=False))
    assert result.status_code == 201
    assert result.json()['mode'] == 'public_template'
    assert result.json()['public_payload']['verification_state'] == 'reviewed_public_guidance'


def test_same_display_name_does_not_substitute_recipient_or_link(connected):
    app, client, elder, child, _, other_child, link, c = connected
    from app.models import Account
    with app.state.session_factory() as db:
        for recipient in (child, other_child):
            db.get(Account, recipient['account']['id']).display_name = 'Synthetic same name'
            recipient['account']['display_name'] = 'Synthetic same name'
        db.commit()
    other_link = link_accounts(client, elder, other_child, ['family_messages'])
    assert child['account']['display_name'] == other_child['account']['display_name']
    forged = preview(c, other_child, link)
    assert send(client, elder, c, forged).status_code == 409
    assert inbox(client, child) == inbox(client, other_child) == []
    assert send(client, elder, c, preview(c, other_child, other_link)).status_code == 201
    assert inbox(client, child) == []
    assert len(inbox(client, other_child)) == 1
