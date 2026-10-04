"""Synthetic regressions: explicitly sourced pending actions cannot revive memory."""
from concurrent.futures import ThreadPoolExecutor
from threading import Event
import os
import subprocess
import sys

import pytest
from sqlalchemy import event, select

from app.main import create_app
from app.memory_models import PersonalMemory
from app.memory_service import lock_owner_account, purge_memory_set
from app.models import ActionProposal, Conversation, FamilyLink, Message, Task
from app.task_share_models import TaskShare
from app.task_share_service import content_hash
from fastapi.testclient import TestClient
from tests.test_memory_controls import setup, auth, enable, deletion

PRIVATE = 'WITHDRAWN_EXPLICIT_ACTION_MEMORY_20261003'


def seed(app, owner, *, linked=True, action_owner=None):
    owner_id = owner['account']['id']
    with app.state.session_factory() as db:
        conversation = Conversation(owner_id=owner_id, title='Synthetic context')
        db.add(conversation); db.flush()
        source = Message(conversation_id=conversation.id, sender_id=owner_id,
                         role='user', content=PRIVATE, ordinal=1)
        db.add(source); db.flush()
        memory = PersonalMemory(owner_id=owner_id, content=PRIVATE,
                                status='confirmed', source_message_id=source.id)
        db.add(memory); db.flush()
        action = ActionProposal(owner_id=action_owner or owner_id,
                                conversation_id=conversation.id, status='pending',
                                payload={'title': 'Synthetic task', 'description': PRIVATE})
        db.add(action); db.flush()
        metadata = {'action_id': action.id}
        if linked:
            metadata['source_memory_ids'] = [memory.id]
        db.add(Message(conversation_id=conversation.id, role='assistant',
                       content=PRIVATE, ordinal=2, metadata_json=metadata))
        db.commit()
        return conversation.id, action.id, memory.id


def confirm(client, owner, action_id):
    return client.post(f'/actions/{action_id}/confirm', headers=auth(owner),
                       json={'idempotency_key': 'synthetic-confirm-' + action_id})


@pytest.mark.parametrize('selected', [False, True])
def test_deleted_source_invalidates_proposal_read_and_direct_confirmation(setup, selected):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    conversation_id, action_id, memory_id = seed(app, owner)
    removed = deletion(client, owner, mode='selected' if selected else 'all',
                       ids=[memory_id] if selected else [], key='withdraw-proposal')
    assert removed.status_code == 200, removed.text
    history = client.get(f'/conversations/{conversation_id}/messages', headers=auth(owner))
    assert PRIVATE not in history.text
    actions = client.get(f'/conversations/{conversation_id}/actions', headers=auth(owner))
    assert actions.status_code == 200
    assert PRIVATE not in actions.text
    invalidated = next(item for item in actions.json() if item['id'] == action_id)
    assert invalidated['status'] == 'invalidated' and invalidated['payload'] == {}
    rejected = confirm(client, owner, action_id)
    assert rejected.status_code == 409, rejected.text
    assert PRIVATE not in rejected.text
    with app.state.session_factory() as db:
        assert db.scalar(select(Task).where(Task.source_action_id == action_id)) is None
    assert client.post(f'/actions/{action_id}/dismiss', headers=auth(owner)).status_code == 409


def test_withdrawn_action_remains_invalid_after_application_restart(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    conversation_id, action_id, _ = seed(app, owner)
    assert deletion(client, owner).status_code == 200
    restarted = create_app(app.state.settings)
    with TestClient(restarted) as after_restart:
        response = after_restart.get(f'/conversations/{conversation_id}/actions', headers=auth(owner))
        assert PRIVATE not in response.text
        assert confirm(after_restart, owner, action_id).status_code == 409
    # A fresh Python interpreter also reconstructs the application and reads
    # the same synthetic SQLite file; no in-process invalidation can help it.
    probe = '''
import sys
from app.config import Settings
from app.main import create_app
from fastapi.testclient import TestClient
app = create_app(Settings(database_url=sys.argv[1], auth_secret='memory-control-test', demo_mode=True))
with TestClient(app) as client:
    headers = {'Authorization': 'Bearer ' + sys.argv[2]}
    response = client.get('/conversations/' + sys.argv[3] + '/actions', headers=headers)
    assert response.status_code == 200
    assert 'WITHDRAWN_EXPLICIT_ACTION_MEMORY_20261003' not in response.text
    action = next(row for row in response.json() if row['id'] == sys.argv[4])
    assert action['status'] == 'invalidated' and action['payload'] == {}
    assert client.post('/actions/' + sys.argv[4] + '/confirm', headers=headers).status_code == 409
'''
    checked = subprocess.run([sys.executable, '-c', probe, app.state.settings.database_url,
                              owner['access_token'], conversation_id, action_id],
                             capture_output=True, text=True, timeout=20, env=os.environ.copy())
    assert checked.returncode == 0, checked.stderr


@pytest.mark.parametrize('foreign', [False, True])
def test_unrelated_or_foreign_proposal_is_preserved(setup, foreign):
    app, client, (owner, other, _) = setup
    enable(client, owner)
    _, action_id, _ = seed(app, owner, linked=foreign,
                           action_owner=other['account']['id'] if foreign else None)
    assert deletion(client, owner).status_code == 200
    with app.state.session_factory() as db:
        action = db.get(ActionProposal, action_id)
        assert action.status == 'pending' and action.payload['description'] == PRIVATE
    assert confirm(client, other if foreign else owner, action_id).status_code == 200


def test_already_confirmed_task_and_proposal_remain_available(setup):
    app, client, (owner, _, caregiver) = setup
    enable(client, owner)
    _, action_id, _ = seed(app, owner)
    first = confirm(client, owner, action_id)
    assert first.status_code == 200
    task_id = first.json()['task']['id']
    with app.state.session_factory() as db:
        task = db.get(Task, task_id)
        link = FamilyLink(elder_id=owner['account']['id'], caregiver_id=caregiver['account']['id'],
                          scopes=['care_tasks'], status='active')
        db.add(link); db.flush()
        share = TaskShare(task_id=task.id, family_link_id=link.id, shared_by=owner['account']['id'],
                          content_hash=content_hash(task), request_hash='a'*64,
                          idempotency_key='synthetic-existing-task-share')
        db.add(share); db.commit(); share_id = share.id
    assert client.get(f'/tasks/{task_id}', headers=auth(caregiver)).status_code == 200
    assert deletion(client, owner).status_code == 200
    replay = confirm(client, owner, action_id)
    assert replay.status_code == 200 and replay.json()['task']['id'] == task_id
    with app.state.session_factory() as db:
        assert db.get(Task, task_id).description == PRIVATE
        assert db.get(ActionProposal, action_id).status == 'executed'
        assert db.get(TaskShare, share_id).revoked_at is None
    assert client.get(f'/tasks/{task_id}', headers=auth(caregiver)).status_code == 200


def test_failed_delete_rolls_back_action_withdrawal_and_retry_succeeds(setup, monkeypatch):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    _, action_id, memory_id = seed(app, owner)
    from app import memory_service
    original = memory_service.scrub_memory_references
    def fail_after_scrub(db, *args, **kwargs):
        original(db, *args, **kwargs)
        raise RuntimeError('Synthetic failure after action invalidation')
    monkeypatch.setattr(memory_service, 'scrub_memory_references', fail_after_scrub)
    assert deletion(client, owner, key='rollback-action').status_code == 500
    with app.state.session_factory() as db:
        assert db.get(PersonalMemory, memory_id) is not None
        action = db.get(ActionProposal, action_id)
        assert action.status == 'pending' and action.payload['description'] == PRIVATE
    monkeypatch.setattr(memory_service, 'scrub_memory_references', original)
    assert deletion(client, owner, key='rollback-action').status_code == 200
    assert confirm(client, owner, action_id).status_code == 409


@pytest.mark.parametrize('winner', ['delete', 'confirm'])
def test_confirm_delete_serialize_on_owner_and_preserve_confirmed_winner(setup, winner):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    _, action_id, memory_id = seed(app, owner)
    attempted = Event()
    def observe(conn, cursor, statement, parameters, context, executemany):
        if statement.strip().upper() == 'BEGIN IMMEDIATE':
            attempted.set()
    if winner == 'confirm':
        # Pause the real HTTP confirmation after its task INSERT, while its
        # owner/action transaction still holds the write lock.
        inserted, release = Event(), Event()
        def hold_task(conn, cursor, statement, parameters, context, executemany):
            if statement.upper().startswith('INSERT INTO TASKS '):
                inserted.set()
                assert release.wait(5)
        event.listen(app.state.engine, 'after_cursor_execute', hold_task)
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(confirm, client, owner, action_id)
                assert inserted.wait(3)
                event.listen(app.state.engine, 'before_cursor_execute', observe)
                second = pool.submit(deletion, client, owner, revision=1)
                try:
                    assert attempted.wait(3)
                finally:
                    release.set()
                assert first.result(timeout=5).status_code == 200
                assert second.result(timeout=5).status_code == 200
        finally:
            event.remove(app.state.engine, 'after_cursor_execute', hold_task)
            event.remove(app.state.engine, 'before_cursor_execute', observe)
    else:
        with app.state.session_factory() as db:
            lock_owner_account(db, owner['account']['id'])
            event.listen(app.state.engine, 'before_cursor_execute', observe)
            try:
                with ThreadPoolExecutor(max_workers=1) as pool:
                    waiting = pool.submit(confirm, client, owner, action_id)
                    try:
                        assert attempted.wait(3)
                        purge_memory_set(db, owner['account']['id'], {memory_id})
                        db.commit()
                    finally:
                        db.rollback()
                    assert waiting.result(timeout=5).status_code == 409
            finally:
                event.remove(app.state.engine, 'before_cursor_execute', observe)
    with app.state.session_factory() as db:
        task = db.scalar(select(Task).where(Task.source_action_id == action_id))
        assert (task is not None) is (winner == 'confirm')
