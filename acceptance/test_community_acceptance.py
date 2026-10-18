"""Contract regressions for acceptance scripts, never live provider tests."""
from __future__ import annotations
import copy,importlib,json,sys,time
from pathlib import Path
import pytest

sys.path.insert(0,str(Path(__file__).resolve().parent))
import echo_mvp_phase1_acceptance as phase1

URL='https://data.smartplay.lcsd.gov.hk/rest/cms/api/v1/publ/contents/open-data/activity-prog/file'
STAMP='2026-10-15T00:00:00Z'
def catalog():
    return {'search_state':'live','search_reason':None,'checked_at':STAMP,'requested_at':STAMP,
            'sources':[{'url':URL,'state':'live','checked_at':STAMP,'error_kind':None}],
            'items':[{'source_url':'https://www.smartplay.lcsd.gov.hk/programme/detail?activityNo=SYNTHETIC001&lang=en',
                      'last_checked_at':STAMP,'event_end_at':'2099-10-01T00:00:00Z',
                      'verified':False,'registration_url':None,'listing_type':'activity'}],
            'no_results':False,'total_count':1,'offset':0,'limit':20,'has_more':False}
def validator():
    fn=getattr(phase1,'assert_activity_catalog',None)
    assert callable(fn),'Phase-1 acceptance needs the current enabled SmartPLAY contract validator'
    return fn

def test_enabled_activity_and_cached_snapshot_are_valid():
    check=validator();body=catalog();check(body,expected_state='live')
    body['search_state']='cache';body['sources'][0]['state']='cache'
    check(body,expected_state='cache',expected_checked_at=STAMP)

@pytest.mark.parametrize('change',[
    lambda b:b.update(search_state='unavailable',search_reason='sources_disabled',items=[],sources=[],no_results=True),
    lambda b:b['items'][0].update(source_url='https://www.smartplay.lcsd.gov.hk.evil.invalid/programme/detail'),
    lambda b:b['items'][0].update(verified=True),
    lambda b:b['items'][0].update(registration_url='https://invented.invalid/book'),
    lambda b:b['items'][0].update(last_checked_at=None),
    lambda b:b['items'][0].update(event_end_at=None),
    lambda b:b.update(no_results=True),
    lambda b:b.update(total_count=0),
    lambda b:b['sources'][0].update(url='https://unapproved.invalid/data'),
])
def test_current_contract_still_rejects_real_product_regressions(change):
    check=validator();body=catalog();change(body)
    with pytest.raises(AssertionError):check(body,expected_state='live')

def test_cache_must_not_rewrite_original_retrieval_date():
    check=validator();body=catalog();body['search_state']='cache';body['sources'][0]['state']='cache'
    with pytest.raises(AssertionError):check(body,expected_state='cache',expected_checked_at='2026-10-14T00:00:00Z')

def test_supported_empty_snapshot_is_not_silently_a_provider_failure():
    check=validator();body=catalog();body.update(items=[],no_results=True,total_count=0,search_reason='no_matches')
    check(body,expected_state='live',require_items=False)
    with pytest.raises(AssertionError):check(body,expected_state='live')

def test_opportunity_contract_requires_explicit_disabled_reason_and_no_citations():
    check=getattr(phase1,'assert_disabled_opportunities',None)
    assert callable(check),'Unsupported opportunities must have explicit disabled-source acceptance'
    body={'search_state':'unavailable','search_reason':'sources_disabled','sources':[],
          'items':[],'no_results':True,'checked_at':None,'total_count':0,'message':'Not enabled'}
    check(body)
    for key,value in [('search_reason','source_unavailable'),('sources',[{'url':URL}]),('items',[{}]),('checked_at',STAMP)]:
        bad=copy.deepcopy(body);bad[key]=value
        with pytest.raises(AssertionError):check(bad)

def test_fixture_uses_real_adapter_without_an_external_provider(monkeypatch,tmp_path):
    factory=getattr(phase1,'create_fixture_app',None)
    assert callable(factory),'The default phase-1 journey must use an explicit offline provider fixture'
    monkeypatch.setenv('DATABASE_URL','sqlite:///'+(tmp_path/'synthetic.db').as_posix())
    monkeypatch.setenv('DEMO_MODE','1')
    from fastapi.testclient import TestClient
    with TestClient(factory()) as client:
        first=client.get('/community/activities').json();validator()(first,expected_state='live')
        assert 'Synthetic acceptance' in first['items'][0]['title']
        cached=client.get('/community/activities').json()
        validator()(cached,expected_state='cache',expected_checked_at=first['checked_at'])

@pytest.mark.parametrize('wrong_adapter',[False,True])
def test_fixture_does_not_hide_disabled_or_wrong_default_application_wiring(monkeypatch,wrong_adapter):
    from app import main
    original=main.create_app
    def broken_default():
        app=original()
        if wrong_adapter:app.state.community_search=object()
        else:app.state.community_search.enabled=False
        return app
    monkeypatch.setattr(main,'create_app',broken_default)
    with pytest.raises(AssertionError,match='default.*enabled'):phase1.create_fixture_app()

def supervisor():
    spec=importlib.util.find_spec('_bounded_acceptance')
    assert spec is not None,'Acceptance needs an absolute worker deadline, not an extended HTTP read timeout'
    return importlib.import_module('_bounded_acceptance').supervise

def test_worker_success_retains_a_machine_readable_report(tmp_path,monkeypatch):
    run=supervisor();script=tmp_path/'success.py';report=tmp_path/'result.json'
    monkeypatch.setenv('MODEL_API_KEY','synthetic-must-be-stripped')
    script.write_text("import os; print('MODEL_KEY_ABSENT='+str(not bool(os.getenv('MODEL_API_KEY'))),flush=True)")
    assert run(script,[],timeout_seconds=10,report_path=report)==0
    result=json.loads(report.read_text());assert result['outcome']=='passed'
    assert 'MODEL_KEY_ABSENT=True' in result['output_tail']

def test_nonzero_worker_is_a_failure_with_diagnostics(tmp_path):
    run=supervisor();script=tmp_path/'fail.py';report=tmp_path/'result.json'
    script.write_text("print('synthetic contract diagnostic',flush=True); raise SystemExit(7)")
    assert run(script,[],timeout_seconds=10,report_path=report)==7
    result=json.loads(report.read_text());assert result['outcome']=='failed'
    assert 'synthetic contract diagnostic' in result['output_tail']

def test_timeout_is_bounded_and_retains_last_output(tmp_path):
    run=supervisor();script=tmp_path/'hang.py';report=tmp_path/'result.json'
    script.write_text("import time; print('synthetic request remains pending',flush=True); time.sleep(60)")
    started=time.monotonic()
    assert run(script,[],timeout_seconds=1,report_path=report)==124
    assert time.monotonic()-started<15
    result=json.loads(report.read_text());assert result['outcome']=='timed_out'
    assert result['deadline_seconds']==1 and 'remains pending' in result['output_tail']

def test_deadline_also_stops_the_workers_descendant_listener(tmp_path):
    import re,socket
    run=supervisor();report=tmp_path/'result.json';child=tmp_path/'listener.py';worker=tmp_path/'parent.py'
    child.write_text("import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print('CHILD_PORT='+str(s.getsockname()[1]),flush=True); time.sleep(60)")
    worker.write_text("import subprocess,sys,time; subprocess.Popen([sys.executable,'-u',"+repr(str(child))+"]); time.sleep(60)")
    assert run(worker,[],timeout_seconds=2,report_path=report)==124
    result=json.loads(report.read_text());port=int(re.search(r'CHILD_PORT=(\d+)',result['output_tail']).group(1))
    with socket.socket() as listener:listener.bind(('127.0.0.1',port))

def test_live_runner_requires_explicit_opt_in_without_contacting_a_provider():
    import subprocess
    script=Path(__file__).with_name('community_live_search_acceptance.py')
    result=subprocess.run([sys.executable,str(script)],capture_output=True,text=True,timeout=10)
    assert result.returncode==2 and '--live is required' in result.stderr

@pytest.mark.parametrize('parent_exit',[0,7])
def test_early_worker_exit_cannot_orphan_a_descendant_or_lose_report(tmp_path,parent_exit):
    import socket
    run=supervisor();info=tmp_path/'child.json';report=tmp_path/'result.json'
    child=tmp_path/'orphan-listener.py';worker=tmp_path/'early-exit.py'
    child.write_text("import socket,time,json,pathlib; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); pathlib.Path("+repr(str(info))+").write_text(json.dumps({'port':s.getsockname()[1]})); print('descendant pending after parent exit',flush=True); time.sleep(8)")
    worker.write_text("import subprocess,sys; subprocess.Popen([sys.executable,'-u',"+repr(str(child))+"]); raise SystemExit("+str(parent_exit)+")")
    assert run(worker,[],timeout_seconds=2,report_path=report)==124
    result=json.loads(report.read_text())
    assert result['outcome']=='timed_out' and result['worker_exit_code']==parent_exit
    assert result['cleanup_or_runner_errors']==[] and 'descendant pending' in result['output_tail']
    port=json.loads(info.read_text())['port']
    with socket.socket() as listener:listener.bind(('127.0.0.1',port))

def test_live_journey_contract_can_be_replayed_offline_without_claiming_provider_verification(monkeypatch):
    import community_live_search_acceptance as live
    from app.smartplay_community_search import SmartPlayCommunitySearch
    fixture_app=phase1.create_fixture_app()
    fetch=fixture_app.state.community_search._fetch
    monkeypatch.setattr(SmartPlayCommunitySearch,'_fetch',lambda self,checked:fetch(checked))
    try:live.run_live()
    finally:fixture_app.state.engine.dispose()

@pytest.mark.skipif(sys.platform!='win32',reason='Windows ownership assignment failure')
def test_failed_job_assignment_never_runs_target_or_leaves_bootstrap(monkeypatch,tmp_path):
    import _bounded_acceptance as bounded
    marker=tmp_path/'must-not-exist';script=tmp_path/'blocked.py';report=tmp_path/'result.json'
    script.write_text('from pathlib import Path; Path('+repr(str(marker))+').write_text("unexpected")')
    processes=[];original=bounded.subprocess.Popen
    def capture(*args,**kwargs):
        process=original(*args,**kwargs);processes.append(process);return process
    def refuse(self,process):raise OSError('synthetic assignment refusal')
    monkeypatch.setattr(bounded.subprocess,'Popen',capture)
    monkeypatch.setattr(bounded._WindowsJob,'assign',refuse)
    try:
        assert bounded.supervise(script,[],timeout_seconds=10,report_path=report)==125
        assert not marker.exists() and all(p.poll() is not None for p in processes)
        result=json.loads(report.read_text());assert result['outcome']=='runner_error'
        assert 'assignment refusal' in ' '.join(result['cleanup_or_runner_errors'])
    finally:
        for process in processes:
            if process.poll() is None:process.kill();process.wait(timeout=5)
