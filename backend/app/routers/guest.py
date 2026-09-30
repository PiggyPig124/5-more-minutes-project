"""Ephemeral unauthenticated conversation sessions."""

from __future__ import annotations

import re
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from ..db import get_db
from ..community_search import community_listing_type_from_query, explicit_community_query, topic_from_query
from ..resource_models import ResourceSearchResponse
from ..resource_service import search_resources

router = APIRouter(prefix="/guest", tags=["guest"])
GUEST_TTL = timedelta(minutes=30)


class GuestMessage(BaseModel):
    content: str = Field(min_length=1, max_length=10000)

    @field_validator("content")
    @classmethod
    def trim_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("message cannot be blank")
        return value


def _now() -> datetime:
    return datetime.now(timezone.utc)


def cleanup_expired_sessions(sessions: dict[str, dict[str, Any]]) -> None:
    now = _now()
    expired = [key for key, value in sessions.items() if value["expires_at"] <= now]
    for key in expired:
        sessions.pop(key, None)


def _session(request: Request, session_id: str) -> dict[str, Any]:
    sessions: dict[str, dict[str, Any]] = request.app.state.guest_sessions
    active = sessions.get(session_id)
    if active is None:
        raise HTTPException(status_code=404, detail="Guest session not found or expired")
    if active["expires_at"] <= _now():
        sessions.pop(session_id, None)
        raise HTTPException(status_code=404, detail="Guest session not found or expired")
    return active


@router.post("/sessions", status_code=status.HTTP_201_CREATED)
def create_session(request: Request) -> dict[str, Any]:
    cleanup_expired_sessions(request.app.state.guest_sessions)
    session_id = secrets.token_urlsafe(32)
    expires_at = _now() + GUEST_TTL
    request.app.state.guest_sessions[session_id] = {
        "expires_at": expires_at,
        "recent_context": [],
        "rolling_summary": "",
    }
    return {"session_id": session_id, "expires_at": expires_at}


@router.get("/resources/search", response_model=ResourceSearchResponse)
async def search_public_resources(
    query: str = Query(min_length=1, max_length=500),
    limit: int = Query(default=4, ge=1, le=20),
    db: Session = Depends(get_db),
) -> ResourceSearchResponse:
    """Search sourced public guidance without requiring a personal account."""

    if not query.strip():
        raise HTTPException(status_code=422, detail="query cannot be blank")
    return ResourceSearchResponse(**(await search_resources(db, query, limit)))


@router.post("/sessions/{session_id}/messages")
async def send_message(
    session_id: str,
    payload: GuestMessage,
    request: Request,
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    cleanup_expired_sessions(request.app.state.guest_sessions)
    session = _session(request, session_id)
    context: dict[str, Any] = {
        "rolling_summary": session["rolling_summary"],
        "recent_context": list(session["recent_context"]),
        "memory_sources": [],
        "memory_retrieval_mode": "disabled",
    }
    resource_query = bool(re.search(
        r"福利|津貼|津贴|補助|补助|資助|资助|醫療費|医疗费|覆診費|覆诊费|"
        r"照顧者支援|照顾者支援|社區照顧|社区照顾|長者中心|长者中心|"
        r"\bwelfare\b|\bsubsid(?:y|ies)\b|\bfee waiver\b|\bcaregiver support\b",
        payload.content,
        re.IGNORECASE,
    ))
    resource_result = {"items": [], "retrieval_mode": "not_requested", "conflicts": []}
    if resource_query:
        resource_result = await search_resources(db, payload.content[:500])
    context["resource_query"] = resource_query
    context["resource_sources"] = resource_result["items"]
    context["resource_conflicts"] = resource_result["conflicts"]
    community_result = None
    if explicit_community_query(payload.content):
        community_result = await run_in_threadpool(
            request.app.state.community_search.search,
            listing_type=community_listing_type_from_query(payload.content),
            topic=topic_from_query(payload.content),
        )
        from fastapi.encoders import jsonable_encoder
        context["community_search"] = jsonable_encoder({
            "search_state": community_result["search_state"],
            "message": community_result["message"],
            "checked_at": community_result["checked_at"],
            "sources": community_result["sources"],
            "items": community_result["items"][:8],
        })
    db.rollback()

    reply = await request.app.state.orchestrator.run(context, payload.content)
    if reply.mode == "error":
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"message": reply.text, "mode": "error"},
        )

    # Recheck in case the session expired while a provider request was in flight.
    session = _session(request, session_id)
    turns = session["recent_context"]
    turns.extend([
        {"role": "user", "content": payload.content},
        {"role": "assistant", "content": reply.text},
    ])
    session["recent_context"] = turns[-12:]
    session["rolling_summary"] = ""
    session["expires_at"] = _now() + GUEST_TTL
    response = {
        "reply": reply.text,
        "mode": reply.mode,
        "expires_at": session["expires_at"],
    }
    if community_result is not None:
        response.update({
            "community_sources": jsonable_encoder(community_result["sources"]),
            "community_search_state": community_result["search_state"],
            "community_results": community_result["items"][:8],
            "community_search_checked_at": community_result["checked_at"],
        })
    return response


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
def end_session(session_id: str, request: Request) -> Response:
    request.app.state.guest_sessions.pop(session_id, None)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
