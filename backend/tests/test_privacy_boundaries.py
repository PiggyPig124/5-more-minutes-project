from __future__ import annotations
from .memory_revision_helpers import memory_revision_headers

from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.config import Settings
from app.llm import AgentReply
from app.main import create_app
from app.memory_models import MemoryConsent, PersonalMemory
from app.models import Conversation, Message
from app.memory_service import retrieve_for_chat
import asyncio


def _settings(path: Path) -> Settings:
    return Settings(database_url=f"sqlite:///{path}", auth_secret="privacy-test-secret", demo_mode=True)


def _register(client: TestClient, email: str, *, enable_memory: bool = False) -> dict:
    response = client.post(
        "/auth/register",
        json={"email": email, "password": "correct horse battery", "display_name": "Test Elder"},
    )
    assert response.status_code == 201, response.text
    account = response.json()
    if enable_memory:
        changed = client.put(
            "/memories/consent",
            headers=memory_revision_headers(client, {"Authorization": f"Bearer {account['access_token']}"}),
            json={"enabled": True},
        )
        assert changed.status_code == 200, changed.text
    return account


def _headers(account: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {account['access_token']}"}


def test_guest_context_is_ephemeral_expires_and_can_be_ended(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "guest.db"))

    class EchoOrchestrator:
        async def run(self, context, user_message):
            assert "memory_sources" in context and context["memory_sources"] == []
            earlier = " ".join(item["content"] for item in context["recent_context"])
            return type("Reply", (), {"text": f"{earlier} {user_message}".strip(), "mode": "deterministic_demo"})()

    with TestClient(app) as client:
        app.state.orchestrator = EchoOrchestrator()
        created = client.post("/guest/sessions")
        assert created.status_code == 201
        session_id = created.json()["session_id"]
        first = client.post(f"/guest/sessions/{session_id}/messages", json={"content": "I like tea."})
        assert first.status_code == 200
        second = client.post(f"/guest/sessions/{session_id}/messages", json={"content": "What did I say?"})
        assert second.status_code == 200
        assert "I like tea." in second.json()["reply"]

        with app.state.session_factory() as db:
            assert db.scalar(select(func.count(Conversation.id))) == 0
            assert db.scalar(select(func.count(Message.id))) == 0

        app.state.guest_sessions[session_id]["expires_at"] = datetime.now(timezone.utc) - timedelta(seconds=1)
        expired = client.post(f"/guest/sessions/{session_id}/messages", json={"content": "again"})
        assert expired.status_code == 404
        assert session_id not in app.state.guest_sessions
        assert client.post(f"/guest/sessions/{session_id}/messages", json={"content": "again"}).status_code == 404

        ended = client.post("/guest/sessions")
        assert client.delete(f"/guest/sessions/{ended.json()['session_id']}").status_code == 204
        assert ended.json()["session_id"] not in app.state.guest_sessions


def test_memory_defaults_off_blocks_create_search_and_chat_suggestion_but_keeps_management(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "consent.db"))
    with TestClient(app) as client:
        elder = _register(client, "default-off@example.test")
        headers = _headers(elder)
        assert client.get("/memories/consent", headers=headers).json() == {
            "enabled": False, "revision": 0, "counts": {"total": 0, "current": 0},
        }
        assert client.post("/memories", headers=memory_revision_headers(client, headers), json={"content": "Jasmine tea"}).status_code == 403
        assert client.post("/memories/search", headers=headers, json={"query": "tea"}).status_code == 403

        # Existing account records remain reviewable and removable while consent is off.
        with app.state.session_factory() as db:
            memory = PersonalMemory(owner_id=elder["account"]["id"], content="Existing memory", status="confirmed")
            db.add(memory)
            db.commit()
            memory_id = memory.id
        assert client.get("/memories", headers=headers).status_code == 200
        edited = client.patch(f"/memories/{memory_id}", headers=memory_revision_headers(client, headers), json={"content": "Edited"})
        assert edited.status_code == 200
        assert client.delete(f"/memories/{edited.json()['id']}", headers=memory_revision_headers(client, headers, idempotency_key='test_privacy_boundaries-96-delete')).status_code == 204

        conversation = client.post("/conversations", headers=headers, json={}).json()
        turn = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=headers,
            json={"content": "Remember that I like jasmine tea."},
        )
        assert turn.status_code == 200, turn.text
        assert "memory_suggestion" not in turn.json()["assistant_message"]["metadata_json"]
        with app.state.session_factory() as db:
            assert db.scalar(select(func.count(PersonalMemory.id)).where(PersonalMemory.owner_id == elder["account"]["id"])) == 0


def test_explicit_save_is_first_memory_persistence_and_opt_out_stops_recall(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "save.db"))

    class MockMemoryModel:
        async def run(self, context, user_message):
            assert "memory_management" in context
            return AgentReply(
                text="我可以替你保留這項偏好。",
                proposed_task=None,
                mode="openai_compatible",
                memory_actions=[{
                    "action": "suggest",
                    "memory_id": None,
                    "content": "I like jasmine tea.",
                    "kind": "preference",
                    "sensitivity": "ordinary",
                    "topic_key": "jasmine_tea",
                    "evidence": "Remember that I like jasmine tea.",
                }],
            )

    app.state.orchestrator = MockMemoryModel()
    with TestClient(app) as client:
        elder = _register(client, "save-explicit@example.test", enable_memory=True)
        headers = _headers(elder)
        conversation = client.post("/conversations", headers=headers, json={}).json()
        turn = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=headers,
            json={"content": "Remember that I like jasmine tea.", "client_message_id": "save-turn"},
        )
        assert turn.status_code == 200, turn.text
        suggestion = turn.json()["assistant_message"]["metadata_json"]["memory_suggestion"]
        assert suggestion == {
            "content": "I like jasmine tea.",
            "kind": "preference",
            "source_message_id": turn.json()["user_message"]["id"],
            "sensitivity": "ordinary",
            "requires_confirmation": True,
            "topic_key": "jasmine_tea",
            "revision": 1,
        }
        assert "candidate_memory_id" not in turn.json()["assistant_message"]["metadata_json"]

        with app.state.session_factory() as db:
            assert db.scalar(select(func.count(PersonalMemory.id))) == 0
            assistant = db.scalar(select(Message).where(Message.role == "assistant"))
            assert assistant.metadata_json["memory_suggestion"]["content"] == suggestion["content"]

        saved = client.post(
            "/memories/save",
            headers=memory_revision_headers(client, headers),
            json={
                "content": suggestion["content"],
                "kind": suggestion["kind"],
                "source_message_id": suggestion["source_message_id"],
                "topic_key": suggestion["topic_key"],
            },
        )
        assert saved.status_code == 201, saved.text
        assert saved.json()["status"] == "confirmed"
        replay = client.post(
            "/memories/save",
            headers=memory_revision_headers(client, headers),
            json={
                "content": suggestion["content"],
                "kind": suggestion["kind"],
                "source_message_id": suggestion["source_message_id"],
                "topic_key": suggestion["topic_key"],
            },
        )
        assert replay.status_code == 201
        assert replay.json()["id"] == saved.json()["id"]

        withdrawal_headers = memory_revision_headers(client, headers)
        assert client.put("/memories/consent", headers=withdrawal_headers, json={"enabled": False}).json() == {
            "enabled": False,
            "revision": int(withdrawal_headers["X-Memory-Revision"]) + 1,
            "counts": {"total": 1, "current": 1},
        }
        assert client.post("/memories/search", headers=headers, json={"query": "jasmine"}).status_code == 403
        with app.state.session_factory() as db:
            retrieval = asyncio.run(retrieve_for_chat(db, elder["account"]["id"], "jasmine"))
            assert retrieval["items"] == []
            assert retrieval["retrieval_mode"] == "disabled"
            assert db.get(MemoryConsent, elder["account"]["id"]).enabled is False
            assert db.scalar(select(func.count(PersonalMemory.id))) == 1


def test_existing_database_without_consent_table_starts_default_off(tmp_path: Path) -> None:
    database = tmp_path / "legacy.db"
    app = create_app(_settings(database))
    with TestClient(app) as client:
        elder = _register(client, "legacy-account@example.test")
        token = elder["access_token"]
        with app.state.engine.begin() as connection:
            connection.exec_driver_sql("DROP TABLE memory_consents")

    restarted = create_app(_settings(database))
    with TestClient(restarted) as client:
        consent = client.get("/memories/consent", headers={"Authorization": f"Bearer {token}"})
        assert consent.status_code == 200
        assert consent.json() == {
            "enabled": False, "revision": 0, "counts": {"total": 0, "current": 0},
        }
        assert client.post(
            "/memories", headers=memory_revision_headers(client, {"Authorization": f"Bearer {token}"}), json={"content": "Legacy"}
        ).status_code == 403
