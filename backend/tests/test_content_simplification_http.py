"""HTTP contract, synthetic accounts/text and explicitly mocked provider only."""
import asyncio
import copy
import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.config import Settings
from app.db import Base
from app.main import create_app

ORIGINAL = 'At the fictional club, people gather for friendly conversation.'
SIMPLER = 'People meet and chat at the fictional club.'
REAL_CLIENT = httpx.AsyncClient


@pytest.fixture
def setup(tmp_path, monkeypatch):
    captured = []
    response = {'finish_reason': 'stop', 'text': SIMPLER, 'status': 200}
    def provider(request):
        captured.append(json.loads(request.content))
        if response.get('on_request'):
            response['on_request']()
        if response.get('timeout'):
            raise httpx.ReadTimeout('synthetic provider timeout')
        content = response.get('raw', json.dumps(dict(text=response['text'], proposed_task=None, memory_actions=[])))
        return httpx.Response(response['status'], json={'choices': [{
            'finish_reason': response['finish_reason'], 'message': {'content': content}}]})
    async def forbidden(*args, **kwargs):
        raise AssertionError('Real external HTTP forbidden')
    monkeypatch.setattr(httpx.AsyncHTTPTransport, 'handle_async_request', forbidden)
    monkeypatch.setattr(httpx, 'AsyncClient', lambda **kw:
        REAL_CLIENT(transport=httpx.MockTransport(provider), **kw))
    app = create_app(Settings(database_url=f'sqlite:///{tmp_path / "synthetic.db"}',
        auth_secret='synthetic-http-secret', model_api_key='synthetic-not-a-secret',
        model_base_url='https://model.example.invalid/v1', model_name='existing-mock-model'))
    with TestClient(app) as client:
        account = client.post('/auth/register', json={'email':'synthetic@example.invalid',
            'password':'synthetic-password-123','display_name':'Synthetic','role':'elder'}).json()
        headers = {'Authorization': 'Bearer ' + account['access_token']}
        session = client.post('/guest/sessions').json()['session_id']
        yield app, client, headers, session, captured, response


def payload(**changes):
    return dict(text=ORIGINAL, locale='en', explicit_request=True, **changes)


def database_state(app):
    with app.state.session_factory() as db:
        return {table.name: [tuple(row) for row in db.execute(select(table)).all()]
                for table in Base.metadata.sorted_tables}


@pytest.mark.parametrize('guest', [False, True])
def test_explicit_http_request_is_read_only_and_uses_only_selected_text(setup, guest):
    app, client, headers, session, captured, response = setup
    before = database_state(app)
    guest_before = copy.deepcopy(app.state.guest_sessions)
    path = f'/guest/sessions/{session}/simplifications' if guest else '/content/simplifications'
    result = client.post(path, headers={} if guest else headers, json=payload())
    assert result.status_code == 200, result.text
    assert result.json() == dict(status='draft', original=ORIGINAL, simpler=SIMPLER,
                                 reason=None, independently_verified=False)
    assert database_state(app) == before
    assert app.state.guest_sessions == guest_before
    assert len(captured) == 1 and len(captured[0]['messages']) == 2
    selected = json.loads(captured[0]['messages'][-1]['content'])
    assert selected['selected_answer'] == ORIGINAL
    assert 'memory_id' not in selected and 'conversation_id' not in selected


def test_missing_configuration_returns_honest_unavailable_without_provider(setup):
    app, client, headers, session, captured, response = setup
    app.state.settings.model_api_key = None
    result = client.post('/content/simplifications', headers=headers, json=payload())
    assert result.status_code == 200
    assert result.json()['status'] == 'unavailable'
    assert result.json()['reason'] == 'model_unavailable'
    assert result.json()['original'] == ORIGINAL and result.json()['simpler'] is None
    assert captured == []


@pytest.mark.parametrize('change', [dict(explicit_request=False),dict(explicit_request='true'),
    dict(text=' '),dict(text='x'*10001),dict(locale='fr'),dict(memory_id='synthetic'),dict(provider='new')])
def test_invalid_or_implicit_requests_never_call_provider(setup, change):
    app, client, headers, session, captured, response = setup
    body=payload(); body.update(change)
    result=client.post('/content/simplifications',headers=headers,json=body)
    assert result.status_code == 422
    assert captured == []


def test_signed_route_reuses_auth_and_guest_route_requires_live_session(setup):
    app, client, headers, session, captured, response = setup
    assert client.post('/content/simplifications',json=payload()).status_code == 401
    assert client.post('/guest/sessions/missing/simplifications',json=payload()).status_code == 404
    app.state.guest_sessions[session]['expires_at']=datetime.now(timezone.utc)-timedelta(seconds=1)
    assert client.post(f'/guest/sessions/{session}/simplifications',json=payload()).status_code == 404
    assert captured == []


@pytest.mark.parametrize('bad', [dict(timeout=True),dict(status=503),dict(text=''),
    dict(raw='{"text":"unfinished'),dict(finish_reason='length'),dict(finish_reason=None)])
def test_failed_incomplete_or_empty_provider_output_never_becomes_success(setup, bad):
    app, client, headers, session, captured, response = setup
    response.update(bad)
    before=database_state(app)
    result=client.post('/content/simplifications',headers=headers,json=payload())
    assert result.status_code == 200 and result.json()['status']=='unavailable'
    assert result.json()['simpler'] is None and result.json()['original']==ORIGINAL
    assert database_state(app)==before


@pytest.mark.parametrize('change', ['delete', 'expire', 'replace'])
def test_guest_result_cannot_outlive_its_session(setup, change):
    app, client, headers, session, captured, response = setup
    def mutate():
        if change == 'delete':
            app.state.guest_sessions.pop(session)
        elif change == 'expire':
            app.state.guest_sessions[session]['expires_at']=datetime.now(timezone.utc)-timedelta(seconds=1)
        else:
            app.state.guest_sessions[session]=copy.deepcopy(app.state.guest_sessions[session])
    response['on_request']=mutate
    result=client.post(f'/guest/sessions/{session}/simplifications',json=payload())
    assert result.status_code==404 and 'simpler' not in result.json()


def test_http_cancellation_propagates_without_guest_history_or_database_write(setup,monkeypatch):
    app, client, headers, session, captured, response = setup
    before=database_state(app);guest_before=copy.deepcopy(app.state.guest_sessions)
    async def exercise():
        started=asyncio.Event()
        async def provider(request):
            started.set()
            await asyncio.Future()
        monkeypatch.setattr(httpx,'AsyncClient',lambda **kw:REAL_CLIENT(transport=httpx.MockTransport(provider),**kw))
        async with REAL_CLIENT(transport=httpx.ASGITransport(app=app),base_url='http://synthetic') as connection:
            pending=asyncio.create_task(connection.post(f'/guest/sessions/{session}/simplifications',json=payload()))
            await asyncio.wait_for(started.wait(),timeout=2)
            pending.cancel()
            with pytest.raises(asyncio.CancelledError):await pending
    asyncio.run(exercise())
    assert database_state(app)==before and app.state.guest_sessions==guest_before
