from __future__ import annotations
from .memory_revision_helpers import memory_revision_headers

from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.config import Settings
from app.llm import AgentReply
from app.main import create_app
from app.memory_models import MemoryPreferenceBlock, PersonalMemory
from app.memory_service import _preference_hash
from .test_integration import _headers, _register


def _settings(path: Path) -> Settings:
    return Settings(database_url=f"sqlite:///{path}", auth_secret="model-memory-test-key", demo_mode=True)


def _enable_memory(client: TestClient, account: dict) -> dict[str, str]:
    headers = _headers(account)
    response = client.put("/memories/consent", headers=memory_revision_headers(client, headers), json={"enabled": True})
    assert response.status_code == 200, response.text
    return headers


def _conversation(client: TestClient, headers: dict[str, str]) -> str:
    response = client.post("/conversations", headers=headers, json={})
    assert response.status_code == 201, response.text
    return response.json()["id"]


def _send(client: TestClient, headers: dict[str, str], conversation_id: str, content: str, key: str):
    return client.post(
        f"/conversations/{conversation_id}/messages",
        headers=headers,
        json={"content": content, "client_message_id": key},
    )


def _memory_action(
    action: str,
    evidence: str,
    *,
    content: str | None = None,
    kind: str = "preference",
    memory_id: str | None = None,
    sensitivity: str = "ordinary",
    topic_key: str | None = None,
) -> dict:
    return {
        "action": action,
        "memory_id": memory_id,
        "content": content,
        "kind": kind,
        "sensitivity": sensitivity,
        "topic_key": topic_key,
        "evidence": evidence,
    }


class MockMemoryModel:
    """Deterministic model boundary: decisions are supplied as structured output."""

    def __init__(self, decisions):
        self.decisions = list(decisions)
        self.contexts: list[dict] = []

    async def run(self, context, user_message):
        self.contexts.append(context)
        decision = self.decisions.pop(0) if self.decisions else []
        if callable(decision):
            decision = decision(context, user_message)
        return AgentReply(
            text="我已按你的意思處理。",
            proposed_task=None,
            mode="openai_compatible",
            memory_actions=decision,
        )


def test_demo_mode_does_not_auto_save_or_offer_regex_suggestions(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "demo-no-memory.db"))
    with TestClient(app) as client:
        elder = _register(client, "demo-memory@example.test")
        headers = _enable_memory(client, elder)
        conversation_id = _conversation(client, headers)
        response = _send(client, headers, conversation_id, "我喜歡粵劇", "demo-pref")
        assert response.status_code == 200, response.text
        metadata = response.json()["assistant_message"]["metadata_json"]
        assert "auto_saved_memory" not in metadata
        assert "memory_suggestion" not in metadata
        assert client.get("/memories", headers=headers).json() == []


def test_model_paraphrase_inference_correction_forget_and_community_topic(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "model-decisions.db"))

    class NoSearch:
        calls = 0

        def search(self, **kwargs):
            self.calls += 1
            raise AssertionError("A Community prompt must not start a provider search")

    search = NoSearch()
    app.state.community_search = search
    with TestClient(app) as client:
        elder = _register(client, "model-memory@example.test")
        headers = _enable_memory(client, elder)
        conversation_id = _conversation(client, headers)

        def correction(context, _message):
            current = context["memory_management"]["active_memories"][0]
            return [_memory_action(
                "correct_preference",
                "Cantonese opera no longer interests me; these days pottery is what I love.",
                content="I enjoy pottery.",
                memory_id=current["id"],
                topic_key="pottery",
            )]

        def forget(context, _message):
            current = context["memory_management"]["active_memories"][0]
            return [_memory_action(
                "forget",
                "Please forget my preference for pottery.",
                kind="preference",
                memory_id=current["id"],
            )]

        model = MockMemoryModel([
            [_memory_action(
                "save_preference",
                "The opera is what I look forward to every week.",
                content="I enjoy Cantonese opera.",
                topic_key="cantonese_opera",
            )],
            correction,
            [],
            forget,
            [_memory_action(
                "save_preference",
                "I still enjoy pottery on some days.",
                content="I enjoy pottery.",
                topic_key="pottery",
            )],
        ])
        app.state.orchestrator = model

        first_text = "The opera is what I look forward to every week."
        first = _send(client, headers, conversation_id, first_text, "model-save")
        assert first.status_code == 200, first.text
        saved = first.json()["assistant_message"]["metadata_json"]["auto_saved_memory"]
        assert saved["content"] == "I enjoy Cantonese opera."
        assert saved["capture_method"] == "agent_auto"
        memory_id = saved["id"]
        assert model.contexts[0]["memory_management"]["active_memories"] == []

        correction_text = "Cantonese opera no longer interests me; these days pottery is what I love."
        corrected = _send(client, headers, conversation_id, correction_text, "model-correct")
        assert corrected.status_code == 200, corrected.text
        replacement = corrected.json()["assistant_message"]["metadata_json"]["auto_saved_memory"]
        assert replacement["content"] == "I enjoy pottery."
        assert replacement["id"] != memory_id
        assert model.contexts[1]["memory_management"]["active_memories"][0]["id"] == memory_id
        assert client.get(f"/memories/{memory_id}", headers=headers).status_code == 404

        later = _send(client, headers, conversation_id, "I have free time this weekend.", "community-prompt")
        assert later.status_code == 200, later.text
        prompt = later.json()["assistant_message"]["metadata_json"]["community_memory_prompt"]
        assert prompt["memory_id"] == replacement["id"]
        assert prompt["topic"] == "pottery"
        assert search.calls == 0

        forget_text = "Please forget my preference for pottery."
        forgotten = _send(client, headers, conversation_id, forget_text, "model-forget")
        assert forgotten.status_code == 200, forgotten.text
        assert client.get("/memories", headers=headers).json() == []
        history = client.get(f"/conversations/{conversation_id}/messages", headers=headers).json()
        assert any(item["content"] == "[記憶已由擁有人移除]" for item in history)
        assert client.get(f"/memories/{replacement['id']}", headers=headers).status_code == 404

        # A later model decision for a deleted topic is blocked by its hashed tombstone.
        relearn = _send(client, headers, conversation_id, "I still enjoy pottery on some days.", "blocked-relearn")
        assert relearn.status_code == 200, relearn.text
        assert "auto_saved_memory" not in relearn.json()["assistant_message"]["metadata_json"]
        with app.state.session_factory() as db:
            blocks = db.scalars(select(MemoryPreferenceBlock)).all()
            assert any(block.topic_hash == _preference_hash(elder["account"]["id"], "pottery") for block in blocks)
            assert all(block.topic_hash != "pottery" for block in blocks)


def test_sensitive_mislabel_hallucinated_evidence_unknown_ids_and_curated_memory_are_rejected(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "model-guards.db"))
    with TestClient(app) as client:
        elder = _register(client, "model-guards@example.test")
        headers = _enable_memory(client, elder)
        conversation_id = _conversation(client, headers)

        manual = client.post(
            "/memories", headers=memory_revision_headers(client, headers),
            json={"content": "I enjoy classical music.", "kind": "preference"},
        ).json()
        assert client.post(f"/memories/{manual['id']}/confirm", headers=memory_revision_headers(client, headers)).status_code == 200

        model = MockMemoryModel([
            [_memory_action(
                "save_preference", "I take medication for diabetes.",
                content="I manage diabetes with medication.", topic_key="diabetes", sensitivity="ordinary",
            )],
            [_memory_action(
                "correct_preference", "I do not enjoy classical music anymore.",
                content="I enjoy jazz.", memory_id=manual["id"], topic_key="jazz",
            )],
            [_memory_action(
                "forget", "Please forget classical music.",
                kind="preference", memory_id="00000000-0000-0000-0000-000000000000",
            )],
        ])
        app.state.orchestrator = model

        hallucinated = _send(client, headers, conversation_id, "I am thinking about Saturday.", "bad-evidence")
        assert hallucinated.status_code == 200
        assert "auto_saved_memory" not in hallucinated.json()["assistant_message"]["metadata_json"]

        sensitive = _send(
            client, headers, conversation_id, "I take medication for diabetes.", "sensitive-mislabel"
        )
        assert sensitive.status_code == 200
        assert "auto_saved_memory" not in sensitive.json()["assistant_message"]["metadata_json"]
        assert all("diabetes" not in item["content"].casefold() for item in client.get("/memories", headers=headers).json())

        # Even exact quoted support cannot make a model-generated claim overwrite a curated memory.
        unsupported_correction = _send(
            client, headers, conversation_id, "I do not enjoy classical music anymore.", "curated-correction"
        )
        assert unsupported_correction.status_code == 200
        assert "auto_saved_memory" not in unsupported_correction.json()["assistant_message"]["metadata_json"]
        assert client.get(f"/memories/{manual['id']}", headers=headers).json()["content"] == "I enjoy classical music."

        # An unknown model-supplied ID cannot delete the owner's real memory.
        unknown_forget = _send(client, headers, conversation_id, "Please forget classical music.", "unknown-forget")
        assert unknown_forget.status_code == 200
        assert client.get(f"/memories/{manual['id']}", headers=headers).status_code == 200


def test_sensitive_item_requires_owner_save_action(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "sensitive-suggestion.db"))
    with TestClient(app) as client:
        elder = _register(client, "sensitive-suggestion@example.test")
        headers = _enable_memory(client, elder)
        conversation_id = _conversation(client, headers)
        app.state.orchestrator = MockMemoryModel([[
            _memory_action(
                "suggest", "Please remember that I have diabetes.",
                content="I have diabetes.", kind="fact", sensitivity="sensitive",
            )
        ]])
        response = _send(
            client, headers, conversation_id,
            "Please remember that I have diabetes.", "sensitive-suggestion",
        )
        assert response.status_code == 200, response.text
        suggestion = response.json()["assistant_message"]["metadata_json"]["memory_suggestion"]
        assert suggestion["requires_confirmation"] is True
        assert suggestion["sensitivity"] == "sensitive"
        assert client.get("/memories", headers=headers).json() == []

        saved = client.post("/memories/save", headers=memory_revision_headers(client, headers), json={
            "content": suggestion["content"],
            "kind": suggestion["kind"],
            "source_message_id": suggestion["source_message_id"],
            "topic_key": suggestion.get("topic_key"),
        })
        assert saved.status_code == 201, saved.text
        assert saved.json()["content"] == "I have diabetes."
        assert saved.json()["capture_method"] == "user_saved"


def test_old_turn_cannot_authorize_model_forgetting_on_unrelated_turn(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "stale-forget.db"))
    with TestClient(app) as client:
        elder = _register(client, "stale-forget@example.test")
        headers = _enable_memory(client, elder)
        conversation_id = _conversation(client, headers)
        created = client.post(
            "/memories", headers=memory_revision_headers(client, headers),
            json={"content": "I enjoy gardening.", "kind": "preference"},
        ).json()
        assert client.post(f"/memories/{created['id']}/confirm", headers=memory_revision_headers(client, headers)).status_code == 200
        app.state.orchestrator = MockMemoryModel([
            [],
            [_memory_action(
                "forget", "Please forget my gardening preference.",
                memory_id=created["id"],
            )],
        ])
        first = _send(
            client, headers, conversation_id,
            "Please forget my gardening preference.", "first-request",
        )
        assert first.status_code == 200
        second = _send(client, headers, conversation_id, "How is the weather?", "later-turn")
        assert second.status_code == 200
        assert client.get(f"/memories/{created['id']}", headers=headers).status_code == 200
