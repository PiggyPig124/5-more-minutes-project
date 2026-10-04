"""Interest uniqueness without silently deleting legacy user records.

All databases are temporary and local. SQLAlchemy events widen real races or
introduce real database constraint failures; route/session logic is not mocked.
"""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, BrokenBarrierError

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event, inspect, select
from sqlalchemy.exc import IntegrityError

from app.activity_catalog_models import CommunityActivity, CommunityInterest
from app.config import Settings
from app.db import initialize_database
from app.main import create_app
from tests.test_integration import _headers, _register


@pytest.fixture
def interest_catalog(tmp_path):
    app = create_app(Settings(database_url=f"sqlite:///{tmp_path / 'catalog-interest.db'}",
                              auth_secret="interest-race-test", demo_mode=True))
    with TestClient(app) as client:
        elder = _register(client, "interest-owner@example.test")
        other = _register(client, "interest-other@example.test")
        with app.state.session_factory() as db:
            db.add_all([
                CommunityActivity(id="race-activity", title="Race activity", description="Class",
                                  organizer="Test", district="Test", verified=True),
                CommunityActivity(id="other-activity", title="Other activity", description="Class",
                                  organizer="Test", district="Test", verified=True),
            ])
            db.commit()
        yield app, client, elder, other


def rows(app):
    with app.state.session_factory() as db:
        return [(row.id, row.elder_id, row.activity_id) for row in
                db.scalars(select(CommunityInterest).order_by(CommunityInterest.id)).all()]


def replace_with_legacy_table(app, *, unique_status=False):
    # Deliberately reproduce the pre-feature schema without pair uniqueness.
    # SQL does not depend on the new index's name or model metadata.
    with app.state.engine.begin() as connection:
        connection.exec_driver_sql("DROP TABLE community_interests")
        status_constraint = " UNIQUE" if unique_status else ""
        connection.exec_driver_sql(f"""
            CREATE TABLE community_interests (
                id VARCHAR(36) PRIMARY KEY NOT NULL,
                elder_id VARCHAR(36) NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                activity_id VARCHAR(120) NOT NULL REFERENCES community_activities(id) ON DELETE CASCADE,
                status VARCHAR(20) NOT NULL{status_constraint},
                created_at DATETIME NOT NULL
            )
        """)


def seed_interests(app, owner, activity_id, count=1):
    with app.state.session_factory() as db:
        db.add_all([CommunityInterest(elder_id=owner['account']['id'], activity_id=activity_id)
                    for _ in range(count)])
        db.commit()


def has_pair_uniqueness(app):
    inspector = inspect(app.state.engine)
    constraints = inspector.get_unique_constraints("community_interests")
    indexes = [index for index in inspector.get_indexes("community_interests") if index['unique']]
    return any(set(item['column_names']) == {'elder_id', 'activity_id'}
               for item in constraints + indexes)


def test_concurrent_interest_requests_create_one_row_without_server_error(interest_catalog):
    app, client, elder, other = interest_catalog
    gate = Barrier(2)

    def widen_interest_read_race(connection, cursor, statement, parameters, context, executemany):
        if statement.lstrip().upper().startswith("SELECT") and "FROM community_interests" in statement:
            try:
                # With serialization, the first transaction reaches this alone
                # and continues after a bounded timeout. Without it both stale
                # reads arrive together, making duplicate inserts deterministic.
                gate.wait(timeout=0.5)
            except BrokenBarrierError:
                pass

    event.listen(app.state.engine, 'after_cursor_execute', widen_interest_read_race)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: client.post('/community/catalog/interest/race-activity',
                                                          headers=_headers(elder)), range(2)))
    finally:
        event.remove(app.state.engine, 'after_cursor_execute', widen_interest_read_race)
    assert all(result.status_code == 201 for result in results), [result.text for result in results]
    assert sorted(result.json()['already_expressed'] for result in results) == [False, True]
    matching = [row for row in rows(app) if row[1:] == (elder['account']['id'], 'race-activity')]
    assert len(matching) == 1
    assert client.get('/community/catalog/interests', headers=_headers(other)).json()['interests'] == []
    assert client.post('/community/catalog/interest/race-activity', headers=_headers(other)).status_code == 201
    assert len(rows(app)) == 2


def test_fresh_database_enforces_unique_owner_activity_pair(interest_catalog):
    app, client, elder, other = interest_catalog
    seed_interests(app, elder, 'race-activity')
    with app.state.session_factory() as db:
        db.add(CommunityInterest(elder_id=elder['account']['id'], activity_id='race-activity'))
        with pytest.raises(IntegrityError):
            db.commit()
    assert has_pair_uniqueness(app)


def test_legacy_unique_pair_receives_index_without_changing_records(interest_catalog):
    app, client, elder, other = interest_catalog
    replace_with_legacy_table(app)
    seed_interests(app, elder, 'race-activity')
    seed_interests(app, other, 'race-activity')
    original = rows(app)
    initialize_database(app.state.engine)
    initialize_database(app.state.engine)
    assert rows(app) == original
    assert has_pair_uniqueness(app)
    with app.state.session_factory() as db:
        db.add(CommunityInterest(elder_id=elder['account']['id'], activity_id='race-activity'))
        with pytest.raises(IntegrityError):
            db.commit()


def test_legacy_duplicates_retained_until_owner_explicitly_withdraws(interest_catalog):
    app, client, elder, other = interest_catalog
    replace_with_legacy_table(app)
    seed_interests(app, elder, 'race-activity', count=2)
    seed_interests(app, elder, 'other-activity')
    seed_interests(app, other, 'race-activity')
    original = rows(app)
    initialize_database(app.state.engine)
    initialize_database(app.state.engine)
    assert rows(app) == original
    assert not has_pair_uniqueness(app)
    expressed = client.post('/community/catalog/interest/race-activity', headers=_headers(elder))
    assert expressed.status_code == 201 and expressed.json()['already_expressed'] is True
    assert rows(app) == original
    assert client.delete('/community/catalog/interest/race-activity', headers=_headers(elder)).status_code == 200
    expected = [row for row in original if row[1:] != (elder['account']['id'], 'race-activity')]
    assert rows(app) == expected
    assert client.delete('/community/catalog/interest/race-activity', headers=_headers(elder)).status_code == 404
    # Once the user's explicit withdrawal has removed duplicates, a later
    # startup may add the deferred index without deleting any remaining rows.
    initialize_database(app.state.engine)
    assert rows(app) == expected and has_pair_uniqueness(app)


@pytest.mark.parametrize('constraint', ['foreign_key', 'unrelated_unique'])
def test_non_pair_integrity_errors_do_not_report_success(interest_catalog, constraint):
    app, client, elder, other = interest_catalog
    if constraint == 'unrelated_unique':
        replace_with_legacy_table(app, unique_status=True)
        seed_interests(app, other, 'other-activity')
    original = rows(app)

    def break_foreign_key(connection, cursor, statement, parameters, context, executemany):
        if statement.lstrip().upper().startswith('INSERT INTO COMMUNITY_INTERESTS'):
            # Real FK violation on INSERT. Rollback must preserve the activity;
            # no route/session method is mocked and no external writer is used.
            connection.exec_driver_sql("DELETE FROM community_activities WHERE id = ?", ('race-activity',))

    if constraint == 'foreign_key':
        event.listen(app.state.engine, 'before_cursor_execute', break_foreign_key)
    try:
        failed_client = TestClient(app, raise_server_exceptions=False)
        result = failed_client.post('/community/catalog/interest/race-activity', headers=_headers(elder))
        assert result.status_code == 500, result.text
    finally:
        if constraint == 'foreign_key':
            event.remove(app.state.engine, 'before_cursor_execute', break_foreign_key)
    assert rows(app) == original
    with app.state.session_factory() as db:
        assert db.get(CommunityActivity, 'race-activity') is not None
