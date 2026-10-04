"""Database engine, session, and ORM base helpers."""

from __future__ import annotations

from collections.abc import Generator

from fastapi import Request
from sqlalchemy import create_engine, event
from sqlalchemy import inspect, select, func
from sqlalchemy.exc import IntegrityError
import logging
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker


class Base(DeclarativeBase):
    """Base class for all persisted entities."""


def make_engine(database_url: str) -> Engine:
    """Create an engine suitable for SQLite development or PostgreSQL.

    SQLite is used for local development and tests. PostgreSQL receives the
    normal SQLAlchemy pooling defaults; deployments can tune the URL and pool
    settings at the platform layer.
    """

    connect_args = {"check_same_thread": False} if database_url.startswith("sqlite") else {}
    engine = create_engine(database_url, connect_args=connect_args, pool_pre_ping=True)
    if engine.dialect.name == "sqlite":
        @event.listens_for(engine, "connect")
        def enable_foreign_keys(connection, _record):
            connection.execute("PRAGMA foreign_keys=ON")
    return engine


def make_session_factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(bind=engine, class_=Session, expire_on_commit=False, autoflush=False)


def get_db(request: Request) -> Generator[Session, None, None]:
    """Yield the request's database session and always close it."""

    session_factory = request.app.state.session_factory
    db = session_factory()
    try:
        yield db
    finally:
        db.close()


def initialize_database(engine: Engine) -> None:
    # Importing models before create_all registers every table on Base.metadata.
    from . import models  # noqa: F401
    from . import collaboration_models  # noqa: F401
    from . import community_models, memory_models, resource_models  # noqa: F401
    from . import group_models, safety_models, scam_models, activity_catalog_models  # noqa: F401
    from . import care_models, task_share_models, family_connection_models  # noqa: F401

    if engine.dialect.name == "postgresql":
        with engine.begin() as connection:
            connection.exec_driver_sql("CREATE EXTENSION IF NOT EXISTS vector")

    from . import answer_card_models  # noqa: F401

    Base.metadata.create_all(bind=engine)
    # This project's startup schema setup predates a migration framework.
    # Keep the one additive memory field compatible with existing databases.
    columns = {column["name"] for column in inspect(engine).get_columns("personal_memories")}
    if "topic_key" not in columns:
        with engine.begin() as connection:
            connection.exec_driver_sql("ALTER TABLE personal_memories ADD COLUMN topic_key VARCHAR(120)")

    _ensure_family_authorization_columns(engine)
    _ensure_catalog_interest_index(engine)


def _ensure_catalog_interest_index(engine: Engine) -> None:
    """Upgrade duplicate-free legacy tables without deleting user records."""
    from .activity_catalog_models import CommunityInterest
    table = CommunityInterest.__table__
    index = next(item for item in table.indexes if item.name == "uq_community_interest_pair")
    duplicates = select(table.c.elder_id).group_by(
        table.c.elder_id, table.c.activity_id
    ).having(func.count() > 1).limit(1)
    try:
        with engine.begin() as connection:
            if engine.dialect.name == "sqlite":
                connection.exec_driver_sql("BEGIN IMMEDIATE")
            elif engine.dialect.name == "postgresql":
                # Serialize parallel startup migrations on this index only.
                connection.exec_driver_sql("SELECT pg_advisory_xact_lock(642731901)")
            if connection.execute(duplicates).first() is not None:
                logging.getLogger(__name__).warning(
                    "Existing duplicate catalog interests preserved; unique index deferred."
                )
                return
            index.create(connection, checkfirst=True)
    except IntegrityError:
        # A direct legacy writer may race startup. Defer only if duplicate
        # pairs actually exist after rollback; unrelated failures still raise.
        with engine.connect() as connection:
            if connection.execute(duplicates).first() is None:
                raise
        logging.getLogger(__name__).warning(
            "Duplicate catalog interests preserved during index migration; index deferred."
        )


def _ensure_family_authorization_columns(engine):
    """Additive startup compatibility; never infer an accepted token's epoch."""
    additions = {
        "family_links": {"authorization_epoch": "INTEGER NOT NULL DEFAULT 1"},
        "family_invitations": {"accepted_link_id": "VARCHAR(36)", "accepted_epoch": "INTEGER"},
        "family_messages": {"link_epoch": "INTEGER NOT NULL DEFAULT 1",
            "access_revoked_at": "TIMESTAMP", "access_revocation_reason": "VARCHAR(120)"},
    }
    # Backfill only while upgrading old message columns; later startup must not
    # reclassify or resurrect any historical message.
    old_messages = not {"link_epoch", "access_revoked_at", "access_revocation_reason"}.issubset({c["name"] for c in inspect(engine).get_columns("family_messages")})
    with engine.begin() as connection:
        for table, fields in additions.items():
            columns = {c["name"] for c in inspect(connection).get_columns(table)}
            for name, ddl in fields.items():
                if name not in columns:
                    connection.exec_driver_sql(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}")
        if old_messages:
            # ORM JSON decoding is portable across SQLite and PostgreSQL.
            from .models import FamilyLink
            from .collaboration_models import FamilyMessage
            with Session(bind=connection) as db:
                links = {link.id: link for link in db.scalars(select(FamilyLink)).all()}
                from datetime import datetime, timezone
                for message in db.scalars(select(FamilyMessage)).all():
                    link = links.get(message.link_id)
                    if message.access_revoked_at is None and (not link or link.status != "active" or "family_messages" not in (link.scopes or [])):
                        message.access_revoked_at = datetime.now(timezone.utc)
                        message.access_revocation_reason = "legacy_authorization_unavailable"
                db.flush()
