"""Dialect compilation only: these tests do not connect to PostgreSQL."""
from types import SimpleNamespace

from sqlalchemy.dialects import postgresql

from app.task_share_service import begin_guard


class RecordingSession:
    def __init__(self, dialect):
        self.bind = SimpleNamespace(dialect=SimpleNamespace(name=dialect))
        self.info = {}
        self.calls = []
        self.statement = None

    def rollback(self):
        self.calls.append("rollback")

    def scalars(self, statement):
        self.calls.append("scalars")
        self.statement = statement
        return SimpleNamespace(all=lambda: [])

    def connection(self):
        return self

    def exec_driver_sql(self, sql):
        self.calls.append(sql)


def test_postgresql_account_mutex_compiles_no_key_update():
    db = RecordingSession("postgresql")
    begin_guard(db, ["owner-z", "owner-a", "owner-z"])
    compiled = db.statement.compile(dialect=postgresql.dialect())
    sql = str(compiled)
    assert sql.endswith("FOR NO KEY UPDATE"), sql
    assert "ORDER BY accounts.id" in sql
    assert list(compiled.params.values()) == [["owner-a", "owner-z"]]
    assert db.calls == ["rollback", "scalars"]
    assert db.info["task_share_guard_owners"] == {"owner-a", "owner-z"}


def test_sqlite_guard_keeps_begin_immediate_before_reads():
    db = RecordingSession("sqlite")
    begin_guard(db, ["owner-a"])
    assert db.calls == ["rollback", "BEGIN IMMEDIATE"]
    assert db.statement is None
