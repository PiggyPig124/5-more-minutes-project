"""Tests for safety-assistance, proactive check-in, and speech transcription.

These tests use the same patterns as test_integration.py: SQLite temp
databases, FastAPI TestClient, and deterministic demo mode (no model key).
"""

from __future__ import annotations

import base64
import os
import zlib
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.llm import detect_urgent_risk, safety_intervention_reply
from app.main import create_app


def _settings(database: Path) -> Settings:
    return Settings(
        database_url=f"sqlite:///{database}",
        auth_secret="safety-test-secret",
        demo_mode=True,
    )


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


def _headers(auth: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {auth['access_token']}"}


# ---------------------------------------------------------------------------
# Safety detection unit tests
# ---------------------------------------------------------------------------


def test_detect_urgent_risk_english_direct() -> None:
    assert detect_urgent_risk("I want to die") is True
    assert detect_urgent_risk("I am suicidal") is True
    assert detect_urgent_risk("I'm going to kill myself") is True
    assert detect_urgent_risk("I plan to hurt myself") is True


def test_detect_urgent_risk_english_negated() -> None:
    assert detect_urgent_risk("I am not suicidal") is False
    assert detect_urgent_risk("I don't want to die") is False
    assert detect_urgent_risk("I never said I want to kill myself") is False


def test_detect_urgent_risk_chinese_direct() -> None:
    assert detect_urgent_risk("我想死") is True
    assert detect_urgent_risk("我唔想活") is True
    assert detect_urgent_risk("我想自殺") is True
    assert detect_urgent_risk("我有自殺念頭") is True


def test_detect_urgent_risk_chinese_negated() -> None:
    assert detect_urgent_risk("我沒有想死") is False
    assert detect_urgent_risk("唔會自殺") is False
    assert detect_urgent_risk("我不想自殺") is False


def test_detect_urgent_risk_benign_messages() -> None:
    assert detect_urgent_risk("今日天氣好好") is False
    assert detect_urgent_risk("I had a good day today") is False
    assert detect_urgent_risk("My daughter visited yesterday") is False


def test_safety_intervention_reply_has_hotline() -> None:
    reply = safety_intervention_reply()
    assert reply.mode == "safety_intervention"
    assert "2389 2222" in reply.text
    assert "999" in reply.text
    assert reply.proposed_task is None


# ---------------------------------------------------------------------------
# Safety intervention in conversations
# ---------------------------------------------------------------------------


def test_safety_intervention_in_conversation(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "safety-conv.db"))
    with TestClient(app) as client:
        elder = _register(client, "safety-elder@example.test")
        headers = _headers(elder)
        conversation = client.post("/conversations", headers=headers, json={}).json()
        response = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=headers,
            json={"content": "I want to die", "client_message_id": "risk-1"},
        )
        assert response.status_code == 200
        body = response.json()
        assert body["mode"] == "safety_intervention"
        assert "2389 2222" in body["assistant_message"]["content"]
        # The safety event should be recorded.
        events = client.get("/safety/events", headers=headers).json()
        assert len(events) == 1
        assert events[0]["trigger_message_id"] == body["user_message"]["id"]
        assert "trigger_message" not in events[0]
        assert events[0]["support_request_sent"] is False


def test_safety_intervention_skips_normal_response(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "safety-skip.db"))
    with TestClient(app) as client:
        elder = _register(client, "safety-skip@example.test")
        headers = _headers(elder)
        conversation = client.post("/conversations", headers=headers, json={}).json()
        response = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=headers,
            json={"content": "I am suicidal", "client_message_id": "risk-2"},
        )
        assert response.json()["mode"] == "safety_intervention"
        # No task proposal should come from a safety intervention.
        assert response.json()["action"] is None


def test_negated_risk_does_not_trigger_intervention(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "negated-risk.db"))
    with TestClient(app) as client:
        elder = _register(client, "negated@example.test")
        headers = _headers(elder)
        conversation = client.post("/conversations", headers=headers, json={}).json()
        response = client.post(
            f"/conversations/{conversation['id']}/messages",
            headers=headers,
            json={"content": "I am not suicidal, just having a bad day.", "client_message_id": "neg-1"},
        )
        assert response.status_code == 200
        assert response.json()["mode"] != "safety_intervention"
        events = client.get("/safety/events", headers=headers).json()
        assert len(events) == 0


# ---------------------------------------------------------------------------
# Emergency contact management
# ---------------------------------------------------------------------------


def _create_family_link(client: TestClient, elder_auth: dict, caregiver_auth: dict) -> dict:
    """Create a family link with family_messages scope for testing."""
    invitation = client.post(
        "/family-links/invitations",
        headers=_headers(elder_auth),
        json={"email": caregiver_auth["account"]["email"], "scopes": ["care_tasks", "family_messages"]},
    )
    assert invitation.status_code == 201, invitation.text
    token = invitation.json()["token"]
    accepted = client.post(
        "/family-links/invitations/accept",
        headers=_headers(caregiver_auth),
        json={"token": token},
    )
    assert accepted.status_code == 201, accepted.text
    return accepted.json()


def test_emergency_contact_crud(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "emergency-contact.db"))
    with TestClient(app) as client:
        elder = _register(client, "ec-elder@example.test")
        caregiver = _register(client, "ec-care@example.test", "caregiver")
        link = _create_family_link(client, elder, caregiver)
        # Initially empty.
        assert client.get("/safety/emergency-contacts", headers=_headers(elder)).json() == []
        # Add a contact.
        created = client.post(
            "/safety/emergency-contacts",
            headers=_headers(elder),
            json={"family_link_id": link["id"], "label": "女兒"},
        )
        assert created.status_code == 201
        assert created.json()["label"] == "女兒"
        assert created.json()["is_enabled"] is True
        contact_id = created.json()["id"]
        # List shows the contact.
        contacts = client.get("/safety/emergency-contacts", headers=_headers(elder)).json()
        assert len(contacts) == 1
        assert contacts[0]["id"] == contact_id
        # Delete it.
        deleted = client.delete(f"/safety/emergency-contacts/{contact_id}", headers=_headers(elder))
        assert deleted.status_code == 204
        assert client.get("/safety/emergency-contacts", headers=_headers(elder)).json() == []


def test_emergency_contact_requires_family_messages_scope(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "ec-scope.db"))
    with TestClient(app) as client:
        elder = _register(client, "ec-scope-elder@example.test")
        caregiver = _register(client, "ec-scope-care@example.test", "caregiver")
        # Create a link with only care_tasks scope (no family_messages).
        invitation = client.post(
            "/family-links/invitations",
            headers=_headers(elder),
            json={"email": caregiver["account"]["email"], "scopes": ["care_tasks"]},
        )
        token = invitation.json()["token"]
        accepted = client.post(
            "/family-links/invitations/accept",
            headers=_headers(caregiver),
            json={"token": token},
        )
        link_id = accepted.json()["id"]
        # Adding as emergency contact should fail (no family_messages scope).
        response = client.post(
            "/safety/emergency-contacts",
            headers=_headers(elder),
            json={"family_link_id": link_id, "label": "son"},
        )
        assert response.status_code == 403


def test_emergency_contact_duplicate_rejected(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "ec-dup.db"))
    with TestClient(app) as client:
        elder = _register(client, "ec-dup-elder@example.test")
        caregiver = _register(client, "ec-dup-care@example.test", "caregiver")
        link = _create_family_link(client, elder, caregiver)
        first = client.post(
            "/safety/emergency-contacts",
            headers=_headers(elder),
            json={"family_link_id": link["id"], "label": "son"},
        )
        assert first.status_code == 201
        second = client.post(
            "/safety/emergency-contacts",
            headers=_headers(elder),
            json={"family_link_id": link["id"], "label": "son again"},
        )
        assert second.status_code == 409


# ---------------------------------------------------------------------------
# Safety support request
# ---------------------------------------------------------------------------


def test_safety_support_request_sends_family_message(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "support-request.db"))
    with TestClient(app) as client:
        elder = _register(client, "sr-elder@example.test")
        caregiver = _register(client, "sr-care@example.test", "caregiver")
        link = _create_family_link(client, elder, caregiver)
        contact = client.post(
            "/safety/emergency-contacts",
            headers=_headers(elder),
            json={"family_link_id": link["id"], "label": "daughter"},
        ).json()
        # Send a support request.
        response = client.post(
            "/safety/support-request",
            headers=_headers(elder),
            json={
                "emergency_contact_id": contact["id"],
                "message": "我現在需要你的幫助，請聯絡我。",
                "idempotency_key": "support-1",
                "family_link_id": link["id"],
                "expected_authorization_epoch": link["authorization_epoch"],
            },
        )
        assert response.status_code == 200
        assert response.json()["sent"] is True
        assert response.json()["emergency_contact_id"] == contact["id"]
        # Idempotent retry returns the same message.
        retry = client.post(
            "/safety/support-request",
            headers=_headers(elder),
            json={
                "emergency_contact_id": contact["id"],
                "message": "我現在需要你的幫助，請聯絡我。",
                "idempotency_key": "support-1",
                "family_link_id": link["id"],
                "expected_authorization_epoch": link["authorization_epoch"],
            },
        )
        assert retry.status_code == 200
        assert retry.json()["family_message_id"] == response.json()["family_message_id"]
        # The caregiver should see the message.
        messages = client.get("/family-messages", headers=_headers(caregiver)).json()
        assert len(messages) == 1
        assert "幫助" in messages[0]["content"]


def test_safety_support_request_caregiver_forbidden(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "sr-caregiver.db"))
    with TestClient(app) as client:
        caregiver = _register(client, "sr-care2@example.test", "caregiver")
        response = client.post(
            "/safety/support-request",
            headers=_headers(caregiver),
            json={"emergency_contact_id": "fake", "message": "help",
                  "family_link_id": "unavailable-link", "expected_authorization_epoch": 1},
        )
        assert response.status_code == 403


# ---------------------------------------------------------------------------
# Check-in schedule management
# ---------------------------------------------------------------------------


def test_check_in_schedule_crud(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "checkin-schedule.db"))
    with TestClient(app) as client:
        elder = _register(client, "ci-elder@example.test")
        headers = _headers(elder)
        # Initially no schedule.
        assert client.get("/check-ins/schedule", headers=headers).json() is None
        # Create a schedule.
        created = client.put(
            "/check-ins/schedule",
            headers=headers,
            json={"enabled": True, "frequency": "daily", "check_in_time": "10:00", "weekday": 1},
        )
        assert created.status_code == 200
        assert created.json()["enabled"] is True
        assert created.json()["frequency"] == "daily"
        assert created.json()["check_in_time"] == "10:00"
        # Read it back.
        schedule = client.get("/check-ins/schedule", headers=headers).json()
        assert schedule["enabled"] is True
        # Update it.
        updated = client.put(
            "/check-ins/schedule",
            headers=headers,
            json={"enabled": False, "frequency": "weekly", "check_in_time": "14:00", "weekday": 3},
        )
        assert updated.json()["enabled"] is False
        assert updated.json()["frequency"] == "weekly"
        assert updated.json()["weekday"] == 3


def test_check_in_schedule_rejects_quiet_hours(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "checkin-quiet.db"))
    with TestClient(app) as client:
        elder = _register(client, "ci-quiet@example.test")
        headers = _headers(elder)
        # 21:00 should be rejected (quiet hours start).
        response = client.put(
            "/check-ins/schedule",
            headers=headers,
            json={"enabled": True, "frequency": "daily", "check_in_time": "21:00", "weekday": 1},
        )
        assert response.status_code == 422
        # 08:00 should be rejected (before 09:00).
        response = client.put(
            "/check-ins/schedule",
            headers=headers,
            json={"enabled": True, "frequency": "daily", "check_in_time": "08:00", "weekday": 1},
        )
        assert response.status_code == 422
        # 09:00 should be accepted.
        response = client.put(
            "/check-ins/schedule",
            headers=headers,
            json={"enabled": True, "frequency": "daily", "check_in_time": "09:00", "weekday": 1},
        )
        assert response.status_code == 200
        # 20:59 should be accepted.
        response = client.put(
            "/check-ins/schedule",
            headers=headers,
            json={"enabled": True, "frequency": "daily", "check_in_time": "20:59", "weekday": 1},
        )
        assert response.status_code == 200


def test_check_in_trigger_generates_message(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "checkin-trigger.db"))
    with TestClient(app) as client:
        elder = _register(client, "ci-trigger@example.test")
        headers = _headers(elder)
        from datetime import datetime, timezone
        from unittest.mock import patch
        import app.routers.check_ins as check_ins
        assert client.post("/check-ins/trigger", headers=headers, json={}).json()["triggered"] is False
        client.put("/check-ins/schedule", headers=headers, json={"enabled": True, "check_in_time": "10:00"})
        fixed = datetime(2026, 10, 3, 4, 0, tzinfo=timezone.utc)
        with patch.object(check_ins, "datetime") as clock:
            clock.now.return_value = fixed
            clock.combine.side_effect = datetime.combine
            response = client.post("/check-ins/trigger", headers=headers, json={})
            assert response.status_code == 200, response.text
            body = response.json()
            assert body["triggered"] is True
            assert body["message_id"]
            conversation = client.get(f"/conversations/{body['conversation_id']}", headers=headers).json()
            assert len(conversation["messages"]) == 2
            assert client.post("/check-ins/trigger", headers=headers, json={}).json()["triggered"] is False
            assert len(client.get(f"/conversations/{body['conversation_id']}", headers=headers).json()["messages"]) == 2
            notices = client.get("/notifications", headers=headers).json()["notifications"]
            assert len(notices) == 1 and notices[0]["kind"] == "check_in"



def test_check_in_trigger_caregiver_forbidden(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "checkin-caregiver.db"))
    with TestClient(app) as client:
        caregiver = _register(client, "ci-care@example.test", "caregiver")
        response = client.post("/check-ins/trigger", headers=_headers(caregiver), json={})
        assert response.status_code == 403


# ---------------------------------------------------------------------------
# Speech transcription
# ---------------------------------------------------------------------------


def test_speech_transcribe_has_no_fake_demo(tmp_path: Path, monkeypatch) -> None:
    from .test_speech_provider import _payload
    monkeypatch.delenv("TENCENT_ASR_SECRET_ID", raising=False)
    monkeypatch.delenv("TENCENT_ASR_SECRET_KEY", raising=False)
    app = create_app(_settings(tmp_path / "speech-demo.db"))
    with TestClient(app) as client:
        elder = _register(client, "speech-elder@example.test")
        response = client.post("/speech/transcribe", headers=_headers(elder), json=_payload())
        assert response.status_code == 503
        assert "transcript" not in response.json()


def test_speech_transcribe_rejects_short_audio(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "speech-short.db"))
    with TestClient(app) as client:
        elder = _register(client, "speech-short@example.test")
        audio_data = base64.b64encode(b"short").decode("ascii")
        response = client.post(
            "/speech/transcribe",
            headers=_headers(elder),
            json={
                "audio_base64": audio_data,
                "format": "wav",
                "language_hint": "yue-HK",
                "sample_rate": 16000,
                "audio_processing_consent": True,
            },
        )
        assert response.status_code == 400


def test_speech_transcribe_requires_auth(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "speech-auth.db"))
    with TestClient(app) as client:
        audio_data = base64.b64encode(b"x" * 200).decode("ascii")
        response = client.post(
            "/speech/transcribe",
            json={
                "audio_base64": audio_data,
                "format": "wav",
                "language_hint": "yue-HK",
                "sample_rate": 16000,
                "audio_processing_consent": True,
            },
        )
        assert response.status_code == 401


# ---------------------------------------------------------------------------
# Health endpoint shows new features
# ---------------------------------------------------------------------------


def test_health_shows_langgraph_and_version(tmp_path: Path) -> None:
    app = create_app(_settings(tmp_path / "health.db"))
    with TestClient(app) as client:
        response = client.get("/health")
        assert response.status_code == 200
        body = response.json()
        assert body["status"] == "ok"
        assert body["demo_mode"] is True
        assert body["langgraph"] is True
