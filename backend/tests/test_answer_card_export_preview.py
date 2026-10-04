"""Closed owner-only export-preview, without file or family side effects."""
import pytest

from tests.test_memory_controls import setup, auth
from tests.test_answer_card_sharing import card, patch


def export(client, owner, c, **change):
    return client.post('/answer-cards/' + c['id'] + '/export-preview', headers=auth(owner), json={
        'expected_version': c['version'], 'previewed_payload_hash': c['public_payload_hash'],
        'personal_review_ack': True, **change})


@pytest.mark.parametrize('owner_index', [0, 2])
def test_owner_export_no_family_required_closed_payload_and_no_provenance(setup, owner_index):
    app, client, accounts = setup
    owner = accounts[owner_index]
    c = card(app, client, owner)
    response = export(client, owner, c)
    assert response.status_code == 200, response.text
    assert response.json() == {'card_version': 1, 'public_payload': c['public_payload'],
                               'public_payload_hash': c['public_payload_hash']}
    assert client.get('/family-links', headers=auth(owner)).json() == []


@pytest.mark.parametrize('change,expected', [({'personal_review_ack': False}, 422),
    ({'personal_review_ack': 'true'}, 422), ({'expected_version': True}, 422),
    ({'expected_version': 2}, 409), ({'previewed_payload_hash': 'a' * 64}, 409),
    ({'public_payload': {}}, 422), ({'recipient_id': 'synthetic'}, 422)])
def test_export_capture_and_ack_are_strict(setup, change, expected):
    app, client, (owner, _, _) = setup
    c = card(app, client, owner)
    assert export(client, owner, c, **change).status_code == expected


@pytest.mark.parametrize('field', ['expected_version', 'previewed_payload_hash', 'personal_review_ack'])
def test_export_requires_all_fields(setup, field):
    app, client, (owner, _, _) = setup
    c = card(app, client, owner)
    request = {'expected_version': 1, 'previewed_payload_hash': c['public_payload_hash'], 'personal_review_ack': True}
    request.pop(field)
    assert client.post('/answer-cards/' + c['id'] + '/export-preview', headers=auth(owner), json=request).status_code == 422


def test_export_foreign_guest_edited_and_deleted_version_fail_closed(setup):
    app, client, (owner, other, _) = setup
    c = card(app, client, owner)
    assert export(client, other, c).status_code == 404
    assert client.post('/answer-cards/' + c['id'] + '/export-preview', json={
        'expected_version': 1, 'previewed_payload_hash': c['public_payload_hash'], 'personal_review_ack': True}).status_code == 401
    changed = patch(client, owner, c)
    assert changed.status_code == 200
    assert export(client, owner, c).status_code == 409
    updated = changed.json()
    assert export(client, owner, updated).status_code == 200
    assert client.request('DELETE', '/answer-cards/' + c['id'], headers=auth(owner),
        json={'expected_version': 2, 'client_operation_id': 'delete'}).status_code == 200
    assert export(client, owner, updated).status_code == 404


def test_reviewed_public_template_can_explicitly_decline_extra_personal_ack(setup):
    app, client, (owner, _, _) = setup
    c = card(app, client, owner, mode='template')
    assert c['public_payload']['verification_state'] == 'reviewed_public_guidance'
    assert export(client, owner, c, personal_review_ack=False).status_code == 200
