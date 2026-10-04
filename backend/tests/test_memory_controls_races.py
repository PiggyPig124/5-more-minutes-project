"""Synthetic race acceptance for memory controls and captured model revisions."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from threading import Event
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from sqlalchemy import event, func, select

from app.care_models import CareNotification
from app.collaboration_models import FamilyMessage
from app.community_models import CommunitySkill
from app.llm import AgentReply
from app.memory_models import MemoryEmbedding, PersonalMemory, Story, StoryMemoryLink
from app.memory_service import (EmbeddingAdapter, index_memory_with_adapter,
    lock_owner_account, purge_memory_set, retrieve_for_chat)
from app.models import Conversation, FamilyLink, Message, Task
from app.task_share_models import TaskShare
from app.task_share_service import content_hash
from tests.test_memory_controls import setup as controls, auth, state, headers, enable, save, deletion


@pytest.mark.parametrize('operation', ['retrieve', 'index'])
@pytest.mark.parametrize('barrier', ['delete', 'consent_off'])
def test_delayed_embedding_cannot_cross_delete_or_consent_barrier(controls, operation, barrier):
    app, client, (owner, _, _) = controls
    enable(client, owner)
    memory = save(client, owner, 'I taught mathematics in Tai O')
    owner_id = owner['account']['id']

    class DelayedAdapter:
        settings = SimpleNamespace(configured=True, model='synthetic-vector', dimensions=1)

        async def embed(self, text):
            if barrier == 'delete':
                result = await asyncio.to_thread(deletion, client, owner, key=f'{operation}-barrier')
                assert result.status_code == 200, result.text
            else:
                result = await asyncio.to_thread(enable, client, owner, False)
                assert result['enabled'] is False
            return [1.0]

    async def delayed_operation():
        with app.state.session_factory() as db:
            if operation == 'retrieve':
                return await retrieve_for_chat(db, owner_id, 'Tai O mathematics', adapter=DelayedAdapter())
            row = db.get(PersonalMemory, memory['id'])
            await index_memory_with_adapter(db, row, DelayedAdapter())
            db.commit()

    with pytest.raises(HTTPException) as rejected:
        asyncio.run(delayed_operation())
    assert rejected.value.status_code == 409
    with app.state.session_factory() as db:
        assert db.scalar(select(func.count(MemoryEmbedding.id)).where(MemoryEmbedding.memory_id == memory['id'])) == 0
        assert (db.get(PersonalMemory, memory['id']) is None) is (barrier == 'delete')


def test_delete_wins_owner_lock_and_rejects_old_save_but_allows_fresh_save(controls):
    app, client, (owner, _, _) = controls
    enable(client, owner)
    memory = save(client, owner)
    captured_headers = headers(client, owner)
    waiting = Event()

    def observe_waiting_writer(connection, cursor, statement, parameters, context, executemany):
        if statement.strip().upper() == 'BEGIN IMMEDIATE':
            waiting.set()

    with app.state.session_factory() as deletion_session:
        lock_owner_account(deletion_session, owner['account']['id'])
        event.listen(app.state.engine, 'before_cursor_execute', observe_waiting_writer)
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(client.post, '/memories/save', headers=captured_headers,
                                      json={'content':'Old RAM draft', 'kind':'experience'})
                try:
                    assert waiting.wait(3), 'Save did not attempt its owner lock'
                finally:
                    # Real production purge under the already acquired owner
                    # lock fixes the delete-first order without timing sleeps.
                    purge_memory_set(deletion_session, owner['account']['id'], {memory['id']})
                    deletion_session.commit()
                rejected = pending.result(timeout=5)
        finally:
            event.remove(app.state.engine, 'before_cursor_execute', observe_waiting_writer)
    assert rejected.status_code == 409, rejected.text
    assert state(client, owner)['counts']['total'] == 0
    fresh = save(client, owner, 'Explicitly saved after reading new revision')
    assert client.get('/memories', headers=auth(owner)).json()[0]['id'] == fresh['id']


def test_save_wins_owner_lock_and_stale_delete_cannot_remove_new_save(controls, monkeypatch):
    app, client, (owner, _, _) = controls
    enable(client, owner)
    before_revision = state(client, owner)['revision']
    captured_headers = headers(client, owner)
    embedding_started, release_embedding, delete_waiting = Event(), Event(), Event()

    async def delay_embedding(self, text):
        embedding_started.set()
        assert await asyncio.to_thread(release_embedding.wait, 3)
        return [1.0]

    def observe_waiting_delete(connection, cursor, statement, parameters, context, executemany):
        if statement.strip().upper() == 'BEGIN IMMEDIATE':
            delete_waiting.set()

    monkeypatch.setattr(EmbeddingAdapter, 'embed', delay_embedding)
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending_save = pool.submit(client.post, '/memories/save', headers=captured_headers,
                                   json={'content':'Save committed before delete', 'kind':'experience'})
        try:
            assert embedding_started.wait(3), 'Save did not reach embedding while holding owner lock'
            event.listen(app.state.engine, 'before_cursor_execute', observe_waiting_delete)
            pending_delete = pool.submit(deletion, client, owner, revision=before_revision, key='stale-delete')
            try:
                assert delete_waiting.wait(3), 'Delete did not attempt the owner lock'
            finally:
                release_embedding.set()
            saved_result, deleted_result = pending_save.result(timeout=5), pending_delete.result(timeout=5)
        finally:
            release_embedding.set()
            if event.contains(app.state.engine, 'before_cursor_execute', observe_waiting_delete):
                event.remove(app.state.engine, 'before_cursor_execute', observe_waiting_delete)
    assert saved_result.status_code == 201, saved_result.text
    assert deleted_result.status_code == 409, deleted_result.text
    assert client.get('/memories', headers=auth(owner)).json()[0]['id'] == saved_result.json()['id']


@pytest.mark.parametrize('operation', ['skill_get', 'skill_decision', 'story_create', 'story_share'])
def test_captured_derived_request_is_rejected_after_deletion(controls, operation):
    app, client, (owner, _, recipient) = controls
    enable(client, owner)
    memory = save(client, owner, 'I worked as a gardening teacher')
    owner_id = owner['account']['id']
    with app.state.session_factory() as db:
        story = Story(owner_id=owner_id, title='Garden', content='Derived garden story')
        skill = CommunitySkill(owner_id=owner_id, memory_id=memory['id'], suggestion='Gardening')
        link = FamilyLink(elder_id=owner_id, caregiver_id=recipient['account']['id'],
                          scopes=['family_messages'], status='active')
        db.add_all([story, skill, link])
        db.flush()
        db.add(StoryMemoryLink(story_id=story.id, memory_id=memory['id']))
        db.commit(); story_id, skill_id = story.id, skill.id
        family_preview = {'family_link_id': link.id, 'expected_authorization_epoch': link.authorization_epoch}
    captured_headers = headers(client, owner)
    assert deletion(client, owner).status_code == 200
    if operation == 'skill_get':
        result = client.get('/community/skills/suggestions', headers=captured_headers)
    elif operation == 'skill_decision':
        result = client.post(f'/community/skills/{skill_id}/decision', headers=captured_headers, json={'decision':'confirm'})
    elif operation == 'story_create':
        result = client.post('/stories', headers=captured_headers,
            json={'title':'Old draft', 'content':'Old derived story', 'memory_ids':[memory['id']]})
    else:
        result = client.post('/family-messages', headers=captured_headers,
            json={'recipient_id':recipient['account']['id'], 'source_story_id':story_id, **family_preview,
                  'content':'Garden\nDerived garden story', 'client_message_id':'stale-story-share'})
    assert result.status_code == 409, result.text
    with app.state.session_factory() as db:
        for model in (PersonalMemory, CommunitySkill, Story, FamilyMessage):
            owner_field = model.sender_id if model is FamilyMessage else model.owner_id
            assert db.scalar(select(func.count()).select_from(model).where(owner_field == owner_id)) == 0


def test_bulk_cleanup_redacts_derived_copies_and_preserves_independent_and_other_owner_data(controls):
    app, client, (owner, other, recipient) = controls
    enable(client, owner)
    owner_id, other_id, recipient_id = owner['account']['id'], other['account']['id'], recipient['account']['id']
    with app.state.session_factory() as db:
        link = FamilyLink(elder_id=owner_id, caregiver_id=recipient_id, scopes=['family_messages','care_tasks'], status='active')
        conversation = Conversation(owner_id=owner_id, title='Memory conversation')
        other_conversation = Conversation(owner_id=other_id, title='Keep other context', rolling_summary='Other owner text')
        independent_story = Story(owner_id=owner_id, title='Independent', content='Keep independent story')
        derived_story = Story(owner_id=owner_id, title='Derived', content='Private mathematics story')
        task = Task(owner_id=owner_id, created_by=owner_id, title='Independent task', description='Keep task')
        db.add_all([link, conversation, other_conversation, independent_story, derived_story, task]); db.flush()
        source = Message(conversation_id=conversation.id, sender_id=owner_id, role='user', content='I taught mathematics in Tai O', ordinal=1)
        db.add(source); db.flush()
        current = PersonalMemory(owner_id=owner_id, content=source.content, kind='experience', status='confirmed', source_message_id=source.id)
        candidate = PersonalMemory(owner_id=owner_id, content='Pending own candidate')
        paused = PersonalMemory(owner_id=owner_id, content='Paused own memory', status='confirmed', suppressed=True)
        legacy = PersonalMemory(owner_id=owner_id, content='Legacy own deleted', deleted_at=datetime.now(timezone.utc))
        foreign = PersonalMemory(owner_id=other_id, content='Other owner confirmed', status='confirmed')
        foreign_candidate = PersonalMemory(owner_id=other_id, content='Other owner candidate')
        db.add_all([current, candidate, paused, legacy, foreign, foreign_candidate]); db.flush()
        old = PersonalMemory(owner_id=owner_id, content='Own predecessor', superseded_by=current.id)
        derived_turn = Message(conversation_id=conversation.id, role='assistant', content='A paraphrased private teaching story', ordinal=2,
                               metadata_json={'memory_sources':[{'id':current.id, 'content':current.content}]})
        copied = FamilyMessage(link_id=link.id, sender_id=owner_id, recipient_id=recipient_id, source_story_id=derived_story.id,
                               content='Derived\nPrivate mathematics story', client_message_id='derived-copy')
        independent_message = FamilyMessage(link_id=link.id, sender_id=owner_id, recipient_id=recipient_id,
                                            content='Keep unrelated family hello', client_message_id='ordinary-copy')
        explicit_task_share = TaskShare(task_id=task.id, family_link_id=link.id, shared_by=owner_id,
            content_hash=content_hash(task), request_hash='b'*64, idempotency_key='independent-task-consent')
        db.add_all([old, derived_turn, copied, independent_message, explicit_task_share,
                    StoryMemoryLink(story_id=derived_story.id, memory_id=current.id),
                    CommunitySkill(owner_id=owner_id, memory_id=current.id, suggestion='Teaching'),
                    MemoryEmbedding(memory_id=current.id, embedding=[1.0]),
                    MemoryEmbedding(memory_id=foreign.id, embedding=[2.0])])
        conversation.recent_context = [{'role':'user','content':current.content,'ordinal':1}]
        conversation.rolling_summary = current.content
        db.commit()
        keep_ids = {'story':independent_story.id,'task':task.id,'share':explicit_task_share.id,
                    'message':independent_message.id,'copy':copied.id,'foreign':foreign.id,
                    'foreign_candidate':foreign_candidate.id,'conversation':conversation.id,
                    'other_conversation':other_conversation.id}
    assert client.get(f'/tasks/{keep_ids["task"]}', headers=auth(recipient)).status_code == 200
    result = deletion(client, owner)
    assert result.status_code == 200, result.text
    assert client.get(f'/tasks/{keep_ids["task"]}', headers=auth(recipient)).status_code == 200
    assert result.json()['counts'] == {'memories':5, 'stories':1}
    with app.state.session_factory() as db:
        assert db.scalar(select(func.count(PersonalMemory.id)).where(PersonalMemory.owner_id == owner_id)) == 0
        assert db.scalar(select(func.count(CommunitySkill.id)).where(CommunitySkill.owner_id == owner_id)) == 0
        assert db.get(Story, keep_ids['story']).content == 'Keep independent story'
        assert db.get(Task, keep_ids['task']).description == 'Keep task'
        assert db.get(TaskShare, keep_ids['share']).revoked_at is None
        assert db.get(FamilyMessage, keep_ids['message']).content == 'Keep unrelated family hello'
        assert db.get(FamilyMessage, keep_ids['copy']).content == '[故事已由擁有人撤回]'
        assert db.get(PersonalMemory, keep_ids['foreign']).content == 'Other owner confirmed'
        assert db.get(PersonalMemory, keep_ids['foreign_candidate']).content == 'Other owner candidate'
        assert db.scalar(select(func.count(MemoryEmbedding.id)).where(MemoryEmbedding.memory_id == keep_ids['foreign'])) == 1
        assert db.get(Conversation, keep_ids['other_conversation']).rolling_summary == 'Other owner text'
        cleaned = db.get(Conversation, keep_ids['conversation'])
        assert 'mathematics' not in str(cleaned.recent_context) + cleaned.rolling_summary
        for message in db.scalars(select(Message).where(Message.conversation_id == cleaned.id)):
            assert 'Tai O' not in message.content and 'private teaching story' not in message.content
            assert not (message.metadata_json or {}).get('memory_sources')


def test_model_suggestion_captures_post_action_revision_for_owner_save(controls):
    app, client, (owner, _, _) = controls
    enable(client, owner)
    before = state(client, owner)['revision']
    conversation = client.post('/conversations', headers=auth(owner), json={}).json()

    class Model:
        async def run(self, context, user_message):
            return AgentReply(text='Preference saved; review the story if you wish.', proposed_task=None,
                mode='openai_compatible', memory_actions=[
                    {'action':'save_preference','memory_id':None,'content':'I enjoy pottery.',
                     'kind':'preference','sensitivity':'ordinary','topic_key':'pottery','evidence':'I enjoy pottery.'},
                    {'action':'suggest','memory_id':None,'content':'I taught pottery years ago.',
                     'kind':'experience','sensitivity':'ordinary','topic_key':None,'evidence':'I taught pottery years ago.'},
                ])

    app.state.orchestrator = Model()
    response = client.post(f'/conversations/{conversation["id"]}/messages', headers=auth(owner),
        json={'content':'I enjoy pottery. I taught pottery years ago.', 'client_message_id':'suggestion-revision'})
    assert response.status_code == 200, response.text
    metadata = response.json()['assistant_message']['metadata_json']
    current = state(client, owner)['revision']
    assert current > before
    assert metadata['memory_revision'] == current
    assert metadata['memory_suggestion']['revision'] == current
    history = client.get(f'/conversations/{conversation["id"]}/messages', headers=auth(owner)).json()
    assert history[-1]['metadata_json']['memory_suggestion']['revision'] == current
    suggestion = metadata['memory_suggestion']
    saved = client.post('/memories/save', headers={**auth(owner),'X-Memory-Revision':str(suggestion['revision'])},
        json={'content':suggestion['content'], 'kind':suggestion['kind'], 'source_message_id':suggestion['source_message_id']})
    assert saved.status_code == 201, saved.text
