from concurrent.futures import ThreadPoolExecutor
from threading import Event
from time import monotonic
import pytest
from sqlalchemy import event
from tests.test_memory_controls import setup, auth, enable, headers
from app.routers import memories

@pytest.mark.parametrize('different_owner', [False, True])
@pytest.mark.parametrize('operation', ['confirm', 'create', 'save', 'patch', 'search', 'chat', 'check_in', 'check_in_new'])
def test_live_api_get_then_confirm(setup, monkeypatch, different_owner, operation):
    app, client, (owner, second, _) = setup
    enable(client, owner)
    if different_owner:
        enable(client, second)
    read_account = second if different_owner else owner
    created = client.post('/memories', headers=headers(client, owner), json={'content':'Synthetic concurrent candidate','kind':'experience'})
    assert created.status_code == 201, created.text
    memory_id = created.json()['id']
    if operation in {'patch', 'search'}:
        assert client.post(f'/memories/{memory_id}/confirm', headers=headers(client, owner)).status_code == 200
    conversation = client.post('/conversations', headers=auth(owner), json={'title':'Synthetic concurrent chat'})
    assert conversation.status_code == 201
    if operation in {'check_in', 'check_in_new'}:
        from app.safety_models import CheckInSchedule
        from app.routers import check_ins
        with app.state.session_factory() as db:
            db.add(CheckInSchedule(elder_id=owner['account']['id'], enabled=True, frequency='daily', check_in_time='00:00'))
            db.commit()
        monkeypatch.setattr(check_ins, 'quiet_or_paused', lambda settings, now: False)
    confirm_headers = headers(client, owner)
    revision = int(confirm_headers['X-Memory-Revision'])
    requests = {
        'confirm': ('post', f'/memories/{memory_id}/confirm', None, 200),
        'create': ('post', '/memories', {'content':'Synthetic second candidate','kind':'experience'}, 201),
        'save': ('post', '/memories/save', {'content':'Synthetic explicit saved memory','kind':'experience'}, 201),
        'patch': ('patch', f'/memories/{memory_id}', {'content':'Synthetic edited memory'}, 200),
        'search': ('post', '/memories/search', {'query':'Synthetic concurrent candidate'}, 200),
        'check_in_new': ('post', '/check-ins/trigger', {}, 200),
        'check_in': ('post', '/check-ins/trigger', {'conversation_id':conversation.json()['id']}, 200),
        'chat': ('post', f'/conversations/{conversation.json()['id']}/messages', {'content':'Hello synthetic world','client_message_id':'synthetic-concurrent-chat'}, 200),
    }
    method, url, payload, expected_status = requests[operation]
    def mutate():
        kwargs={'headers':confirm_headers}
        if payload is not None: kwargs['json']=payload
        return getattr(client, method)(url, **kwargs)
    read_locked, confirm_attempt = Event(), Event()
    original = memories._control_counts
    def ordered_counts(db, owner_id):
        result = original(db, owner_id)
        read_locked.set()
        assert confirm_attempt.wait(4), 'confirm never reached the SQL transaction'
        return result
    monkeypatch.setattr(memories, '_control_counts', ordered_counts)
    def before_sql(conn, cursor, statement, parameters, context, executemany):
        if read_locked.is_set() and (statement == 'BEGIN IMMEDIATE' or (operation == 'check_in_new' and statement.startswith('INSERT INTO conversations'))):
            confirm_attempt.set()
    sql_errors = []
    def on_sql_error(context):
        sql_errors.append(str(context.original_exception))
    engine = app.state.session_factory.kw['bind']
    event.listen(engine, 'handle_error', on_sql_error)
    event.listen(engine, 'before_cursor_execute', before_sql)
    try:
        started = monotonic()
        with ThreadPoolExecutor(max_workers=2) as pool:
            reading = pool.submit(client.get, '/memories/control-state', headers=auth(read_account))
            assert read_locked.wait(4), 'GET did not acquire transaction'
            confirming = pool.submit(mutate)
            confirmed = confirming.result(timeout=15)
            read = reading.result(timeout=15)
        print(f'\nDIAGNOSTIC different_owner={different_owner} operation={operation} GET={read.status_code} confirm={confirmed.status_code} elapsed={monotonic()-started:.2f}s body={confirmed.text}')
        assert read.status_code == 200, read.text
        print(f'SQL_ERRORS={sql_errors}')
        assert confirmed.status_code == expected_status, confirmed.text
        assert sql_errors == []
        with app.state.session_factory() as db:
            from app.memory_models import PersonalMemory
            from app.memory_service import memory_revision
            from app.models import Message
            from sqlalchemy import select
            if operation in {'confirm', 'create', 'save', 'patch'}:
                persisted=db.get(PersonalMemory, confirmed.json()['id'])
                assert persisted.owner_id == owner['account']['id']
                assert memory_revision(db, persisted.owner_id) == revision+1
                assert persisted.content == (payload['content'] if payload else 'Synthetic concurrent candidate')
                assert persisted.status == ('candidate' if operation in {'create', 'patch'} else 'confirmed')
            elif operation in {'chat', 'check_in', 'check_in_new'}:
                rows=db.scalars(select(Message).where(Message.conversation_id==(confirmed.json()['conversation_id'] if operation == 'check_in_new' else conversation.json()['id']))).all()
                assert len(rows)==2 and {row.ordinal for row in rows}=={1,2}
                if operation in {'check_in', 'check_in_new'}: assert confirmed.json()['triggered'] is True
            else:
                assert confirmed.json()['items'][0]['id']==memory_id
                assert memory_revision(db, owner['account']['id'])==revision
        if operation in {'confirm', 'create', 'save', 'patch'}:
            stale_id=confirmed.json()['id'] if operation == 'patch' else memory_id
            assert client.post(f'/memories/{stale_id}/confirm', headers=confirm_headers).status_code == 409
    finally:
        event.remove(engine, 'before_cursor_execute', before_sql)
        event.remove(engine, 'handle_error', on_sql_error)

