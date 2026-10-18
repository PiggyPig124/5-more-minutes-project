"""Legacy candidate URLs must not persist unconfirmed personal memory."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import pytest

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.config import Settings
from app.main import create_app
from app.memory_models import MemoryEmbedding, PersonalMemory
from app.models import Message
from app.routers import memories
from .test_memory_controls import setup, auth, enable, headers, save, state


def candidate(client, owner, **values):
    response = client.post('/memories', headers=headers(client, owner), json={
        'content': 'Synthetic private life experience', 'kind': 'experience', **values})
    assert response.status_code == 201, response.text
    assert response.json()['status'] == 'candidate'
    return response.json()


def rows(app, model):
    with app.state.session_factory() as db:
        return db.scalars(select(model)).all()


def test_new_candidate_writes_neither_memory_vector_revision_nor_source_metadata(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    conversation = client.post('/conversations', headers=auth(owner), json={}).json()
    turn = client.post(f"/conversations/{conversation['id']}/messages", headers=auth(owner),
        json={'content': 'A synthetic sensitive experience', 'client_message_id': 'draft-source'})
    assert turn.status_code == 200, turn.text
    source_id = turn.json()['user_message']['id']
    with app.state.session_factory() as db:
        source_metadata = dict(db.get(Message, source_id).metadata_json)
    before = state(client, owner)
    draft = candidate(client, owner, source_message_id=source_id)
    assert rows(app, PersonalMemory) == [], 'Unconfirmed candidate body reached long-term storage'
    assert rows(app, MemoryEmbedding) == []
    assert state(client, owner) == before
    assert draft['revision'] == before['revision']
    with app.state.session_factory() as db:
        assert db.get(Message, source_id).metadata_json == source_metadata
    assert client.post('/memories/search', headers=auth(owner), json={'query': draft['content']}).json()['items'] == []


def test_cancel_discards_ram_candidate_without_changing_existing_data(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    existing = save(client, owner, 'Existing user-owned memory must survive')
    draft = candidate(client, owner)
    cancelled = client.delete(f"/memories/{draft['id']}",
        headers={**headers(client, owner), 'Idempotency-Key': 'discard-synthetic-draft'})
    assert cancelled.status_code == 204, cancelled.text
    assert client.get(f"/memories/{draft['id']}", headers=auth(owner)).status_code == 404
    assert client.post(f"/memories/{draft['id']}/confirm", headers=headers(client, owner)).status_code == 404
    assert [row.id for row in rows(app, PersonalMemory)] == [existing['id']]
    assert rows(app, MemoryEmbedding) == []  # No provider is configured in this fixture.


def test_confirm_persists_same_id_once_and_repeat_is_a_noop(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    draft = candidate(client, owner)
    confirmed = client.post(f"/memories/{draft['id']}/confirm", headers=headers(client, owner))
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()['id'] == draft['id']
    assert confirmed.json()['status'] == 'confirmed'
    first = state(client, owner)
    repeated = client.post(f"/memories/{draft['id']}/confirm", headers=headers(client, owner))
    assert repeated.status_code == 200, repeated.text
    assert repeated.json() == confirmed.json()
    assert state(client, owner) == first, 'Repeated confirmation performed another memory mutation'
    assert len(rows(app, PersonalMemory)) == 1
    assert rows(app, MemoryEmbedding) == []


def test_candidate_edit_only_final_confirmed_body_is_stored(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    original = candidate(client, owner, content='Unconfirmed original must not persist')
    edited = client.patch(f"/memories/{original['id']}", headers=headers(client, owner),
        json={'content': 'Final explicitly confirmed synthetic body'})
    assert edited.status_code == 200, edited.text
    final_id = edited.json()['id']
    assert final_id != original['id'], 'A stale confirmation must not silently accept an edited draft'
    assert rows(app, PersonalMemory) == []
    assert client.post(f"/memories/{original['id']}/confirm", headers=headers(client, owner)).status_code == 404
    assert client.post(f'/memories/{final_id}/confirm', headers=headers(client, owner)).status_code == 200
    stored = rows(app, PersonalMemory)
    assert [(row.id, row.content, row.status) for row in stored] == [
        (final_id, 'Final explicitly confirmed synthetic body', 'confirmed')]


def test_restart_does_not_resurrect_unconfirmed_candidate(tmp_path: Path):
    settings = Settings(database_url=f'sqlite:///{tmp_path / "draft-restart.db"}',
        auth_secret='synthetic-draft-restart', demo_mode=True)
    app = create_app(settings)
    with TestClient(app) as client:
        registered = client.post('/auth/register', json={'email': 'draft-restart@example.test',
            'password': 'synthetic-password', 'display_name': 'Synthetic', 'role': 'elder'})
        assert registered.status_code == 201
        owner = registered.json()
        enable(client, owner)
        draft = candidate(client, owner)
    restarted = create_app(settings)
    with TestClient(restarted) as client:
        assert client.get('/memories', headers=auth(owner)).json() == []
        assert client.post(f"/memories/{draft['id']}/confirm", headers=headers(client, owner)).status_code == 404
        assert rows(restarted, PersonalMemory) == []


def test_off_then_on_does_not_reactivate_old_draft(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    draft = candidate(client, owner)
    enable(client, owner, False)
    enable(client, owner)
    result = client.post(f"/memories/{draft['id']}/confirm", headers=headers(client, owner))
    assert result.status_code in (404, 409), result.text
    assert rows(app, PersonalMemory) == []


def test_draft_is_owner_only_and_existing_legacy_candidates_are_not_migrated(setup):
    app, client, (owner, other, _) = setup
    enable(client, owner)
    enable(client, other)
    draft = candidate(client, owner)
    assert client.get(f"/memories/{draft['id']}", headers=auth(other)).status_code in (403, 404)
    assert client.post(f"/memories/{draft['id']}/confirm", headers=headers(client, other)).status_code in (403, 404)
    with app.state.session_factory() as db:
        legacy = PersonalMemory(owner_id=owner['account']['id'], content='Pre-existing legacy candidate',
            kind='experience', status='candidate')
        db.add(legacy)
        db.commit()
        legacy_id = legacy.id
    assert client.get(f'/memories/{legacy_id}', headers=auth(owner)).json()['status'] == 'candidate'
    with app.state.session_factory() as db:
        assert db.get(PersonalMemory, legacy_id).content == 'Pre-existing legacy candidate'
    assert client.post(f'/memories/{legacy_id}/confirm', headers=headers(client, owner)).status_code == 200


def test_explicit_saved_edit_never_commits_a_new_pending_candidate(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    existing = save(client, owner, 'Previously explicitly saved body')
    edited = client.patch(f"/memories/{existing['id']}", headers=headers(client, owner),
        json={'content': 'Explicit Save changes final version'})
    assert edited.status_code == 200, edited.text
    assert edited.json()['status'] == 'confirmed'
    assert not [row for row in rows(app, PersonalMemory) if row.status == 'candidate']
    assert client.get(f"/memories/{existing['id']}", headers=auth(owner)).status_code == 404


def test_changed_memory_revision_cannot_silently_rebase_pending_draft(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    draft = candidate(client, owner)
    existing = save(client, owner, 'An unrelated explicit user save')
    confirmed = client.post(f"/memories/{draft['id']}/confirm", headers=headers(client, owner))
    assert confirmed.status_code in (404, 409), confirmed.text
    assert [row.id for row in rows(app, PersonalMemory)] == [existing['id']]


def test_expired_draft_is_not_listed_or_confirmable(setup, monkeypatch):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    clock = [100.0]
    monkeypatch.setattr(memories, 'monotonic', lambda: clock[0], raising=False)
    draft = candidate(client, owner)
    clock[0] += 1801
    assert client.get('/memories', headers=auth(owner)).json() == []
    assert client.post(f"/memories/{draft['id']}/confirm", headers=headers(client, owner)).status_code == 404
    assert rows(app, PersonalMemory) == []


def test_pending_drafts_are_bounded_without_persisting_overflow(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    revision = headers(client, owner)
    for number in range(64):
        response = client.post('/memories', headers=revision, json={'content': f'Synthetic draft {number}'})
        assert response.status_code == 201, response.text
    overflow = client.post('/memories', headers=revision, json={'content': 'Synthetic overflow'})
    assert overflow.status_code == 429
    assert rows(app, PersonalMemory) == []


def test_failed_confirmation_rolls_back_and_same_draft_can_be_explicitly_retried(setup, monkeypatch):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    draft = candidate(client, owner)
    captured = headers(client, owner)
    real_index = memories.index_memory_with_adapter

    async def interrupted_index(db, memory):
        await real_index(db, memory)
        raise RuntimeError('Synthetic interruption before confirmation commit')

    monkeypatch.setattr(memories, 'index_memory_with_adapter', interrupted_index)
    assert client.post(f"/memories/{draft['id']}/confirm", headers=captured).status_code == 500
    assert rows(app, PersonalMemory) == []
    monkeypatch.setattr(memories, 'index_memory_with_adapter', real_index)
    retried = client.post(f"/memories/{draft['id']}/confirm", headers=captured)
    assert retried.status_code == 200, retried.text
    assert [row.id for row in rows(app, PersonalMemory)] == [draft['id']]


def test_simultaneous_confirmations_create_only_one_record(setup):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    draft = candidate(client, owner)
    captured = headers(client, owner)
    with ThreadPoolExecutor(max_workers=2) as pool:
        attempts = [pool.submit(client.post, f"/memories/{draft['id']}/confirm", headers=captured) for _ in range(2)]
        responses = [attempt.result(timeout=15) for attempt in attempts]
    assert sorted(response.status_code for response in responses) == [200, 409]
    assert [row.id for row in rows(app, PersonalMemory)] == [draft['id']]


def test_legacy_unconfirmed_edit_cannot_bypass_disabled_memory(setup):
    app, client, (owner, _, _) = setup
    with app.state.session_factory() as db:
        legacy = PersonalMemory(owner_id=owner['account']['id'], content='Existing unconfirmed user data',
            kind='experience', status='candidate')
        db.add(legacy)
        db.commit()
        legacy_id = legacy.id
    edited = client.patch(f'/memories/{legacy_id}', headers=headers(client, owner),
        json={'content': 'Must not become active while Memory is off'})
    assert edited.status_code == 403, edited.text
    stored = rows(app, PersonalMemory)
    assert [(row.id, row.content, row.status) for row in stored] == [
        (legacy_id, 'Existing unconfirmed user data', 'candidate')]


@pytest.mark.parametrize('operation', ['patch', 'confirm'])
def test_persisted_mutation_never_commits_past_a_released_revision_guard(setup, monkeypatch, operation):
    app, client, (owner, _, _) = setup
    enable(client, owner)
    existing = save(client, owner, 'Existing explicitly confirmed version')
    captured = headers(client, owner)
    original_lock = memories.lock_owner_account
    lock_calls = 0
    competing_writes = []

    def competing_lock(db, owner_id):
        nonlocal lock_calls
        lock_calls += 1
        if lock_calls == 2:
            # lock_owner_account's real first action is rollback. Make that
            # release/reacquire window deterministic, with a real API writer.
            db.rollback()
            competing = client.post('/memories/save', headers=captured,
                json={'content': 'Concurrent explicit save', 'kind': 'experience'})
            assert competing.status_code == 201, competing.text
            competing_writes.append(competing.json()['id'])
        original_lock(db, owner_id)

    monkeypatch.setattr(memories, 'lock_owner_account', competing_lock)
    if operation == 'patch':
        result = client.patch(f"/memories/{existing['id']}", headers=captured,
            json={'content': 'Stale competing replacement'})
    else:
        result = client.post(f"/memories/{existing['id']}/confirm", headers=captured)
    if competing_writes:
        assert result.status_code == 409, 'A newer committed owner revision was silently accepted'
        assert not [row for row in rows(app, PersonalMemory) if row.content == 'Stale competing replacement']
    else:
        assert result.status_code == 200, result.text
