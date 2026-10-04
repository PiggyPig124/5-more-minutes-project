"""User-confirmed opt-in policy; synthetic model decisions, no provider keys."""
from pathlib import Path
import asyncio
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, func
from app.main import create_app
from app.llm import AgentReply
from app.memory_models import PersonalMemory
from app.collaboration_models import FamilyMessage
from app.memory_models import Story
from .test_integration import _headers, _register
from .memory_revision_helpers import memory_revision_headers
from .test_agent_memory_community import (
    _settings, _enable_memory, _conversation, _send, _memory_action, MockMemoryModel,
)

TEXT = "I enjoy gardening."

def decision():
    return _memory_action("save_preference", TEXT, content=TEXT, topic_key="gardening")

@pytest.mark.parametrize("role,enabled,allowed", [
    ("elder", False, False), ("elder", True, True), ("caregiver", False, False),
])
def test_auto_save_requires_elder_opt_in_and_never_shares(tmp_path: Path, role, enabled, allowed):
    app = create_app(_settings(tmp_path / "policy.db"))
    with TestClient(app) as client:
        account = _register(client, f"{role}@example.test", role)
        headers = _headers(account)
        consent = client.get("/memories/consent", headers=headers)
        if role == "elder":
            assert consent.json()["enabled"] is False
        else:
            assert consent.status_code == 403
        if enabled:
            headers = _enable_memory(client, account)
        app.state.orchestrator = MockMemoryModel([[decision()]])
        result = _send(client, headers, _conversation(client, headers), TEXT, "auto")
        assert result.status_code == 200, result.text
        metadata = result.json()["assistant_message"]["metadata_json"]
        assert ("auto_saved_memory" in metadata) is allowed
        with app.state.session_factory() as db:
            assert db.scalar(select(func.count(PersonalMemory.id))) == int(allowed)
            assert db.scalar(select(func.count(FamilyMessage.id))) == 0
            assert db.scalar(select(func.count(Story.id))) == 0
        if allowed:
            memories = client.get("/memories", headers=headers).json()
            assert memories[0]["capture_method"] == "agent_auto"
            assert memories[0]["status"] == "confirmed"

@pytest.mark.parametrize("kind,sensitivity,content", [
    ("fact", "ordinary", "I worked as a teacher."),
    ("experience", "ordinary", "I worked as a teacher."),
    ("emotion", "ordinary", "I feel lonely."),
    ("preference", "sensitive", "I enjoy gardening."),
    ("preference", "uncertain", "I enjoy gardening."),
    ("preference", "ordinary", "I take medication for diabetes."),
])
def test_auto_save_exception_does_not_expand_to_other_or_sensitive_content(tmp_path, kind, sensitivity, content):
    app = create_app(_settings(tmp_path / "excluded.db"))
    with TestClient(app) as client:
        account = _register(client, "excluded@example.test")
        headers = _enable_memory(client, account)
        app.state.orchestrator = MockMemoryModel([[_memory_action("save_preference", content,
            content=content, kind=kind, sensitivity=sensitivity, topic_key="excluded")]])
        result = _send(client, headers, _conversation(client, headers), content, "excluded")
        assert result.status_code == 200, result.text
        assert "auto_saved_memory" not in result.json()["assistant_message"]["metadata_json"]
        assert client.get("/memories", headers=headers).json() == []

@pytest.mark.parametrize("barrier", ["off", "delete"])
def test_real_control_request_fences_delayed_auto_preference(tmp_path, barrier):
    app = create_app(_settings(tmp_path / "late.db"))
    with TestClient(app) as client:
        account = _register(client, "late@example.test")
        headers = _enable_memory(client, account)
        conversation = _conversation(client, headers)
        class DelayedModel:
            async def run(self, context, user_message):
                def apply_control():
                    if barrier == "off":
                        response = client.put("/memories/consent", headers=memory_revision_headers(client, headers), json={"enabled": False})
                    else:
                        revision = client.get("/memories/control-state", headers=headers).json()["revision"]
                        response = client.post("/memories/deletions", headers=headers,
                            json={"mode": "all", "memory_ids": [], "expected_revision": revision, "idempotency_key": "synthetic-late-delete"})
                    assert response.status_code == 200, response.text
                await asyncio.to_thread(apply_control)
                return AgentReply(text="Synthetic delayed reply", proposed_task=None,
                    mode="openai_compatible", memory_actions=[decision()])
        app.state.orchestrator = DelayedModel()
        result = _send(client, headers, conversation, TEXT, "late")
        assert result.status_code == 409, result.text
        assert client.get("/memories", headers=headers).json() == []

@pytest.mark.parametrize("operation", ["pause", "delete"])
@pytest.mark.parametrize("renamed_key", [False, True])
def test_same_topic_not_recaptured_after_owner_pause_or_delete(tmp_path, operation, renamed_key):
    app = create_app(_settings(tmp_path / "blocked.db"))
    with TestClient(app) as client:
        account = _register(client, "blocked@example.test")
        headers = _enable_memory(client, account)
        conversation = _conversation(client, headers)
        later_action = decision()
        if renamed_key:
            later_action["topic_key"] = "a_different_model_key"
        app.state.orchestrator = MockMemoryModel([[decision()], [later_action]])
        first = _send(client, headers, conversation, TEXT, "first")
        memory = first.json()["assistant_message"]["metadata_json"]["auto_saved_memory"]
        if operation == "pause":
            response = client.patch("/memories/" + memory["id"], headers=memory_revision_headers(client, headers), json={"suppressed": True})
        else:
            response = client.delete("/memories/" + memory["id"], headers={**memory_revision_headers(client, headers), "Idempotency-Key": "synthetic-delete"})
        assert response.status_code in (200, 204), response.text
        later = _send(client, headers, conversation, TEXT, "second")
        assert later.status_code == 200, later.text
        assert "auto_saved_memory" not in later.json()["assistant_message"]["metadata_json"]
        rows = client.get("/memories", headers=headers).json()
        assert all(r["suppressed"] for r in rows)


def test_explicit_owner_save_can_restore_deleted_content(tmp_path):
    app = create_app(_settings(tmp_path / "explicit-restore.db"))
    with TestClient(app) as client:
        owner = _register(client, "restore@example.test")
        headers = _enable_memory(client, owner)
        app.state.orchestrator = MockMemoryModel([[decision()]])
        first = _send(client, headers, _conversation(client, headers), TEXT, "first")
        memory = first.json()["assistant_message"]["metadata_json"]["auto_saved_memory"]
        deleted = client.delete("/memories/"+memory["id"], headers={
            **memory_revision_headers(client, headers), "Idempotency-Key": "delete-restore"})
        assert deleted.status_code == 204, deleted.text
        saved = client.post("/memories/save", headers=memory_revision_headers(client, headers),
            json={"content": TEXT, "kind": "preference", "topic_key": "gardening"})
        assert saved.status_code == 201, saved.text
        assert saved.json()["content"] == TEXT and saved.json()["id"] != memory["id"]
        assert client.get("/memories", headers=headers).json()[0]["suppressed"] is False
        from app.memory_service import _preference_content_hash, _preference_hash
        from app.memory_models import MemoryPreferenceBlock
        with app.state.session_factory() as db:
            for hashed in [_preference_content_hash(owner["account"]["id"], TEXT),
                           _preference_hash(owner["account"]["id"], "gardening")]:
                assert db.get(MemoryPreferenceBlock, (owner["account"]["id"], hashed)) is None


def test_content_fence_is_owner_scoped(tmp_path):
    app = create_app(_settings(tmp_path / "owner-scope.db"))
    with TestClient(app) as client:
        first = _register(client, "first@example.test")
        first_headers = _enable_memory(client, first)
        second = _register(client, "second@example.test")
        second_headers = _enable_memory(client, second)
        app.state.orchestrator = MockMemoryModel([[decision()], [decision()]])
        result = _send(client, first_headers, _conversation(client, first_headers), TEXT, "first")
        memory = result.json()["assistant_message"]["metadata_json"]["auto_saved_memory"]
        deleted = client.delete("/memories/"+memory["id"], headers={
            **memory_revision_headers(client, first_headers), "Idempotency-Key": "owner-delete"})
        assert deleted.status_code == 204, deleted.text
        result = _send(client, second_headers, _conversation(client, second_headers), TEXT, "second")
        assert result.status_code == 200, result.text
        assert "auto_saved_memory" in result.json()["assistant_message"]["metadata_json"]
        assert client.get("/memories", headers=first_headers).json() == []
        assert len(client.get("/memories", headers=second_headers).json()) == 1
