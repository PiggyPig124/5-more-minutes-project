"""Explicit elder-only pair blocking, with atomic consent withdrawal."""
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import select
from ..db import get_db
from ..dependencies import require_elder
from ..models import Account, FamilyInvitation, FamilyLink
from ..family_connection_models import FamilyBlock, FamilyConnectionRequest, FamilyConnectionOperation
from ..family_connection_service import begin_family_guard, withdraw_family_access, set_pair_block, clear_pair_block
from ..task_share_service import digest

router = APIRouter(prefix="/family-links/blocks", tags=["family-blocks"])

class BlockCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    caregiver_id: str = Field(min_length=1, max_length=36)
    request_id: str | None = Field(default=None, min_length=1, max_length=36)
    link_id: str | None = Field(default=None, min_length=1, max_length=36)
    client_operation_id: str = Field(min_length=1, max_length=200)
    @model_validator(mode="after")
    def source(self):
        if bool(self.request_id) == bool(self.link_id):
            raise ValueError("Supply exactly one connection source")
        return self

class Unblock(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_version: int = Field(ge=1)
    client_operation_id: str = Field(min_length=1, max_length=200)

def block_out(db, block, operation=None):
    from .family import _as_utc
    caregiver = db.get(Account, block.caregiver_id)
    result = dict(elder_id=block.elder_id, caregiver_id=block.caregiver_id,
        active=block.active, version=block.version, blocked_at=_as_utc(block.blocked_at),
        caregiver_name=caregiver.display_name, caregiver_email=caregiver.email)
    if operation:
        result["operation_id"] = operation.id
        result["operation_type"] = operation.operation_type
    return result

def previous_operation(db, actor_id, kind, target, key, payload):
    previous = db.scalar(select(FamilyConnectionOperation).where(
        FamilyConnectionOperation.actor_id == actor_id, FamilyConnectionOperation.client_key == key))
    if previous and (previous.operation_type, previous.target_id, previous.payload_hash) != (kind, target, digest(payload)):
        raise HTTPException(409, "Retry key belongs to another operation")
    return previous

def remember(db, actor_id, kind, target, key, payload, block):
    operation = FamilyConnectionOperation(actor_id=actor_id, operation_type=kind,
        target_id=target, client_key=key, payload_hash=digest(payload),
        result={"version": block.version, "active": block.active})
    db.add(operation)
    return operation

@router.get("")
def list_blocks(account=Depends(require_elder), db=Depends(get_db)):
    rows = db.scalars(select(FamilyBlock).where(FamilyBlock.elder_id == account.id)).all()
    return [block_out(db, block) for block in rows]

@router.post("")
def block_pair(payload: BlockCreate, account=Depends(require_elder), db=Depends(get_db)):
    actor_id = account.id
    begin_family_guard(db, actor_id)
    body = payload.model_dump()
    previous = previous_operation(db, actor_id, "block", payload.caregiver_id, payload.client_operation_id, body)
    if previous:
        block = db.get(FamilyBlock, (actor_id, payload.caregiver_id))
        if not block:
            raise HTTPException(410, "Operation state unavailable")
        return block_out(db, block, previous)
    source = db.get(FamilyConnectionRequest, payload.request_id) if payload.request_id else db.get(FamilyLink, payload.link_id)
    if not source or (source.elder_id, source.caregiver_id) != (actor_id, payload.caregiver_id):
        raise HTTPException(404, "Connection source not found")
    caregiver = db.get(Account, payload.caregiver_id)
    if not caregiver or caregiver.role != "caregiver":
        raise HTTPException(404, "Connection source not found")
    block = set_pair_block(db, actor_id, caregiver.id, caregiver.email)
    db.flush()
    operation = remember(db, actor_id, "block", caregiver.id, payload.client_operation_id, body, block)
    db.commit()
    return block_out(db, block, operation)

@router.post("/{caregiver_id}/unblock")
def unblock_pair(caregiver_id: str, payload: Unblock, account=Depends(require_elder), db=Depends(get_db)):
    actor_id = account.id
    begin_family_guard(db, actor_id)
    previous = previous_operation(db, actor_id, "unblock", caregiver_id, payload.client_operation_id, payload.model_dump())
    block = db.get(FamilyBlock, (actor_id, caregiver_id))
    if not block:
        raise HTTPException(404, "Block not found")
    if previous:
        return block_out(db, block, previous)
    if payload.expected_version != block.version:
        raise HTTPException(409, "Block changed")
    clear_pair_block(db, block)
    operation = remember(db, actor_id, "unblock", caregiver_id, payload.client_operation_id, payload.model_dump(), block)
    db.commit()
    return block_out(db, block, operation)
