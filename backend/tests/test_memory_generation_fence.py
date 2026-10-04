"""Owner revision fences stale generation even without retrieved memories."""
import asyncio
from contextlib import nullcontext
from datetime import datetime, timezone
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.config import Settings
from app.llm import AgentReply
from app.main import create_app
from app.models import Conversation, Message
from app.memory_models import MemoryConsent, PersonalMemory
from app.memory_service import bump_memory_revision, lock_owner_account
from app.safety_models import CheckInSchedule
from app.care_models import CareNotification, CarePreference
from tests.test_integration import _headers, _register


@pytest.mark.parametrize('route, role, consent', [
    ('chat', 'elder', False),
    ('chat', 'elder', True),
    ('chat', 'caregiver', False),
    ('greeting', 'elder', False),
    ('greeting', 'elder', True),
])
def test_revision_change_rejects_inflight_generation_with_empty_sources(tmp_path, route, role, consent):
    app = create_app(Settings(database_url=f"sqlite:///{tmp_path / 'generation-fence.db'}",
                              auth_secret="generation-fence-test", demo_mode=True))
    with TestClient(app) as client:
        owner = _register(client, 'fence-owner@example.test', role)
        owner_id = owner['account']['id']
        headers = _headers(owner)
        with app.state.session_factory() as db:
            conversation = Conversation(owner_id=owner_id, title='Existing conversation',
                rolling_summary='A remembered preference was pottery.',
                recent_context=[{'role':'assistant', 'content':'You enjoy pottery.', 'ordinal':1}])
            db.add(conversation)
            if consent:
                db.add(MemoryConsent(owner_id=owner_id, enabled=True))
            if route == 'greeting':
                db.add(CarePreference(owner_id=owner_id,
                    settings={'quiet_start':'00:00', 'quiet_end':'00:00'}))
                db.add(CheckInSchedule(elder_id=owner_id, enabled=True,
                    frequency='daily', check_in_time='10:00', weekday=1))
            db.commit()
            conversation_id = conversation.id

        def commit_delete_fence():
            # Synthetic owner-atomic deletion effect. No real data or DeleteAll
            # API is involved: this proves the consumer handles the barrier.
            with app.state.session_factory() as db:
                lock_owner_account(db, owner_id)
                row = db.get(Conversation, conversation_id)
                row.rolling_summary = ''
                row.recent_context = []
                bump_memory_revision(db, owner_id)
                db.commit()

        class ModelDuringDeletion:
            calls = 0

            async def run(self, context, user_message):
                self.calls += 1
                assert context['memory_sources'] == []
                assert 'pottery' in context['rolling_summary']
                assert 'pottery' in str(context['recent_context'])
                await asyncio.to_thread(commit_delete_fence)
                return AgentReply(text='Stale remembered pottery response', proposed_task=None,
                    mode='openai_compatible', memory_actions=[{
                        'action':'save_preference', 'memory_id':None,
                        'content':'I enjoy pottery.', 'kind':'preference',
                        'sensitivity':'ordinary', 'topic_key':'pottery',
                        'evidence':'I enjoy pottery.',
                    }])

        model = ModelDuringDeletion()
        app.state.orchestrator = model
        if route == 'greeting':
            fixed = datetime(2026, 10, 3, 4, 0, tzinfo=timezone.utc)
            clock_context = patch('app.routers.check_ins.datetime')
        else:
            clock_context = nullcontext()
        with clock_context as clock:
            if route == 'greeting':
                clock.now.return_value = fixed
                clock.combine.side_effect = datetime.combine
                response = client.post('/check-ins/trigger', headers=headers,
                                       json={'conversation_id':conversation_id})
            else:
                response = client.post(f'/conversations/{conversation_id}/messages', headers=headers,
                                       json={'content':'I enjoy pottery.', 'client_message_id':'old-generation'})
        assert response.status_code == 409, response.text
        assert model.calls == 1
        with app.state.session_factory() as db:
            assert db.scalar(select(func.count(Message.id)).where(Message.conversation_id == conversation_id)) == 0
            assert db.scalar(select(func.count(PersonalMemory.id)).where(PersonalMemory.owner_id == owner_id)) == 0
            assert db.scalar(select(func.count(CareNotification.id)).where(CareNotification.owner_id == owner_id)) == 0
            current = db.get(Conversation, conversation_id)
            assert current.rolling_summary == '' and current.recent_context == []
            if route == 'greeting':
                schedule = db.scalar(select(CheckInSchedule).where(CheckInSchedule.elder_id == owner_id))
                assert schedule.last_check_in_at is None
