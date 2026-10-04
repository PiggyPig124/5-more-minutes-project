"""Explicit item consent: private defaults, least privilege and replay boundaries."""
from .memory_revision_helpers import memory_revision_headers
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.config import Settings
from app.main import create_app
from app.models import Task
from app.care_models import CarePreference, CareNotification
from tests.test_integration import _register, _headers


@pytest.fixture
def sharing(tmp_path):
    settings = Settings(database_url=f"sqlite:///{tmp_path / 'sharing.db'}", auth_secret="sharing-test", demo_mode=True)
    app = create_app(settings)
    with TestClient(app) as client:
        elder = _register(client, "e@example.test")
        a = _register(client, "a@example.test", "caregiver")
        b = _register(client, "b@example.test", "caregiver")
        x = _register(client, "x@example.test")
        links = []
        for caregiver in (a, b):
            invite = client.post("/family-links/invitations", headers=_headers(elder),
                json={"email": caregiver['account']['email'], "scopes": ["care_tasks"]}).json()
            links.append(client.post("/family-links/invitations/accept", headers=_headers(caregiver),
                json={"token": invite['token']}).json()['id'])
        with app.state.session_factory() as db:
            task = Task(owner_id=elder['account']['id'], created_by=elder['account']['id'],
                title="Private appointment", description="Full sensitive description", due_at=datetime(2020, 1, 1, tzinfo=timezone.utc))
            own = Task(owner_id=a['account']['id'], created_by=a['account']['id'], title="Caregiver own task")
            db.add_all([task, own]); db.commit()
            task_id, own_id = task.id, own.id
        yield app, client, elder, a, b, x, links, task_id, own_id, settings


def share_request(client, elder, task_id, link_id, key="consent-1"):
    preview = client.get(f"/tasks/{task_id}", headers=_headers(elder))
    assert preview.status_code == 200, preview.text
    return {'family_link_id': link_id, 'expected_content_hash': preview.json()['content_hash'], 'idempotency_key': key}


def test_private_default_even_with_care_tasks_link(sharing):
    app, c, e, a, b, x, links, tid, own, settings = sharing
    assert [t['id'] for t in c.get('/tasks', headers=_headers(a)).json()] == [own]
    for account in (a, b, x):
        assert c.get(f'/tasks/{tid}', headers=_headers(account)).status_code == 404
    assert c.get('/tasks', params={'owner_id': e['account']['id']}, headers=_headers(a)).status_code == 404


def test_selected_share_is_minimal_and_readonly(sharing):
    app, c, e, a, b, x, links, tid, own, settings = sharing
    payload = share_request(c, e, tid, links[0])
    created = c.post(f'/tasks/{tid}/shares', headers=_headers(e), json=payload)
    assert created.status_code == 201, created.text
    result = c.get(f'/tasks/{tid}', headers=_headers(a)).json()
    assert result['access_mode'] == 'shared_readonly'
    assert result['share_id'] == created.json()['id']
    assert result['description'] == 'Full sensitive description'
    assert not {'source_action_id', 'created_by', 'conversation_id', 'content_hash'} & result.keys()
    for account in (b, x):
        assert c.get(f'/tasks/{tid}', headers=_headers(account)).status_code == 404
    for patch in ({'status': 'completed'}, {'title': 'Changed'}, {'description': 'Changed'}, {'due_at': None}):
        assert c.patch(f'/tasks/{tid}', headers=_headers(a), json=patch).status_code in (403, 404)
    assert c.patch(f'/tasks/{own}', headers=_headers(a), json={'status': 'completed'}).status_code == 200
    assert c.get(f'/tasks/{tid}/shares', headers=_headers(a)).status_code == 404
    assert c.post(f'/tasks/{tid}/shares', headers=_headers(a), json=payload).status_code == 404
    assert c.patch(f'/tasks/{tid}', headers=_headers(e), json={'owner_id': a['account']['id']}).status_code == 422


def test_idempotency_conflicts_and_revoked_key_never_reactivates(sharing):
    app, c, e, a, b, x, links, tid, own, settings = sharing
    url = f'/tasks/{tid}/shares'
    payload = share_request(c, e, tid, links[0])
    first = c.post(url, headers=_headers(e), json=payload)
    assert first.status_code == 201, first.text
    sid = first.json()['id']
    assert c.post(url, headers=_headers(e), json=payload).json()['id'] == sid
    assert c.post(url, headers=_headers(e), json={**payload, 'family_link_id': links[1]}).status_code == 409
    assert c.post(url, headers=_headers(e), json={**payload, 'idempotency_key': 'new-key'}).status_code == 409
    assert c.delete(f'{url}/{sid}', headers=_headers(e)).status_code == 200
    assert c.delete(f'{url}/{sid}', headers=_headers(e)).status_code == 200
    replay = c.post(url, headers=_headers(e), json=payload)
    assert replay.status_code == 409
    assert c.get(f'/tasks/{tid}', headers=_headers(a)).status_code == 404
    replacement = c.post(url, headers=_headers(e), json={**payload, 'idempotency_key': 'replacement'})
    assert replacement.status_code == 201 and replacement.json()['id'] != sid


def test_edit_invalidates_consent_but_status_and_equal_utc_do_not(sharing):
    app, c, e, a, b, x, links, tid, own, settings = sharing
    payload = share_request(c, e, tid, links[0])
    assert c.post(f'/tasks/{tid}/shares', headers=_headers(e), json=payload).status_code == 201
    for patch in ({'status':'in_progress'}, {'due_at':'2020-01-01T08:00:00+08:00'}):
        assert c.patch(f'/tasks/{tid}', headers=_headers(e), json=patch).status_code == 200
        assert c.get(f'/tasks/{tid}', headers=_headers(a)).status_code == 200
    assert c.patch(f'/tasks/{tid}', headers=_headers(e), json={'description':'New private content'}).status_code == 200
    assert c.get(f'/tasks/{tid}', headers=_headers(a)).status_code == 404
    assert c.post(f'/tasks/{tid}/shares', headers=_headers(e), json={**payload,'idempotency_key':'stale'}).status_code == 409


def test_link_reconnect_does_not_restore_shares(sharing):
    app, c, e, a, b, x, links, tid, own, settings = sharing
    payload = share_request(c, e, tid, links[0])
    assert c.post(f'/tasks/{tid}/shares', headers=_headers(e), json=payload).status_code == 201
    assert c.delete(f'/family-links/{links[0]}', headers=_headers(e)).status_code == 200
    invite = c.post('/family-links/invitations', headers=_headers(e), json={'email':a['account']['email'],'scopes':['care_tasks']}).json()
    assert c.post('/family-links/invitations/accept', headers=_headers(a),json={'token':invite['token']}).status_code == 201
    assert c.get(f'/tasks/{tid}', headers=_headers(a)).status_code == 404
    assert c.post(f'/tasks/{tid}/shares', headers=_headers(e), json=payload).status_code == 409


def test_shared_notification_uses_share_identity_and_live_authorization(sharing):
    app, c, e, a, b, x, links, tid, own, settings = sharing
    with app.state.session_factory() as db:
        db.add(CarePreference(owner_id=a['account']['id'],settings={'task_reminders':True,'quiet_start':'00:00','quiet_end':'00:00'}))
        db.add(CareNotification(owner_id=a['account']['id'],kind='task_reminder',source_id=tid,body='old broad reminder'))
        db.commit()
    assert c.get('/notifications', headers=_headers(a)).json()['notifications'] == []
    payload = share_request(c,e,tid,links[0])
    share = c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).json()
    notices = c.get('/notifications',headers=_headers(a)).json()['notifications']
    assert len(notices)==1 and notices[0]['kind']=='shared_task_reminder'
    assert notices[0]['share_id'] == share['id']
    nid = notices[0]['id']
    assert c.patch(f'/notifications/{nid}',headers=_headers(a),json={'status':'handled'}).status_code==200
    c.delete(f'/tasks/{tid}/shares/{share["id"]}',headers=_headers(e))
    assert c.get('/notifications',headers=_headers(a)).json()['notifications']==[]
    assert c.patch(f'/notifications/{nid}',headers=_headers(a),json={'status':'acknowledged'}).status_code==404
    c.post(f'/tasks/{tid}/shares',headers=_headers(e),json={**payload,'idempotency_key':'reshare'})
    fresh=c.get('/notifications',headers=_headers(a)).json()['notifications']
    assert len(fresh)==1 and fresh[0]['id']!=nid and fresh[0]['status']=='pending'


def test_concurrent_share_retries_persist_one_consent(sharing):
    app, c, e, a, b, x, links, tid, own, settings = sharing
    payload=share_request(c,e,tid,links[0])
    with ThreadPoolExecutor(max_workers=4) as pool:
        results=list(pool.map(lambda _:c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload),range(4)))
    assert all(r.status_code in (200,201) for r in results)
    assert len({r.json()['id'] for r in results})==1
    assert len(c.get(f'/tasks/{tid}/shares',headers=_headers(e)).json())==1


def test_scope_removed_and_restored_never_restores_consent(sharing):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    payload=share_request(c,e,tid,links[0])
    assert c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).status_code==201
    for scopes in (['family_messages'],['care_tasks']):
        invite=c.post('/family-links/invitations',headers=_headers(e),json={'email':a['account']['email'],'scopes':scopes}).json()
        assert c.post('/family-links/invitations/accept',headers=_headers(a),json={'token':invite['token']}).status_code==201
        assert c.get(f'/tasks/{tid}',headers=_headers(a)).status_code==404
    history=c.get(f'/tasks/{tid}/shares',headers=_headers(e)).json()
    assert history[0]['revoked_at'] and history[0]['revocation_reason']=='family_link_changed'


def test_task_type_edit_revokes_consent(sharing):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    payload=share_request(c,e,tid,links[0])
    assert c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).status_code==201
    assert c.patch(f'/tasks/{tid}',headers=_headers(e),json={'task_type':'appointment'}).status_code==200
    assert c.get(f'/tasks/{tid}',headers=_headers(a)).status_code==404


def test_notification_authorization_happens_before_limit(sharing):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    with app.state.session_factory() as db:
        valid=CareNotification(owner_id=a['account']['id'],kind='task_reminder',source_id=own,body='own visible reminder',created_at=datetime(2000,1,1))
        db.add(valid)
        for i in range(105):
            db.add(CareNotification(owner_id=a['account']['id'],kind='task_reminder',source_id=f'inaccessible-{i}',body='hidden'))
        db.commit(); valid_id=valid.id
    assert [n['id'] for n in c.get('/notifications',headers=_headers(a)).json()['notifications']]==[valid_id]


def test_share_survives_restart_without_broadening_access(sharing):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    payload=share_request(c,e,tid,links[0])
    original=c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).json()
    with TestClient(create_app(settings)) as fresh:
        assert fresh.get(f'/tasks/{tid}',headers=_headers(a)).json()['share_id']==original['id']
        assert fresh.get(f'/tasks/{tid}',headers=_headers(b)).status_code==404
        assert fresh.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).json()['id']==original['id']


def test_legacy_database_initialization_never_backfills_consent(sharing):
    from app.db import initialize_database
    app,c,e,a,b,x,links,tid,own,settings=sharing
    with app.state.engine.begin() as connection:
        connection.exec_driver_sql('DROP TABLE task_shares')
    initialize_database(app.state.engine)
    initialize_database(app.state.engine)
    assert c.get(f'/tasks/{tid}',headers=_headers(e)).status_code==200
    assert c.get(f'/tasks/{tid}',headers=_headers(a)).status_code==404
    assert c.get(f'/tasks/{tid}/shares',headers=_headers(e)).json()==[]


@pytest.mark.parametrize('operation',['edit','revoke'])
def test_share_races_serialize_with_content_edit_and_link_revocation(sharing,operation):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    payload=share_request(c,e,tid,links[0])
    with ThreadPoolExecutor(max_workers=2) as pool:
        consent=pool.submit(c.post,f'/tasks/{tid}/shares',headers=_headers(e),json=payload)
        if operation=='edit':
            mutation=pool.submit(c.patch,f'/tasks/{tid}',headers=_headers(e),json={'title':'new private content'})
        else:
            mutation=pool.submit(c.delete,f'/family-links/{links[0]}',headers=_headers(e))
        created,changed=consent.result(),mutation.result()
    assert created.status_code in (201,403,409)
    assert changed.status_code==200
    assert c.get(f'/tasks/{tid}',headers=_headers(a)).status_code==404
    history=c.get(f'/tasks/{tid}/shares',headers=_headers(e)).json()
    assert all(share['revoked_at'] for share in history)


def test_memory_off_does_not_revoke_explicit_task_consent(sharing):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    payload=share_request(c,e,tid,links[0])
    assert c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).status_code==201
    assert c.put('/memories/consent',headers=memory_revision_headers(c, _headers(e)),json={'enabled':False}).status_code==200
    assert c.get(f'/tasks/{tid}',headers=_headers(a)).status_code==200


def test_schema_query_failure_never_falls_back_to_family_scope(sharing):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    with TestClient(app,raise_server_exceptions=False) as failed:
        with app.state.engine.begin() as connection:
            connection.exec_driver_sql('DROP TABLE task_shares')
        assert failed.get(f'/tasks/{tid}',headers=_headers(a)).status_code==500
        assert failed.get('/tasks',headers=_headers(a)).status_code==500


def test_database_uniqueness_rejects_duplicate_active_consent(sharing):
    from app.task_share_models import TaskShare
    from sqlalchemy.exc import IntegrityError
    app,c,e,a,b,x,links,tid,own,settings=sharing
    payload=share_request(c,e,tid,links[0])
    assert c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).status_code==201
    with app.state.session_factory() as db:
        existing=db.scalar(select(TaskShare).where(TaskShare.task_id==tid))
        db.add(TaskShare(task_id=tid,family_link_id=links[0],shared_by=e['account']['id'],content_hash=existing.content_hash,request_hash=existing.request_hash,idempotency_key='other-key'))
        with pytest.raises(IntegrityError):
            db.commit()


def test_share_retry_races_with_share_revocation(sharing):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    payload=share_request(c,e,tid,links[0])
    share=c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).json()
    with ThreadPoolExecutor(max_workers=2) as pool:
        replay=pool.submit(c.post,f'/tasks/{tid}/shares',headers=_headers(e),json=payload)
        revoke=pool.submit(c.delete,f'/tasks/{tid}/shares/{share["id"]}',headers=_headers(e))
        retried,revoked=replay.result(),revoke.result()
    assert retried.status_code in (200,409) and revoked.status_code==200
    assert c.get(f'/tasks/{tid}',headers=_headers(a)).status_code==404
    assert c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).status_code==409


def test_notification_patch_races_with_link_revocation(sharing):
    app,c,e,a,b,x,links,tid,own,settings=sharing
    with app.state.session_factory() as db:
        db.add(CarePreference(owner_id=a['account']['id'],settings={'task_reminders':True,'quiet_start':'00:00','quiet_end':'00:00'})); db.commit()
    payload=share_request(c,e,tid,links[0])
    assert c.post(f'/tasks/{tid}/shares',headers=_headers(e),json=payload).status_code==201
    nid=c.get('/notifications',headers=_headers(a)).json()['notifications'][0]['id']
    with ThreadPoolExecutor(max_workers=2) as pool:
        update=pool.submit(c.patch,f'/notifications/{nid}',headers=_headers(a),json={'status':'handled'})
        revoke=pool.submit(c.delete,f'/family-links/{links[0]}',headers=_headers(e))
        updated,revoked=update.result(),revoke.result()
    assert updated.status_code in (200,404) and revoked.status_code==200
    assert c.get('/notifications',headers=_headers(a)).json()['notifications']==[]
    assert c.patch(f'/notifications/{nid}',headers=_headers(a),json={'status':'acknowledged'}).status_code==404


def test_shared_list_and_detail_show_only_the_actual_owners_public_name(sharing):
    app, client, elder, a, b, unrelated, links, task_id, own_id, settings = sharing
    payload = share_request(client, elder, task_id, links[0], key='public-owner-name')
    created = client.post(f'/tasks/{task_id}/shares', headers=_headers(elder), json=payload)
    assert created.status_code == 201, created.text
    allowed_fields = {'id', 'owner_id', 'owner_display_name', 'task_type', 'title',
                      'description', 'due_at', 'status', 'share_id', 'access_mode'}
    detail = client.get(f'/tasks/{task_id}', headers=_headers(a))
    assert detail.status_code == 200, detail.text
    listed = client.get('/tasks', headers=_headers(a))
    assert listed.status_code == 200, listed.text
    shared_rows = [row for row in listed.json() if row['id'] == task_id]
    assert len(shared_rows) == 1
    for row in (detail.json(), shared_rows[0]):
        assert row['owner_display_name'] == elder['account']['display_name']
        assert row['owner_id'] == elder['account']['id']
        assert set(row) == allowed_fields
        assert row['share_id'] == created.json()['id']
        assert row['access_mode'] == 'shared_readonly'
        for account in (elder, a, b, unrelated):
            assert account['account']['email'] not in str(row)
        for account in (a, b, unrelated):
            assert account['account']['id'] not in str(row)
    for account in (b, unrelated):
        assert client.get(f'/tasks/{task_id}', headers=_headers(account)).status_code == 404
        assert all(row['id'] != task_id for row in client.get('/tasks', headers=_headers(account)).json())
    revoked = client.delete(f'/tasks/{task_id}/shares/{created.json()["id"]}', headers=_headers(elder))
    assert revoked.status_code == 200
    assert client.get(f'/tasks/{task_id}', headers=_headers(a)).status_code == 404
    assert all(row['id'] != task_id for row in client.get('/tasks', headers=_headers(a)).json())


def test_only_owner_share_receipts_expose_the_linked_recipients_email(sharing):
    app, client, elder, a, b, unrelated, links, task_id, own_id, settings = sharing
    shares_url = f'/tasks/{task_id}/shares'
    receipts = {}
    for index, caregiver in enumerate((a, b)):
        payload = share_request(client, elder, task_id, links[index], key=f'email-receipt-{index}')
        created = client.post(shares_url, headers=_headers(elder), json=payload)
        assert created.status_code == 201, created.text
        receipt = created.json()
        assert receipt['caregiver_email'] == caregiver['account']['email']
        assert receipt['caregiver_id'] == caregiver['account']['id']
        assert receipt['family_link_id'] == links[index]
        assert elder['account']['email'] not in str(receipt)
        receipts[receipt['id']] = caregiver
    history = client.get(shares_url, headers=_headers(elder))
    assert history.status_code == 200, history.text
    assert {receipt['id'] for receipt in history.json()} == set(receipts)
    for receipt in history.json():
        assert receipt['caregiver_email'] == receipts[receipt['id']]['account']['email']
    for account in (a, b, unrelated):
        assert client.get(shares_url, headers=_headers(account)).status_code == 404
        for share_id in receipts:
            assert client.delete(f'{shares_url}/{share_id}', headers=_headers(account)).status_code == 404
    for share_id, caregiver in receipts.items():
        withdrawn = client.delete(f'{shares_url}/{share_id}', headers=_headers(elder))
        assert withdrawn.status_code == 200, withdrawn.text
        assert withdrawn.json()['caregiver_email'] == caregiver['account']['email']
        assert withdrawn.json()['revoked_at'] is not None
    for receipt in client.get(shares_url, headers=_headers(elder)).json():
        assert receipt['caregiver_email'] == receipts[receipt['id']]['account']['email']


def test_share_receipt_timestamps_are_explicit_utc_for_sqlite_clients(sharing):
    app, client, elder, a, b, unrelated, links, task_id, own_id, settings = sharing
    shares_url = f'/tasks/{task_id}/shares'
    payload = share_request(client, elder, task_id, links[0], key='utc-receipt')
    created = client.post(shares_url, headers=_headers(elder), json=payload)
    assert created.status_code == 201, created.text
    share_id = created.json()['id']
    history = client.get(shares_url, headers=_headers(elder))
    assert history.status_code == 200, history.text
    withdrawn = client.delete(f'{shares_url}/{share_id}', headers=_headers(elder))
    assert withdrawn.status_code == 200, withdrawn.text
    revoked_history = client.get(shares_url, headers=_headers(elder))
    assert revoked_history.status_code == 200, revoked_history.text
    receipts = [created.json(), history.json()[0], withdrawn.json(), revoked_history.json()[0]]
    for receipt in receipts:
        for field in ('consented_at', 'revoked_at'):
            value = receipt[field]
            if value is None:
                assert field == 'revoked_at'
                continue
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
            assert parsed.tzinfo is not None, (field, value)
            assert parsed.utcoffset().total_seconds() == 0, (field, value)
    consent_times = {datetime.fromisoformat(receipt['consented_at'].replace('Z', '+00:00'))
                     for receipt in receipts}
    assert len(consent_times) == 1
    assert withdrawn.json()['revoked_at'] is not None
