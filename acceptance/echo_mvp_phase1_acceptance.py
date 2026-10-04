"""Independent HTTP acceptance against disposable processes and a synthetic DB."""
from __future__ import annotations
from memory_revision_helpers import http_memory_revision_headers

import secrets
import sqlite3
import tempfile
from contextlib import closing
from pathlib import Path

from foundation_api_acceptance import APIClient
from process_restart_acceptance import _free_port, _start_server, _stop_server, _wait_for_health


def main() -> None:
    passed = 0

    def check(condition: bool, label: str) -> None:
        nonlocal passed
        if not condition:
            raise AssertionError(label)
        passed += 1
        print("PASS", label)

    def call(client: APIClient, method: str, path: str, body=None, status=200, *, headers=None):
        response = client.request(method, path, body, headers=headers)
        check(response.status == status, f"{method} {path} returns {status}: {response.body if response.status != status else ''}")
        return response.body

    with tempfile.TemporaryDirectory(prefix="echo-phase1-") as folder:
        database = Path(folder) / "synthetic.db"
        secret, port = secrets.token_urlsafe(32), _free_port()
        origin = f"http://127.0.0.1:{port}"
        process = _start_server(database, secret, port)
        guest, elder, caregiver = (APIClient(origin) for _ in range(3))
        try:
            check(_wait_for_health(origin, process), "first process healthy")
            session = call(guest, "POST", "/guest/sessions", status=201)
            call(guest, "POST", f"/guest/sessions/{session['session_id']}/messages", {"content": "I worked as a tailor for forty years."})
            with closing(sqlite3.connect(database)) as db:
                check(all(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0 for table in ("accounts", "conversations", "messages", "personal_memories")), "guest text creates no identity, private history or memory rows")
            catalog = call(guest, "GET", "/community/activities")
            check(catalog.get("search_state") == "unavailable" and catalog.get("sources") == [] and catalog["items"] == [] and catalog["no_results"], "unapproved community sources stay disabled by default")
            for client, role in ((elder, "elder"), (caregiver, "caregiver")):
                auth = call(client, "POST", "/auth/register", {"email": f"{role}@example.invalid", "password": "Synthetic-acceptance-2026!", "display_name": f"Synthetic {role}", "role": role}, 201)
                client.token = auth["access_token"]
            check(call(elder, "GET", "/memories/consent")["enabled"] is False, "new elder memory defaults off")
            call(elder, "POST", "/memories/save", {"content": "I worked as a tailor for forty years.", "kind": "experience"}, 403, headers=http_memory_revision_headers(elder))
            call(caregiver, "PUT", "/memories/consent", {"enabled": True}, 403, headers={'X-Memory-Revision': '0'})
            call(elder, "PUT", "/memories/consent", {"enabled": True}, headers=http_memory_revision_headers(elder))
            memory = call(elder, "POST", "/memories/save", {"content": "I worked as a tailor for forty years.", "kind": "experience"}, 201, headers=http_memory_revision_headers(elder))
            check(memory["status"] == "confirmed", "explicit Save creates confirmed memory")
            skills = call(elder, "GET", "/community/skills/suggestions", headers=http_memory_revision_headers(elder))["items"]
            check(len(skills) == 1 and skills[0]["memory_id"] == memory["id"] and skills[0]["status"] == "suggested", "confirmed source yields private unconfirmed skill")
            skill = skills[0]
            call(caregiver, "GET", "/community/skills/suggestions", status=403, headers={'X-Memory-Revision': '0'})
            call(elder, "POST", f"/community/skills/{skill['id']}/decision", {"decision": "confirm"}, headers=http_memory_revision_headers(elder))
            call(elder, "PUT", "/memories/consent", {"enabled": False}, headers=http_memory_revision_headers(elder))
            check(any(row["id"] == memory["id"] for row in call(elder, "GET", "/memories")), "turning memory off preserves owner review")
            call(elder, "GET", "/community/skills/suggestions", status=403, headers=http_memory_revision_headers(elder))
            call(guest, "DELETE", f"/guest/sessions/{session['session_id']}", status=204)
            call(guest, "POST", f"/guest/sessions/{session['session_id']}/messages", {"content": "hello"}, 404)
            restart_session = call(guest, "POST", "/guest/sessions", status=201)
        finally:
            _stop_server(process)
        process = _start_server(database, secret, port)
        try:
            check(_wait_for_health(origin, process), "second process healthy")
            check(call(elder, "GET", "/memories/consent")["enabled"] is False, "disabled consent survives process restart")
            call(guest, "POST", f"/guest/sessions/{restart_session['session_id']}/messages", {"content": "hello"}, 404)
            call(elder, "DELETE", f"/memories/{memory['id']}", status=204, headers=http_memory_revision_headers(elder, idempotency_key='echo_mvp_phase1_acceptance-70-delete'))
            call(elder, "PUT", "/memories/consent", {"enabled": True}, headers=http_memory_revision_headers(elder))
            check(call(elder, "GET", "/community/skills/suggestions", headers=http_memory_revision_headers(elder))["items"] == [], "deleted source is absent from skill discovery")
        finally:
            _stop_server(process)
    print(f"\nEcho phase 1 acceptance: {passed} passed, 0 failed")


if __name__ == "__main__":
    main()
