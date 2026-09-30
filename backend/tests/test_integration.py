from __future__ import annotations

import asyncio
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.llm import AgentReply, OpenAICompatibleAdapter, _validate_memory_actions
from app.main import create_app


def _settings(database: Path, *, model_key: str | None = None) -> Settings:
    return Settings(
        database_url=f"sqlite:///{database}",
        auth_secret="integration-test-secret",
        model_api_key=model_key,
        demo_mode=model_key is None,
    )


def _register(client: TestClient, email: str, role: str = "elder") -> dict:
    response = client.post(
        "/auth/register",
        json={"email": email, "password": "correct horse battery", "display_name": email.split("@")[0], "role": role},
    )
    assert response.status_code == 201, response.text
    return response.json()


def _headers(auth: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {auth['access_token']}"}


def test_concurrent_messages_keep_response_pairing(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "parallel-messages.db"))

    class EchoOrchestrator:
        async def run(self, context, user_message):
            await asyncio.sleep(0.03)
            return AgentReply(text=f"Reply to {user_message}", proposed_task=None, mode="deterministic_demo")

    with TestClient(app) as client:
        elder = _register(client, "parallel@example.test")
        headers = _headers(elder)
        conversation = client.post("/conversations", headers=headers, json={}).json()
        url = f"/conversations/{conversation['id']}/messages"
        app.state.orchestrator = EchoOrchestrator()

        def send(index):
            return client.post(url, headers=headers, json={"content": f"turn {index}", "client_message_id": f"turn-{index}"})

        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(send, range(4)))
        assert all(result.status_code == 200 for result in results)
        history = client.get(url, headers=headers).json()
        assert [message["ordinal"] for message in history] == list(range(1, 9))
        for index, original in enumerate(results):
            replay = send(index)
            assert replay.status_code == 200
            assert replay.json()["assistant_message"]["id"] == original.json()["assistant_message"]["id"]
            assert replay.json()["assistant_message"]["content"] == f"Reply to turn {index}"


def test_competing_confirm_and_dismiss_keep_one_terminal_state(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "parallel-decisions.db"))
    with TestClient(app) as client:
        elder = _register(client, "decisions@example.test")
        headers = _headers(elder)
        conversation = client.post("/conversations", headers=headers, json={}).json()
        for index in range(4):
            reply = client.post(
                f"/conversations/{conversation['id']}/messages", headers=headers,
                json={"content": "Please remind me to call my daughter", "client_message_id": f"decision-{index}"},
            ).json()
            action_id = reply["action"]["id"]
            with ThreadPoolExecutor(max_workers=2) as pool:
                confirm = pool.submit(client.post, f"/actions/{action_id}/confirm", headers=headers, json={})
                dismiss = pool.submit(client.post, f"/actions/{action_id}/dismiss", headers=headers)
                confirmed, dismissed = confirm.result(), dismiss.result()
            assert confirmed.status_code in {200, 409}
            assert dismissed.status_code == 200
            actions = client.get(f"/conversations/{conversation['id']}/actions", headers=headers).json()
            action = next(item for item in actions if item["id"] == action_id)
            tasks = client.get("/tasks", headers=headers).json()
            matching = [task for task in tasks if task["source_action_id"] == action_id]
            if action["status"] == "executed":
                assert confirmed.status_code == 200
                assert len(matching) == 1
                assert matching[0]["id"] == action["result_task_id"]
            else:
                assert action["status"] == "dismissed"
                assert confirmed.status_code == 409
                assert matching == []


def test_auth_isolation_and_client_message_retry(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "auth.db"))
    with TestClient(app) as client:
        elder = _register(client, "elder@example.test")
        other = _register(client, "other@example.test")
        conversation = client.post("/conversations", headers=_headers(elder), json={"title": "Private"}).json()
        first = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "I enjoy jasmine tea.", "client_message_id": "mobile-1"},
        )
        assert first.status_code == 200, first.text
        replay = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "I enjoy jasmine tea.", "client_message_id": "mobile-1"},
        )
        assert replay.status_code == 200
        assert replay.json()["user_message"]["id"] == first.json()["user_message"]["id"]
        conflict = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "a different body", "client_message_id": "mobile-1"},
        )
        assert conflict.status_code == 409
        messages = client.get(f"/conversations/{conversation['id']}/messages", headers=_headers(elder)).json()
        assert len(messages) == 2
        forbidden = client.get(f"/conversations/{conversation['id']}", headers=_headers(other))
        assert forbidden.status_code == 403


def test_context_persists_across_app_restart(tmp_path: Path) -> None:
    database = tmp_path / "restart.db"
    app = create_app(_settings(database))
    with TestClient(app) as client:
        elder = _register(client, "context@example.test")
        conversation = client.post("/conversations", headers=_headers(elder), json={}).json()
        for index in range(7):
            response = client.post(
                f"/conversations/{conversation['id']}/messages",
                headers=_headers(elder),
                json={"content": f"Earlier detail number {index}", "client_message_id": f"ctx-{index}"},
            )
            assert response.status_code == 200
        detail = client.get(f"/conversations/{conversation['id']}", headers=_headers(elder)).json()
        assert detail["recent_context"]
        assert detail["rolling_summary"]
        conversation_id = conversation["id"]
        token = elder["access_token"]

    restarted = create_app(_settings(database))
    with TestClient(restarted) as client:
        response = client.post(
            f"/conversations/{conversation_id}/messages",
            headers={"Authorization": f"Bearer {token}"},
            json={"content": "What did I say earlier?", "client_message_id": "ctx-recall"},
        )
        assert response.status_code == 200, response.text
        assert "Earlier detail" in response.json()["assistant_message"]["content"]
        assert response.json()["mode"] == "deterministic_demo"


def test_action_confirmation_is_idempotent_and_memory_is_not_a_task(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "actions.db"))
    with TestClient(app) as client:
        elder = _register(client, "tasks@example.test")
        conversation = client.post("/conversations", headers=_headers(elder), json={}).json()
        memory = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "I remember my appointment was last Tuesday.", "client_message_id": "memory-1"},
        ).json()
        assert memory["action"] is None
        proposed = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "Please remind me to call my daughter tomorrow", "client_message_id": "task-1"},
        ).json()
        assert proposed["action"]["status"] == "pending"
        action_id = proposed["action"]["id"]
        first = client.post(
            f"/actions/{action_id}/confirm",
            headers=_headers(elder),
            json={"idempotency_key": "confirm-1"},
        )
        assert first.status_code == 200, first.text
        second = client.post(
            f"/actions/{action_id}/confirm",
            headers=_headers(elder),
            json={"idempotency_key": "confirm-1"},
        )
        assert second.status_code == 200, second.text
        assert second.json()["task"]["id"] == first.json()["task"]["id"]
        tasks = client.get("/tasks", headers=_headers(elder)).json()
        assert len(tasks) == 1
        invalid_patch = client.patch(
            f"/tasks/{tasks[0]['id']}",
            headers=_headers(elder),
            json={"status": None},
        )
        assert invalid_patch.status_code == 422

        second_proposal = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "Please remind me to check the door", "client_message_id": "task-2"},
        ).json()
        second_action = second_proposal["action"]["id"]
        dismissed = client.post(f"/actions/{second_action}/dismiss", headers=_headers(elder))
        assert dismissed.status_code == 200 and dismissed.json()["status"] == "dismissed"
        cannot_confirm = client.post(f"/actions/{second_action}/confirm", headers=_headers(elder), json={})
        assert cannot_confirm.status_code == 409


def test_task_gate_handles_negation_and_combined_emotion(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "gate.db"))
    with TestClient(app) as client:
        elder = _register(client, "gate@example.test")
        conversation = client.post("/conversations", headers=_headers(elder), json={}).json()
        for content, client_id in (
            ("I don't want you to remind me about anything", "negated-1"),
            ("以前社工跟進過這件事", "story-1"),
            ("My story says I should call the clinic tomorrow; I am only remembering it.", "story-2"),
            ("I remember to call my doctor tomorrow.", "story-3"),
        ):
            response = client.post(
                f"/conversations/{conversation['id']}/messages",
                headers=_headers(elder),
                json={"content": content, "client_message_id": client_id},
            )
            assert response.status_code == 200
            assert response.json()["action"] is None
        combined = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={
                "content": "I feel lonely; please remind me to call my daughter tomorrow",
                "client_message_id": "combined-1",
            },
        )
        assert combined.status_code == 200
        assert combined.json()["action"] is not None
        assert "難過" in combined.json()["assistant_message"]["content"] or "照護任務" in combined.json()["assistant_message"]["content"]


def test_provider_error_is_not_persisted_and_same_id_can_retry(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "provider-retry.db"))

    class FlakyOrchestrator:
        def __init__(self) -> None:
            self.calls = 0

        async def run(self, context, user_message):
            self.calls += 1
            if self.calls == 1:
                return AgentReply(text="[ERROR MODE] temporary", proposed_task=None, mode="error")
            return AgentReply(text="retry succeeded", proposed_task=None, mode="deterministic_demo")

    with TestClient(app) as client:
        elder = _register(client, "provider-retry@example.test")
        conversation = client.post("/conversations", headers=_headers(elder), json={}).json()
        app.state.orchestrator = FlakyOrchestrator()
        first = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "Please try this", "client_message_id": "retry-1"},
        )
        assert first.status_code == 503
        assert client.get(f"/conversations/{conversation['id']}/messages", headers=_headers(elder)).json() == []
        second = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "Please try this", "client_message_id": "retry-1"},
        )
        assert second.status_code == 200
        assert second.json()["assistant_message"]["content"] == "retry succeeded"


def test_malformed_provider_text_enters_error_mode(monkeypatch: pytest.MonkeyPatch) -> None:
    async def exercise() -> None:
        class BadResponse:
            def raise_for_status(self) -> None:
                return None

            def json(self) -> dict:
                return {"choices": [{"message": {"content": {"unexpected": "object"}}}]}

        class BadClient:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return None

            async def post(self, *args, **kwargs):
                return BadResponse()

        monkeypatch.setattr("app.llm.httpx.AsyncClient", lambda **kwargs: BadClient())
        adapter = OpenAICompatibleAdapter(_settings(Path("bad-adapter.db"), model_key="server-key"))
        result = await adapter.reply({}, "hello")
        assert result.mode == "error"
        assert isinstance(result.text, str)

    asyncio.run(exercise())


def test_family_scope_and_revoke_are_enforced(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "family.db"))
    with TestClient(app) as client:
        elder = _register(client, "owner@example.test")
        caregiver = _register(client, "helper@example.test", "caregiver")
        invitation = client.post(
            "/family-links/invitations",
            headers=_headers(elder),
            json={"email": "helper@example.test", "scopes": ["care_tasks"]},
        )
        assert invitation.status_code == 201, invitation.text
        token = invitation.json()["token"]
        accepted = client.post("/family-links/invitations/accept", headers=_headers(caregiver), json={"token": token})
        assert accepted.status_code == 201, accepted.text
        link_id = accepted.json()["id"]
        assert accepted.json()["scopes"] == ["care_tasks"]
        conversation = client.post("/conversations", headers=_headers(elder), json={}).json()
        proposed = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=_headers(elder),
            json={"content": "Create a task to check the care plan", "client_message_id": "scope-task"},
        ).json()
        client.post(f"/actions/{proposed['action']['id']}/confirm", headers=_headers(elder), json={})
        visible = client.get("/tasks", headers=_headers(caregiver))
        assert visible.status_code == 200 and len(visible.json()) == 1
        private = client.get(f"/conversations/{conversation['id']}", headers=_headers(caregiver))
        assert private.status_code == 403
        revoked = client.post(f"/family-links/{link_id}/revoke", headers=_headers(elder))
        assert revoked.status_code == 200
        assert client.get("/tasks", headers=_headers(caregiver)).json() == []


def test_openai_compatible_adapter_receives_persisted_context(monkeypatch: pytest.MonkeyPatch) -> None:
    async def exercise() -> None:
        captured: dict = {}

        class FakeResponse:
            def raise_for_status(self) -> None:
                return None

            def json(self) -> dict:
                action = {
                    "action": "save_preference", "memory_id": None,
                    "content": "I enjoy Cantonese opera.", "kind": "preference",
                    "sensitivity": "ordinary", "topic_key": "cantonese_opera",
                    "evidence": "The opera is what I look forward to every week.",
                }
                return {"choices": [{"message": {"content": json.dumps({
                    "text": "收到", "proposed_task": None, "memory_actions": [action],
                })}}]}

        class FakeClient:
            def __init__(self, **kwargs):
                self.kwargs = kwargs

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return None

            async def post(self, url, headers, json):
                captured["url"] = url
                captured["body"] = json
                return FakeResponse()

        monkeypatch.setattr("app.llm.httpx.AsyncClient", FakeClient)
        adapter = OpenAICompatibleAdapter(_settings(Path("adapter.db"), model_key="server-key"))
        result = await adapter.reply(
            {
                "rolling_summary": "user: an older persisted detail",
                "recent_context": [{"role": "user", "content": "a recent persisted detail"}],
                "memory_management": {"active_memories": [{"id": "memory-1", "content": "I enjoy opera."}]},
            },
            "What did I say earlier?",
        )
        assert result.mode == "openai_compatible"
        assert captured["url"].endswith("/chat/completions")
        serialized = json.dumps(captured["body"]["messages"], ensure_ascii=False)
        assert "older persisted detail" in serialized
        assert "recent persisted detail" in serialized
        assert "untrusted context" in serialized
        assert "I enjoy opera" in serialized
        assert captured["body"]["response_format"]["type"] == "json_schema"
        assert "memory_actions" in captured["body"]["response_format"]["json_schema"]["schema"]["required"]
        assert result.memory_actions[0]["content"] == "I enjoy Cantonese opera."

    asyncio.run(exercise())


def test_memory_action_schema_fails_closed_on_partial_or_sensitive_auto_save() -> None:
    valid_except_extra = {
        "action": "save_preference", "memory_id": None,
        "content": "I enjoy opera.", "kind": "preference",
        "sensitivity": "ordinary", "topic_key": "opera", "evidence": "I enjoy opera.",
        "untrusted": "ignored only if parser is unsafe",
    }
    assert _validate_memory_actions([valid_except_extra]) == []
    invalid_sensitivity = {
        **{key: value for key, value in valid_except_extra.items() if key != "untrusted"},
        "sensitivity": "sensitive",
    }
    assert _validate_memory_actions([invalid_sensitivity]) == []
