"""Owner revision fences for derived memory writes and explicit story sharing."""
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.main import create_app
from app.memory_models import MemoryConsent, MemoryRevision, PersonalMemory, Story, StoryMemoryLink
from app.community_models import CommunitySkill
from app.collaboration_models import FamilyMessage
from app.models import FamilyLink
from .test_family_messages import message_preview
from tests.test_safety_checkin_speech import _settings, _register, _headers


@pytest.fixture
def related(tmp_path):
    app = create_app(_settings(tmp_path / "related.db"))
    with TestClient(app) as client:
        owner = _register(client, "related-owner@example.test")
        recipient = _register(client, "related-family@example.test", "caregiver")
        owner_id = owner["account"]["id"]
        with app.state.session_factory() as db:
            link = FamilyLink(elder_id=owner_id, caregiver_id=recipient["account"]["id"],
                              scopes=["care_tasks", "family_messages"], status="active")
            db.add_all([MemoryConsent(owner_id=owner_id, enabled=True),
                        MemoryRevision(owner_id=owner_id, version=7), link])
            memory = PersonalMemory(owner_id=owner_id, content="I enjoy gardening", kind="experience", status="confirmed")
            story = Story(owner_id=owner_id, title="Garden", content="My private garden story")
            db.add_all([memory, story])
            db.flush()
            skill = CommunitySkill(owner_id=owner_id, memory_id=memory.id, suggestion="Gardening", status="suggested")
            db.add_all([skill, StoryMemoryLink(story_id=story.id, memory_id=memory.id)])
            db.commit()
            ids = {"memory": memory.id, "story": story.id, "skill": skill.id,
                   "link": {"id": link.id, "authorization_epoch": link.authorization_epoch}}
        yield app, client, owner, recipient, ids


def revision_headers(owner, revision=None):
    headers = _headers(owner)
    if revision is not None:
        headers["X-Memory-Revision"] = str(revision)
    return headers


@pytest.mark.parametrize("revision,expected", [(None, 422), (6, 409)])
@pytest.mark.parametrize("operation", ["skill_suggestions", "skill_decision", "story_create", "story_delete", "story_share"])
def test_derived_writes_reject_missing_and_stale_revision(related, operation, revision, expected):
    app, client, owner, recipient, ids = related
    headers = revision_headers(owner, revision)
    if operation == "skill_suggestions":
        response = client.get("/community/skills/suggestions", headers=headers)
    elif operation == "skill_decision":
        response = client.post(f"/community/skills/{ids['skill']}/decision", headers=headers, json={"decision": "confirm"})
    elif operation == "story_create":
        response = client.post("/stories", headers=headers, json={"title": "Old draft", "content": "Stale content", "memory_ids": []})
    elif operation == "story_delete":
        response = client.delete(f"/stories/{ids['story']}", headers=headers)
    else:
        response = client.post("/family-messages", headers=headers, json={
            "recipient_id": recipient["account"]["id"], **message_preview(ids["link"]), "source_story_id": ids["story"],
            "content": "Garden\nMy private garden story", "client_message_id": "story-send"})
    assert response.status_code == expected, response.text
    with app.state.session_factory() as db:
        assert db.get(CommunitySkill, ids["skill"]).status == "suggested"
        assert db.get(Story, ids["story"]) is not None
        assert db.scalar(select(func.count()).select_from(Story)) == 1
        assert db.scalar(select(func.count()).select_from(FamilyMessage)) == 0
        assert db.get(MemoryRevision, owner["account"]["id"]).version == 7


def test_skill_and_story_responses_expose_revision_snapshot(related):
    _, client, owner, _, ids = related
    headers = revision_headers(owner, 7)
    skills = client.get("/community/skills/suggestions", headers=headers)
    assert skills.status_code == 200, skills.text
    assert skills.json()["items"][0]["revision"] == 7
    decision = client.post(f"/community/skills/{ids['skill']}/decision", headers=headers, json={"decision": "confirm"})
    assert decision.status_code == 200, decision.text
    assert decision.json()["revision"] == 7
    for response in (client.get("/stories", headers=headers), client.get(f"/stories/{ids['story']}", headers=headers)):
        assert response.status_code == 200, response.text
        data = response.json()
        assert (data[0] if isinstance(data, list) else data)["revision"] == 7
    created = client.post("/stories", headers=headers, json={"title": "Current draft", "content": "Current content", "memory_ids": []})
    assert created.status_code == 201, created.text
    assert created.json()["revision"] == 8


def test_current_revision_allows_story_share_and_delete(related):
    _, client, owner, recipient, ids = related
    headers = revision_headers(owner, 7)
    response = client.post("/family-messages", headers=headers, json={
        "recipient_id": recipient["account"]["id"], **message_preview(ids["link"]), "source_story_id": ids["story"],
        "content": "Garden\nMy private garden story", "client_message_id": "current-send"})
    assert response.status_code == 201, response.text
    assert client.delete(f"/stories/{ids['story']}", headers=headers).status_code == 204


def test_plain_family_message_does_not_require_memory_revision(related):
    _, client, owner, recipient, ids = related
    response = client.post("/family-messages", headers=_headers(owner), json={
        "recipient_id": recipient["account"]["id"], **message_preview(ids["link"]), "content": "Hello", "client_message_id": "plain-send"})
    assert response.status_code == 201, response.text


def test_story_delete_fences_replayed_share_before_returning_old_body(related):
    _, client, owner, recipient, ids = related
    headers = revision_headers(owner, 7)
    payload = {"recipient_id": recipient["account"]["id"], **message_preview(ids["link"]), "source_story_id": ids["story"],
               "content": "Garden\nMy private garden story", "client_message_id": "replayed-share"}
    assert client.post("/family-messages", headers=headers, json=payload).status_code == 201
    deleted = client.delete(f"/stories/{ids['story']}", headers=headers)
    assert deleted.status_code == 204
    assert deleted.headers["X-Memory-Revision"] == "8"
    replay = client.post("/family-messages", headers=headers, json=payload)
    assert replay.status_code == 409, replay.text
