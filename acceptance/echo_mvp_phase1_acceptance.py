"""Independent HTTP acceptance against disposable processes and a synthetic DB."""
from __future__ import annotations
from memory_revision_helpers import http_memory_revision_headers

import secrets
import argparse
import os
import sqlite3
import subprocess
import sys
import tempfile
import uuid
from contextlib import closing
from pathlib import Path
from urllib.parse import urlsplit

from foundation_api_acceptance import APIClient
from process_restart_acceptance import ROOT, _free_port, _wait_for_health
from _bounded_acceptance import stop_tree, supervise

SNAPSHOT_URL = 'https://data.smartplay.lcsd.gov.hk/rest/cms/api/v1/publ/contents/open-data/activity-prog/file'

def assert_activity_catalog(body, *, expected_state, expected_checked_at=None, require_items=True):
    assert body['search_state']==expected_state, 'Activity snapshot state differs from the expected completed result'
    assert body['checked_at'], 'Successful retrieval needs its original timestamp'
    if expected_checked_at is not None:assert body['checked_at']==expected_checked_at, 'Cache rewrote the original retrieval date'
    assert len(body['sources'])==1 and body['sources'][0]['url']==SNAPSHOT_URL, 'Activity citations must use the approved snapshot'
    source=body['sources'][0]
    assert source['state']==expected_state and source['checked_at']==body['checked_at'] and source.get('error_kind') is None
    assert body['total_count']>=len(body['items']) and len(body['items'])<=body['limit']
    assert body['no_results'] is (body['total_count']==0)
    assert body['has_more'] is (body['offset']+body['limit']<body['total_count'])
    assert body['search_reason']==('no_matches' if body['total_count']==0 else None)
    if require_items:assert body['items'], 'Controlled activity fixture unexpectedly empty'
    for item in body['items']:
        url=urlsplit(item['source_url'])
        assert url.scheme=='https' and url.netloc=='www.smartplay.lcsd.gov.hk' and url.path=='/programme/detail'
        assert item['last_checked_at']==body['checked_at'] and item['event_end_at'], 'Listing dates must survive retrieval'
        assert item['listing_type']=='activity' and item['verified'] is False, 'Availability must remain unverified'
        assert item['registration_url'] is None, 'Activity details are not invented booking links'

def assert_disabled_opportunities(body):
    assert body['search_state']=='unavailable' and body['search_reason']=='sources_disabled'
    assert body['items']==[] and body['sources']==[] and body['no_results'] is True
    assert body['checked_at'] is None and body['total_count']==0 and body['message']

def create_fixture_app():
    """Acceptance-only synthetic transport; the actual parser/cache/router run."""
    sys.path.insert(0,str(ROOT/'backend'))
    from datetime import datetime,timedelta,timezone
    import httpx
    from app.main import create_app
    from app.smartplay_community_search import SmartPlayCommunitySearch
    today=datetime.now(timezone.utc).date()
    row={'ACTIVITY_NO':'SYNTHETIC001','EN_PGM_NAME':'Synthetic acceptance activity (not a real event)',
         'TC_PGM_NAME':'Synthetic acceptance activity (not a real event)',
         'PGM_START_DATE':today.isoformat(),'PGM_END_DATE':(today+timedelta(days=7)).isoformat(),
         'TC_URL':'https://www.smartplay.lcsd.gov.hk/programme/detail?activityNo=SYNTHETIC001&lang=tc',
         'EN_URL':'https://www.smartplay.lcsd.gov.hk/programme/detail?activityNo=SYNTHETIC001&lang=en'}
    def fixture(request):
        assert request.method=='GET' and str(request.url)==SNAPSHOT_URL and not request.content
        payload=httpx.Response(200,json=[row]).content
        return httpx.Response(200,headers={'content-type':'application/json'},stream=httpx.ByteStream(payload))
    app=create_app()
    service=app.state.community_search
    assert isinstance(service,SmartPlayCommunitySearch) and service.enabled is True, 'Application default SmartPLAY adapter must be enabled'
    service.transport=httpx.MockTransport(fixture)
    return app

def _start_fixture_server(database,secret,port,log):
    env=os.environ.copy()
    env.update(DATABASE_URL='sqlite:///'+database.as_posix(),AUTH_SECRET=secret,DEMO_MODE='1',APP_ENV='development')
    return subprocess.Popen([sys.executable,'-m','uvicorn','echo_mvp_phase1_acceptance:create_fixture_app',
        '--factory','--app-dir','acceptance','--host','127.0.0.1','--port',str(port)],
        cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)


def run_journey() -> None:
    passed = 0

    def check(condition: bool, label: str) -> None:
        nonlocal passed
        if not condition:
            raise AssertionError(label)
        passed += 1
        print("PASS", label)

    def call(client: APIClient, method: str, path: str, body=None, status=200, *, headers=None):
        response = client.request(method, path, body, headers=headers)
        check(response.status == status, f"{method} {path} returns {status} (actual={response.status}, transport_error={response.error})")
        return response.body

    with tempfile.TemporaryDirectory(prefix="echo-phase1-") as folder:
        database = Path(folder) / "synthetic.db"
        secret, port = secrets.token_urlsafe(32), _free_port()
        origin = f"http://127.0.0.1:{port}"
        log=(Path(folder)/'server.log').open('w',encoding='utf-8')
        process = _start_fixture_server(database, secret, port,log)
        guest, elder, caregiver = (APIClient(origin) for _ in range(3))
        try:
            check(_wait_for_health(origin, process), "first process healthy")
            session = call(guest, "POST", "/guest/sessions", status=201)
            call(guest, "POST", f"/guest/sessions/{session['session_id']}/messages", {"content": "I worked as a tailor for forty years."})
            with closing(sqlite3.connect(database)) as db:
                check(all(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0 for table in ("accounts", "conversations", "messages", "personal_memories")), "guest text creates no identity, private history or memory rows")
            catalog = call(guest, "GET", "/community/activities")
            assert_activity_catalog(catalog,expected_state='live')
            check(True,'offline fixture exercises enabled official activity retrieval without claiming a live provider check')
            cached=call(guest,'GET','/community/activities')
            assert_activity_catalog(cached,expected_state='cache',expected_checked_at=catalog['checked_at'])
            check(True,'cached activities preserve original retrieval dates and unverified availability')
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
            opportunities=call(elder,'GET',f"/community/opportunities?skill_id={skill['id']}")
            assert_disabled_opportunities(opportunities)
            check(True,'unsupported opportunity sources remain explicitly disabled with no invented citations')
            call(elder, "PUT", "/memories/consent", {"enabled": False}, headers=http_memory_revision_headers(elder))
            check(any(row["id"] == memory["id"] for row in call(elder, "GET", "/memories")), "turning memory off preserves owner review")
            call(elder, "GET", "/community/skills/suggestions", status=403, headers=http_memory_revision_headers(elder))
            call(guest, "DELETE", f"/guest/sessions/{session['session_id']}", status=204)
            call(guest, "POST", f"/guest/sessions/{session['session_id']}/messages", {"content": "hello"}, 404)
            restart_session = call(guest, "POST", "/guest/sessions", status=201)
        finally:
            stop_tree(process)
            if sys.exc_info()[0] is not None:
                log.flush()
                print('Synthetic server diagnostics:',Path(log.name).read_text(encoding='utf-8',errors='replace')[-4000:])
                log.close()
        process = _start_fixture_server(database, secret, port,log)
        try:
            check(_wait_for_health(origin, process), "second process healthy")
            check(call(elder, "GET", "/memories/consent")["enabled"] is False, "disabled consent survives process restart")
            call(guest, "POST", f"/guest/sessions/{restart_session['session_id']}/messages", {"content": "hello"}, 404)
            call(elder, "DELETE", f"/memories/{memory['id']}", status=204, headers=http_memory_revision_headers(elder, idempotency_key='echo_mvp_phase1_acceptance-70-delete'))
            call(elder, "PUT", "/memories/consent", {"enabled": True}, headers=http_memory_revision_headers(elder))
            check(call(elder, "GET", "/community/skills/suggestions", headers=http_memory_revision_headers(elder))["items"] == [], "deleted source is absent from skill discovery")
        finally:
            stop_tree(process)
            log.close()
    print(f"\nEcho phase 1 acceptance: {passed} passed, 0 failed")


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker',action='store_true',help=argparse.SUPPRESS)
    parser.add_argument('--report',type=Path,default=Path(tempfile.gettempdir())/f'echo-phase1-{uuid.uuid4().hex}.json')
    args=parser.parse_args()
    if args.worker:run_journey();return 0
    return supervise(Path(__file__),['--worker'],timeout_seconds=60,report_path=args.report)

if __name__ == "__main__":
    raise SystemExit(main())
