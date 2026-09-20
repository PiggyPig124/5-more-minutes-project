"""Authenticated retrieval routes for verified public Hong Kong resources."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from ..db import get_db
from ..dependencies import get_current_account
from ..models import Account
from ..resource_models import ResourceSearchRequest, ResourceSearchResponse
from ..resource_service import ResourceService

router = APIRouter(prefix="/resources", tags=["resources"])


def get_resource_service(request: Request) -> ResourceService:
    """Cache one service per app while keeping the public table separate."""

    service = getattr(request.app.state, "resource_service", None)
    if service is None:
        service = ResourceService()
        request.app.state.resource_service = service
    return service


@router.get("/search", response_model=ResourceSearchResponse)
async def search_resources_get(
    query: str = Query(min_length=1, max_length=500),
    limit: int = Query(default=4, ge=1, le=20),
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
    service: ResourceService = Depends(get_resource_service),
) -> ResourceSearchResponse:
    """Search the public collection for either an elder or caregiver."""

    del account
    if not query.strip():
        raise HTTPException(status_code=422, detail="query cannot be blank")
    return await run_in_threadpool(service.search, query, limit, db=db)


@router.post("/search", response_model=ResourceSearchResponse, status_code=status.HTTP_200_OK)
async def search_resources_post(
    payload: ResourceSearchRequest,
    account: Account = Depends(get_current_account),
    db: Session = Depends(get_db),
    service: ResourceService = Depends(get_resource_service),
) -> ResourceSearchResponse:
    """JSON equivalent of the GET search route used by mobile clients."""

    del account
    return await run_in_threadpool(service.search, payload.query, payload.limit, db=db)
