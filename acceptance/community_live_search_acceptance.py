"""Opt-in live retrieval smoke test using synthetic accounts and a temporary DB."""
from __future__ import annotations
from memory_revision_helpers import memory_revision_headers

import argparse
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from _bounded_acceptance import supervise
from echo_mvp_phase1_acceptance import assert_activity_catalog, assert_disabled_opportunities


def run_live() -> None:
    from fastapi.testclient import TestClient
    from app.config import Settings
    from app.main import create_app
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
            assert_activity_catalog(first,expected_state='live',require_items=False)
            check(True, "official snapshot fetched and parsed; current inventory may honestly be empty")
            cached = client.get("/community/activities").json()
            assert_activity_catalog(cached,expected_state='cache',expected_checked_at=first['checked_at'],require_items=False)
            check(True, "cached response retains original retrieval time and source boundaries")
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
            assert_disabled_opportunities(opportunities)
            check(True, "unapproved opportunity providers remain explicitly disabled; activities are not relabeled")
            session = client.post("/guest/sessions").json()
            reply = client.post(f"/guest/sessions/{session['session_id']}/messages", json={"content": "Please search community activities."})
            check(reply.status_code == 200 and bool(reply.json().get("community_sources")), "guest conversation invokes search with public citations")
            conversation = client.post("/conversations", headers=headers, json={}).json()
            reply = client.post(f"/conversations/{conversation['id']}/messages", headers=headers, json={"content": "Please search community activities."})
            check(reply.status_code == 200 and bool(reply.json()["assistant_message"]["metadata_json"].get("community_sources")), "authenticated conversation stores source metadata correctly")
            print(f"Live snapshot: {len(first['items'])} activity listings; {len(opportunities['items'])} skill-filtered opportunities.")
    print(f"Community live acceptance: {count} passed, 0 failed")


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live',action='store_true',help='Contact the fixed official SmartPLAY public endpoint')
    parser.add_argument('--worker',action='store_true',help=argparse.SUPPRESS)
    parser.add_argument('--report',type=Path,default=Path(tempfile.gettempdir())/f'echo-community-live-{uuid.uuid4().hex}.json')
    args=parser.parse_args()
    if not args.live:parser.error('--live is required; this test contacts the official public provider')
    if args.worker:run_live();return 0
    return supervise(Path(__file__),['--live','--worker'],timeout_seconds=90,report_path=args.report)

if __name__ == "__main__":
    raise SystemExit(main())
