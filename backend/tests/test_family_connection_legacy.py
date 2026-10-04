"""Synthetic legacy compatibility regressions; never opens the default DB."""
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import inspect
from app.db import initialize_database, make_engine
from app.main import create_app
from .test_integration import _settings, _register, _headers
from .test_family_messages import link_accounts


def test_accepted_token_cannot_replay_into_a_later_authorization_epoch(tmp_path):
    with TestClient(create_app(_settings(tmp_path / 'accepted-replay.db'))) as client:
        elder = _register(client, 'elder@example.test')
        child = _register(client, 'child@example.test', 'caregiver')
        invitation = client.post('/family-links/invitations', headers=_headers(elder),
            json={'email': child['account']['email'], 'scopes': ['family_messages']}).json()
        accepted = client.post('/family-links/invitations/accept', headers=_headers(child),
            json={'token': invitation['token']})
        assert accepted.status_code == 201
        link_accounts(client, elder, child, ['care_tasks', 'family_messages'])
        replay = client.post('/family-links/invitations/accept', headers=_headers(child),
            json={'token': invitation['token']})
        assert replay.status_code == 410, replay.text


def legacy_engine(tmp_path, status='active', scopes='["family_messages"]'):
    engine = make_engine(f"sqlite:///{tmp_path / 'old-schema.db'}")
    statements = [
        '''CREATE TABLE accounts (id VARCHAR(36) PRIMARY KEY, email VARCHAR(320) NOT NULL UNIQUE,
        display_name VARCHAR(120) NOT NULL, role VARCHAR(20) NOT NULL, password_hash TEXT NOT NULL,
        is_active BOOLEAN NOT NULL, created_at DATETIME NOT NULL)''',
        '''CREATE TABLE family_links (id VARCHAR(36) PRIMARY KEY, elder_id VARCHAR(36) NOT NULL,
        caregiver_id VARCHAR(36) NOT NULL, scopes JSON NOT NULL, status VARCHAR(20) NOT NULL,
        created_at DATETIME NOT NULL, revoked_at DATETIME,
        UNIQUE (elder_id, caregiver_id))''',
        '''CREATE TABLE family_messages (id VARCHAR(36) PRIMARY KEY, link_id VARCHAR(36),
        sender_id VARCHAR(36), recipient_id VARCHAR(36), content TEXT, client_message_id VARCHAR(200),
        source_story_id VARCHAR(36), created_at DATETIME, UNIQUE (sender_id, client_message_id))''',
        '''CREATE TABLE family_invitations (id VARCHAR(36) PRIMARY KEY, elder_id VARCHAR(36) NOT NULL,
        email VARCHAR(320) NOT NULL, token_digest VARCHAR(64) NOT NULL UNIQUE, scopes JSON NOT NULL,
        status VARCHAR(20) NOT NULL, expires_at DATETIME NOT NULL, accepted_by VARCHAR(36),
        created_at DATETIME NOT NULL, accepted_at DATETIME, revoked_at DATETIME)''',
    ]
    with engine.begin() as connection:
        for statement in statements:
            connection.exec_driver_sql(statement)
        for account_id, role in [('elder', 'elder'), ('child', 'caregiver')]:
            connection.exec_driver_sql('INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?, ?)',
                (account_id, f'{account_id}@example.test', account_id, role, 'unused', 1, '2025-01-01'))
        connection.exec_driver_sql('INSERT INTO family_links VALUES (?, ?, ?, ?, ?, ?, ?)',
            ('link', 'elder', 'child', scopes, status, '2025-01-01', None))
        connection.exec_driver_sql('INSERT INTO family_messages VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            ('message', 'link', 'elder', 'child', 'Legacy original text', 'old-key', None, '2025-01-01'))
        for invitation_id, invitation_status in [('accepted', 'accepted'), ('pending', 'pending')]:
            connection.exec_driver_sql('INSERT INTO family_invitations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                (invitation_id, 'elder', 'child@example.test', invitation_id, scopes, invitation_status,
                 '2099-01-01', 'child' if invitation_status == 'accepted' else None,
                 '2025-01-01', '2025-01-01' if invitation_status == 'accepted' else None, None))
    return engine


@pytest.mark.parametrize('status,scopes,revoked', [
    ('active', '["family_messages"]', False),
    ('revoked', '["family_messages"]', True),
    ('active', '["care_tasks"]', True),
])
def test_old_schema_initialization_is_repeatable_and_never_resurrects_history(tmp_path, status, scopes, revoked):
    engine = legacy_engine(tmp_path, status, scopes)
    try:
        initialize_database(engine)
        columns = {column['name'] for column in inspect(engine).get_columns('family_messages')}
        assert {'link_epoch', 'access_revoked_at', 'access_revocation_reason'} <= columns
        with engine.connect() as connection:
            first = dict(connection.exec_driver_sql('SELECT * FROM family_messages').mappings().one())
            link = dict(connection.exec_driver_sql('SELECT * FROM family_links').mappings().one())
            invitations = connection.exec_driver_sql('SELECT * FROM family_invitations ORDER BY id').mappings().all()
        assert link['authorization_epoch'] == 1
        assert first['link_epoch'] == 1
        assert (first['access_revoked_at'] is not None) == revoked
        assert bool(first['access_revocation_reason']) == revoked
        assert first['content'] == 'Legacy original text'
        assert invitations[0]['accepted_epoch'] is None
        assert invitations[0]['accepted_link_id'] is None
        assert invitations[1]['status'] == 'pending'
        initialize_database(engine)
        with engine.connect() as connection:
            second = dict(connection.exec_driver_sql('SELECT * FROM family_messages').mappings().one())
            assert second == first
            if revoked:
                connection.exec_driver_sql("UPDATE family_links SET status='active', scopes='[\"family_messages\"]'")
                connection.commit()
        initialize_database(engine)
        with engine.connect() as connection:
            assert dict(connection.exec_driver_sql('SELECT * FROM family_messages').mappings().one()) == first
    finally:
        engine.dispose()


def test_legacy_accepted_invitation_without_epoch_is_invalid_without_changing_active_link(tmp_path):
    app = create_app(_settings(tmp_path / 'legacy-accepted.db'))
    with TestClient(app) as client:
        elder = _register(client, 'elder@example.test')
        child = _register(client, 'child@example.test', 'caregiver')
        invitation = client.post('/family-links/invitations', headers=_headers(elder),
            json={'email': child['account']['email'], 'scopes': ['family_messages']}).json()
        accepted = client.post('/family-links/invitations/accept', headers=_headers(child),
            json={'token': invitation['token']})
        assert accepted.status_code == 201
        columns = {column['name'] for column in inspect(app.state.engine).get_columns('family_invitations')}
        with app.state.engine.begin() as connection:
            for column in ('accepted_epoch', 'accepted_link_id'):
                if column in columns:
                    connection.exec_driver_sql(f'UPDATE family_invitations SET {column}=NULL WHERE id=?',
                        (invitation['id'],))
        before = client.get('/family-links', headers=_headers(elder)).json()
        replay = client.post('/family-links/invitations/accept', headers=_headers(child),
            json={'token': invitation['token']})
        assert replay.status_code == 410, replay.text
        assert client.get('/family-links', headers=_headers(elder)).json() == before


def test_missing_message_schema_fails_closed_with_503(tmp_path):
    app = create_app(_settings(tmp_path / 'missing-schema.db'))
    with TestClient(app, raise_server_exceptions=False) as client:
        elder = _register(client, 'elder@example.test')
        child = _register(client, 'child@example.test', 'caregiver')
        link_accounts(client, elder, child, ['family_messages'])
        with app.state.engine.begin() as connection:
            connection.exec_driver_sql('DROP TABLE family_messages')
        for path in ('/family-messages', '/family-messages/sent'):
            response = client.get(path, headers=_headers(child))
            assert response.status_code == 503, (path, response.text)


def test_partial_legacy_upgrade_still_permanently_withdraws_nonactive_history(tmp_path):
    engine = legacy_engine(tmp_path, status='revoked')
    try:
        # SQLite additive DDL can survive an interrupted startup before the
        # remaining marker columns and legacy backfill are completed.
        with engine.begin() as connection:
            connection.exec_driver_sql('ALTER TABLE family_messages ADD COLUMN link_epoch INTEGER NOT NULL DEFAULT 1')
        initialize_database(engine)
        with engine.connect() as connection:
            message = dict(connection.exec_driver_sql('SELECT * FROM family_messages').mappings().one())
        assert message['content'] == 'Legacy original text'
        assert message['link_epoch'] == 1
        assert message['access_revoked_at'] is not None
        assert message['access_revocation_reason']
        initialize_database(engine)
        with engine.connect() as connection:
            assert dict(connection.exec_driver_sql('SELECT * FROM family_messages').mappings().one()) == message
    finally:
        engine.dispose()
