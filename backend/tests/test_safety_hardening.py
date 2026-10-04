"""Safety authorization, privacy, idempotency, and race regressions."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from threading import Event

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, event as sa_event, select
from sqlalchemy.exc import IntegrityError

from app.collaboration_models import FamilyMessage
from app.llm import detect_urgent_risk, safety_intervention_reply
from app.main import create_app
from app.memory_models import PersonalMemory
from app.memory_service import purge_memory
from app.models import Conversation, Message
from app.safety_models import EmergencyContact, SafetyEvent
from .test_family_messages import message_preview
from .test_safety_checkin_speech import _create_family_link, _headers, _register, _settings


@pytest.mark.parametrize("message", [
    "I am not suicidal, but I want to die",
    "not suicidal but I want to die",
    "I want to die, but I am not suicidal",
    "I don't want to die. I might hurt myself",
    "I never said I want to kill myself; I am suicidal",
    "I am not suicidal and I want to die",
    "I am not suicidal\nI want to die",
    "I’m going to hurt myself",
    "我沒有想死，但我想自殺",
    "我不想自殺可是我不想活了",
    "我想死，但我不想傷害自己",
    "我没有想自杀，但是我想死",
    "I am not suicidal, 但我想自殺",
])
def test_negation_does_not_hide_other_risk_clauses(message):
    assert detect_urgent_risk(message)


@pytest.mark.parametrize("message", [
    "I am not suicidal", "I don't want to die", "I never said I want to kill myself",
    "I am not suicidal and I don't want to die", "我沒有想死", "我不想自殺",
    "我没有想自杀", "我沒有想死，也不想自殺", "A news story about suicide",
])
def test_negated_and_benign_statements_remain_negative(message):
    assert not detect_urgent_risk(message)


def test_reply_uses_verified_hotline_and_no_availability_promise():
    text = safety_intervention_reply().text
    assert "The Samaritan Befrienders Hong Kong: 2389 2222" in text
    assert "2389 2389" not in text
    assert "999 in Hong Kong" in text
    assert "volunteers" in text
    assert "cannot guarantee" in text
    assert "I have not contacted anyone" in text
    assert "confirm the recipient and message" in text


@pytest.fixture
def setup(tmp_path):
    app = create_app(_settings(tmp_path / "safety-hardening.db"))

    # Exercise declared on-delete semantics; production SQLite connections must
    # also enable foreign keys (the shared db module is outside this workstream).
    @sa_event.listens_for(app.state.engine, "connect")
    def enable_foreign_keys(connection, record):
        connection.execute("PRAGMA foreign_keys=ON")

    with TestClient(app) as client:
        elder = _register(client, "elder@example.test")
        other = _register(client, "other@example.test")
        carers = [_register(client, f"carer{i}@example.test", "caregiver") for i in range(2)]
        links = [_create_family_link(client, elder, carer) for carer in carers]
        contacts = []
        for link in links:
            response = client.post("/safety/emergency-contacts", headers=_headers(elder),
                                   json={"family_link_id": link["id"], "label": "Family"})
            assert response.status_code == 201, response.text
            contacts.append(response.json())
        yield app, client, elder, other, carers, links, contacts


def _event(app, owner_id):
    with app.state.session_factory() as db:
        conversation = Conversation(owner_id=owner_id)
        db.add(conversation)
        db.flush()
        message = Message(conversation_id=conversation.id, sender_id=owner_id,
                          role="user", content="I want to die")
        db.add(message)
        db.flush()
        event = SafetyEvent(elder_id=owner_id, conversation_id=conversation.id, trigger_message_id=message.id)
        db.add(event)
        db.commit()
        return event.id, message.id, conversation.id


def _request(contact, link, **changes):
    payload = {"emergency_contact_id": contact["id"], "message": "Please call me",
               "idempotency_key": "stable-client-key", **message_preview(link)}
    payload.update(changes)
    return payload


def test_events_are_owner_only_and_never_auto_send(setup):
    app, client, elder, other, carers, _, _ = setup
    event_id, message_id, _ = _event(app, elder["account"]["id"])
    rows = client.get("/safety/events", headers=_headers(elder)).json()
    assert rows[0]["id"] == event_id
    assert rows[0]["trigger_message_id"] == message_id
    assert "trigger_message" not in rows[0]
    assert "I want to die" not in str(rows)
    assert not rows[0]["support_request_sent"]
    assert client.get("/safety/events", headers=_headers(other)).json() == []
    assert client.get("/safety/events", headers=_headers(carers[0])).status_code == 403
    assert client.get("/family-messages", headers=_headers(carers[0])).json() == []


def test_source_memory_purge_does_not_leave_duplicate_risk_text(setup):
    app, client, elder, *_ = setup
    event_id, message_id, conversation_id = _event(app, elder["account"]["id"])
    with app.state.session_factory() as db:
        memory = PersonalMemory(owner_id=elder["account"]["id"], source_message_id=message_id,
                                content="I want to die", kind="emotion", status="confirmed")
        db.add(memory)
        db.commit()
        purge_memory(db, memory)
        db.commit()
        db.expire_all()
        assert "I want to die" not in db.get(Message, message_id).content
        assert db.get(SafetyEvent, event_id).trigger_message_id == message_id
        assert "trigger_message" not in SafetyEvent.__table__.columns
        assert "I want to die" not in str(client.get("/safety/events", headers=_headers(elder)).json())
        db.execute(delete(Message).where(Message.id == message_id))
        db.commit()
        db.expire_all()
        assert db.get(SafetyEvent, event_id).trigger_message_id is None
        db.execute(delete(Conversation).where(Conversation.id == conversation_id))
        db.commit()
        db.expire_all()
        assert db.get(SafetyEvent, event_id).conversation_id is None


def test_contact_uniqueness_enforced_in_database_and_datetime_values(setup):
    app, _, elder, _, _, links, contacts = setup
    with app.state.session_factory() as db:
        contact = db.get(EmergencyContact, contacts[0]["id"])
        assert isinstance(contact.created_at, datetime)
        db.add(EmergencyContact(elder_id=elder["account"]["id"], family_link_id=links[0]["id"],
                                caregiver_id=contact.caregiver_id))
        with pytest.raises(IntegrityError):
            db.commit()
        db.rollback()
    event_id, _, _ = _event(app, elder["account"]["id"])
    with app.state.session_factory() as db:
        assert isinstance(db.get(SafetyEvent, event_id).created_at, datetime)


@pytest.mark.parametrize("changes", [{"message": " \n\t"}, {"idempotency_key": " "},
                                      {"idempotency_key": None}, {"idempotency_key": ""}])
def test_nonblank_message_and_stable_key_required(setup, changes):
    _, client, elder, _, _, links, contacts = setup
    assert client.post("/safety/support-request", headers=_headers(elder),
                       json=_request(contacts[0], links[0], **changes)).status_code == 422


def test_missing_key_rejected(setup):
    _, client, elder, _, _, links, contacts = setup
    payload = _request(contacts[0], links[0])
    payload.pop("idempotency_key")
    assert client.post("/safety/support-request", headers=_headers(elder), json=payload).status_code == 422


def test_idempotency_binds_content_recipient_and_event(setup):
    app, client, elder, _, _, links, contacts = setup
    event_id, _, _ = _event(app, elder["account"]["id"])
    second_event, _, _ = _event(app, elder["account"]["id"])
    payload = _request(contacts[0], links[0], safety_event_id=event_id)
    first = client.post("/safety/support-request", headers=_headers(elder), json=payload)
    assert first.status_code == 200, first.text
    repeat = client.post("/safety/support-request", headers=_headers(elder), json=payload)
    assert repeat.json() == first.json()
    for changes in ({"message": "Changed"}, {"emergency_contact_id": contacts[1]["id"], **message_preview(links[1])},
                    {"safety_event_id": second_event}, {"safety_event_id": None}):
        assert client.post("/safety/support-request", headers=_headers(elder),
                           json={**payload, **changes}).status_code == 409
    with app.state.session_factory() as db:
        messages = db.scalars(select(FamilyMessage)).all()
        assert len(messages) == 1
        assert messages[0].client_message_id.startswith("safety:")
        assert db.get(SafetyEvent, event_id).support_request_sent
        assert not db.get(SafetyEvent, second_event).support_request_sent


def test_safety_key_is_separate_from_ordinary_message_key(setup):
    _, client, elder, _, carers, links, contacts = setup
    normal = client.post("/family-messages", headers=_headers(elder), json={
        "recipient_id": carers[0]["account"]["id"], "content": "Ordinary message",
        "client_message_id": "stable-client-key", **message_preview(links[0]),
    })
    assert normal.status_code == 201
    safety = client.post("/safety/support-request", headers=_headers(elder), json=_request(contacts[0], links[0]))
    assert safety.status_code == 200
    assert safety.json()["family_message_id"] != normal.json()["id"]


@pytest.mark.parametrize("foreign", [False, True])
def test_event_must_exist_and_belong_to_owner(setup, foreign):
    app, client, elder, other, carers, links, contacts = setup
    event_id = _event(app, other["account"]["id"])[0] if foreign else "missing"
    response = client.post("/safety/support-request", headers=_headers(elder),
                           json=_request(contacts[0], links[0], safety_event_id=event_id))
    assert response.status_code == 404
    assert client.get("/family-messages", headers=_headers(carers[0])).json() == []


def test_revocation_denies_new_sends_and_replays(setup):
    _, client, elder, _, _, links, contacts = setup
    payload = _request(contacts[0], links[0])
    assert client.post("/safety/support-request", headers=_headers(elder), json=payload).status_code == 200
    assert client.delete(f"/family-links/{links[0]['id']}", headers=_headers(elder)).status_code == 200
    assert client.post("/safety/support-request", headers=_headers(elder), json=payload).status_code == 403
    assert client.post("/safety/support-request", headers=_headers(elder),
                       json={**payload, "idempotency_key": "new-key"}).status_code == 403


def test_concurrent_retries_send_once(setup):
    app, client, elder, _, _, links, contacts = setup
    def send():
        return client.post("/safety/support-request", headers=_headers(elder), json=_request(contacts[0], links[0]))
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda _: send(), range(4)))
    assert [response.status_code for response in responses] == [200] * 4
    assert len({response.json()["family_message_id"] for response in responses}) == 1
    with app.state.session_factory() as db:
        assert len(db.scalars(select(FamilyMessage)).all()) == 1


@pytest.mark.parametrize("revoke_first", [False, True])
def test_send_and_revoke_serialize_at_database_lock(setup, revoke_first):
    app, client, elder, _, _, links, contacts = setup
    held, release, contender_started = Event(), Event(), Event()

    def hold_writer(connection, cursor, statement, parameters, context, executemany):
        normalized = statement.lower()
        target = "update family_links" if revoke_first else "insert into family_messages"
        if normalized.startswith(target):
            held.set()
            assert release.wait(10), "test did not release writer"
        elif held.is_set() and normalized == "begin immediate":
            contender_started.set()

    sa_event.listen(app.state.engine, "before_cursor_execute", hold_writer)
    def send():
        return client.post("/safety/support-request", headers=_headers(elder), json=_request(contacts[0], links[0]))
    def revoke():
        return client.delete(f"/family-links/{links[0]['id']}", headers=_headers(elder))
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(revoke if revoke_first else send)
            try:
                assert held.wait(10), "writer did not reach the protected mutation"
                second = pool.submit(send if revoke_first else revoke)
                assert contender_started.wait(10), "contending transaction did not start"
                assert not second.done()
            finally:
                release.set()
            first_result, second_result = first.result(10), second.result(10)
        assert first_result.status_code == 200
        assert second_result.status_code == (403 if revoke_first else 200)
        with app.state.session_factory() as db:
            assert len(db.scalars(select(FamilyMessage)).all()) == (0 if revoke_first else 1)
    finally:
        release.set()
        sa_event.remove(app.state.engine, "before_cursor_execute", hold_writer)
