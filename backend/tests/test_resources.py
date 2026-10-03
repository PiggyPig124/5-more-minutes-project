from __future__ import annotations

import asyncio
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.config import Settings
from app.main import create_app
from app.resource_models import KnowledgeSource, ResourceRecord
from app.resource_service import ResourceService, search_resources, seed_resources
from app.routers.resources import router as resources_router


def _settings(database: Path) -> Settings:
    return Settings(
        database_url=f"sqlite:///{database}",
        auth_secret="resource-test-secret",
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


def _app(database: Path):
    app = create_app(_settings(database))
    # The production app includes this router during integration.  Keeping the
    # test registration local lets this focused suite run before that wiring
    # lands in the shared entry point.
    app.include_router(resources_router)
    return app


def test_resource_search_requires_auth_and_serves_both_roles(tmp_path: Path) -> None:
    app = _app(tmp_path / "resources-auth.db")
    with TestClient(app) as client:
        unauthenticated = client.post("/resources/search", json={"query": "medical fee waiver"})
        assert unauthenticated.status_code == 401

        elder = _register(client, "resource-elder@example.test", "elder")
        caregiver = _register(client, "resource-caregiver@example.test", "caregiver")

        elder_result = client.post(
            "/resources/search",
            headers=_headers(elder),
            json={"query": "medical fee waiver", "limit": 4},
        )
        assert elder_result.status_code == 200, elder_result.text
        body = elder_result.json()
        assert set(body) == {"query", "retrieval_mode", "items", "conflicts"}
        assert body["retrieval_mode"] == "keyword"
        item = next(item for item in body["items"] if item["id"] == "ha-medical-fee-waiver")
        assert item["url"].startswith("https://www.ha.org.hk/")
        assert item["verified_at"] == "2026-09-20"
        assert item["effective_date"] == "2026-01-01"
        assert item["conditions"]
        assert item["missing_information"]
        assert len(item["next_steps"]) == 3
        assert "you qualify" not in item["excerpt"].lower()

        caregiver_result = client.get(
            "/resources/search",
            headers=_headers(caregiver),
            params={"query": "carer support", "limit": 2},
        )
        assert caregiver_result.status_code == 200, caregiver_result.text
        assert any(item["id"] == "swd-carer-support-hotline" for item in caregiver_result.json()["items"])


def test_no_match_abstains_and_post_contract_validates_limit(tmp_path: Path) -> None:
    app = _app(tmp_path / "resources-abstain.db")
    with TestClient(app) as client:
        elder = _register(client, "resource-abstain@example.test")
        no_match = client.post(
            "/resources/search",
            headers=_headers(elder),
            json={"query": "zxqv-unrelated-astrophysics-991", "limit": 4},
        )
        assert no_match.status_code == 200, no_match.text
        assert no_match.json() == {
            "query": "zxqv-unrelated-astrophysics-991",
            "retrieval_mode": "keyword",
            "items": [],
            "conflicts": [],
        }

        blank = client.get("/resources/search", headers=_headers(elder), params={"query": "   "})
        assert blank.status_code == 422
        invalid_limit = client.post(
            "/resources/search",
            headers=_headers(elder),
            json={"query": "elderly", "limit": 0},
        )
        assert invalid_limit.status_code == 422


def test_seed_is_idempotent_and_search_uses_separate_public_table(tmp_path: Path) -> None:
    app = _app(tmp_path / "resources-seed.db")
    with TestClient(app) as client:
        elder = _register(client, "resource-seed@example.test")
        db = app.state.session_factory()
        try:
            # The integrated app may already seed the collection during its
            # lifespan; a focused app without that hook inserts all six rows.
            assert seed_resources(db) in {0, 6}
            assert seed_resources(db) == 0
            rows = db.scalars(select(KnowledgeSource)).all()
            assert len(rows) == len(ResourceService(embedding_provider=None).records)
            assert all(row.content_hash for row in rows)
            response = asyncio.run(search_resources(db, "community care voucher", 4))
            assert response["retrieval_mode"] == "keyword"
            assert any(item["id"] == "swd-community-care-service-voucher" for item in response["items"])
        finally:
            db.close()

        # The HTTP route can use the same persisted public collection while
        # private account data remains irrelevant to the retrieval query.
        result = client.get(
            "/resources/search",
            headers=_headers(elder),
            params={"query": "community care voucher"},
        )
        assert result.status_code == 200
        assert result.json()["items"]


def test_every_seed_source_has_provenance_complete_conditions_and_three_steps() -> None:
    service = ResourceService(embedding_provider=None)
    assert len(service.records) >= 6
    for record in service.records:
        assert record.url.startswith("https://")
        assert record.verified_at.isoformat() == "2026-09-20"
        assert record.title and record.excerpt and record.source_authority
        assert record.conditions
        assert record.missing_information
        assert len(record.next_steps) == 3
    directory = next(record for record in service.records if record.id == "swd-elderly-centres-directory-2026-05")
    assert len(directory.districts) == 18
    assert {"Central and Western", "Eastern", "Yuen Long"}.issubset(directory.districts)
    for district in directory.districts:
        result = service.search(f"{district} elderly centre")
        assert any(
            item.id == "swd-elderly-centres-directory-2026-05"
            for item in result.items
        ), district


def test_conflicting_verified_records_are_reported_without_choosing_a_winner() -> None:
    common = {
        "title": "Example official service",
        "excerpt": "Official source evidence for a service.",
        "url": "https://example.gov.hk/service",
        "verified_at": "2026-09-20",
        "effective_date": None,
        "conditions": ["A condition requires checking."],
        "missing_information": ["Current status is unknown."],
        "next_steps": ["Read the source.", "Ask the office.", "Keep the answer unconfirmed."],
        "search_terms": ["example service", "service conflict"],
        "category": "test",
        "source_authority": "Example authority",
        "districts": [],
        "conflict_group": "example-service",
    }
    first = ResourceRecord(**common, id="example-a", conflict_note="The source says applications are open.")
    second = ResourceRecord(**common, id="example-b", conflict_note="The source says applications are paused.")
    result = ResourceService([first, second], embedding_provider=None).search("service conflict")
    assert len(result.items) == 2
    assert result.conflicts and "Conflicting official evidence" in result.conflicts[0]
