from __future__ import annotations
from .memory_revision_helpers import memory_revision_headers

from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi.testclient import TestClient

from app.community_models import CommunityListing, CommunitySkill
from app.config import Settings
from app.main import create_app
from app.memory_models import PersonalMemory


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


def _app(path: Path):
    return create_app(Settings(database_url=f"sqlite:///{path}", auth_secret="community-test", demo_mode=True))


class _UnavailableCommunitySearch:
    def search(self, *, listing_type: str, topic: str | None = None, area: str | None = None, **kwargs) -> dict:
        from datetime import datetime, timezone
        return {
            "items": [], "no_results": True,
            "message": "Community sources could not be reached, so no current result can be confirmed.",
            "search_state": "unavailable", "checked_at": None,
            "requested_at": datetime.now(timezone.utc),
            "sources": [{"name": "Offline fixture", "url": "https://example.test", "state": "unavailable", "checked_at": None, "error": "offline fixture"}],
        }


def test_browse_empty_catalog_and_personal_skill_consent_boundary(tmp_path: Path) -> None:
    app = _app(tmp_path / "community.db")
    with TestClient(app) as client:
        app.state.community_search = _UnavailableCommunitySearch()
        elder = _register(client, "community-owner@example.test")
        caregiver = _register(client, "community-caregiver@example.test", "caregiver")

        empty = client.get("/community/activities")
        assert empty.status_code == 200
        assert empty.json()["items"] == []
        assert empty.json()["search_state"] == "unavailable"
        assert empty.json()["checked_at"] is None
        # These rows are clearly synthetic test fixtures. The API displays a
        # listing only after explicit approval, a recent check, and safe source URLs.
        now = datetime.now(timezone.utc)
        with app.state.session_factory() as db:
            db.add_all([
                CommunityListing(
                    listing_type="activity", title="Synthetic workshop", summary="test only",
                    organization="Synthetic test organization", source_name="Synthetic test fixture",
                    source_url="https://example.test/verified-fixture", last_checked_at=now,
                    status="approved",
                ),
                CommunityListing(
                    listing_type="activity", title="Expired fixture", summary="test only",
                    organization="Synthetic test organization", source_name="Synthetic test fixture",
                    source_url="https://example.test/old-fixture", last_checked_at=now - timedelta(days=40),
                    status="approved",
                ),
                CommunityListing(
                    listing_type="activity", title="Draft fixture", summary="test only",
                    organization="Synthetic test organization", source_name="Synthetic test fixture",
                    source_url="https://example.test/draft-fixture", last_checked_at=now,
                    status="draft",
                ),
                CommunityListing(
                    listing_type="activity", title="Unsafe fixture", summary="test only",
                    organization="Synthetic test organization", source_name="Synthetic test fixture",
                    source_url="javascript:alert(1)", last_checked_at=now,
                    status="approved",
                ),
                CommunityListing(
                    listing_type="activity", title="Future check fixture", summary="test only",
                    organization="Synthetic test organization", source_name="Synthetic test fixture",
                    source_url="https://example.test/future-check", last_checked_at=now + timedelta(days=1),
                    status="approved",
                ),
                CommunityListing(
                    listing_type="activity", title="Ended fixture", summary="test only",
                    organization="Synthetic test organization", source_name="Synthetic test fixture",
                    source_url="https://example.test/ended", last_checked_at=now,
                    event_end_at=now - timedelta(days=1), status="approved",
                ),
                CommunityListing(
                    listing_type="activity", title="Unsafe registration fixture", summary="test only",
                    organization="Synthetic test organization", source_name="Synthetic test fixture",
                    source_url="https://example.test/safe-source", registration_url="javascript:alert(1)",
                    last_checked_at=now, status="approved",
                ),
            ])
            db.commit()
        # Legacy/manual rows do not feed the autonomous search result.
        curated = client.get("/community/activities").json()
        assert curated["items"] == []
        assert curated["search_state"] == "unavailable"
        headers = _headers(elder)
        assert client.get("/community/skills/suggestions", headers=memory_revision_headers(client, headers)).status_code == 403
        assert client.get("/community/skills/suggestions", headers={**_headers(caregiver), 'X-Memory-Revision': '0'}).status_code == 403

        enabled = client.put("/memories/consent", headers=memory_revision_headers(client, headers), json={"enabled": True})
        assert enabled.status_code == 200
        candidate = client.post(
            "/memories", headers=memory_revision_headers(client, headers), json={"content": "I was a tailor and taught sewing."}
        )
        assert candidate.status_code == 201
        memory_id = candidate.json()["id"]
        assert client.get("/community/skills/suggestions", headers=memory_revision_headers(client, headers)).json()["items"] == []
        assert client.post(f"/memories/{memory_id}/confirm", headers=memory_revision_headers(client, headers)).status_code == 200

        suggestions = client.get("/community/skills/suggestions", headers=memory_revision_headers(client, headers))
        assert suggestions.status_code == 200
        skill = suggestions.json()["items"][0]
        assert skill["suggestion"] == "Tailoring and basic sewing"
        assert skill["status"] == "suggested"
        assert client.get(
            "/community/opportunities", headers=headers, params={"skill_id": skill["id"]}
        ).status_code == 409

        rejected = client.post(
            f"/community/skills/{skill['id']}/decision", headers=memory_revision_headers(client, headers), json={"decision": "reject"}
        )
        assert rejected.status_code == 200
        assert rejected.json()["status"] == "rejected"
        assert client.get("/community/skills/suggestions", headers=memory_revision_headers(client, headers)).json()["items"] == []


def test_skill_requires_owner_confirmation_and_active_source_memory(tmp_path: Path) -> None:
    app = _app(tmp_path / "community-source.db")
    with TestClient(app) as client:
        app.state.community_search = _UnavailableCommunitySearch()
        owner = _register(client, "skill-owner@example.test")
        other = _register(client, "skill-other@example.test")
        headers = _headers(owner)
        client.put("/memories/consent", headers=memory_revision_headers(client, headers), json={"enabled": True})
        other_headers = _headers(other)
        client.put("/memories/consent", headers=memory_revision_headers(client, other_headers), json={"enabled": True})
        created = client.post("/memories", headers=memory_revision_headers(client, headers), json={"content": "I spent years gardening."})
        memory_id = created.json()["id"]
        client.post(f"/memories/{memory_id}/confirm", headers=memory_revision_headers(client, headers))
        skill = client.get("/community/skills/suggestions", headers=memory_revision_headers(client, headers)).json()["items"][0]

        assert client.post(
            f"/community/skills/{skill['id']}/decision",
            headers=memory_revision_headers(client, other_headers),
            json={"decision": "confirm"},
        ).status_code in {403, 404}
        assert client.post(
            f"/community/skills/{skill['id']}/decision",
            headers=memory_revision_headers(client, headers),
            json={"decision": "edit", "skill": "Community gardening"},
        ).json()["status"] == "confirmed"
        refreshed = client.get("/community/skills/suggestions", headers=memory_revision_headers(client, headers))
        assert len(refreshed.json()["items"]) == 1
        assert refreshed.json()["items"][0]["suggestion"] == "Community gardening"
        no_matches = client.get(
            "/community/opportunities", headers=headers, params={"skill_id": skill["id"]}
        )
        assert no_matches.status_code == 200
        assert no_matches.json()["no_results"] is True

        # Consent withdrawal immediately blocks memory-linked matching.
        client.put("/memories/consent", headers=memory_revision_headers(client, headers), json={"enabled": False})
        assert client.get(
            "/community/opportunities", headers=headers, params={"skill_id": skill["id"]}
        ).status_code == 403
        suppressed = client.patch(
            f"/memories/{memory_id}", headers=memory_revision_headers(client, headers), json={"suppressed": True}
        )
        assert suppressed.status_code == 200
        with app.state.session_factory() as db:
            assert db.get(CommunitySkill, skill["id"]) is None
        assert client.delete(f"/memories/{memory_id}", headers=memory_revision_headers(client, headers, idempotency_key='test_community-189-delete')).status_code == 204
        with app.state.session_factory() as db:
            assert db.get(PersonalMemory, memory_id) is None
