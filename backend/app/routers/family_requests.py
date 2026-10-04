"""Caregiver requests are inert until their target elder explicitly approves."""
from datetime import datetime, timedelta, timezone
from typing import Literal
from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from ..db import get_db
from ..dependencies import get_current_account, require_elder
from ..models import Account, FamilyLink
from ..family_connection_models import FamilyConnectionRequest, FamilyConnectionOperation
from ..task_share_service import digest
from ..family_connection_service import begin_family_guard, pair_is_blocked, withdraw_family_access, approve_request
from .family import _link_out, _as_utc

router = APIRouter(prefix="/family-links/requests", tags=["family-requests"])

class RequestCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    elder_email: str = Field(min_length=3, max_length=320)
    client_request_id: str = Field(min_length=1, max_length=200)
    @field_validator("elder_email")
    @classmethod
    def email(cls, value):
        value = value.strip().lower()
        if "@" not in value:
            raise ValueError("Invalid email")
        return value

class Decision(BaseModel):
    model_config = ConfigDict(extra="forbid")
    decision: Literal["approve", "reject"]
    expected_version: int = Field(ge=1)
    scopes: list[str] = Field(default_factory=list)
    @model_validator(mode="after")
    def check_scopes(self):
        if self.decision == "approve" and not self.scopes:
            raise ValueError("Select at least one scope")
        if len(set(self.scopes)) != len(self.scopes) or set(self.scopes) - {"care_tasks", "family_messages"}:
            raise ValueError("Invalid scopes")
        if self.decision == "reject" and self.scopes:
            raise ValueError("Reject grants no scopes")
        return self

class Withdraw(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_version: int = Field(ge=1)

def request_out(db, request, incoming=False):
    result = {key: getattr(request, key) for key in (
        "id", "elder_id", "caregiver_id", "status", "version", "created_at", "expires_at", "decided_at")}
    for key in ('created_at', 'expires_at', 'decided_at'):
        if result[key] is not None:
            result[key] = _as_utc(result[key])
    result["elder_email"] = request.submitted_email
    if incoming:
        caregiver = db.get(Account, request.caregiver_id)
        result["requester_name"] = caregiver.display_name
        result["requester_email"] = caregiver.email
    return result

def pending_or_terminal(db, request):
    if request.status == "pending" and _as_utc(request.expires_at) <= datetime.now(timezone.utc):
        request.status = "expired"
        request.version += 1
        request.decided_at = datetime.now(timezone.utc)
        db.commit()
    if request.status != "pending":
        raise HTTPException(410, "Request is no longer available")

def _create_request(payload: RequestCreate, response: Response,
    account=Depends(get_current_account), db=Depends(get_db)):
    if account.role != "caregiver":
        raise HTTPException(403, "Only caregivers can create requests")
    actor_id = account.id
    own_key = db.scalar(select(FamilyConnectionOperation).where(
        FamilyConnectionOperation.actor_id == actor_id,
        FamilyConnectionOperation.client_key == payload.client_request_id))
    if own_key and (own_key.operation_type != "create_request" or own_key.payload_hash != digest(payload.elder_email)):
        raise HTTPException(409, "Retry key belongs to another request")
    elder = db.scalar(select(Account).where(Account.email == payload.elder_email))
    if not elder or elder.role != "elder" or not elder.is_active:
        raise HTTPException(400, "Unable to create request")
    begin_family_guard(db, elder.id)
    elder = db.get(Account, elder.id)
    if not elder or not elder.is_active or pair_is_blocked(db, elder.id, actor_id):
        raise HTTPException(400, "Unable to create request")
    own_key = db.scalar(select(FamilyConnectionOperation).where(
        FamilyConnectionOperation.actor_id == actor_id,
        FamilyConnectionOperation.client_key == payload.client_request_id))
    if own_key:
        if own_key.operation_type != "create_request" or own_key.payload_hash != digest(payload.elder_email):
            raise HTTPException(409, "Retry key belongs to another request")
        original = db.get(FamilyConnectionRequest, own_key.result.get("request_id"))
        if not original or original.caregiver_id != actor_id:
            raise HTTPException(410, "Request is no longer available")
        response.status_code = 200
        return request_out(db, original)
    previous = db.scalar(select(FamilyConnectionRequest).where(
        FamilyConnectionRequest.caregiver_id == actor_id,
        FamilyConnectionRequest.client_request_id == payload.client_request_id))
    if previous:
        if previous.submitted_email != payload.elder_email:
            raise HTTPException(409, "Retry key belongs to another request")
        response.status_code = 200
        return request_out(db, previous)
    link = db.scalar(select(FamilyLink).where(FamilyLink.elder_id == elder.id, FamilyLink.caregiver_id == actor_id))
    if link and link.status == "active":
        raise HTTPException(409, "A connection already exists")
    pending = db.scalars(select(FamilyConnectionRequest).where(
        FamilyConnectionRequest.elder_id == elder.id, FamilyConnectionRequest.caregiver_id == actor_id,
        FamilyConnectionRequest.status == "pending").order_by(FamilyConnectionRequest.created_at)).all()
    for existing in pending:
        if _as_utc(existing.expires_at) > datetime.now(timezone.utc):
            record_request_key(db, actor_id, payload, existing)
            db.commit()
            response.status_code = 200
            return request_out(db, existing)
        existing.status = "expired"
        existing.version += 1
        existing.decided_at = datetime.now(timezone.utc)
    request = FamilyConnectionRequest(elder_id=elder.id, caregiver_id=actor_id,
        submitted_email=payload.elder_email, client_request_id=payload.client_request_id,
        expires_at=datetime.now(timezone.utc) + timedelta(days=7))
    db.add(request)
    db.flush()
    record_request_key(db, actor_id, payload, request)
    db.commit()
    return request_out(db, request)

@router.get("")
def list_requests(account=Depends(get_current_account), db=Depends(get_db)):
    field = FamilyConnectionRequest.elder_id if account.role == "elder" else FamilyConnectionRequest.caregiver_id
    rows = db.scalars(select(FamilyConnectionRequest).where(field == account.id)
        .order_by(FamilyConnectionRequest.created_at.desc())).all()
    # Lists do not mutate pending records without their owner guard.
    return [request_out(db, row, account.role == "elder") for row in rows]

@router.post("/{request_id}/decision")
def decide_request(request_id: str, payload: Decision, account=Depends(require_elder), db=Depends(get_db)):
    actor_id = account.id
    begin_family_guard(db, actor_id)
    request = db.get(FamilyConnectionRequest, request_id)
    if not request or request.elder_id != actor_id:
        raise HTTPException(404, "Request not found")
    if request.status == "approved" and payload.decision == "approve":
        if set(payload.scopes) != set(request.approved_scopes or []):
            raise HTTPException(409, "Approval differs from original decision")
        link = db.get(FamilyLink, request.approved_link_id)
        if (not link or link.status != "active" or link.authorization_epoch != request.approved_epoch
                or pair_is_blocked(db, actor_id, request.caregiver_id)):
            raise HTTPException(410, "Approval authorization has ended")
        if payload.expected_version not in {request.version, request.version - 1}:
            raise HTTPException(409, "Request changed")
        return _link_out(db, link)
    if request.status == "rejected" and payload.decision == "reject":
        if payload.expected_version not in {request.version, request.version - 1}:
            raise HTTPException(409, "Request changed")
        return request_out(db, request, True)
    pending_or_terminal(db, request)
    if payload.expected_version != request.version:
        raise HTTPException(409, "Request changed")
    if pair_is_blocked(db, actor_id, request.caregiver_id):
        raise HTTPException(403, "Connection unavailable")
    if payload.decision == "approve":
        caregiver = db.get(Account, request.caregiver_id)
        if not caregiver or not caregiver.is_active or caregiver.role != "caregiver":
            raise HTTPException(403, "Connection unavailable")
        link = approve_request(db, request, payload.scopes)
        request.approved_link_id = link.id
        request.approved_epoch = link.authorization_epoch
        request.approved_scopes = list(payload.scopes)
        request.status = "approved"
    else:
        request.status = "rejected"
    request.version += 1
    request.decided_at = datetime.now(timezone.utc)
    db.commit()
    return _link_out(db, link) if payload.decision == "approve" else request_out(db, request, True)

@router.post("/{request_id}/withdraw")
def withdraw_request(request_id: str, payload: Withdraw, account=Depends(get_current_account), db=Depends(get_db)):
    if account.role != "caregiver":
        raise HTTPException(403, "Only caregivers can withdraw requests")
    actor_id = account.id
    candidate = db.get(FamilyConnectionRequest, request_id)
    if not candidate or candidate.caregiver_id != actor_id:
        raise HTTPException(404, "Request not found")
    begin_family_guard(db, candidate.elder_id)
    request = db.get(FamilyConnectionRequest, request_id)
    if request.status == "revoked" and payload.expected_version in {request.version, request.version - 1}:
        return request_out(db, request)
    pending_or_terminal(db, request)
    if payload.expected_version != request.version:
        raise HTTPException(409, "Request changed")
    request.status = "revoked"
    request.version += 1
    request.decided_at = datetime.now(timezone.utc)
    db.commit()
    return request_out(db, request)


def record_request_key(db, actor_id, payload, request):
    db.add(FamilyConnectionOperation(actor_id=actor_id, operation_type="create_request",
        target_id=request.elder_id, client_key=payload.client_request_id,
        payload_hash=digest(payload.elder_email), result={"request_id": request.id}))


@router.post("", status_code=201)
def create_request(payload: RequestCreate, response: Response,
    account=Depends(get_current_account), db=Depends(get_db)):
    try:
        return _create_request(payload, response, account, db)
    except IntegrityError:
        # Different elders use different owner mutexes on PostgreSQL. The
        # actor/key unique constraints still arbitrate their concurrent keys.
        db.rollback()
        raise HTTPException(409, "Request changed; retry with the original key")
