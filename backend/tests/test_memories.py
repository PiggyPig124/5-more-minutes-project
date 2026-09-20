from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.memory_models import PersonalMemory
from app.models import Conversation, Message
from app.memory_service import (
    EmbeddingAdapter,
    EmbeddingSettings,
    index_memory_with_adapter,
    retrieve_for_chat,
)
from app.routers import memories, stories


def _settings(path: Path) -> Settings:
    return Settings(database_url=f"sqlite:///{path}", auth_secret="memory-test-secret", demo_mode=True)


def _headers(account: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {account['access_token']}"}


def _register(client: TestClient, email: str, role: str = "elder") -> dict:
    response = client.post(
        "/auth/register",
        json={
            "email": email,
            "password": "correct horse battery",
            "display_name": email.split("@")[0],
            "role": role,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def _memory_app(path: Path):
    app = create_app(_settings(path))
    # The parent integration task owns main.py. Tests attach the new routers
    # explicitly while still using the production app factory and database.
    app.include_router(memories.router)
    app.include_router(stories.router)
    return app


def test_candidates_confirmation_retrieval_and_private_isolation(tmp_path: Path) -> None:
    app = _memory_app(tmp_path / "memory.db")
    with TestClient(app) as client:
        elder = _register(client, "memory-owner@example.test")
        other = _register(client, "other-owner@example.test")
        caregiver = _register(client, "memory-caregiver@example.test", "caregiver")

        created = client.post(
            "/memories",
            headers=_headers(elder),
            json={"content": "My favourite tea is jasmine.", "kind": "preference"},
        )
        assert created.status_code == 201, created.text
        memory = created.json()
        assert memory["status"] == "candidate"
        assert client.post(
            "/memories/search", headers=_headers(elder), json={"query": "jasmine tea"}
        ).json()["items"] == []

        confirmed = client.post(f"/memories/{memory['id']}/confirm", headers=_headers(elder))
        assert confirmed.status_code == 200
        search = client.post(
            "/memories/search", headers=_headers(elder), json={"query": "jasmine tea"}
        )
        assert search.status_code == 200
        assert search.json()["items"][0]["id"] == memory["id"]
        assert search.json()["retrieval_mode"] == "keyword"
        unrelated = client.post(
            "/memories/search",
            headers=_headers(elder),
            json={"query": "\u4f60\u8a18\u5f97\u6211\u559c\u6b61\u98df\u4ec0\u9ebc"},
        )
        assert unrelated.status_code == 200
        assert unrelated.json()["items"] == []

        assert client.get(f"/memories/{memory['id']}", headers=_headers(other)).status_code in {403, 404}
        assert client.get("/memories", headers=_headers(caregiver)).status_code == 403
        assert client.post(
            "/memories/search", headers=_headers(caregiver), json={"query": "jasmine"}
        ).status_code == 403


def test_event_time_is_validated_and_preserved_across_correction(tmp_path: Path) -> None:
    app = _memory_app(tmp_path / "event-time.db")
    with TestClient(app) as client:
        elder = _register(client, "event-owner@example.test")
        headers = _headers(elder)
        created = client.post(
            "/memories",
            headers=headers,
            json={"content": "Graduated from school", "event_time": "1988-06-01"},
        )
        assert created.status_code == 201, created.text
        assert created.json()["event_time"] == "1988-06-01"
        memory_id = created.json()["id"]
        invalid = client.patch(
            f"/memories/{memory_id}", headers=headers, json={"event_time": "tomorrow"}
        )
        assert invalid.status_code == 422
        assert client.patch(f"/memories/{memory_id}", headers=headers, json={"content": None}).status_code == 422
        assert client.patch(f"/memories/{memory_id}", headers=headers, json={"kind": None}).status_code == 422
        corrected = client.patch(
            f"/memories/{memory_id}", headers=headers, json={"event_time": "1989-06-01T12:30:00+08:00"}
        )
        assert corrected.status_code == 200, corrected.text
        assert corrected.json()["event_time"] == "1989-06-01T12:30:00+08:00"


def test_deletion_rebuilds_an_old_rolling_summary(tmp_path: Path) -> None:
    app = _memory_app(tmp_path / "summary-scrub.db")
    with TestClient(app) as client:
        elder = _register(client, "summary-owner@example.test")
        headers = _headers(elder)
        conversation_id = client.post("/conversations", headers=headers, json={}).json()["id"]
        with app.state.session_factory() as db:
            conversation = db.get(Conversation, conversation_id)
            source = Message(
                conversation_id=conversation_id,
                sender_id=elder["account"]["id"],
                role="user",
                content="My private garden memory",
                metadata_json={"source_memory_ids": ["pending"]},
                ordinal=1,
            )
            db.add(source)
            db.flush()
            for ordinal in range(2, 16):
                db.add(
                    Message(
                        conversation_id=conversation_id,
                        sender_id=elder["account"]["id"],
                        role="user",
                        content=f"ordinary turn {ordinal}",
                        metadata_json={},
                        ordinal=ordinal,
                    )
                )
            memory = PersonalMemory(
                owner_id=elder["account"]["id"],
                content="My private garden memory",
                kind="experience",
                status="confirmed",
                source_message_id=source.id,
            )
            db.add(memory)
            db.flush()
            source.metadata_json = {"source_memory_ids": [memory.id]}
            conversation.recent_context = [
                {"role": "user", "content": f"ordinary turn {ordinal}", "ordinal": ordinal}
                for ordinal in range(4, 16)
            ]
            conversation.rolling_summary = "user: My private garden memory"
            db.commit()
            memory_id = memory.id

        assert client.delete(f"/memories/{memory_id}", headers=headers).status_code == 204
        detail = client.get(f"/conversations/{conversation_id}", headers=headers)
        assert detail.status_code == 200
        payload = detail.json()
        assert "My private garden memory" not in payload["rolling_summary"]
        assert "My private garden memory" not in str(payload["recent_context"])


def test_correction_suppression_and_deletion_propagate(tmp_path: Path) -> None:
    app = _memory_app(tmp_path / "propagation.db")
    with TestClient(app) as client:
        elder = _register(client, "propagation@example.test")
        conversation = client.post("/conversations", headers=_headers(elder), json={}).json()
        turn = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "I enjoy jasmine tea.", "client_message_id": "source-1"},
        ).json()
        source_id = turn["user_message"]["id"]
        created = client.post(
            "/memories",
            headers=_headers(elder),
            json={
                "content": "I enjoy jasmine tea.",
                "kind": "preference",
                "source_message_id": source_id,
            },
        ).json()
        old_id = created["id"]
        client.post(f"/memories/{old_id}/confirm", headers=_headers(elder))
        story = client.post(
            "/stories",
            headers=_headers(elder),
            json={"title": "Tea", "content": "A jasmine tea memory", "memory_ids": [old_id]},
        )
        assert story.status_code == 201, story.text

        corrected = client.patch(
            f"/memories/{old_id}",
            headers=_headers(elder),
            json={"content": "I enjoy oolong tea."},
        )
        assert corrected.status_code == 200, corrected.text
        new_id = corrected.json()["id"]
        assert new_id != old_id and corrected.json()["status"] == "candidate"
        assert client.get(f"/memories/{old_id}", headers=_headers(elder)).status_code == 404
        assert client.get("/stories", headers=_headers(elder)).json() == []
        messages = client.get(f"/conversations/{conversation['id']}/messages", headers=_headers(elder)).json()
        assert all("I enjoy jasmine tea." not in item["content"] for item in messages)

        client.post(f"/memories/{new_id}/confirm", headers=_headers(elder))
        story2 = client.post(
            "/stories",
            headers=_headers(elder),
            json={"title": "Tea 2", "content": "An oolong tea memory", "memory_ids": [new_id]},
        )
        assert story2.status_code == 201
        suppressed = client.patch(
            f"/memories/{new_id}", headers=_headers(elder), json={"suppressed": True}
        )
        assert suppressed.status_code == 200
        assert client.post(
            "/memories/search", headers=_headers(elder), json={"query": "oolong"}
        ).json()["items"] == []
        assert client.get("/stories", headers=_headers(elder)).json() == []

        deleted = client.delete(f"/memories/{new_id}", headers=_headers(elder))
        assert deleted.status_code == 204
        assert client.get(f"/memories/{new_id}", headers=_headers(elder)).status_code == 404


def test_story_sources_must_be_confirmed_and_owned(tmp_path: Path) -> None:
    app = _memory_app(tmp_path / "stories.db")
    with TestClient(app) as client:
        elder = _register(client, "story-owner@example.test")
        other = _register(client, "story-other@example.test")
        candidate = client.post(
            "/memories", headers=_headers(elder), json={"content": "A candidate"}
        ).json()
        candidate_story = client.post(
            "/stories",
            headers=_headers(elder),
            json={"title": "Candidate", "content": "Draft", "memory_ids": [candidate["id"]]},
        )
        assert candidate_story.status_code == 400
        client.post(f"/memories/{candidate['id']}/confirm", headers=_headers(elder))
        assert client.post(
            "/stories",
            headers=_headers(other),
            json={"title": "Wrong owner", "content": "No", "memory_ids": [candidate["id"]]},
        ).status_code == 400
        story = client.post(
            "/stories",
            headers=_headers(elder),
            json={"title": "Confirmed", "content": "A confirmed story", "memory_ids": [candidate["id"]]},
        )
        assert story.status_code == 201
        assert client.get(f"/stories/{story.json()['id']}", headers=_headers(other)).status_code in {403, 404}


def test_embedding_adapter_protocol_and_hybrid_retrieval(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    captured: list[dict] = []

    class FakeResponse:
        def raise_for_status(self) -> None:
            return None

        def json(self) -> dict:
            return {"data": [{"embedding": [1.0, 0.0]}]}

    class FakeClient:
        def __init__(self, *args, **kwargs):
            self.timeout = kwargs.get("timeout")

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def post(self, url, headers, json):
            captured.append({"url": url, "headers": headers, "json": json})
            return FakeResponse()

    monkeypatch.setattr("app.memory_service.httpx.AsyncClient", FakeClient)
    adapter = EmbeddingAdapter(
        EmbeddingSettings(
            api_key="embedding-secret",
            base_url="https://embedding.test/v1",
            model="mock-embedding",
            timeout_seconds=5,
            dimensions=2,
        )
    )
    assert asyncio.run(adapter.embed("jasmine")) == [1.0, 0.0]
    assert captured[0]["url"].endswith("/embeddings")
    assert captured[0]["headers"]["Authorization"] == "Bearer embedding-secret"

    app = _memory_app(tmp_path / "embedding.db")
    with TestClient(app) as client:
        elder = _register(client, "embedding-owner@example.test")
        with app.state.session_factory() as db:
            memory = PersonalMemory(
                owner_id=elder["account"]["id"],
                content="Jasmine tea from the garden",
                kind="experience",
                status="confirmed",
            )
            db.add(memory)
            db.flush()
            asyncio.run(index_memory_with_adapter(db, memory, adapter))
            db.commit()
            result = asyncio.run(retrieve_for_chat(db, elder["account"]["id"], "jasmine", adapter=adapter))
            assert result["retrieval_mode"] == "hybrid_python"
            assert result["items"][0]["id"] == memory.id
