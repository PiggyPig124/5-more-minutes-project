"""Database engine, session, and ORM base helpers."""

from __future__ import annotations

from collections.abc import Generator

from fastapi import Request
from sqlalchemy import create_engine
from sqlalchemy import inspect
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
    return create_engine(database_url, connect_args=connect_args, pool_pre_ping=True)


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
    from . import group_models  # noqa: F401

    if engine.dialect.name == "postgresql":
        with engine.begin() as connection:
            connection.exec_driver_sql("CREATE EXTENSION IF NOT EXISTS vector")

    Base.metadata.create_all(bind=engine)
    # This project's startup schema setup predates a migration framework.
    # Keep the one additive memory field compatible with existing databases.
    columns = {column["name"] for column in inspect(engine).get_columns("personal_memories")}
    if "topic_key" not in columns:
        with engine.begin() as connection:
            connection.exec_driver_sql("ALTER TABLE personal_memories ADD COLUMN topic_key VARCHAR(120)")
