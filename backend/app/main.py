"""FastAPI application entry point for Anxin Companion."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import Settings
from .smartplay_community_search import SmartPlayCommunitySearch
from .db import initialize_database, make_engine, make_session_factory
from .group_realtime import GroupRealtimeHub
from .orchestrator import ConversationOrchestrator
from .routers import actions, auth, community, conversations, family, guest, tasks
from .routers import family_messages, groups, family_requests, family_blocks
from .routers import memories, stories, resources
from .routers import answer_cards
from .resource_service import seed_resources
from .routers import safety, check_ins, speech, scam, activity_catalog
from .seed_extras import seed_community_activities, seed_scam_resources
from .routers import notifications
from .care_service import collect_notifications
from .models import Account
from .schemas import CheckInTriggerRequest
from fastapi import Request
from sqlalchemy import select
import logging


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    if settings.environment == "production" and not settings.auth_secret:
        raise RuntimeError("AUTH_SECRET must be configured when APP_ENV=production")
    engine = make_engine(settings.database_url)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        initialize_database(app.state.engine)
        with app.state.session_factory() as db:
            seed_resources(db)
            seed_community_activities(db)
            seed_scam_resources(db)

        async def reap_guest_sessions() -> None:
            while True:
                await asyncio.sleep(60)
                guest.cleanup_expired_sessions(app.state.guest_sessions)

        guest_reaper = asyncio.create_task(reap_guest_sessions())
        async def run_care_schedules() -> None:
            while True:
                await asyncio.sleep(60)
                try:
                    async with app.state.care_lock:
                        with app.state.session_factory() as db:
                            accounts = db.scalars(select(Account).where(Account.is_active.is_(True))).all()
                            for account in accounts:
                                collect_notifications(db, account)
                                if account.role == 'elder':
                                    await check_ins.generate_check_in(CheckInTriggerRequest(),
                                        Request({'type': 'http', 'app': app}), account, db)
                except Exception:
                    logging.getLogger(__name__).exception('Care scheduler iteration failed')

        care_scheduler = asyncio.create_task(run_care_schedules())
        try:
            yield
        finally:
            guest_reaper.cancel()
            care_scheduler.cancel()
            try:
                await guest_reaper
            except asyncio.CancelledError:
                pass
            try:
                await care_scheduler
            except asyncio.CancelledError:
                pass
        app.state.engine.dispose()

    app = FastAPI(title=settings.app_name, version="0.2.0", lifespan=lifespan)
    app.state.settings = settings
    app.state.engine = engine
    app.state.session_factory = make_session_factory(engine)
    app.state.group_realtime = GroupRealtimeHub()
    app.state.care_lock = asyncio.Lock()
    app.state.orchestrator = ConversationOrchestrator(settings)
    # The official public JSON snapshot is enabled; legacy HTML adapters remain
    # unregistered. User queries and identity are only used for local filtering.
    app.state.community_search = SmartPlayCommunitySearch()
    # Guest transcripts live only in this process and are removed after
    # inactivity or an explicit DELETE. They never create database rows.
    app.state.guest_sessions = {}

    # Flutter's local development client runs on a different origin. A
    # deployment can place the API behind a stricter gateway policy.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(answer_cards.router)
    app.include_router(auth.router)
    app.include_router(guest.router)
    app.include_router(community.router)
    app.include_router(family_blocks.router)
    app.include_router(family_requests.router)
    app.include_router(family.router)
    app.include_router(family_messages.router)
    app.include_router(groups.router)
    app.include_router(memories.router)
    app.include_router(stories.router)
    app.include_router(resources.router)
    app.include_router(conversations.router)
    app.include_router(actions.router)
    app.include_router(tasks.router)
    app.include_router(notifications.router)
    for module in (safety, check_ins, speech, scam, activity_catalog):
        app.include_router(module.router)

    @app.get("/health", tags=["system"])
    def health() -> dict[str, object]:
        adapter = app.state.orchestrator.adapter
        return {
            "status": "ok",
            "mode": adapter.mode,
            "demo_mode": adapter.mode == "deterministic_demo",
            "langgraph": app.state.orchestrator._graph is not None,
            "database": "postgresql" if settings.database_url.startswith("postgres") else "sqlite",
        }

    return app


app = create_app()
