"""Opt-in live retrieval smoke test using synthetic accounts and a temporary DB."""
from __future__ import annotations
from memory_revision_helpers import memory_revision_headers

import argparse
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from fastapi.testclient import TestClient
from app.config import Settings
from app.main import create_app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Fetch the configured public community pages")
    if not parser.parse_args().live:
        parser.error("--live is required; this test contacts the configured public providers")
    count = 0

    def check(ok: bool, label: str) -> None:
        nonlocal count
        if not ok:
            raise AssertionError(label)
        count += 1
        print("PASS", label)

    with tempfile.TemporaryDirectory(prefix="echo-community-live-") as folder:
        app = create_app(Settings(database_url=f"sqlite:///{Path(folder) / 'synthetic.db'}", demo_mode=True))
        with TestClient(app) as client:
            response = client.get("/community/activities")
            check(response.status_code == 200, "public activity endpoint responds")
            first = response.json()
            check(first["search_state"] == "live" and bool(first["items"]), "activities retrieved from a real provider")
            check(all(row["source_url"].startswith("https://") and row["last_checked_at"] and row["event_end_at"] and row["verified"] is False for row in first["items"]), "results preserve dates and do not guarantee availability")
            cached = client.get("/community/activities").json()
            check(cached["search_state"] == "cache" and cached["checked_at"] == first["checked_at"], "cached response retains original retrieval time")
            auth = client.post("/auth/register", json={"email": "community-live@example.invalid", "password": "Synthetic-live-test-2026!", "display_name": "Synthetic elder", "role": "elder"}).json()
            headers = {"Authorization": f"Bearer {auth['access_token']}"}
            client.put("/memories/consent", headers=memory_revision_headers(client, headers), json={"enabled": True})
            saved = client.post("/memories/save", headers=memory_revision_headers(client, headers), json={"content": "I worked as a cook and baking teacher.", "kind": "experience"})
            check(saved.status_code == 201, "synthetic experience explicitly saved")
            skill = client.get("/community/skills/suggestions", headers=memory_revision_headers(client, headers)).json()["items"][0]
            client.post(f"/community/skills/{skill['id']}/decision", headers=memory_revision_headers(client, headers), json={"decision": "confirm"})
            result = client.get("/community/opportunities", headers=headers, params={"skill_id": skill["id"]})
            check(result.status_code == 200, "confirmed skill invokes opportunity retrieval")
            opportunities = result.json()
            check(opportunities["search_state"] == "live" and all(row["listing_type"] == "opportunity" for row in opportunities["items"]), "volunteer source reached without relabeling classes")
            session = client.post("/guest/sessions").json()
            reply = client.post(f"/guest/sessions/{session['session_id']}/messages", json={"content": "Please search community activities."})
            check(reply.status_code == 200 and bool(reply.json().get("community_sources")), "guest conversation invokes search with public citations")
            conversation = client.post("/conversations", headers=headers, json={}).json()
            reply = client.post(f"/conversations/{conversation['id']}/messages", headers=headers, json={"content": "Please search community activities."})
            check(reply.status_code == 200 and bool(reply.json()["assistant_message"]["metadata_json"].get("community_sources")), "authenticated conversation stores source metadata correctly")
            print(f"Live snapshot: {len(first['items'])} activity listings; {len(opportunities['items'])} skill-filtered opportunities.")
    print(f"Community live acceptance: {count} passed, 0 failed")


if __name__ == "__main__":
    main()
